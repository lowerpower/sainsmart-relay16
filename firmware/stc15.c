/*
 * stc15.c - relay16 firmware, STC15W401AS on the SainSmart 101-70-208
 *
 * Clock: internal RC trimmed to 22.1184 MHz by stcgal (-t 22118.4)
 * UART1 on P3.6 (RxD_2) / P3.7 (TxD_2) -> CH340G, 115200 8N1
 *
 * Relay -> pin, from the vendor schematic (ULN2803, pin high = relay on):
 *   K1 P5.5  K2 P5.4  K3 P3.5  K4 P3.4  K5 P3.3  K6 P3.2  K7 P3.1  K8 P3.0
 *   K9 P1.1  K10 P1.0 K11-K16 P1.2-P1.7
 * P5.4 is the reset pin: flash with reset_pin_enabled=false.
 *
 * Copyright (c) 2025-2026 Mike Johnson (Mycal)
 * SPDX-License-Identifier: MIT
 * https://github.com/lowerpower/sainsmart-relay16
 */
#include <8051.h>
#include "compat.h"

__sfr __at(0x8E) AUXR;
__sfr __at(0xA2) P_SW1;
__sfr __at(0xD6) T2H;
__sfr __at(0xD7) T2L;
__sfr __at(0x91) P1M1;
__sfr __at(0x92) P1M0;
__sfr __at(0xB1) P3M1;
__sfr __at(0xB2) P3M0;
__sfr __at(0xC9) P5M1;
__sfr __at(0xCA) P5M0;
__sfr __at(0xC1) WDT_CONTR;
__sfr __at(0xC2) IAP_DATA;
__sfr __at(0xC3) IAP_ADDRH;
__sfr __at(0xC4) IAP_ADDRL;
__sfr __at(0xC5) IAP_CMD;
__sfr __at(0xC6) IAP_TRIG;
__sfr __at(0xC7) IAP_CONTR;
__sbit __at(0xCC) P54;
__sbit __at(0xCD) P55;

#define FOSC       22118400UL
#define T0_RELOAD  (65536UL - FOSC / 1000UL)          /* 1 ms, 1T */
#define T2_RELOAD  (65536UL - FOSC / 4UL / 115200UL)  /* 115200 baud */
#define IAP_EN     0x81                                /* wait states, <= 24 MHz */

#include "core.c"

static volatile uint8_t txbusy;

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

void hw_putc(uint8_t c)
{
    while (txbusy)
        ;
    txbusy = 1;
    SBUF = c;
}

void hw_apply(uint16_t m)
{
    uint8_t lo = (uint8_t)m, hi = (uint8_t)(m >> 8);
    uint8_t p3 = 0xC0, msk = 0x80, b = 0x01;      /* keep UART pins high */
    while (b != 0x40) {                            /* K8..K3 -> P3.0..P3.5 */
        if (lo & msk)
            p3 |= b;
        msk >>= 1;
        b <<= 1;
    }
    P3 = p3;
    P55 = lo & 0x01;
    P54 = (lo >> 1) & 0x01;
    P1 = (hi & 0xFC) | ((hi << 1) & 0x02) | ((hi >> 1) & 0x01);
}

static uint8_t iap(uint8_t cmd, uint8_t addr, uint8_t d)
{
    EA = 0;
    IAP_CONTR = IAP_EN;
    IAP_CMD = cmd;
    IAP_ADDRH = 0;
    IAP_ADDRL = addr;
    IAP_DATA = d;
    IAP_TRIG = 0x5A;
    IAP_TRIG = 0xA5;
    __asm nop __endasm;
    d = IAP_DATA;
    IAP_CONTR = 0;
    IAP_CMD = 0;
    IAP_TRIG = 0;
    IAP_ADDRH = 0x80;
    IAP_ADDRL = 0;
    EA = 1;
    return d;
}

uint8_t hw_ee_read(uint8_t addr)          { return iap(1, addr, 0); }
void    hw_ee_write(uint8_t addr, uint8_t d) { iap(2, addr, d); }
void    hw_ee_erase(void)                 { iap(3, 0, 0); }

void main(void)
{
    /* relay outputs low, then push-pull */
    P1 = 0x00;
    P3 = 0xC0;
    P54 = 0;
    P55 = 0;
    P1M1 = 0x00;
    P1M0 = 0xFF;
    P3M1 = 0x00;
    P3M0 = 0xBF;                 /* P3.6 RX stays quasi-bidirectional */
    P5M1 &= 0xCF;
    P5M0 |= 0x30;

    WDT_CONTR = 0x33;            /* watchdog on, ~280 ms */

    P_SW1 = (P_SW1 & 0x3F) | 0x40;   /* UART1 -> P3.6/P3.7 */
    SCON = 0x50;
    T2L = T2_RELOAD & 0xFF;
    T2H = T2_RELOAD >> 8;
    AUXR |= 0x15;                /* T2R | T2x12 | S1ST2 */

    TMOD = 0x00;                 /* T0 16-bit auto-reload */
    TL0 = T0_RELOAD & 0xFF;
    TH0 = T0_RELOAD >> 8;
    AUXR |= 0x80;                /* T0 1T */
    TR0 = 1;

    core_init();
    ES = 1;
    EA = 1;

    for (;;) {
        WDT_CONTR |= 0x10;
        if (TF0) {
            TF0 = 0;
            core_tick();
        }
        core_poll();
    }
}
