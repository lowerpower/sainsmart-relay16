# sainsmart-relay16 - fast, indexable, fail-safe firmware and host tools
# for SainSmart 16-channel USB relay boards
#
# Copyright (c) 2025-2026 Mike Johnson (Mycal)
#
# Author:       https://anchorid.net/resolve/4ff7ed97-b78f-4ae6-9011-5af714ee241c
# Repository:   https://github.com/lowerpower/sainsmart-relay16
#
# SPDX-License-Identifier: MIT
# See LICENSE file for full terms.
#
# Built for the Reared In Steel crew's fire art.

all:
	$(MAKE) -C firmware
	$(MAKE) -C sim

test: all
	python3 -m unittest discover -s test -v

clean:
	$(MAKE) -C firmware clean
	$(MAKE) -C sim clean

.PHONY: all test clean
