/**
 * sainsmart-relay16 - fast, indexable, fail-safe firmware and host tools
 * for SainSmart 16-channel USB relay boards
 *
 * Copyright (c) 2025-2026 Mike Johnson (Mycal)
 *
 * Author:       https://anchorid.net/resolve/4ff7ed97-b78f-4ae6-9011-5af714ee241c
 * Repository:   https://github.com/lowerpower/sainsmart-relay16
 *
 * SPDX-License-Identifier: MIT
 * See LICENSE file for full terms.
 *
 * Built for the Reared In Steel crew's fire art.
 */
/*
 * ============================================================================
 * core.c - relay16 protocol core, full build (see docs/PROTOCOL.md)
 * ============================================================================
 *
 * This is the whole protocol: line parsing, commands, replies, relay timers,
 * the failsafe and the settings block. It knows nothing about the chip.
 *
 * It is compiled twice:
 *
 *   firmware/stc15.c  #includes it for the board (SDCC, 8051, ~2.2 KB)
 *   sim/sim.c         #includes it for the Linux simulator (gcc)
 *
 * so test/test_protocol.py, which drives the simulator, exercises exactly
 * this code. compat.h papers over the SDCC memory-space keywords for gcc.
 *
 * The platform provides four things:
 *
 *   hw_apply(mask)           drive the 16 relays, bit 0 = relay 1
 *   hw_putc(c)               send one byte to the host
 *   hw_ee_read / write /     one EEPROM sector, byte addressed; write can
 *     erase                  only clear bits (flash), so erase comes first
 *
 * and calls in four places:
 *
 *   core_init()              once at power-up: load settings, relays off
 *   core_rx(c)               for every received byte (on the board, from the
 *                            UART interrupt)
 *   core_poll()              continuously from the main loop: runs a
 *                            completed line
 *   core_tick()              once per millisecond from the main loop
 *
 * Commands (each gets exactly one reply line, "?" for anything invalid):
 *
 *   r            read                 -> state, 4 hex digits
 *   s N / c N    relay N on / off     -> state
 *   h XXXX       set all 16 (hex)     -> state
 *   p N [MS]     pulse relay N        -> state
 *   d N [MS]     default pulse ms     -> value
 *   m N [MS]     max-on ms for N      -> value
 *   t [MS]       host-silence failsafe-> value
 *   i [ID]       board ID 0-255       -> value
 *   w            save settings        -> state (only with all relays off)
 *   v            version              -> "relay16 1 id N"
 *
 * The lite firmware (firmware/lite/relay16_lite.asm) implements the same
 * protocol minus p/d/m, and the same EEPROM layout, by hand in assembly.
 */
#include "compat.h"

#define FW_VERSION "1"                  /* reported by v                    */
#define NRELAY     16                   /* relays per board                 */
#define LBUF       20                   /* longest command line we keep;    */
                                        /*   longer lines answer "?"        */
#define CFG_MAGIC  0xA5                 /* marks a settings block we wrote  */
#define CFG_SEED   0x5A                 /* checksum seed, so an all-zero    */
                                        /*   block doesn't pass             */

/* --------------------------------------------------------- platform hooks */

void    hw_apply(uint16_t mask);
void    hw_putc(uint8_t c);
uint8_t hw_ee_read(uint8_t addr);
void    hw_ee_write(uint8_t addr, uint8_t d);
void    hw_ee_erase(void);

/* ------------------------------------------------------------------ state */

/*
 * The settings block, exactly as it sits in EEPROM. The lite firmware reads
 * and writes the same 69 bytes (it only uses magic, id and failsafe, and
 * writes the tables as zeros), so a board keeps its ID across lite <-> full
 * reflashes. Changing this layout breaks that: bump CFG_MAGIC if you do.
 *
 * On SDCC the struct is packed, so sum lands at offset 68. On gcc there may
 * be padding, which doesn't matter: the simulator's EEPROM is only ever read
 * back by the simulator.
 */
typedef struct {
    uint8_t  magic;              /* CFG_MAGIC when valid                       */
    uint8_t  id;                 /* board ID; 0 = unassigned                   */
    uint16_t failsafe;           /* ms of host silence before all off, 0 = off */
    uint16_t pulse[NRELAY];      /* default pulse ms for "p N", 0 = none       */
    uint16_t maxon[NRELAY];      /* max continuous on ms, 0 = no limit         */
    uint8_t  sum;                /* CFG_SEED + sum of every byte above         */
} cfg_t;

static XDATA cfg_t cfg;                 /* live settings (EEPROM copy, edited */
                                        /*   in RAM until w saves them)       */
static IDATA uint16_t left[NRELAY];     /* per relay: ms until it turns itself*/
                                        /*   off, 0 = no timer running        */
static IDATA uint8_t lbuf[LBUF];        /* the command line being received    */
static volatile uint8_t llen, lready;   /* line length so far; 1 = a complete */
                                        /*   line waiting for core_poll       */
                                        /*   (both touched by the UART ISR)   */
static uint16_t state, idle, val;       /* relay mask; ms since last valid    */
                                        /*   command; parser's number         */
static uint8_t pi, pn;                  /* parser position, line length       */

/* ----------------------------------------------------------------- config */

/*
 * Checksum over everything before the sum byte, seeded so a block of all
 * zeros (or all 0xFF, a freshly erased sector) never passes.
 */
static uint8_t cfg_sum(void)
{
    uint8_t i, s = CFG_SEED;
    uint8_t XDATA *p = (uint8_t XDATA *)&cfg;
    for (i = 0; i < offsetof(cfg_t, sum); i++)
        s += p[i];
    return s;
}

/*
 * Read the block. If the magic or the checksum is wrong (blank chip, never
 * saved, or corrupted) start from defaults: everything 0, which means ID
 * unassigned, failsafe off, no pulse defaults and no max-on limits.
 */
static void cfg_load(void)
{
    uint8_t i;
    uint8_t XDATA *p = (uint8_t XDATA *)&cfg;
    for (i = 0; i < sizeof(cfg); i++)
        p[i] = hw_ee_read(i);
    if (cfg.magic != CFG_MAGIC || cfg.sum != cfg_sum()) {
        for (i = 0; i < sizeof(cfg); i++)
            p[i] = 0;
        cfg.magic = CFG_MAGIC;
    }
}

/*
 * Write the block back: checksum, erase the sector, then every byte. The
 * sum is the last byte written, so a save cut short by power loss leaves a
 * block that fails its checksum (defaults next boot) rather than a block
 * that looks valid with half-written contents.
 */
static void cfg_save(void)
{
    uint8_t i;
    uint8_t XDATA *p = (uint8_t XDATA *)&cfg;
    cfg.sum = cfg_sum();
    hw_ee_erase();
    for (i = 0; i < sizeof(cfg); i++)
        hw_ee_write(i, p[i]);
}

/* ----------------------------------------------------------------- relays */

/*
 * Every relay change goes through here, so the max-on interlock can't be
 * bypassed. For each relay:
 *
 *   going (or staying) off   cancel its timer
 *   going from off to on     start its timer at its max-on limit (0 = none)
 *   staying on               leave its timer alone, so repeating "s N"
 *                            can't extend a relay past its limit
 *
 * Then drive the pins.
 */
static void set_state(uint16_t m)
{
    uint8_t i;
    uint16_t b = 1;
    for (i = 0; i < NRELAY; i++, b <<= 1) {
        if (!(m & b))
            left[i] = 0;                  /* off: no timer                    */
        else if (!(state & b))
            left[i] = cfg.maxon[i];       /* newly on: arm the interlock      */
    }
    state = m;
    hw_apply(m);
}

/*
 * Once a millisecond. Two jobs:
 *
 * 1. Relay timers. A running timer counts down; when it hits 0 that relay
 *    turns off. This one mechanism serves both p (pulse) and m (max-on):
 *    a pulse just loads a shorter count.
 *
 * 2. The host-silence failsafe. idle counts ms since the last valid command
 *    (core_poll zeroes it). When it reaches cfg.failsafe, every relay goes
 *    off once; idle then parks at the limit until the next valid command.
 */
void core_tick(void)
{
    uint8_t i;
    uint16_t b = 1, off = 0;
    for (i = 0; i < NRELAY; i++, b <<= 1)
        if (left[i] && !--left[i])        /* timer running and just expired? */
            off |= b;
    if (off)
        set_state(state & (uint16_t)~off);
    if (cfg.failsafe && idle < cfg.failsafe && ++idle == cfg.failsafe && state)
        set_state(0);                     /* host went quiet: all off         */
}

/* ----------------------------------------------------------------- output */

static const CODE uint16_t pow10[] = { 10000, 1000, 100, 10, 1 };

/* every reply line ends CR LF, whatever the host sent */
static void eol(void)
{
    hw_putc('\r');
    hw_putc('\n');
}

/* 16 bits as exactly 4 uppercase hex digits, most significant first */
static void puthex(uint16_t v)
{
    uint8_t i, d;
    for (i = 0; i < 4; i++) {
        d = (uint8_t)(v >> 12);           /* top nibble                      */
        hw_putc(d < 10 ? '0' + d : 'A' - 10 + d);
        v <<= 4;                          /* next nibble to the top          */
    }
}

/*
 * 0-65535 in decimal without leading zeros, by repeated subtraction of
 * powers of ten. On the 8051 that avoids pulling in SDCC's 16-bit divide
 * and modulo library routines.
 */
static void putdec(uint16_t v)
{
    uint8_t i, d, lead = 1;
    for (i = 0; i < 5; i++) {
        d = '0';
        while (v >= pow10[i]) {           /* how many times does it fit?     */
            v -= pow10[i];
            d++;
        }
        if (d != '0' || i == 4)           /* first non-zero, or the last     */
            lead = 0;                     /*   digit: stop suppressing        */
        if (!lead)
            hw_putc(d);
    }
}

/* a constant string from code memory */
static void putstr(const CODE char *s)
{
    while (*s)
        hw_putc(*s++);
}

/* ----------------------------------------------------------------- parser */

/*
 * The parser works on a complete line in lbuf[0..pn). pi is the read
 * position. Commands are one letter, optionally followed by numbers, with
 * any number of spaces between fields. Tabs were already turned into spaces
 * and control characters into '#' by core_rx.
 */

/* skip spaces; return the next character lowercased, or 0 at end of line */
static uint8_t peek(void)
{
    while (pi < pn && lbuf[pi] == ' ')
        pi++;
    return pi < pn ? (lbuf[pi] | 0x20) : 0;   /* | 0x20 lowercases letters;  */
                                              /*   digits already have it     */
}

/*
 * Read a number into val: decimal, or hex for h. Returns how many digits
 * were read, 0 if there was no number or it doesn't fit in 16 bits (more
 * than 4 hex digits, or decimal over 65535). Out-of-range numbers are
 * refused rather than wrapped: "t 70000" must answer "?", not quietly set a
 * 4464 ms failsafe.
 */
static uint8_t getnum(uint8_t hex)
{
    uint8_t c, d, n = 0;
    val = 0;
    peek();                               /* skip leading spaces             */
    while (pi < pn) {
        c = lbuf[pi] | 0x20;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (hex && c >= 'a' && c <= 'f')
            d = c - ('a' - 10);
        else
            break;                        /* end of the number               */
        if (hex) {
            if (n == 4)
                return 0;                 /* a 5th hex digit: too big        */
            val = (val << 4) | d;
        } else {
            if (val > 6553 || (val == 6553 && d > 5))
                return 0;                 /* val * 10 + d would pass 65535   */
            val = (val << 3) + (val << 1) + d;  /* val * 10 + d, no multiply */
        }
        n++;
        pi++;
    }
    return n;
}

/* relay number 1-16 as an index 0-15, or 0xFF if missing or out of range */
static uint8_t getrelay(void)
{
    if (!getnum(0) || val == 0 || val > NRELAY)
        return 0xFF;
    return (uint8_t)val - 1;
}

/*
 * An optional decimal number, then nothing else on the line.
 * Returns 0 for junk, 1 for no number, 2 for a number (in val).
 */
static uint8_t optnum(void)
{
    uint8_t got = getnum(0);
    if (peek())
        return 0;                         /* something after it: junk        */
    return got ? 2 : 1;
}

/*
 * Run one complete line. Sends its reply and returns 1, or returns 0 and
 * sends nothing, in which case core_poll answers "?". Every path that
 * changes relays goes through set_state.
 */
static uint8_t do_line(void)
{
    uint8_t cmd, r, o;
    uint16_t b;
    uint16_t XDATA *p;

    pi = 0;
    cmd = peek();                         /* the command letter              */
    pi++;

    switch (cmd) {
    case 'r':                             /* read, save, version: no args    */
    case 'w':
    case 'v':
        if (peek())
            return 0;
        if (cmd == 'v') {
            putstr("relay16 " FW_VERSION " id ");
            putdec(cfg.id);
            eol();
            return 1;
        }
        if (cmd == 'w') {
            if (state)
                return 0;            /* save only with all relays off: the  */
                                     /*   erase stalls the CPU for ms        */
            cfg_save();
        }
        break;                       /* r and w reply with the state        */

    case 'h':                        /* h XXXX: all 16 relays at once       */
        if (!getnum(1) || peek())
            return 0;
        set_state(val);
        break;

    case 'i':                        /* settings without a relay number:    */
    case 't':                        /*   set if given, always report       */
        o = optnum();
        if (!o)
            return 0;
        if (cmd == 'i') {
            if (o == 2) {
                if (val > 255)
                    return 0;        /* IDs are one byte                    */
                cfg.id = (uint8_t)val;
            }
            putdec(cfg.id);
        } else {
            if (o == 2) {
                cfg.failsafe = val;
                idle = 0;            /* new limit: start counting afresh    */
            }
            putdec(cfg.failsafe);
        }
        eol();
        return 1;

    case 's':                        /* everything that takes a relay N     */
    case 'c':
    case 'p':
    case 'd':
    case 'm':
        r = getrelay();
        if (r == 0xFF)
            return 0;
        b = (uint16_t)1 << r;        /* relay N's bit in the state mask     */
        if (cmd == 'd' || cmd == 'm') {
            /* per-relay settings: d = default pulse, m = max-on limit */
            p = cmd == 'd' ? &cfg.pulse[r] : &cfg.maxon[r];
            o = optnum();
            if (!o)
                return 0;
            if (o == 2)
                *p = val;            /* takes effect next time it turns on  */
            putdec(*p);
            eol();
            return 1;
        }
        if (cmd == 'p') {
            /*
             * Pulse: on now, off after MS (or the relay's default). The
             * board times it, so the burst length doesn't depend on USB or
             * host timing, and it still ends if the host dies mid-burst.
             */
            o = optnum();
            if (!o)
                return 0;
            if (o == 1)
                val = cfg.pulse[r];  /* no MS given: use the default        */
            if (!val)
                return 0;            /* no time given and no default        */
            set_state(state | b);    /* on (arms max-on if newly on)        */
            if (!left[r] || val < left[r])
                left[r] = val;       /* never outlast the max-on budget     */
            break;
        }
        if (peek())
            return 0;                /* s N / c N take nothing more         */
        set_state(cmd == 's' ? state | b : state & (uint16_t)~b);
        break;

    default:
        return 0;                    /* unknown command                     */
    }

    puthex(state);                   /* relay commands reply with the state */
    eol();
    return 1;
}

/* -------------------------------------------------------------------- API */

/* power-up: settings from EEPROM, then every relay off */
void core_init(void)
{
    cfg_load();
    set_state(0);
}

/*
 * One received byte. On the board this runs in the UART interrupt, so it
 * only builds the line; core_poll does the work in the main loop.
 *
 * While a complete line is waiting (lready), further bytes are dropped: the
 * protocol is one command at a time, and the host waits for each reply.
 * An over-long line keeps counting (llen) past LBUF so core_poll can tell
 * it was too long and answer "?".
 *
 * SDCC: functions called from an interrupt mustn't share overlaid locals
 * with the main program, hence nooverlay.
 */
#ifdef __SDCC
#pragma nooverlay
#endif
void core_rx(uint8_t c)
{
    if (lready)
        return;                      /* one command at a time               */
    if (c == '\r' || c == '\n') {    /* end of line: CR, LF or CR LF        */
        if (llen)
            lready = 1;              /* empty lines are ignored, which also */
        return;                      /*   swallows the LF of a CR LF         */
    }
    if (c == '\t')
        c = ' ';                     /* tabs count as spaces                */
    else if (c < ' ' || c > '~')
        c = '#';                     /* poison the line: reply "?"          */
    if (llen < LBUF)
        lbuf[llen] = c;
    if (llen != 0xFF)
        llen++;                      /* saturates: still "too long"         */
}

/*
 * From the main loop: if a complete line is waiting, run it. A valid
 * command restarts the failsafe countdown; an invalid one ("?") does not,
 * so a host spewing garbage still gets its relays dropped.
 */
void core_poll(void)
{
    if (!lready)
        return;
    pn = llen;
    if (pn > LBUF || !do_line()) {   /* too long, or rejected               */
        hw_putc('?');
        eol();
    } else {
        idle = 0;                    /* valid: the host is alive            */
    }
    llen = 0;                        /* ready for the next line             */
    lready = 0;
}
