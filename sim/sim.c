/*
 * sim.c - runs the real firmware core (firmware/core.c) on Linux.
 *
 *   sim                       talk on stdin/stdout
 *   sim --pty                 create a pseudo-terminal, print its path
 *   sim --eeprom FILE         persist the EEPROM sector in FILE
 *   sim -v                    log relay changes to stderr
 *
 * Ticks run in real time (1 ms), so pulses and timeouts behave as on the board.
 */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "../firmware/core.c"

#define EE_SIZE 512

static int out_fd = 1, verbose;
static uint8_t ee[EE_SIZE];
static const char *ee_path;

void hw_apply(uint16_t m)
{
    if (verbose)
        fprintf(stderr, "relays %04X\n", m);
}

void hw_putc(uint8_t c)
{
    if (write(out_fd, &c, 1) != 1 && verbose)
        perror("write");
}

static void ee_flush(void)
{
    FILE *f;
    if (!ee_path || !(f = fopen(ee_path, "wb")))
        return;
    fwrite(ee, 1, EE_SIZE, f);
    fclose(f);
}

uint8_t hw_ee_read(uint8_t a)            { return ee[a]; }
void    hw_ee_write(uint8_t a, uint8_t d) { ee[a] &= d; ee_flush(); }   /* flash: 1 -> 0 only */
void    hw_ee_erase(void)                { memset(ee, 0xFF, EE_SIZE); ee_flush(); }

static long long now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

int main(int argc, char **argv)
{
    int in_fd = 0, use_pty = 0, i;
    long long last;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--pty"))
            use_pty = 1;
        else if (!strcmp(argv[i], "-v"))
            verbose = 1;
        else if (!strcmp(argv[i], "--eeprom") && i + 1 < argc)
            ee_path = argv[++i];
        else {
            fprintf(stderr, "usage: %s [--pty] [--eeprom FILE] [-v]\n", argv[0]);
            return 2;
        }
    }

    memset(ee, 0xFF, EE_SIZE);
    if (ee_path) {
        FILE *f = fopen(ee_path, "rb");
        if (f) {
            if (fread(ee, 1, EE_SIZE, f) != EE_SIZE)
                memset(ee, 0xFF, EE_SIZE);
            fclose(f);
        }
    }

    if (use_pty) {
        int master, slave;
        char name[256];
        struct termios t;
        if (openpty(&master, &slave, name, NULL, NULL) < 0) {
            perror("openpty");
            return 1;
        }
        tcgetattr(slave, &t);
        cfmakeraw(&t);
        tcsetattr(slave, TCSANOW, &t);
        /* slave stays open so the master never sees EIO between clients */
        printf("%s\n", name);
        fflush(stdout);
        in_fd = out_fd = master;
    }

    core_init();
    last = now_ms();

    for (;;) {
        struct pollfd p = { .fd = in_fd, .events = POLLIN };
        long long now;
        int r = poll(&p, 1, 1);
        if (r < 0 && errno != EINTR)
            return 1;
        if (r > 0 && (p.revents & POLLIN)) {
            uint8_t buf[256];
            ssize_t n = read(in_fd, buf, sizeof buf), k;
            if (n == 0 && !use_pty)
                return 0;
            for (k = 0; k < n; k++) {
                core_rx(buf[k]);
                core_poll();
            }
        }
        for (now = now_ms(); last < now; last++)
            core_tick();
    }
}
