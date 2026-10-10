#!/usr/bin/env python3
"""Lite firmware tests: the assembled 8051 binary runs in ucsim.

The SIM build differs from the board build only in baud clock, tick timer
and EEPROM backing (XRAM); parser, replies, failsafe, pin mapping and the
EEPROM layout are the same code.

    make -C firmware lite && python3 -m unittest test.test_lite -v
"""
import os
import random
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ucsim import LITE_SIM_HEX, ROOT, UCSIM, UcsimBoard  # noqa: E402
from relay16 import Relay16, Relay16Error  # noqa: E402

FULL_SIM = os.path.join(ROOT, "sim", "sim")


def expected_pins(mask):
    """Documented relay -> pin map, as (P1, P3, P5 & 0x30)."""
    p3 = 0xC0                                     # UART pins stay high
    for k in range(3, 9):                         # K3..K8 -> P3.5..P3.0
        if mask >> (k - 1) & 1:
            p3 |= 1 << (8 - k)
    p5 = (0x20 if mask & 1 else 0) | (0x10 if mask & 2 else 0)
    hi = mask >> 8                                # K9 P1.1, K10 P1.0, rest straight
    p1 = (hi & 0xFC) | ((hi & 1) << 1) | ((hi >> 1) & 1)
    return p1, p3, p5


@unittest.skipUnless(UCSIM and os.path.exists(LITE_SIM_HEX),
                     "needs ucsim_51 (sdcc-ucsim) and `make -C firmware lite`")
class LiteTest(unittest.TestCase):
    def setUp(self):
        self.b = UcsimBoard()
        self.r = self.b.relay

    def tearDown(self):
        self.b.close()

    def rejected(self, line):
        with self.assertRaises(Relay16Error):
            self.r.command(line)

    def raw(self, data, lines=1):
        """Write bytes, return everything sent back once `lines` reply lines
        have arrived (ucsim reads its input FIFO slowly, in wall time)."""
        self.b.serial.write(data)
        out, end = b"", time.time() + 5
        while out.count(b"\n") < lines and time.time() < end:
            time.sleep(0.05)
            out += self.b.serial.read(1000)
        time.sleep(0.3)                           # anything extra?
        return out + self.b.serial.read(1000)

    # ------------------------------------------------------------ protocol

    def test_powerup(self):
        self.assertEqual(self.r.version(), ("1L", 0))
        self.assertEqual(self.r.command("r"), "0000")
        self.assertEqual(self.b.pins(), expected_pins(0))

    def test_set_clear_mask(self):
        self.assertEqual(self.r.command("s 1"), "0001")
        self.assertEqual(self.r.command("S 16"), "8001")
        self.assertEqual(self.r.command("c 1"), "8000")
        self.assertEqual(self.r.command("  h   abcd "), "ABCD")
        self.assertEqual(self.r.command("h\t1"), "0001")
        self.assertEqual(self.r.command("h 0"), "0000")

    def test_rejects(self):
        for line in ["s 0", "s 17", "s", "s x", "s 1 2", "c 99", "h", "h 12345",
                     "h 0g", "x", "r 1", "w 1", "v 1", "i 256", "t 70000", "t 1x",
                     "p 1 100", "d 1", "m 1 5", "s 65536"]:
            with self.subTest(line=line):
                self.rejected(line)
        self.assertEqual(self.r.command("r"), "0000")

    def test_line_endings(self):
        for eol in [b"\r", b"\n", b"\r\n"]:
            with self.subTest(eol=eol):
                self.assertEqual(self.raw(b"r" + eol), b"0000\r\n")
        self.assertEqual(self.raw(b"\r\n\n\r", lines=0), b"")

    def test_junk(self):
        self.assertEqual(self.raw(b"s " + b"1" * 40 + b"\r"), b"?\r\n")
        self.assertEqual(self.raw(b"s \x111\r"), b"?\r\n")
        self.assertEqual(self.raw(b"s 00000000000005\r"), b"0010\r\n")

    # ------------------------------------------------------------ pins

    def test_pin_map_each_relay(self):
        for n in range(1, 17):
            with self.subTest(relay=n):
                self.r.set(1 << (n - 1))
                self.assertEqual(self.b.pins(), expected_pins(1 << (n - 1)))

    def test_pin_map_patterns(self):
        rnd = random.Random(16)
        for mask in [0xFFFF, 0x0000, 0xAAAA, 0x5555, 0x8421] + [rnd.randrange(65536) for _ in range(5)]:
            with self.subTest(mask=f"{mask:04X}"):
                self.assertEqual(self.r.set(mask), mask)
                self.assertEqual(self.b.pins(), expected_pins(mask))

    # ------------------------------------------------------------ failsafe

    def test_failsafe(self):
        self.assertEqual(self.r.failsafe(3000), 3000)
        self.r.on(1)
        self.b.wait_sim(2000)
        self.assertEqual(self.r.read(), 0x0001)   # valid command restarts it
        self.b.wait_sim(2000)
        self.assertEqual(self.r.read(), 0x0001)
        self.b.wait_sim(4000)
        self.assertEqual(self.b.pins(), expected_pins(0))
        self.assertEqual(self.r.read(), 0x0000)

    def test_rejected_command_does_not_restart_failsafe(self):
        self.r.failsafe(3000)
        self.r.on(2)
        for _ in range(3):
            self.b.wait_sim(1200)
            self.rejected("x")
        self.assertEqual(self.r.read(), 0x0000)

    def test_failsafe_off_by_default(self):
        self.r.on(3)
        self.b.wait_sim(5000)
        self.assertEqual(self.r.read(), 0x0004)

    # ------------------------------------------------------------ EEPROM

    def test_settings_survive_reset_only_after_save(self):
        self.r.board_id(9)
        self.b.reset()
        self.assertEqual(self.r.version(), ("1L", 0))
        self.r.board_id(9)
        self.r.failsafe(1234)
        self.assertEqual(self.r.save(), 0)
        self.r.set(0x00FF)
        self.b.reset()
        self.assertEqual(self.r.version(), ("1L", 9))
        self.assertEqual(self.r.failsafe(), 1234)
        self.assertEqual(self.r.read(), 0)        # relays never restored
        self.assertEqual(self.b.pins(), expected_pins(0))

    def test_save_refused_with_relays_on(self):
        self.r.on(4)
        self.rejected("w")
        self.r.all_off()
        self.assertEqual(self.r.save(), 0)

    def test_eeprom_layout(self):
        self.r.board_id(9)
        self.r.failsafe(1234)
        self.r.save()
        block = self.b.xram(0, 68)
        self.assertEqual(block[:4], bytes([0xA5, 9, 0xD2, 0x04]))
        self.assertEqual(block[4:68], bytes(64))
        self.assertEqual(block[68], (0x5A + sum(block[:68])) & 0xFF)

    def test_corrupt_eeprom_means_unassigned(self):
        self.r.board_id(9)
        self.r.save()
        self.b.set_xram(1, [8])
        self.b.reset()
        self.assertEqual(self.r.version(), ("1L", 0))

    # ------------------------------------------------- lite <-> full compat

    @unittest.skipUnless(os.path.exists(FULL_SIM), "needs `make -C sim`")
    def test_compat_lite_to_full(self):
        self.r.board_id(42)
        self.r.failsafe(777)
        self.r.save()
        block = self.b.xram(0, 68)
        with tempfile.TemporaryDirectory() as d:
            ee = os.path.join(d, "ee.bin")
            with open(ee, "wb") as f:
                f.write(block + b"\xff" * (512 - len(block)))
            p = subprocess.Popen([FULL_SIM, "--pty", "--eeprom", ee],
                                 stdout=subprocess.PIPE, text=True)
            try:
                with Relay16(p.stdout.readline().strip()) as full:
                    self.assertEqual(full.version(), ("1", 42))
                    self.assertEqual(full.failsafe(), 777)
                    self.assertEqual(full.max_on(1), 0)
            finally:
                p.kill()
                p.wait()
                p.stdout.close()

    @unittest.skipUnless(os.path.exists(FULL_SIM), "needs `make -C sim`")
    def test_compat_full_to_lite(self):
        with tempfile.TemporaryDirectory() as d:
            ee = os.path.join(d, "ee.bin")
            p = subprocess.Popen([FULL_SIM, "--pty", "--eeprom", ee],
                                 stdout=subprocess.PIPE, text=True)
            try:
                with Relay16(p.stdout.readline().strip()) as full:
                    full.board_id(23)
                    full.failsafe(4321)
                    full.max_on(5, 1000)          # lite ignores, checksum still valid
                    full.save()
            finally:
                p.kill()
                p.wait()
                p.stdout.close()
            with open(ee, "rb") as f:
                block = f.read(69)
        self.b.set_xram(0, block)
        self.b.reset()
        self.assertEqual(self.r.version(), ("1L", 23))
        self.assertEqual(self.r.failsafe(), 4321)


if __name__ == "__main__":
    unittest.main()
