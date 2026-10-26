# Copyright (c) 2025-2026 Mike Johnson (Mycal)
# SPDX-License-Identifier: MIT
# https://github.com/lowerpower/sainsmart-relay16

all:
	$(MAKE) -C firmware
	$(MAKE) -C sim

test: all
	python3 -m unittest discover -s test -v

clean:
	$(MAKE) -C firmware clean
	$(MAKE) -C sim clean

.PHONY: all test clean
