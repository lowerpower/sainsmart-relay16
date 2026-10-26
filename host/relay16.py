#!/usr/bin/env python3
# Copyright (c) 2025-2026 Mike Johnson (Mycal)
# SPDX-License-Identifier: MIT
# https://github.com/lowerpower/sainsmart-relay16
"""relay16 - host library and CLI for SainSmart 101-70-208 boards running
the relay16 firmware (protocol: docs/PROTOCOL.md).

Library:
    from relay16 import Relay16, Bus

    r = Relay16("/dev/ttyUSB0")     # one board, by port
    r.on(5); r.pulse(3, 250); r.set(0xF0F0)

    bus = Bus(require=[1, 2, 3])    # every board, indexed by its stored ID
    bus[2].pulse(7, 100)

Boards are found by the CH340's USB ID (1a86:7523) and identified by the ID
stored in each board's EEPROM, so the index is the same after every reboot,
on Windows, macOS and Linux.
"""
import argparse
import sys
import time

import serial
from serial.tools import list_ports

CH340_VID, CH340_PID = 0x1A86, 0x7523
BAUD = 115200


class Relay16Error(Exception):
    pass


class Relay16:
    def __init__(self, port, timeout=0.3):
        """port: a device (/dev/ttyUSB0, COM7), a pyserial URL
        (socket://host:port), or an already-open serial-like object."""
        if isinstance(port, str):
            self.port = port
            self.s = serial.serial_for_url(port, BAUD, timeout=timeout)
        else:
            self.port = getattr(port, "name", repr(port))
            self.s = port
        self.s.write(b"\n")          # end any partial line left by line noise
        time.sleep(0.05)
        self.s.reset_input_buffer()

    def close(self):
        self.s.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def command(self, line):
        """Send one command line, return the reply line without CR/LF."""
        self.s.write(line.encode("ascii") + b"\n")
        reply = self.s.readline()
        if not reply.endswith(b"\n"):
            raise Relay16Error(f"{self.port}: no reply to {line!r}")
        text = reply.decode("ascii", "replace").strip()
        if text == "?":
            raise Relay16Error(f"{self.port}: board rejected {line!r}")
        return text

    def _state(self, line):
        return int(self.command(line), 16)

    def _num(self, line, value=None):
        return int(self.command(line if value is None else f"{line} {value}"))

    # relay state (each returns the 16-bit state after the command)
    def read(self):              return self._state("r")
    def on(self, n):             return self._state(f"s {n}")
    def off(self, n):            return self._state(f"c {n}")
    def set(self, mask):         return self._state(f"h {mask & 0xFFFF:04X}")
    def all_off(self):           return self.set(0)

    def pulse(self, n, ms=None):
        return self._state(f"p {n}" if ms is None else f"p {n} {ms}")

    # settings (each returns the current value; pass a value to change it)
    def default_pulse(self, n, ms=None): return self._num(f"d {n}", ms)
    def max_on(self, n, ms=None):        return self._num(f"m {n}", ms)
    def failsafe(self, ms=None):         return self._num("t", ms)
    def board_id(self, new=None):        return self._num("i", new)

    def save(self):
        """Write settings to EEPROM. The board refuses unless all relays are off."""
        return self._state("w")

    def version(self):
        """Returns (firmware_version, board_id)."""
        parts = self.command("v").split()
        if len(parts) != 4 or parts[0] != "relay16" or parts[2] != "id":
            raise Relay16Error(f"{self.port}: not a relay16 board ({' '.join(parts)!r})")
        return parts[1], int(parts[3])


def find_ports():
    """Serial ports with a CH340 (the chip on the 101-70-208)."""
    return sorted(p.device for p in list_ports.comports()
                  if p.vid == CH340_VID and p.pid == CH340_PID)


def scan(ports=None, timeout=0.3):
    """Probe ports. Returns (boards {id: port}, unassigned [port],
    other [port], duplicates {id: [port, ...]})."""
    boards, unassigned, other, dups = {}, [], [], {}
    for port in find_ports() if ports is None else ports:
        try:
            with Relay16(port, timeout) as r:
                _, bid = r.version()
        except (serial.SerialException, OSError, Relay16Error, ValueError):
            other.append(port)
            continue
        if bid == 0:
            unassigned.append(port)
        elif bid in boards:
            dups.setdefault(bid, [boards[bid]]).append(port)
        else:
            boards[bid] = port
    for bid in dups:
        del boards[bid]
    return boards, unassigned, other, dups


class Bus:
    """All relay16 boards, indexed by the ID stored on each board.

    Missing or duplicate IDs are errors; boards never renumber to fill a gap.
    """

    def __init__(self, require=(), ports=None):
        found, self.unassigned, self.other, dups = scan(ports)
        if dups:
            raise Relay16Error("duplicate board IDs: " + "; ".join(
                f"id {i} on {', '.join(p)}" for i, p in sorted(dups.items())))
        missing = sorted(set(require) - set(found))
        if missing:
            raise Relay16Error("board(s) not found: " + ", ".join(map(str, missing)))
        self.boards = {i: Relay16(p) for i, p in sorted(found.items())}

    def __getitem__(self, bid):
        try:
            return self.boards[bid]
        except KeyError:
            raise Relay16Error(f"board {bid} not found") from None

    def __iter__(self):
        return iter(self.boards.items())

    def close(self):
        for b in self.boards.values():
            b.close()


# ------------------------------------------------------------------- CLI

USAGE = """commands:
  scan                    list boards by ID
  r                       read state
  s N | c N               relay N on | off (1-16)
  h MASK                  set all, hex mask, 0001 = relay 1
  p N [MS]                pulse relay N (default time if MS omitted)
  d N [MS] | m N [MS]     default pulse | max on-time for relay N
  t [MS]                  host-silence failsafe, 0 = off
  i [ID]                  board ID, 1-255 (0 = unassigned)
  w                       save settings to EEPROM (all relays must be off)
  v                       firmware version and ID
  raw LINE...             send a line as-is
  walk [SECONDS]          click relays 1-16 in turn
  bench [COUNT]           time round trips
  perf [COUNT] [RATE]     random 16-relay patterns, confirmed; RATE per
                          second (omit for as fast as possible)"""


def perf(r, count, rate=None):
    """Send `count` random set-all patterns, check every reply, report timing.
    With `rate`, sends are paced to that many per second."""
    import random
    rnd = random.Random()
    lat, bad, late = [], 0, 0
    period = 1 / rate if rate else 0
    t0 = time.perf_counter()
    for i in range(count):
        due = t0 + i * period
        while period and time.perf_counter() < due:
            pass
        mask = rnd.randrange(1, 65536)
        t = time.perf_counter()
        try:
            ok = r.set(mask) == mask
        except Relay16Error:
            ok = False
        lat.append(time.perf_counter() - t)
        bad += not ok
        late += bool(period) and t - due > 0.005
    total = time.perf_counter() - t0
    r.all_off()
    lat.sort()
    print(f"{count} random patterns in {total:.2f} s = {count / total:.0f} updates/s")
    print(f"per update: median {lat[count // 2] * 1e3:.2f} ms  "
          f"p99 {lat[int(count * .99)] * 1e3:.2f} ms  max {lat[-1] * 1e3:.2f} ms")
    print(f"wrong or missing replies: {bad}" + (f"  sends >5 ms late: {late}" if period else ""))


def open_target(args):
    if args.port:
        return Relay16(args.port)
    if args.board is not None:
        boards, *_ = scan()
        if args.board not in boards:
            sys.exit(f"board {args.board} not found")
        return Relay16(boards[args.board])
    ports = find_ports()
    if len(ports) != 1:
        sys.exit(f"{len(ports)} CH340 ports found; pick one with -p PORT or -b ID")
    return Relay16(ports[0])


def main():
    ap = argparse.ArgumentParser(description="relay16 board control",
                                 epilog=USAGE,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--port", help="serial port")
    ap.add_argument("-b", "--board", type=int, help="board ID")
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()

    if a.cmd == "scan":
        boards, unassigned, other, dups = scan()
        for bid, port in sorted(boards.items()):
            print(f"board {bid:3d}  {port}")
        for port in unassigned:
            print(f"unassigned {port}  (set with: relay16 -p {port} i ID; relay16 -p {port} w)")
        for bid, ports in sorted(dups.items()):
            print(f"DUPLICATE id {bid}: {', '.join(ports)}")
        for port in other:
            print(f"not relay16 {port}")
        return

    try:
        with open_target(a) as r:
            if a.cmd == "walk":
                dwell = float(a.args[0]) if a.args else 0.5
                for n in range(1, 17):
                    r.set(1 << (n - 1))
                    print(f"relay {n}")
                    time.sleep(dwell)
                r.all_off()
            elif a.cmd == "bench":
                n = int(a.args[0]) if a.args else 1000
                t = []
                for _ in range(n):
                    t0 = time.perf_counter()
                    r.read()
                    t.append(time.perf_counter() - t0)
                t.sort()
                print(f"{n} round trips: min {t[0]*1e3:.2f} ms  median {t[n//2]*1e3:.2f} ms  "
                      f"p99 {t[int(n*.99)]*1e3:.2f} ms  max {t[-1]*1e3:.2f} ms")
            elif a.cmd == "perf":
                perf(r, int(a.args[0]) if a.args else 1000,
                     float(a.args[1]) if len(a.args) > 1 else None)
            elif a.cmd == "raw":
                print(r.command(" ".join(a.args)))
            else:
                print(r.command(" ".join([a.cmd] + a.args)))
    except Relay16Error as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
