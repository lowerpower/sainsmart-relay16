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
Hardware, flashing and pin map: [docs/HARDWARE.md](docs/HARDWARE.md).

## Two builds

| | lite | full |
|---|---|---|
| Fits | stock STC15W401AS (1 KB) | STC15W404AS/408AS (chip swap) |
| Source | 8051 assembly, ~790 bytes | C, ~2.2 KB |
| Commands | `r s c h t i w v` | adds `p d m` |
| Tested | the assembled binary, in ucsim (17 tests) | the C core, in a Linux simulator (19 tests) |

Both share the EEPROM layout, so IDs survive moving a board from lite to full.

**Neither has run on a real board yet.**

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

USB-TTL adapter on the 4-pin ISP header (docs/HARDWARE.md), then:

```sh
make -C firmware info       PORT=/dev/ttyUSB1   # read-only handshake
make -C firmware flash-lite PORT=/dev/ttyUSB1   # stock chip; EEPROM kept
make -C firmware flash      PORT=/dev/ttyUSB1   # 404AS/408AS; EEPROM kept
```

## Set up boards

```sh
host/relay16.py -p /dev/ttyUSB0 i 3      # plug in alone, give it an ID
host/relay16.py -p /dev/ttyUSB0 w        # save
host/relay16.py scan                     # list all boards by ID
host/relay16.py -b 3 walk                # click relays 1-16 on board 3
host/relay16.py -b 3 bench               # round-trip latency
make -C linux install                    # /dev/relay16-3 on Linux
```
