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
 * stc15.c - relay16 full firmware, board support for the STC15W401AS family
 * ============================================================================
 *
 * The chip-specific half of the full build: pins, UART, the 1 ms timer, the
 * watchdog and the EEPROM (IAP). The protocol itself is core.c, #included
 * below, so this file only has to supply core.c's hw_ hooks and a main loop.
 *
 * Needs a 4 KB or 8 KB part (STC15W404AS / STC15W408AS, same SOP-20 pinout):
 * the full build is ~2.2 KB. The stock 1 KB STC15W401AS runs the lite build
 * (firmware/lite/relay16_lite.asm) instead.
 *
 * Clock: internal RC, trimmed to 22.1184 MHz by stcgal at flash time
 *        (-t 22118.4), a clock that divides exactly to standard baud rates.
 *
 * Serial: UART1 moved to its alternate pins P3.6 (RxD_2) / P3.7 (TxD_2),
 *         the ones wired to the CH340G USB chip. 115200 8N1, baud clock
 *         from timer 2. Receive and transmit are interrupt driven.
 *
 * Relay -> pin, from the vendor schematic (two ULN2803s, pin high = relay on):
 *
 *   K1 P5.5   K2 P5.4   K3 P3.5   K4 P3.4   K5 P3.3   K6 P3.2
 *   K7 P3.1   K8 P3.0   K9 P1.1   K10 P1.0  K11-K16 P1.2-P1.7
 *
 *   P5.4 is the chip's reset pin: it only drives K2 because the board is
 *   flashed with reset_pin_enabled=false (make flash sets it).
 */
#include <8051.h>
#include "compat.h"

/*
 * STC15 registers that a plain 8051 doesn't have, by address from the STC15
 * data sheet. 8051.h covers the standard ones (P1, P3, SCON, TMOD, ...).
 */
__sfr __at(0x8E) AUXR;           /* timer clock dividers, T2 run, UART1 baud  */
__sfr __at(0xA2) P_SW1;          /* peripheral pin switch: UART1 pin set      */
__sfr __at(0xD6) T2H;            /* timer 2 reload, high: the baud generator  */
__sfr __at(0xD7) T2L;            /* timer 2 reload, low                       */
__sfr __at(0x91) P1M1;           /* port mode bits; M1:M0 = 0:1 is push-pull, */
__sfr __at(0x92) P1M0;           /*   0:0 (reset) is quasi-bidirectional      */
__sfr __at(0xB1) P3M1;
__sfr __at(0xB2) P3M0;
__sfr __at(0xC9) P5M1;
__sfr __at(0xCA) P5M0;
__sfr __at(0xC1) WDT_CONTR;      /* watchdog control                          */
__sfr __at(0xC2) IAP_DATA;       /* EEPROM data                               */
__sfr __at(0xC3) IAP_ADDRH;      /* EEPROM address                            */
__sfr __at(0xC4) IAP_ADDRL;
__sfr __at(0xC5) IAP_CMD;        /* 1 read, 2 program, 3 erase sector         */
__sfr __at(0xC6) IAP_TRIG;       /* write 0x5A then 0xA5 to start             */
__sfr __at(0xC7) IAP_CONTR;      /* enable and wait states                    */
__sbit __at(0xCC) P54;           /* K2 (the reset pin, flashed as I/O)        */
__sbit __at(0xCD) P55;           /* K1                                        */

#define FOSC       22118400UL
#define T0_RELOAD  (65536UL - FOSC / 1000UL)          /* 1 ms, timer 0 in 1T  */
#define T2_RELOAD  (65536UL - FOSC / 4UL / 115200UL)  /* 115200 baud: 48      */
#define IAP_EN     0x81                               /* IAPEN + wait states  */
                                                      /*   for clocks <= 24 MHz */

#include "core.c"                /* the protocol, hardware independent        */

/* ------------------------------------------------------------------ UART */

static volatile uint8_t txbusy;  /* 1 while a byte is still being sent        */

/*
 * UART1 interrupt (vector 4), for both directions. A received byte goes
 * straight to core_rx, which just appends it to the line buffer; the line
 * itself is handled in the main loop by core_poll, outside the interrupt.
 * A transmit-complete just releases hw_putc.
 */
void uart_isr(void) __interrupt(4)
{
    if (RI) {
        RI = 0;
        core_rx(SBUF);
    }
    if (TI) {
        TI = 0;
        txbusy = 0;
    }
}

/* send one byte: wait for the previous one to finish, then start this one */
void hw_putc(uint8_t c)
{
    while (txbusy)
        ;
    txbusy = 1;
    SBUF = c;
}

/* ---------------------------------------------------------------- relays */

/*
 * Drive the 16-bit relay mask onto the scattered pins.
 *
 * Relays 3-8 are on P3.5 down to P3.0, i.e. in reverse bit order, so they
 * are built up a bit at a time into p3 and written in one go, with P3.6 and
 * P3.7 (the UART) held high: on an 8051 the alternate function only works
 * while the port latch is 1. Relays 1 and 2 are on port 5. Relays 9-16 are
 * on port 1 in order except that 9 and 10 are swapped (K9 on P1.1, K10 on
 * P1.0).
 */
void hw_apply(uint16_t m)
{
    uint8_t lo = (uint8_t)m, hi = (uint8_t)(m >> 8);
    uint8_t p3 = 0xC0, msk = 0x80, b = 0x01;      /* keep UART pins high      */
    while (b != 0x40) {                            /* K8..K3 -> P3.0..P3.5     */
        if (lo & msk)
            p3 |= b;
        msk >>= 1;                                 /* next relay down ...      */
        b <<= 1;                                   /* ... onto the next pin up */
    }
    P3 = p3;
    P55 = lo & 0x01;                               /* K1                       */
    P54 = (lo >> 1) & 0x01;                        /* K2                       */
    P1 = (hi & 0xFC) | ((hi << 1) & 0x02) | ((hi >> 1) & 0x01);  /* K9/K10 swap */
}

/* ---------------------------------------------------------------- EEPROM */

/*
 * One IAP (in-application programming) operation on the EEPROM area, which
 * the STC15 addresses from 0, separate from code flash.
 *
 * Enable IAP with the wait states for our clock, load command, address and
 * data, then write the 0x5A, 0xA5 trigger. The CPU stalls until the flash
 * operation is done (an erase takes milliseconds), then IAP_DATA holds the
 * result of a read. Afterwards IAP is disabled and its address parked at
 * 0x8000, outside the EEPROM, so a stray trigger can't touch the settings.
 * Interrupts are off for the duration so nothing lands between the two
 * trigger writes.
 */
static uint8_t iap(uint8_t cmd, uint8_t addr, uint8_t d)
{
    EA = 0;                      /* no interrupts during the sequence         */
    IAP_CONTR = IAP_EN;
    IAP_CMD = cmd;
    IAP_ADDRH = 0;               /* the settings block is at the start        */
    IAP_ADDRL = addr;
    IAP_DATA = d;                /* ignored by read and erase                 */
    IAP_TRIG = 0x5A;             /* trigger sequence ...                      */
    IAP_TRIG = 0xA5;             /* ... CPU stalls here until done            */
    __asm nop __endasm;          /* let IAP_DATA settle                       */
    d = IAP_DATA;
    IAP_CONTR = 0;               /* idle the IAP unit                         */
    IAP_CMD = 0;
    IAP_TRIG = 0;
    IAP_ADDRH = 0x80;            /* park outside the EEPROM                   */
    IAP_ADDRL = 0;
    EA = 1;
    return d;
}

uint8_t hw_ee_read(uint8_t addr)          { return iap(1, addr, 0); }
void    hw_ee_write(uint8_t addr, uint8_t d) { iap(2, addr, d); }
void    hw_ee_erase(void)                 { iap(3, 0, 0); }  /* the 512-byte  */
                                                             /*   sector at 0 */

/* ------------------------------------------------------------------ main */

void main(void)
{
    /*
     * Relay outputs first. The bootloader leaves every pin quasi-
     * bidirectional and weakly high, which can nudge the relay drivers, so
     * write the latches low before switching the pins to push-pull: a pin
     * never drives high on the way. P3.6 (UART RX) stays quasi-bidirectional
     * so the CH340 can drive it.
     */
    P1 = 0x00;                   /* relays 9-16 off                           */
    P3 = 0xC0;                   /* relays 3-8 off, UART pins high            */
    P54 = 0;                     /* relays 1-2 off                            */
    P55 = 0;
    P1M1 = 0x00;                 /* port 1 push-pull                          */
    P1M0 = 0xFF;
    P3M1 = 0x00;
    P3M0 = 0xBF;                 /* P3.6 RX stays quasi-bidirectional         */
    P5M1 &= 0xCF;                /* P5.4/P5.5 push-pull, rest untouched       */
    P5M0 |= 0x30;

    WDT_CONTR = 0x33;            /* watchdog on, prescale 16: ~280 ms         */

    /* UART1 on the CH340's pins, 115200 from timer 2 */
    P_SW1 = (P_SW1 & 0x3F) | 0x40;   /* UART1 -> P3.6/P3.7                    */
    SCON = 0x50;                 /* mode 1 (8N1), receive enabled             */
    T2L = T2_RELOAD & 0xFF;
    T2H = T2_RELOAD >> 8;
    AUXR |= 0x15;                /* T2R | T2x12 | S1ST2: run T2 at the full   */
                                 /*   clock and use it for UART1's baud       */

    /* timer 0: the 1 ms tick, polled through TF0 */
    TMOD = 0x00;                 /* STC15 mode 0 = 16-bit auto-reload         */
    TL0 = T0_RELOAD & 0xFF;
    TH0 = T0_RELOAD >> 8;
    AUXR |= 0x80;                /* T0x12: count every clock (1T)             */
    TR0 = 1;

    core_init();                 /* settings from EEPROM, relays off          */
    ES = 1;                      /* UART interrupt on                         */
    EA = 1;

    /*
     * Main loop: feed the watchdog, run the tick when timer 0 overflows,
     * and run any complete command line. A tick can be late (never lost
     * more than one) while a reply is being sent; the relay timers and the
     * failsafe stay accurate to about a millisecond.
     */
    for (;;) {
        WDT_CONTR |= 0x10;       /* CLR_WDT                                   */
        if (TF0) {
            TF0 = 0;
            core_tick();
        }
        core_poll();
    }
}
