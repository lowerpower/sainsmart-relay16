#!/usr/bin/env python3
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

"""Protocol tests: run the real firmware core in sim/sim on a pty and drive
it through host/relay16.py, the same library used with real boards.

    make -C sim && python3 -m unittest discover -s test -v
"""
import os
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "host"))
from relay16 import Relay16, Relay16Error  # noqa: E402

SIM = os.path.join(ROOT, "sim", "sim")


class Board:
    """A simulated board with its own EEPROM file."""

    def __init__(self, eeprom):
        self.proc = subprocess.Popen([SIM, "--pty", "--eeprom", eeprom],
                                     stdout=subprocess.PIPE, text=True)
        self.port = self.proc.stdout.readline().strip()
        self.r = Relay16(self.port)

    def raw(self, data):
        """Write bytes, return everything the board sends back within 100 ms."""
        self.r.s.write(data)
        time.sleep(0.1)
        return self.r.s.read(self.r.s.in_waiting)

    def close(self):
        self.r.close()
        self.proc.kill()
        self.proc.wait()
        self.proc.stdout.close()


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ee = os.path.join(self.tmp.name, "eeprom.bin")
        self.b = Board(self.ee)
        self.r = self.b.r

    def tearDown(self):
        self.b.close()
        self.tmp.cleanup()

    def reboot(self):
        self.b.close()
        self.b = Board(self.ee)
        self.r = self.b.r

    def rejected(self, line):
        with self.assertRaises(Relay16Error):
            self.r.command(line)

    # ------------------------------------------------------------ state

    def test_powerup_all_off(self):
        self.assertEqual(self.r.command("r"), "0000")

    def test_set_and_clear(self):
        self.assertEqual(self.r.command("s 1"), "0001")
        self.assertEqual(self.r.command("s 16"), "8001")
        self.assertEqual(self.r.command("c 1"), "8000")
        self.assertEqual(self.r.command("c 16"), "0000")

    def test_hex_mask(self):
        self.assertEqual(self.r.command("h F0F0"), "F0F0")
        self.assertEqual(self.r.command("h 1"), "0001")
        self.assertEqual(self.r.command("h 0"), "0000")
        self.assertEqual(self.r.set(0xBEEF), 0xBEEF)

    def test_case_and_spacing(self):
        self.assertEqual(self.r.command("S 3"), "0004")
        self.assertEqual(self.r.command("  h   abcd  "), "ABCD")
        self.assertEqual(self.r.command("s\t2"), "ABCF")

    def test_rejects(self):
        for line in ["s 0", "s 17", "s", "s x", "s 1 2", "c 99", "h", "h 12345",
                     "h 0g", "x", "r 1", "p 1 70000", "i 256", "t 1x", "zz top"]:
            with self.subTest(line=line):
                self.rejected(line)
        self.assertEqual(self.r.command("r"), "0000")

    # ------------------------------------------------------- line framing

    def test_line_endings(self):
        for eol in [b"\r", b"\n", b"\r\n"]:
            with self.subTest(eol=eol):
                self.assertEqual(self.b.raw(b"r" + eol), b"0000\r\n")

    def test_empty_lines_ignored(self):
        self.assertEqual(self.b.raw(b"\r\n\r\n\n"), b"")

    def test_long_line_rejected(self):
        self.assertEqual(self.b.raw(b"s " + b"1" * 40 + b"\r"), b"?\r\n")
        self.assertEqual(self.r.command("r"), "0000")

    def test_control_chars_rejected(self):
        self.assertEqual(self.b.raw(b"s \x111\r"), b"?\r\n")

    # ------------------------------------------------------------ timing

    def test_pulse(self):
        self.assertEqual(self.r.pulse(3, 100), 0x0004)
        time.sleep(0.05)
        self.assertEqual(self.r.read(), 0x0004)
        time.sleep(0.1)
        self.assertEqual(self.r.read(), 0x0000)

    def test_default_pulse(self):
        self.rejected("p 4")                     # no default yet
        self.assertEqual(self.r.default_pulse(4, 80), 80)
        self.assertEqual(self.r.default_pulse(4), 80)
        self.assertEqual(self.r.pulse(4), 0x0008)
        time.sleep(0.15)
        self.assertEqual(self.r.read(), 0x0000)

    def test_max_on_interlock(self):
        self.assertEqual(self.r.max_on(5, 100), 100)
        self.assertEqual(self.r.on(5), 0x0010)
        time.sleep(0.15)
        self.assertEqual(self.r.read(), 0x0000)

    def test_pulse_capped_by_max_on(self):
        self.r.max_on(6, 100)
        self.r.pulse(6, 5000)
        time.sleep(0.15)
        self.assertEqual(self.r.read(), 0x0000)

    def test_failsafe(self):
        self.assertEqual(self.r.failsafe(150), 150)
        self.r.on(1)
        time.sleep(0.1)
        self.assertEqual(self.r.read(), 0x0001)  # any command resets the timer
        time.sleep(0.1)
        self.assertEqual(self.r.read(), 0x0001)
        time.sleep(0.25)
        self.assertEqual(self.r.read(), 0x0000)

    def test_failsafe_off_by_default(self):
        self.r.on(2)
        time.sleep(0.3)
        self.assertEqual(self.r.read(), 0x0002)

    # ------------------------------------------------------ ID and EEPROM

    def test_unassigned_by_default(self):
        self.assertEqual(self.r.version(), ("1", 0))

    def test_id_survives_reboot_only_after_save(self):
        self.assertEqual(self.r.board_id(7), 7)
        self.reboot()
        self.assertEqual(self.r.board_id(), 0)   # not saved
        self.r.board_id(7)
        self.r.max_on(9, 1234)
        self.r.failsafe(500)
        self.assertEqual(self.r.save(), 0)
        self.reboot()
        self.assertEqual(self.r.version(), ("1", 7))
        self.assertEqual(self.r.max_on(9), 1234)
        self.assertEqual(self.r.failsafe(), 500)
        self.assertEqual(self.r.read(), 0)       # relays never restored

    def test_save_refused_with_relays_on(self):
        self.r.on(1)
        self.rejected("w")
        self.r.all_off()
        self.assertEqual(self.r.save(), 0)

    def test_corrupt_eeprom_means_unassigned(self):
        self.r.board_id(9)
        self.r.save()
        self.b.close()
        with open(self.ee, "r+b") as f:
            f.seek(1)
            f.write(b"\x08")                     # flip the stored ID
        self.b = Board(self.ee)
        self.r = self.b.r
        self.assertEqual(self.r.version(), ("1", 0))


if __name__ == "__main__":
    unittest.main()
