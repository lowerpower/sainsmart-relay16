# sainsmart_new

Replacement firmware and host tools for the **SainSmart 101-70-208**
16-channel 9-36 V USB relay board, whose stock serial firmware is slow
(9600 baud Modbus ASCII, one relay per 17-byte command) and never reports
real status.

The relay16 firmware gives:

- plain ASCII commands at 115200 baud: `s 5`, `c 5`, `h F0F0`, `r`
- one command sets all 16 relays at once; every reply is the actual state
- a host-silence failsafe, a board ID in EEPROM so 8 boards keep the same
  index after every reboot
- the same hex mask as `usb-relay` (SainSmartUsbRelay): `0001` = relay 1
- full build only: board-timed pulses (`p 3 250`) and a per-relay max-on
  interlock

Protocol: [docs/PROTOCOL.md](docs/PROTOCOL.md).
Hardware, flashing and pin map: [docs/HARDWARE.md](docs/HARDWARE.md)
([photos](docs/HARDWARE.md#photos)).

## Why

These relay boards fire the flame effects on the Reared In Steel crew's
pieces at Burning Man, played live from an 88-key MIDI keyboard, a MIDI
controller and a web interface. The rig started with the Flower Tower on
SainSmart's older USB-HID 16-channel boards, seven of them ganged together by
[SainSmartUsbRelay](https://github.com/lowerpower/SainSmartUsbRelay)
(`usb-relay`), fast enough that the fire keeps up with the keys.

The board SainSmart lists now, the 101-70-208, replaced HID with a CH340
serial port, and its firmware is too slow to play: 9600 baud Modbus ASCII,
one 17-byte command per relay at about 40 ms each, so a chord across 16
relays lands over half a second late. It also never reports what the relays
are actually doing; every command just comes back as an echo.

Under the CH340 sits an STC 8051 that can be reflashed through a 4-pin
header, so instead of retiring the boards, this replaces the firmware:

- **Fast enough to play:** one command sets all 16 relays in about 4 ms, and
  the reply is the real relay state.
- **Fail-safe for fire:** the firmware starts with every relay off, and a
  host-silence failsafe drops them all if the controller stops talking. The
  full build adds board-timed pulses and a per-relay max-on limit, so a valve
  closes on time even if the host crashes mid-burst.
- **Many boards, stable numbering:** each board stores its own ID, so a rig
  of eight comes back in the same order after every reboot, on any USB port.
- **Same masks as before:** `h F0F0` means what `set F0F0` meant in
  `usb-relay`, so the old show logic carries over.

## Two builds

| | lite | full |
|---|---|---|
| Fits | stock STC15W401AS (1 KB) | STC15W404AS/408AS (chip swap) |
| Source | 8051 assembly, ~790 bytes | C, ~2.2 KB |
| Commands | `r s c h t i w v` | adds `p d m` |
| Tested | the assembled binary, in ucsim (17 tests) | the C core, in a Linux simulator (19 tests) |

Both share the EEPROM layout, so IDs survive moving a board from lite to full.

**Lite is verified on a real board** (2026-10-25): all commands, relay walk
1-16 in order, failsafe timing, EEPROM save surviving a power cycle.
Round trip 3.0 ms median; setting all 16 relays with a confirmed reply
4.0 ms median, 5.2 ms p99 (stock firmware: ~40 ms per relay, no status).
The full build has not run on hardware yet (needs a 404AS/408AS).

## Layout

| Path | What |
|---|---|
| `firmware/lite/` | lite firmware (asm); `hw.asm` = board, `sim.asm` = ucsim build |
| `firmware/core.c` | full firmware protocol core, hardware independent |
| `firmware/stc15.c` | full firmware STC15 main: pins, UART, timer, EEPROM |
| `sim/sim.c` | runs `core.c` on Linux, on stdin or a pty |
| `host/relay16.py` | Python library and CLI (Windows, macOS, Linux) |
| `linux/` | udev rule: `/dev/relay16-<id>` |
| `test/` | protocol tests: full core on `sim`, lite binary on ucsim |
| `vendor/` | SainSmart's package (not committed) |

## Build and test

Needs `sdcc` 4.x, `sdcc-ucsim` (tests), `stcgal`, `python3-serial`.

```sh
make            # lite + full firmware, simulator
make test       # both test suites (~90 s; ucsim is slow)
```

Try the protocol without hardware:

```sh
sim/sim -v      # type: s 1 / h f0f0 / p 3 500 / r / v
```

## Flash a board

USB-TTL adapter on the 4-pin ISP header, with a 1 kohm pull-up from 5 V to
P3.1. The pin order is not what the schematic suggests:

![ISP header pinout](docs/images/isp-header-pinout.jpg)

Adapter RX to P3.1, adapter TX to P3.0, GND to GND, adapter 5 V left open
(the board runs from its own USB). The setup that flashed the first board,
and cable color notes, are in [docs/HARDWARE.md](docs/HARDWARE.md#photos).

```sh
make -C firmware info         # read-only handshake, then replug the board's USB
make -C firmware flash-lite   # stock chip; EEPROM (ID, settings) kept
make -C firmware flash        # 404AS/408AS; EEPROM kept
```

`PORT` defaults to the first serial adapter that isn't the board's CH340
(`/dev/serial/by-id/...`); pass `PORT=...` to choose another.

## Set up boards

```sh
host/relay16.py -p /dev/ttyUSB0 i 3      # plug in alone, give it an ID
host/relay16.py -p /dev/ttyUSB0 w        # save
host/relay16.py scan                     # list all boards by ID
host/relay16.py -b 3 walk                # click relays 1-16 on board 3
host/relay16.py -b 3 bench               # round-trip latency
make -C linux install                    # /dev/relay16-3 on Linux
```
