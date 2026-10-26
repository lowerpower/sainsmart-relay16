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
 * core.c - relay16 protocol core (see docs/PROTOCOL.md)
 *
 * Hardware independent. Included by stc15.c for the board and by
 * sim/sim.c for the host simulator, so the tests exercise this exact code.
 *
 * The platform provides:
 *   hw_apply(mask)        drive the 16 relays, bit0 = relay 1
 *   hw_putc(c)            send one byte to the host
 *   hw_ee_read/write/erase  one EEPROM sector, byte addressed
 * and calls:
 *   core_init()           once at power-up
 *   core_rx(c)            for every received byte (may be from an ISR)
 *   core_poll()           continuously from the main loop
 *   core_tick()           once per millisecond from the main loop
 */
#include "compat.h"

#define FW_VERSION "1"
#define NRELAY     16
#define LBUF       20
#define CFG_MAGIC  0xA5
#define CFG_SEED   0x5A

void    hw_apply(uint16_t mask);
void    hw_putc(uint8_t c);
uint8_t hw_ee_read(uint8_t addr);
void    hw_ee_write(uint8_t addr, uint8_t d);
void    hw_ee_erase(void);

typedef struct {
    uint8_t  magic;
    uint8_t  id;                 /* 0 = unassigned */
    uint16_t failsafe;           /* ms of host silence before all off, 0 = off */
    uint16_t pulse[NRELAY];      /* default pulse ms for "p N", 0 = none */
    uint16_t maxon[NRELAY];      /* max continuous on ms, 0 = no limit */
    uint8_t  sum;
} cfg_t;

static XDATA cfg_t cfg;
static IDATA uint16_t left[NRELAY];   /* ms until auto-off, 0 = none */
static IDATA uint8_t lbuf[LBUF];
static volatile uint8_t llen, lready;
static uint16_t state, idle, val;
static uint8_t pi, pn;

/* ---------------------------------------------------------------- config */

static uint8_t cfg_sum(void)
{
    uint8_t i, s = CFG_SEED;
    uint8_t XDATA *p = (uint8_t XDATA *)&cfg;
    for (i = 0; i < offsetof(cfg_t, sum); i++)
        s += p[i];
    return s;
}

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

static void cfg_save(void)
{
    uint8_t i;
    uint8_t XDATA *p = (uint8_t XDATA *)&cfg;
    cfg.sum = cfg_sum();
    hw_ee_erase();
    for (i = 0; i < sizeof(cfg); i++)
        hw_ee_write(i, p[i]);
}

/* ---------------------------------------------------------------- relays */

static void set_state(uint16_t m)
{
    uint8_t i;
    uint16_t b = 1;
    for (i = 0; i < NRELAY; i++, b <<= 1) {
        if (!(m & b))
            left[i] = 0;
        else if (!(state & b))
            left[i] = cfg.maxon[i];       /* newly on: arm the interlock */
    }
    state = m;
    hw_apply(m);
}

void core_tick(void)
{
    uint8_t i;
    uint16_t b = 1, off = 0;
    for (i = 0; i < NRELAY; i++, b <<= 1)
        if (left[i] && !--left[i])
            off |= b;
    if (off)
        set_state(state & (uint16_t)~off);
    if (cfg.failsafe && idle < cfg.failsafe && ++idle == cfg.failsafe && state)
        set_state(0);
}

/* ---------------------------------------------------------------- output */

static const CODE uint16_t pow10[] = { 10000, 1000, 100, 10, 1 };

static void eol(void)
{
    hw_putc('\r');
    hw_putc('\n');
}

static void puthex(uint16_t v)
{
    uint8_t i, d;
    for (i = 0; i < 4; i++) {
        d = (uint8_t)(v >> 12);
        hw_putc(d < 10 ? '0' + d : 'A' - 10 + d);
        v <<= 4;
    }
}

static void putdec(uint16_t v)
{
    uint8_t i, d, lead = 1;
    for (i = 0; i < 5; i++) {
        d = '0';
        while (v >= pow10[i]) {
            v -= pow10[i];
            d++;
        }
        if (d != '0' || i == 4)
            lead = 0;
        if (!lead)
            hw_putc(d);
    }
}

static void putstr(const CODE char *s)
{
    while (*s)
        hw_putc(*s++);
}

/* ---------------------------------------------------------------- parser */

/* skip spaces; next char lowercased, or 0 at end of line */
static uint8_t peek(void)
{
    while (pi < pn && lbuf[pi] == ' ')
        pi++;
    return pi < pn ? (lbuf[pi] | 0x20) : 0;
}

/* number into val; returns 0 if none, too long or > 65535 */
static uint8_t getnum(uint8_t hex)
{
    uint8_t c, d, n = 0;
    val = 0;
    peek();
    while (pi < pn) {
        c = lbuf[pi] | 0x20;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (hex && c >= 'a' && c <= 'f')
            d = c - ('a' - 10);
        else
            break;
        if (hex) {
            if (n == 4)
                return 0;
            val = (val << 4) | d;
        } else {
            if (val > 6553 || (val == 6553 && d > 5))
                return 0;
            val = (val << 3) + (val << 1) + d;
        }
        n++;
        pi++;
    }
    return n;
}

/* relay number 1-16 as index 0-15, 0xFF if invalid */
static uint8_t getrelay(void)
{
    if (!getnum(0) || val == 0 || val > NRELAY)
        return 0xFF;
    return (uint8_t)val - 1;
}

/* optional number then end of line; returns 0 on junk */
static uint8_t optnum(void)
{
    uint8_t got = getnum(0);
    if (peek())
        return 0;
    return got ? 2 : 1;
}

static uint8_t do_line(void)
{
    uint8_t cmd, r, o;
    uint16_t b;
    uint16_t XDATA *p;

    pi = 0;
    cmd = peek();
    pi++;

    switch (cmd) {
    case 'r':
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
                return 0;            /* save only with all relays off */
            cfg_save();
        }
        break;

    case 'h':
        if (!getnum(1) || peek())
            return 0;
        set_state(val);
        break;

    case 'i':
    case 't':
        o = optnum();
        if (!o)
            return 0;
        if (cmd == 'i') {
            if (o == 2) {
                if (val > 255)
                    return 0;
                cfg.id = (uint8_t)val;
            }
            putdec(cfg.id);
        } else {
            if (o == 2) {
                cfg.failsafe = val;
                idle = 0;
            }
            putdec(cfg.failsafe);
        }
        eol();
        return 1;

    case 's':
    case 'c':
    case 'p':
    case 'd':
    case 'm':
        r = getrelay();
        if (r == 0xFF)
            return 0;
        b = (uint16_t)1 << r;
        if (cmd == 'd' || cmd == 'm') {
            p = cmd == 'd' ? &cfg.pulse[r] : &cfg.maxon[r];
            o = optnum();
            if (!o)
                return 0;
            if (o == 2)
                *p = val;
            putdec(*p);
            eol();
            return 1;
        }
        if (cmd == 'p') {
            o = optnum();
            if (!o)
                return 0;
            if (o == 1)
                val = cfg.pulse[r];
            if (!val)
                return 0;            /* no time given and no default */
            set_state(state | b);
            if (!left[r] || val < left[r])
                left[r] = val;       /* never outlast the max-on budget */
            break;
        }
        if (peek())
            return 0;
        set_state(cmd == 's' ? state | b : state & (uint16_t)~b);
        break;

    default:
        return 0;
    }

    puthex(state);
    eol();
    return 1;
}

/* ------------------------------------------------------------------ API */

void core_init(void)
{
    cfg_load();
    set_state(0);
}

#ifdef __SDCC
#pragma nooverlay
#endif
void core_rx(uint8_t c)
{
    if (lready)
        return;                      /* one command at a time */
    if (c == '\r' || c == '\n') {
        if (llen)
            lready = 1;              /* empty lines are ignored */
        return;
    }
    if (c == '\t')
        c = ' ';
    else if (c < ' ' || c > '~')
        c = '#';                     /* poison the line: reply "?" */
    if (llen < LBUF)
        lbuf[llen] = c;
    if (llen != 0xFF)
        llen++;
}

void core_poll(void)
{
    if (!lready)
        return;
    pn = llen;
    if (pn > LBUF || !do_line()) {
        hw_putc('?');
        eol();
    } else {
        idle = 0;
    }
    llen = 0;
    lready = 0;
}
