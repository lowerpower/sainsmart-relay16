# SainSmart 101-70-208 hardware

16-channel 9-36 V USB relay module. Vendor package (schematic, code table):
see `vendor/README.md`.

## Parts

| Ref | Part | Notes |
|---|---|---|
| U1 | STC15W401AS, SOP-20 | 8051, 1 KB code, 512 B RAM (256 idata + 256 xdata), 5 KB EEPROM, internal RC |
| U3 | CH340G + 12 MHz crystal | USB serial, no serial number |
| U2, U4 | ULN2803 | relay drivers; MCU pin high = relay on |
| V1 | LM2576-5.0 | 9-36 V in, 5 V for MCU and SRD-05VDC relays |
| Jumper | USB / COM | fitted = run from USB power (needs >= 1.5 A with many relays on) |

## Code space: lite or full

| Build | Source | Size | Chip |
|---|---|---|---|
| lite | `firmware/lite/relay16_lite.asm` (8051 asm) | ~790 B | stock STC15W401AS (1 KB) |
| full | `firmware/core.c` + `stc15.c` (C) | ~2.2 KB | STC15W404AS (4 KB) or STC15W408AS (8 KB) |

The 404AS/408AS are the same series, same SOP-20 footprint and pinout. The
lite build checks itself against 1 KB at build time (`make -C firmware lite`).
Both builds use the same EEPROM layout, so a board keeps its ID when it moves
from lite to full.

## UART and ISP

- CH340 TXD -> 220R -> U1 pin 17 **P3.6 (RxD_2)**; U1 pin 18 **P3.7 (TxD_2)**
  -> 220R -> CH340 RXD. The firmware moves UART1 to these pins.
- STC's ROM bootloader only listens on **P3.0/P3.1**, so the board's own USB
  port **cannot** program the chip.
- The 4-pin header between the CH340 and U1 is the ISP port. Verified on a
  board by elimination (not the order the schematic text suggests). With the
  board oriented as in the photos (U2 above the header, C3 below it):

  | Header pin | Signal | USB-TTL adapter |
  |---|---|---|
  | top (U2 end) | P3.1, MCU TX (also drives K7) | adapter RX |
  | 2nd | P3.0, MCU RX (also drives K8) | adapter TX |
  | 3rd | GND | GND |
  | bottom (C3 end) | VCC 5 V | leave open (board on its own USB) |

- **Add a 1 kohm pull-up from the bottom pin (5 V) to the top pin (P3.1).**
  The ULN2803 input on P3.1 loads the bootloader's quasi-bidirectional TX so
  much that its high level sags and the adapter reads garbage (relay 7
  chatters at boot). With the pull-up the handshake works first time.
- PL2303 console cables: colors vary. On ours **white = TX, green = RX**
  (the reverse of Adafruit's). Check with a loopback and a relay test.
- The bootloader only runs right after a cold power-up: start `make info`
  or `make flash`, then unplug and replug the board's USB when stcgal waits.
  Relay 8 blips (adapter TX idling high on P3.0) and relay 7 chatters while
  the bootloader answers.
- The adapter's TX idling high can back-power the MCU through P3.0 while the
  board is unplugged; keep the power-off short (about 1 s) or unplug TX.

## Relay -> pin map

From the vendor schematic nets. Confirm with `relay16 walk` after flashing.

| Relay | Pin | Relay | Pin |
|---|---|---|---|
| K1 | P5.5 | K9 | P1.1 |
| K2 | P5.4 (reset pin) | K10 | P1.0 |
| K3 | P3.5 | K11 | P1.2 |
| K4 | P3.4 | K12 | P1.3 |
| K5 | P3.3 | K13 | P1.4 |
| K6 | P3.2 | K14 | P1.5 |
| K7 | P3.1 (ISP) | K15 | P1.6 |
| K8 | P3.0 (ISP) | K16 | P1.7 |

- K2 needs `reset_pin_enabled=false` (set by `make flash`).
- **K7 and K8 chatter while flashing.** Disconnect their loads first.

## Power-up glitch: check before use near fire

After reset every STC pin is quasi-bidirectional with a weak pull-up, and the
ROM bootloader runs before the firmware drives the pins low. Through the
ULN2803 inputs that may be enough to energize relays briefly at every power-up.
No firmware can fix this, because the bootloader runs first.

Test with all loads disconnected: power-cycle repeatedly and watch the relay
LEDs and listen for clicks. If any twitch:

- add 10 kohm pull-downs on the ULN2803 inputs, or
- flash with `-o bsl_pindetect_enabled=true`: the bootloader is skipped
  unless P3.2 and P3.3 are held low at power-up, which shortens the window.
  Reflashing then needs those two pins grounded during power-up.

## Stock chip settings

Read with stcgal before flashing: `docs/stock-chip-info.txt`. STC15W401AS,
BSL 7.2.5T, stock firmware clocked at 11.0592 MHz (relay16 trims the RC to
22.1184 MHz when flashing), reset pin already disabled, EEPROM erase on
programming already off.

## Stock firmware (for reference)

9600 8N1, Modbus ASCII to slave 0xFE (`:FE050000FF00FE` = relay 1 on). Every
command, including reads, is answered with an exact echo of the request about
21 ms later; there is no real status reply. The STC chip cannot be read back,
so erasing it is one-way.
