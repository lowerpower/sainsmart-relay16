# Copyright (c) 2025-2026 Mike Johnson (Mycal)
# SPDX-License-Identifier: MIT
# https://github.com/lowerpower/sainsmart-relay16

CFLAGS ?= -std=c11 -O2 -Wall -Wextra

sim: sim.c ../firmware/core.c ../firmware/compat.h
	$(CC) $(CFLAGS) -o $@ sim.c -lutil

clean:
	rm -f sim

.PHONY: clean
