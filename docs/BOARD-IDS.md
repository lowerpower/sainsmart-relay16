# Board IDs and board order

With several 16-channel boards on one controller, the software has to hit
the same relay on the same board every time it runs. The CH340 on these
boards has no serial number, and `/dev/ttyUSB0`, `ttyUSB1`, ... (or COM
port numbers) follow USB plug-in and enumeration order, which changes
between boots. So each board stores its own ID in EEPROM, and the host
software finds and orders boards by that ID.

- An ID is 1-255. 0 means unassigned, which is what a freshly flashed board
  has.
- The ID belongs to the board, not to the USB port or the cable. Move a
  board to any port or hub and it keeps its place.
- The ID survives power cycles, and reflashing the firmware
  (`make flash-lite` keeps the EEPROM).
- Boards are never renumbered to fill a gap. A missing board leaves its
  place empty and the others stay where they are.

## Set a board's ID

Stop `usb-relay` first: it holds the boards' serial ports open. Then plug
in the board you are numbering **by itself**, so there is no doubt which
physical board gets which ID.

```sh
host/relay16.py scan                   # find it: "unassigned /dev/ttyUSB0"
host/relay16.py -p /dev/ttyUSB0 i 3    # set ID 3 -> 3
host/relay16.py -p /dev/ttyUSB0 w      # save to EEPROM -> 0000
host/relay16.py -p /dev/ttyUSB0 v      # check -> relay16 1L id 3
```

- `i` takes effect at once but is lost at power-off until `w` saves it.
- `w` is refused (`?`) while any relay is on. Turn them all off first with
  `h 0000`.
- On Windows the port is a COM port (`-p COM7`). `relay16.py` runs on
  Windows, macOS and Linux.
- Unplug and replug the board, then `relay16.py scan` again: it should show
  `board   3  /dev/ttyUSB0`.
- Write the ID on the board and on its cable or harness. Once boards are
  bolted into a rig, the label is the only way to tell them apart.

## Choosing IDs

Pick a scheme before numbering a pile of boards. Either works with
`usb-relay`:

**1 to N on every rig.** Each rig numbers its boards 1, 2, 3, ... and
`usb-relay` runs with no options: board ID N is position N. Simple, but a
board carried over from another rig quietly takes whatever position its ID
has on this one.

**IDs unique across all rigs.** For example (one possible plan, not a
decision):

| Rig | Boards | IDs | usb-relay |
|---|---|---|---|
| Fire Kethedral | 7 | 11-17 | `-b 11,12,13,14,15,16,17` |
| Medusa | 3-4 | 21-24 | `-b 21,22,23,24` |
| Flower Tower | 3-4 | 31-34 | `-b 31,32,33,34` |

Each controller lists its own boards with `-b`. A board from another rig
that ends up plugged in is not on the list, so `usb-relay` warns about it
and never drives it. For fire, a stray board doing nothing is the safer
failure.

## How usb-relay orders boards

`usb-relay` (from [SainSmartUsbRelay](https://github.com/lowerpower/SainSmartUsbRelay))
takes one hex mask for all boards: 4 hex digits per board, the rightmost 4
digits are position 1. Each position is one board, chosen by its ID:

- **default:** board ID N is position N
- **`-b 11,12,13`:** position 1 is board ID 11, position 2 is board ID 12,
  position 3 is board ID 13

| Position | Mask digits (from the right) | Relay 1 on | Default board | With `-b 11,12,13` |
|---|---|---|---|---|
| 1 | 1-4 | `set 0001` | ID 1 | ID 11 |
| 2 | 5-8 | `set 00010000` | ID 2 | ID 12 |
| 3 | 9-12 | `set 000100000000` | ID 3 | ID 13 |

Within a board, relay 1 is `0001`, relay 5 is `0010`, relay 16 is `8000`.
So relay 5 of position 3 is `set 001000000000`, and `set 0000F00F00000001`
turns on relay 1 of position 1, relays 1-4 and 13-16 of position 2, and
nothing on positions 3 and 4.

There are at most 16 positions, so in default mode IDs above 16 are not
used; list them with `-b` instead.

Start `usb-relay` with `-v` to see where each board went:

```
usb-relay: relay16 board ID 1 (firmware 1L) on /dev/ttyUSB1 at position 1, failsafe 1000 ms
```

### What happens when something is off

| Situation | usb-relay |
|---|---|
| A board is missing at startup | warns; its position stays empty: its relays are skipped and `get` shows `0000` for it. The other boards keep their positions |
| A missing board is plugged in, or one drops off USB and comes back | reattached by its ID within about 2 seconds, all relays off |
| Two boards have the same ID | refuses to start (exit code 3) and names both ports |
| A board has ID 0 (unassigned) | warns and does not use it |
| A board's ID is not in the `-b` list | warns and does not use it |
| ID above 16 without `-b` | warns and does not use it |
| Old HID boards are plugged in too | they take the positions after the relay16 boards, in discovery order. HID boards have no ID, so that order can change between runs |

## Replacing a board

Give the spare the dead board's ID and save it, then plug it in where the
old one was:

```sh
host/relay16.py -p /dev/ttyUSB0 i 13
host/relay16.py -p /dev/ttyUSB0 w
```

It takes the same position. Keep spares at ID 0 until they are needed: an
unassigned board plugged in by mistake does nothing. Never leave two boards
on one controller with the same ID; `usb-relay` will not start.

## Check a rig before a burn

With the loads disconnected:

```sh
host/relay16.py scan              # every board by ID; flags DUPLICATE and unassigned
host/relay16.py -b 13 walk        # clicks relays 1-16 of board 13, in order
usb-relay -b 11,12,13,14,15,16,17 -t     # walks every relay of every position, 0.5 s each
```

`scan` and `walk` need `usb-relay` stopped. `usb-relay -t` walks position 1
relay 1 through the last position's relay 16, so it shows the whole order
exactly as the show software will see it.

## Other ways to use the ID

- Python: `Bus(require=[11, 12, 13])` in `host/relay16.py` opens every
  board indexed by ID and raises if one is missing or two share an ID.
- Linux: `make -C linux install` adds a udev rule that names each board
  `/dev/relay16-<ID>` on every boot. `usb-relay` does not need it; it finds
  the boards itself.
