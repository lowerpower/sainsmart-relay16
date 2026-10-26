# Copyright (c) 2025-2026 Mike Johnson (Mycal)
# SPDX-License-Identifier: MIT
# https://github.com/lowerpower/sainsmart-relay16

install:
	sudo install -m 0755 relay16-udev-id /usr/local/bin/relay16-udev-id
	sudo install -m 0644 99-relay16.rules /etc/udev/rules.d/99-relay16.rules
	sudo udevadm control --reload-rules
	sudo udevadm trigger --subsystem-match=tty

uninstall:
	sudo rm -f /usr/local/bin/relay16-udev-id /etc/udev/rules.d/99-relay16.rules
	sudo udevadm control --reload-rules

.PHONY: install uninstall
