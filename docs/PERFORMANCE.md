# Performance

Measured 2026-10-25 on the first board flashed with the lite firmware
(`relay16 1L`), against SainSmart's stock firmware on the same board earlier
the same day.

## Setup

| | |
|---|---|
| Board | SainSmart 101-70-208, STC15W401AS, RC trimmed to 22.085 MHz (target 22.1184, -0.15%) |
| Firmware | relay16 lite (`firmware/lite/relay16_lite.asm`, 791 bytes) |
| Link | board's own USB, CH340 at 115200 8N1 |
| Power | USB (jumper on USB), no loads on the relay contacts |
| Host | petaluma-build (Linux x86-64), Python 3, pyserial 3.5 |
| Method | one command, wait for its reply line, next command; timings are host wall-clock per round trip |

Every test checks every reply: an update only counts if the board answered
with exactly the state that was sent.

## Results

| Test | Command | Result |
|---|---|---|
| Read state, 1000x | `relay16.py bench 1000` | min 2.69 ms, median 3.00 ms, p99 4.60 ms (one 97 ms outlier, host side) |
| Set all 16, 500 stepped patterns | `h XXXX` loop | median 4.00 ms, p99 5.16 ms, 0 wrong |
| Set all 16, 1000 random patterns, flat out | `relay16.py perf 1000` | 3.61 s total = **277 updates/s**; median 3.25 ms, p99 5.64 ms, max 6.99 ms; 0 wrong |
| Set all 16, 400 random patterns at 20/s | `relay16.py perf 400 20` | 19.95 s; median 4.04 ms, max 9.60 ms; 0 wrong, 0 sends late by >5 ms |
| Failsafe, set to 1000 ms | `t 1000`, `s 3`, wait | still on after 0.90 s idle, off by 1.10 s |
| EEPROM | `i 1`, `w`, power cycle | ID 1 kept, relays all off at power-up |

Every update, including the worst case seen, finished inside 10 ms. A full
16-relay update costs about the same as reading the state: the time is
almost all USB and CH340 latency, not the serial line (a 7-byte command and
6-byte reply take about 1.1 ms on the wire at 115200).

No brownouts or resets on USB power at 277 random updates/s, with about 8
relays on at a time on average.

## Stock firmware, for comparison

Same board, before flashing: 9600 baud Modbus ASCII, one relay per command.

| | Stock | relay16 lite |
|---|---|---|
| Change one relay | ~40 ms (17-byte command, 17-byte echo at 9600 baud; first byte back after ~21 ms) | 3-4 ms |
| Change all 16 relays | 16 commands, ~640 ms (SainSmart documents a write-multiple-coils command only for all-on/all-off; even that is ~50 ms) | one command, ~4 ms, any pattern |
| Reply | exact echo of the command, even for reads; no relay state | the actual 16-relay state |

## What the relays can follow

A relay needs a few milliseconds to pull in or drop out (the SRD-05VDC data
sheet gives up to 10 ms operate, 5 ms release). At 277 updates/s the board
sets every pattern but the contacts can't keep up, so the relays buzz; at
20 updates/s each pattern has 50 ms and visibly lands. The firmware is no
longer the limit: the relays are.

## SainSmart HID board, for comparison

Pending. The older SainSmart USB-HID 16-channel boards (driven by
[SainSmartUsbRelay](https://github.com/lowerpower/SainSmartUsbRelay)) are the
boards this replaces; the plan is to run the same random-pattern test on one
and add its numbers here.

## Reproduce

```sh
host/relay16.py -b 1 bench 1000        # read round trips
host/relay16.py -b 1 perf 1000         # random patterns, flat out
host/relay16.py -b 1 perf 400 20       # random patterns at 20/s
```
