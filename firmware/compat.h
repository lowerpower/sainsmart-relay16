/*
 * compat.h - lets core.c build with SDCC (target) and gcc (simulator)
 *
 * Copyright (c) 2025-2026 Mike Johnson (Mycal)
 * SPDX-License-Identifier: MIT
 * https://github.com/lowerpower/sainsmart-relay16
 */
#ifndef RELAY16_COMPAT_H
#define RELAY16_COMPAT_H

#include <stdint.h>
#include <stddef.h>

#ifdef __SDCC
#define XDATA __xdata
#define IDATA __idata
#define CODE  __code
#else
#define XDATA
#define IDATA
#define CODE
#endif

#endif
