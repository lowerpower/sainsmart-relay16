# relay16 serial protocol, v1

ASCII lines over the board's USB port (CH340), **115200 8N1**, no flow control.

## Framing

- A command ends with `\r` or `\n`. `\r\n` works too: the empty line that
  follows is ignored. Any terminal on Windows, macOS or Linux works.
- Every command gets exactly **one** reply line, ending `\r\n`.
- Commands are case-insensitive; spaces and tabs between fields are ignored.
- No echo.
- **One command at a time:** wait for the reply before sending the next
  line. Bytes that arrive while a command is being handled are dropped.
- Lines longer than 20 characters, control characters, unknown commands and
  bad arguments get `?`.

## Relay state

The state is a 16-bit mask printed as 4 uppercase hex digits. Bit 0 is
relay 1, so `0001` = relay 1, `8000` = relay 16, `F0F0` = relays 5-8 and
13-16 (the same convention as `usb-relay` in SainSmartUsbRelay).

Relay numbers are decimal 1-16, matching the silkscreen.

| Command | Action | Reply |
|---|---|---|
| `r` | read | state |
| `s N` | relay N on | state |
| `c N` | relay N off | state |
| `h XXXX` | set all 16 from a hex mask (1-4 digits) | state |
| `p N [MS]` | relay N on for MS ms, then off; without MS uses the default set by `d` | state |

`p` is timed on the board (1 ms resolution, 1-65535 ms), so the burst length
does not depend on host or USB timing, and the relay still turns off if the
host dies mid-pulse. `p N` with no MS and no default set is `?`.

## Settings

Each returns the current value in decimal; give a value to change it.
Changes are live immediately but kept only in RAM until `w`.

| Command | Setting | Default |
|---|---|---|
| `d N [MS]` | default pulse length for `p N` | 0 (none) |
| `m N [MS]` | max-on interlock for relay N: however it was turned on, it turns off after MS ms continuously on | 0 (no limit) |
| `t [MS]` | failsafe: all relays off after MS ms with no valid command | 0 (off) |
| `i [ID]` | board ID, 1-255; 0 = unassigned | 0 |
| `w` | save settings to EEPROM; refused (`?`) unless all relays are off | state |
| `v` | version | `relay16 1 id 3` (`relay16 1L id 3` on lite) |

Interlock details: the max-on timer starts when a relay goes from off to on.
Repeating `s N` on a relay that is already on does not restart it, and a `p`
pulse never runs past the remaining max-on time. Changing `m` affects the
next time the relay turns on.

## Lite firmware

The lite build (8051 assembly, fits the stock 1 KB chip) implements
`r s c h t i w v` exactly as above and answers `?` to `p`, `d` and `m`:
no board-timed pulses and no max-on interlock. `v` reports version `1L`.

Differences in framing: lite parses each character as it arrives, so it has
no 20-character line limit (junk or an out-of-range number still makes the
line `?`), and it accepts a number written directly after the command
(`s5`).

## Power-up

- All relays off. A power-on relay state is deliberately not stored.
- Settings load from EEPROM. If the stored block fails its checksum (or was
  never written), everything is default and the ID is 0 (unassigned).
- Flashing new firmware keeps the EEPROM, so IDs and settings survive,
  including switching between the lite and full builds (same layout).

## Finding boards

The CH340 has no USB serial number, so boards are told apart by their stored
ID. Hosts find CH340 ports (USB 1a86:7523), send `v`, and index boards by ID.
A missing board is reported by ID; boards never renumber to fill a gap.
Duplicate IDs and unassigned boards are errors, not guesses.

Setting up or replacing a board: plug it in alone, `i N`, `w`, label it.

## Examples

```
> s 1           > h f0f0        > p 3 250       > v
< 0001          < F0F0          < F0F4          < relay16 1 id 3
> s 16          > c 5           (250 ms later)  > x
< 8001          < F0E0          > r             < ?
                                < F0F0
```
