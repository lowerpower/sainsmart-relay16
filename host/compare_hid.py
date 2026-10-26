#!/usr/bin/env python3
"""Head-to-head: an old SainSmart USB-HID 16-channel board vs a relay16 board.

Both get the same random 16-relay patterns, back to back, each confirmed:
relay16 by its reply, the HID board by reading the state back (as usb-relay
does with verify on). Linux only (hidraw); usually needs root for /dev/hidraw*.

    compare_hid.py /dev/hidraw2 /dev/serial/by-id/usb-1a86_USB_Serial-if00-port0 [COUNT] [SEED]
"""
import os
import random
import select
import struct
import sys
import time

import serial

SIG = 0x43444948                      # "HIDC", from usb-relay.h
# read-back bit layout of the HID controller: (byte, bit, relay index)
BITS = [(2, 0x80, 0), (3, 0x01, 1), (2, 0x40, 2), (3, 0x02, 3), (2, 0x20, 4), (3, 0x04, 5),
        (2, 0x10, 6), (3, 0x08, 7), (2, 0x08, 8), (3, 0x10, 9), (2, 0x04, 10), (3, 0x20, 11),
        (2, 0x02, 12), (3, 0x40, 13), (2, 0x01, 14), (3, 0x80, 15)]


class HidRelay:
    """SainSmart HID_RELAY_V1 (Nuvoton 0416:5020) via hidraw, usb-relay's protocol."""

    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR)

    def _cmd(self, cmd, a1, a2):
        body = struct.pack("<BBIII", cmd, 14, a1, a2, SIG)
        os.write(self.fd, body + struct.pack("<I", sum(body)))

    def write(self, mask):
        self._cmd(0xC3, mask & 0xFFFF, 0x11110000)

    def read(self, timeout=0.1):
        while select.select([self.fd], [], [], 0)[0]:
            os.read(self.fd, 64)                       # drop stale reports
        self._cmd(0xD2, 0x11111111, 0x11111111)
        if not select.select([self.fd], [], [], timeout)[0]:
            return None
        b = os.read(self.fd, 64)
        return sum(1 << n for idx, bit, n in BITS if b[idx] & bit)


def report(name, lat, total, bad):
    lat = sorted(lat)
    n = len(lat)
    print(f"{name}: {n} patterns in {total:.2f} s = {n / total:.0f}/s; "
          f"median {lat[n // 2] * 1e3:.2f} ms, p99 {lat[int(n * .99)] * 1e3:.2f} ms, "
          f"max {lat[-1] * 1e3:.2f} ms; wrong {bad}", flush=True)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    hid_path, ser_path = sys.argv[1], sys.argv[2]
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 1000
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 2026
    rnd = random.Random(seed)
    masks = [rnd.randrange(1, 65536) for _ in range(count)]

    h = HidRelay(hid_path)
    lat, bad = [], 0
    t0 = time.perf_counter()
    for m in masks:
        t = time.perf_counter()
        h.write(m)
        ok = any(h.read() == m for _ in range(6))
        lat.append(time.perf_counter() - t)
        bad += not ok
    total = time.perf_counter() - t0
    h.write(0)
    report("HID board   ", lat, total, bad)

    time.sleep(3)

    s = serial.Serial(ser_path, 115200, timeout=0.5)
    s.write(b"\n")
    time.sleep(0.05)
    s.reset_input_buffer()
    lat, bad = [], 0
    t0 = time.perf_counter()
    for m in masks:
        t = time.perf_counter()
        s.write(f"h {m:04X}\n".encode())
        r = s.readline().strip().decode(errors="replace")
        lat.append(time.perf_counter() - t)
        bad += r != f"{m:04X}"
    total = time.perf_counter() - t0
    s.write(b"h 0\n")
    s.readline()
    report("relay16 lite", lat, total, bad)


if __name__ == "__main__":
    main()
