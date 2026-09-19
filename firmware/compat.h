/* compat.h - lets core.c build with SDCC (target) and gcc (simulator) */
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
