CFLAGS ?= -std=c11 -O2 -Wall -Wextra

sim: sim.c ../firmware/core.c ../firmware/compat.h
	$(CC) $(CFLAGS) -o $@ sim.c -lutil

clean:
	rm -f sim

.PHONY: clean
