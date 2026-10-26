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

install:
	sudo install -m 0755 relay16-udev-id /usr/local/bin/relay16-udev-id
	sudo install -m 0644 99-relay16.rules /etc/udev/rules.d/99-relay16.rules
	sudo udevadm control --reload-rules
	sudo udevadm trigger --subsystem-match=tty

uninstall:
	sudo rm -f /usr/local/bin/relay16-udev-id /etc/udev/rules.d/99-relay16.rules
	sudo udevadm control --reload-rules

.PHONY: install uninstall
