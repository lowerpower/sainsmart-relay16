; sainsmart-relay16 - fast, indexable, fail-safe firmware and host tools
; for SainSmart 16-channel USB relay boards
;
; Copyright (c) 2025-2026 Mike Johnson (Mycal)
;
; Author:       https://anchorid.net/resolve/4ff7ed97-b78f-4ae6-9011-5af714ee241c
; Repository:   https://github.com/lowerpower/sainsmart-relay16
;
; SPDX-License-Identifier: MIT
; See LICENSE file for full terms.
;
; Built for the Reared In Steel crew's fire art.

; ============================================================================
; relay16_lite.asm - relay16 lite firmware, 8051 assembly, fits in 1 KB
; ============================================================================
;
; Target: the STC15W401AS that ships on the SainSmart 101-70-208 16-channel
; serial relay board. That chip has 1 KB of code flash, which is too small
; for the C version of the firmware (~2.2 KB with SDCC), so this is the same
; protocol written by hand in 8051 assembly. It assembles to about 790 bytes.
;
; Protocol (docs/PROTOCOL.md), lite subset:
;
;       r           read relay state            -> "XXXX" (hex mask)
;       s N         relay N on  (1-16)          -> "XXXX"
;       c N         relay N off (1-16)          -> "XXXX"
;       h XXXX      set all 16 from a hex mask  -> "XXXX"
;       t [MS]      host-silence failsafe, ms   -> "MS"   (0 = off)
;       i [ID]      board ID, 0-255             -> "ID"   (0 = unassigned)
;       w           save t and i to EEPROM      -> "XXXX" (all relays off)
;       v           version                     -> "relay16 1L id N"
;       anything else                           -> "?"
;
;   Bit 0 of the mask is relay 1, so "0001" is relay 1 and "8000" is relay 16,
;   the same convention as usb-relay. Every reply line ends in CR LF.
;
;   No p/d/m in lite: no board-timed pulses and no max-on interlock. Those
;   live in the full (C) build, which needs a 4 KB or 8 KB part.
;
; EEPROM layout matches the full firmware (core.c, cfg_t) byte for byte:
;
;       0       magic, 0xA5
;       1       board ID
;       2-3     failsafe ms, little-endian
;       4-67    full firmware's pulse / max-on tables (lite writes zeros)
;       68      checksum: 0x5A + sum of bytes 0-67, low 8 bits
;
;   So a board keeps its ID and failsafe when it moves between lite and full.
;
; Two builds from this one file:
;
;       hw.asm  (SIM = 0)   the board: STC timer 2 baud, 1T timer 0, IAP EEPROM
;       sim.asm (SIM = 1)   ucsim, a generic 8051 simulator, for the tests:
;                           timer 1 baud, 12T timer 0, EEPROM stood in by XRAM
;
;   Everything else - the parser, the replies, the failsafe, the pin map, the
;   EEPROM layout and checksum - is the same code in both, so test/test_lite.py
;   exercises what actually goes on the chip.
;
; Relay -> pin, from the vendor schematic (two ULN2803s, pin high = relay on):
;
;       K1 P5.5   K2 P5.4   K3 P3.5   K4 P3.4   K5 P3.3   K6 P3.2
;       K7 P3.1   K8 P3.0   K9 P1.1   K10 P1.0  K11-K16 P1.2-P1.7
;
;   P5.4 is the chip's reset pin; it only works as I/O for K2 because the
;   board is flashed with reset_pin_enabled=false. P3.0/P3.1 are also the
;   ISP (bootloader) pins, which is why relays 8 and 7 chatter when flashing.
;
; Serial: UART1 moved to its alternate pins P3.6/P3.7, which are the ones
; wired to the CH340 USB chip. 115200 8N1 from the internal RC oscillator,
; trimmed to 22.1184 MHz by stcgal at flash time.
;
; Register use: no interrupts and no register banks. r0-r7 are scratch, and
; each routine says which it uses. Everything persistent lives at fixed
; RAM addresses (see RAM below).

        .module relay16_lite

; ----------------------------------------------------------------------------
; Special function registers
; ----------------------------------------------------------------------------
;
; The assembler doesn't know the STC15's extra registers, so every SFR and
; bit this file touches is defined here by address, from the STC15 data sheet.

SP        = 0x81                ; stack pointer
DPL       = 0x82                ; data pointer, low byte
DPH       = 0x83                ; data pointer, high byte
PCON      = 0x87                ; power control; bit 7 = SMOD (baud doubler)
TCON      = 0x88                ; timer control (TF0/TR0/TR1 live here)
TMOD      = 0x89                ; timer modes
TL0       = 0x8A                ; timer 0 low  / reload low on STC15
TH0       = 0x8C                ; timer 0 high / reload high on STC15
TH1       = 0x8D                ; timer 1 high (ucsim baud reload)
AUXR      = 0x8E                ; STC: timer clock dividers, T2 run, UART1 baud source
P1        = 0x90                ; port 1: relays 9-16
P1M1      = 0x91                ; port 1 mode bits (M1:M0 = 0:1 is push-pull)
P1M0      = 0x92
SCON      = 0x98                ; UART1 control
SBUF      = 0x99                ; UART1 data, both directions
P_SW1     = 0xA2                ; STC: peripheral pin switch (UART1 pin set)
P2        = 0xA0                ; port 2 (not bonded out on SOP-20, unused)
P3        = 0xB0                ; port 3: relays 3-8 on P3.0-P3.5, UART on P3.6/P3.7
P3M1      = 0xB1                ; port 3 mode bits
P3M0      = 0xB2
WDT_CONTR = 0xC1                ; STC: watchdog control
IAP_DATA  = 0xC2                ; STC: EEPROM (IAP) data
IAP_ADDRH = 0xC3                ; STC: EEPROM address high
IAP_ADDRL = 0xC4                ; STC: EEPROM address low
IAP_CMD   = 0xC5                ; STC: EEPROM command (1 read, 2 write, 3 erase)
IAP_TRIG  = 0xC6                ; STC: EEPROM trigger (write 5A then A5)
IAP_CONTR = 0xC7                ; STC: EEPROM enable and wait states
P5        = 0xC8                ; port 5: relays 1-2 on P5.5/P5.4
P5M1      = 0xC9                ; port 5 mode bits
P5M0      = 0xCA
T2H       = 0xD6                ; STC: timer 2 reload high (baud generator)
T2L       = 0xD7                ; STC: timer 2 reload low
ACC       = 0xE0                ; accumulator (direct address, for push/pop)
B         = 0xF0                ; B register

; bit addresses

TR0       = 0x8C                ; TCON.4  timer 0 run
TF0       = 0x8D                ; TCON.5  timer 0 overflow: our 1 ms tick
TR1       = 0x8E                ; TCON.6  timer 1 run (ucsim only)
RI        = 0x98                ; SCON.0  UART byte received
TI        = 0x99                ; SCON.1  UART byte sent
P3_0      = 0xB0                ; K8
P3_1      = 0xB1                ; K7
P3_2      = 0xB2                ; K6
P3_3      = 0xB3                ; K5
P3_4      = 0xB4                ; K4
P3_5      = 0xB5                ; K3
P5_4      = 0xCC                ; K2 (the reset pin, flashed as I/O)
P5_5      = 0xCD                ; K1
ACC_0     = 0xE0                ; accumulator bit 0
ACC_1     = 0xE1                ; accumulator bit 1
B_0       = 0xF0                ; B bit 0
B_1       = 0xF1                ; B bit 1

; ----------------------------------------------------------------------------
; RAM
; ----------------------------------------------------------------------------
;
; Fixed addresses in direct RAM, above register bank 0 (0x00-0x07). The
; startup code zeroes 0x01-0x7F, so every variable starts at 0: relays off,
; parser idle, no failsafe, unassigned ID until cfg_load says otherwise.

state_lo  = 0x08                ; relay mask, relays 1-8   (bit 0 = relay 1)
state_hi  = 0x09                ; relay mask, relays 9-16  (bit 0 = relay 9)
val_lo    = 0x0A                ; number being parsed, or about to be printed
val_hi    = 0x0B
idle_lo   = 0x0C                ; ms since the last valid command (failsafe)
idle_hi   = 0x0D
cmd       = 0x0E                ; command letter of the current line, lowercase
nd        = 0x0F                ; how many digits of the argument we've seen
st        = 0x10                ; line parser state:
                                ;   0 waiting for a command letter
                                ;   1 have the letter, maybe reading a number
                                ;   2 saw a space after the number
                                ;   3 junk: ignore until end of line, then "?"
cfg_magic = 0x11                ; first 4 bytes of the EEPROM block, in order,
cfg_id    = 0x12                ;   so cfg_load/cfg_save can walk them with r1
cfg_fs_lo = 0x13                ; failsafe ms, low byte
cfg_fs_hi = 0x14                ; failsafe ms, high byte
STACK     = 0x20                ; stack grows up from here; deepest use is a
                                ;   few levels of acall, well under 0x7F

CFG_MAGIC = 0xA5                ; marks a block we wrote
CFG_SEED  = 0x5A                ; checksum seed, so an all-0x00 block fails
CFG_SUM   = 68                  ; offset of the checksum byte

; Timer 0 reload for a 1 ms tick at 22.1184 MHz. The STC runs timer 0 in 1T
; mode (one count per clock); the ucsim build has a classic 12T 8051.
.if SIM
T0_RELOAD = 0x10000 - 1843      ; 22118400 / 12 / 1000
.else
T0_RELOAD = 0x10000 - 22118     ; 22118400 / 1000
.endif
T2_RELOAD = 0x10000 - 48        ; 115200 baud: 22118400 / 4 / 115200 = 48

; ============================================================================
; Code
; ============================================================================
;
; No interrupt vectors are used, so the program starts right at address 0.

        .area CODE (ABS)
        .org  0

        ;
        ; Power-up. The ROM bootloader has already run and handed us the chip
        ; with every pin in quasi-bidirectional mode, weakly pulled high. That
        ; can be enough to nudge the relay drivers, so the first job is to get
        ; all 16 outputs driven low.
        ;
start:  mov   SP, #STACK-1      ; stack just above our variables
        clr   a                 ; zero all of direct RAM, 0x7F down to 0x01,
        mov   r0, #0x7F         ;   so every variable starts at 0
clr_lp: mov   @r0, a            ; (r0 itself, at 0x00, ends at 0 by the
        djnz  r0, clr_lp        ;   loop's own count)

        ;
        ; Relay outputs. Write the latches low first, then switch the pins to
        ; push-pull, so a pin never drives high on the way. P3.6 (UART RX)
        ; stays quasi-bidirectional so the CH340 can drive it; P3.7 (UART TX)
        ; goes push-pull with the relay pins.
        ;
        mov   P1, #0x00         ; relays 9-16 latched off
        mov   P3, #0xC0         ; relays 3-8 off, UART pins P3.6/P3.7 high
        anl   P5, #0xCF         ; relays 1-2 off (P5.4, P5.5 low)
        mov   P1M1, #0x00       ; port 1: all push-pull
        mov   P1M0, #0xFF
        mov   P3M1, #0x00       ; port 3: push-pull except P3.6 (RX)
        mov   P3M0, #0xBF
        anl   P5M1, #0xCF       ; port 5: P5.4/P5.5 push-pull,
        orl   P5M0, #0x30       ;   other port 5 bits untouched

        mov   WDT_CONTR, #0x33  ; watchdog on, prescale 16: resets the chip
                                ;   if the main loop stalls for ~280 ms

        ;
        ; Serial port and the 1 ms tick.
        ;
        mov   SCON, #0x50       ; UART mode 1 (8N1, variable baud), receive on
        mov   TL0, #<T0_RELOAD  ; timer 0 reload value for 1 ms
        mov   TH0, #>T0_RELOAD
.if SIM
        ;
        ; ucsim: a classic 8051. Baud from timer 1 in 8-bit auto-reload, and
        ; timer 0 in 16-bit mode 1 (no auto-reload, so tick reloads it).
        ;
        mov   TMOD, #0x21       ; T1 mode 2 (baud), T0 mode 1 (16-bit)
        mov   TH1, #0xFF        ; 115200 with SMOD at 22.1184 MHz:
        orl   PCON, #0x80       ;   22118400 / 12 / 16 / (256 - 255)
        setb  TR1               ; start the baud clock
.else
        ;
        ; STC15: UART1 moves to the CH340's pins and takes its baud clock
        ; from timer 2. TMOD is 0 from reset, which on the STC15 makes timer
        ; 0 a 16-bit auto-reload timer, so TL0/TH0 above double as its
        ; reload registers and the tick never has to reload it.
        ;
        mov   P_SW1, #0x40      ; UART1 on P3.6 (RX) / P3.7 (TX)
        mov   T2L, #<T2_RELOAD  ; timer 2 reload for 115200
        mov   T2H, #>T2_RELOAD
        mov   AUXR, #0x95       ; bit 7 T0x12: timer 0 counts every clock
                                ; bit 4 T2R:   timer 2 runs
                                ; bit 2 T2x12: timer 2 counts every clock
                                ; bit 0 S1ST2: UART1 baud from timer 2
.endif
        setb  TR0               ; start the 1 ms tick

        acall cfg_load          ; board ID and failsafe from EEPROM
        acall apply             ; drive the (all-zero) relay state out

; ----------------------------------------------------------------------------
; Main loop
; ----------------------------------------------------------------------------
;
; Everything is polled; there are no interrupts. Each pass feeds the
; watchdog, runs the 1 ms tick if timer 0 has overflowed, and handles a
; received byte if one is waiting. jbc tests a flag and clears it in the
; same instruction, so a flag can't be lost between the test and the clear.
;
; Reception is safe as long as the host sends one command and waits for the
; reply: a byte takes 87 us at 115200 and this loop is a few microseconds.
; While a reply is being sent, further incoming bytes can be lost, which is
; why the protocol is one command at a time.

loop:   mov   WDT_CONTR, #0x33  ; feed the watchdog (CLR bit set in 0x33)
        jbc   TF0, tick         ; 1 ms elapsed?    clear the flag, go tick
        jbc   RI, rx            ; byte arrived?    clear the flag, go parse it
        sjmp  loop

; ----------------------------------------------------------------------------
; 1 ms tick: the host-silence failsafe
; ----------------------------------------------------------------------------
;
; idle counts milliseconds since the last valid command (execute zeroes it).
; When it reaches the failsafe setting, every relay goes off. It then stops
; counting at the limit, so the relays are switched off once, not every ms,
; and the host can turn them back on and start a new countdown.
;
; A failsafe of 0 disables all of this. Uses a only.

tick:
.if SIM
        mov   TL0, #<T0_RELOAD  ; ucsim's mode 1 has no auto-reload,
        mov   TH0, #>T0_RELOAD  ;   so put the 1 ms count back by hand
.endif
        mov   a, cfg_fs_lo      ; failsafe = 0?
        orl   a, cfg_fs_hi
        jz    loop              ; yes: disabled, nothing to do
        ;
        ; Already at the limit? Then it has fired (or is about to) and we
        ; leave idle parked there until a valid command resets it.
        ;
        mov   a, idle_lo        ; compare idle with the failsafe, low byte
        cjne  a, cfg_fs_lo, tk_inc
        mov   a, idle_hi        ; then high byte
        cjne  a, cfg_fs_hi, tk_inc
        sjmp  loop              ; equal: parked at the limit
        ;
        ; Count one more millisecond (16-bit increment).
        ;
tk_inc: inc   idle_lo           ; low byte
        mov   a, idle_lo        ; a = new low byte, used by the compare below
        jnz   tk_cmp            ; no wrap: done
        inc   idle_hi           ; low wrapped to 0: carry into high (a stays 0,
                                ;   which is still the right low byte)
        ;
        ; Did we just reach the limit? If so, and anything is on, drop it all.
        ;
tk_cmp: cjne  a, cfg_fs_lo, loop ; low byte not there yet
        mov   a, idle_hi
        cjne  a, cfg_fs_hi, loop ; high byte not there yet
        mov   a, state_lo       ; reached the limit: any relay on?
        orl   a, state_hi
        jz    loop              ; no: nothing to switch off
        clr   a                 ; yes: all relays off
        mov   state_lo, a
        mov   state_hi, a
        acall apply             ; and drive the pins
        sjmp  loop

; ----------------------------------------------------------------------------
; Receive: the line parser
; ----------------------------------------------------------------------------
;
; There is no line buffer. Each byte moves a small state machine (st) along
; as it arrives, accumulating the one optional number into val as it goes.
; Saving the buffer saves RAM and code, and means there is no line length
; limit: a line that turns into junk is simply ignored until it ends, then
; answered with "?".
;
;   st 0  waiting: spaces are skipped, the first printable byte is the command
;   st 1  have a command: digits accumulate into val, spaces after digits
;         move to st 2
;   st 2  after the number: more spaces are fine, anything else is junk
;   st 3  junk: everything up to the end of the line is ignored
;
; CR or LF ends a line. An empty line (st still 0) is ignored entirely, which
; is what makes CR LF work: the CR runs the command and the LF that follows
; is an empty line.
;
; Uses a, r4-r7, b.

rx:     mov   a, SBUF           ; the received byte
        mov   r7, a             ; keep a copy; a gets reused
        cjne  a, #0x0D, rx_nl   ; CR?
        sjmp  rx_eol            ;   yes: end of line
rx_nl:  cjne  a, #0x0A, rx_chr  ; LF? no: an ordinary character
        ;
        ; End of line. If there was a command, run it (execute sends the
        ; reply, "?" included). Either way the next line starts clean: st and
        ; nd back to 0, or a leading space on the next line would be taken as
        ; a space after a number.
        ;
rx_eol: mov   a, st             ; anything on this line?
        jz    rx_new            ; no: blank line, ignore it
        acall execute           ; yes: run it and reply
rx_new: mov   st, #0            ; next line starts clean
        mov   nd, #0
        sjmp  loop

        ;
        ; An ordinary character. In junk state, swallow it.
        ;
rx_chr: mov   a, st
        cjne  a, #3, rx_sp      ; not junk: look at the character
        sjmp  loop              ; junk: ignore until end of line
        ;
        ; Space or tab. Before the number (or before the command) it means
        ; nothing; after at least one digit it closes the number (st 2).
        ;
rx_sp:  mov   a, r7
        cjne  a, #0x20, rx_tab  ; space?
        sjmp  rx_ws
rx_tab: cjne  a, #0x09, rx_prn  ; tab?
rx_ws:  mov   a, nd             ; any digits yet?
        jz    loop              ; no: skip the space
        mov   st, #2            ; yes: the number is finished
        sjmp  loop

        ;
        ; Anything else must be printable, '!' (0x21) to '~' (0x7E).
        ; Control characters and bytes above 0x7E poison the line.
        ;
        ; Two adds do the range check: a + (0x100 - 0x21) carries exactly
        ; when a >= 0x21, leaving a - 0x21; adding (0x100 - 0x5E) to that
        ; carries when a - 0x21 >= 0x5E, i.e. when a > 0x7E.
        ;
rx_prn: add   a, #0x100-0x21    ; carry if >= '!'
        jnc   rx_bad            ; below '!': control character, junk
        add   a, #0x100-0x5E    ; carry if > '~'
        jc    rx_bad            ; above '~': junk
        mov   a, r7             ; the character again
        orl   a, #0x20          ; lowercase: 'S' -> 's', 'A' -> 'a'. Digits
        mov   r7, a             ;   already have bit 5 set, so they're unchanged
        mov   a, st
        jnz   rx_arg            ; already have a command: this is an argument
        ;
        ; First printable character of the line: it's the command. Reset the
        ; number for the argument that may follow.
        ;
        mov   cmd, r7           ; remember the command letter
        clr   a
        mov   val_lo, a         ; argument = 0
        mov   val_hi, a
        mov   nd, a             ; no digits yet
        mov   st, #1            ; now expecting an optional number
        ajmp  loop

        ;
        ; A character after the command. In st 2 (number already finished)
        ; any second argument is junk; in st 1 it must be a digit.
        ;
rx_arg: cjne  a, #2, rx_dig     ; st 1: try it as a digit
rx_bad: mov   st, #3            ; st 2, or not a valid digit: junk
        ajmp  loop

        ;
        ; Digits. 0-9 always; a-f only for the h command, which takes hex.
        ; r6 ends up holding the digit's value, 0-15.
        ;
rx_dig: mov   a, r7
        add   a, #0x100-0x30    ; a = char - '0'
        mov   r6, a             ;   (the digit's value, if it is one)
        add   a, #0x100-10      ; carry if char - '0' >= 10, i.e. not 0-9
        jnc   rx_dec            ; 0-9
        mov   a, cmd            ; not 0-9: only h accepts a-f
        cjne  a, #0x68, rx_bad  ; 'h'? no: junk
        mov   a, r7
        add   a, #0x100-0x61    ; a = char - 'a'
        mov   r6, a
        add   a, #0x100-6       ; carry if char - 'a' >= 6, i.e. past 'f'
        jc    rx_bad            ; not a-f: junk
        mov   a, r6
        add   a, #10            ; 'a'-'f' -> 10-15
        mov   r6, a
        sjmp  rx_hex            ; a hex digit, so h: accumulate as hex
rx_dec: mov   a, cmd            ; a decimal digit: hex for h, decimal otherwise
        cjne  a, #0x68, rx_mul  ; 'h'? no: decimal

        ;
        ; Hex accumulate: val = val << 4 | digit, at most 4 digits (16 bits).
        ;
        ; The 16-bit shift by 4 is done with swap, which exchanges the
        ; nibbles of a byte: the high nibble of val_lo moves into the low
        ; nibble of val_hi, and the digit drops into the bottom of val_lo.
        ;
rx_hex: mov   a, nd             ; already 4 hex digits?
        cjne  a, #4, rx_h4
        sjmp  rx_bad            ; a 5th: too big for 16 bits, junk
rx_h4:  mov   a, val_hi
        swap  a                 ; high byte's low nibble -> top
        anl   a, #0xF0          ;   (its old top nibble falls off)
        mov   r5, a             ; r5 = new high nibble of val_hi
        mov   a, val_lo
        swap  a                 ; exchange val_lo's nibbles
        mov   r4, a             ; r4 = val_lo, nibbles swapped
        anl   a, #0x0F          ; val_lo's old top nibble, now at the bottom,
        orl   a, r5             ;   becomes val_hi's low nibble
        mov   val_hi, a
        mov   a, r4
        anl   a, #0xF0          ; val_lo's old bottom nibble, now on top,
        orl   a, r6             ;   with the new digit underneath
        mov   val_lo, a
        sjmp  rx_cnt

        ;
        ; Decimal accumulate: val = val * 10 + digit, refusing anything over
        ; 65535 rather than letting it wrap ("t 70000" must be "?", not a
        ; surprise 4464 ms failsafe).
        ;
        ; mul ab gives a 16-bit product in b:a, so the low byte times 10 is
        ; at most 2550, plus the digit 2559, a 12-bit number. Its high part
        ; carries into the high byte, and the high byte times 10 must itself
        ; fit in 8 bits.
        ;
rx_mul: mov   a, val_lo
        mov   b, #10
        mul   ab                ; b:a = val_lo * 10
        add   a, r6             ;   + digit
        mov   val_lo, a         ; new low byte
        mov   a, b
        addc  a, #0             ; carry from adding the digit
        mov   r5, a             ; r5 = what carries into the high byte
        mov   a, val_hi
        mov   b, #10
        mul   ab                ; b:a = val_hi * 10
        xch   a, b              ; a = overflow byte, b = product low byte
        jnz   rx_bad            ; val_hi * 10 > 255: over 65535, junk
        mov   a, b
        add   a, r5             ; high byte = val_hi * 10 + carry in
        jc    rx_bad            ; carried out: over 65535, junk
        mov   val_hi, a
rx_cnt: inc   nd                ; one more digit
        ajmp  loop

; ----------------------------------------------------------------------------
; Execute a complete line
; ----------------------------------------------------------------------------
;
; Called at end of line with cmd, nd (digit count) and val (the number, if
; nd > 0) filled in. Sends exactly one reply line. Every valid command ends
; at ex_ok, which also restarts the failsafe countdown; every invalid one
; ends at ex_q, which does not.
;
; Relay commands (r s c h w) reply with the 16-bit state in hex. Setting
; commands (i t) reply with the value in decimal. v replies with its string.
;
; Uses a, r1-r7, b, dptr.

execute:
        mov   a, st
        cjne  a, #3, ex_r       ; junk line?
        sjmp  ex_q              ;   yes: "?"
        ;
        ; r: read. No argument allowed.
        ;
ex_r:   mov   a, cmd
        cjne  a, #0x72, ex_w    ; 'r'?
        mov   a, nd
        jnz   ex_q              ; "r 5": no argument allowed
        sjmp  ex_show           ; reply with the state
        ;
        ; w: save settings to EEPROM. Only with every relay off: an EEPROM
        ; erase stalls the CPU for milliseconds, and a relay shouldn't be
        ; sitting on while the firmware isn't watching.
        ;
ex_w:   cjne  a, #0x77, ex_h    ; 'w'?
        mov   a, nd
        jnz   ex_q              ; no argument allowed
        mov   a, state_lo       ; any relay on?
        orl   a, state_hi
        jnz   ex_q              ;   yes: refuse
        acall cfg_save          ; write the block
        sjmp  ex_show           ; reply with the state (0000)
        ;
        ; h XXXX: set all 16 relays. The parser already built the mask in
        ; val; it just has to have been given.
        ;
ex_h:   cjne  a, #0x68, ex_s    ; 'h'?
        mov   a, nd
        jz    ex_q              ; "h" with no mask: "?"
        sjmp  ex_set            ; val is the new state
        ;
        ; s N: relay N on. OR its bit into the state.
        ;
ex_s:   cjne  a, #0x73, ex_c    ; 's'?
        acall relay_bit         ; r4:r5 = relay N's bit, C set if N invalid
        jc    ex_q
        mov   a, state_lo
        orl   a, r5             ; set the bit, low byte
        mov   val_lo, a
        mov   a, state_hi
        orl   a, r4             ; and high byte
        mov   val_hi, a
        sjmp  ex_set
        ;
        ; c N: relay N off. AND the state with the bit's complement.
        ;
ex_c:   cjne  a, #0x63, ex_i    ; 'c'?
        acall relay_bit         ; r4:r5 = relay N's bit, C set if N invalid
        jc    ex_q
        mov   a, r5
        cpl   a                 ; every bit except relay N's
        anl   a, state_lo       ; clear it, low byte
        mov   val_lo, a
        mov   a, r4
        cpl   a
        anl   a, state_hi       ; and high byte
        mov   val_hi, a
        ;
        ; Common tail for h, s and c: val is the new state. Store it, drive
        ; the pins, and fall through to reply with it.
        ;
ex_set: mov   state_lo, val_lo
        mov   state_hi, val_hi
        acall apply             ; out to the relays
ex_show:
        mov   a, state_hi       ; reply "XXXX": high byte first,
        acall puthex2
        mov   a, state_lo       ;   then low byte
        acall puthex2
        sjmp  ex_ok
        ;
        ; Anything invalid: "?" and CR LF. Doesn't touch the failsafe.
        ;
ex_q:   mov   a, #0x3F          ; '?'
        acall putc
        sjmp  crlf
        ;
        ; i [ID]: board ID, 0-255. With a number, set it (RAM only until w);
        ; either way reply with the current value.
        ;
ex_i:   cjne  a, #0x69, ex_t    ; 'i'?
        mov   a, nd
        jz    ex_i2             ; no number: just report
        mov   a, val_hi
        jnz   ex_q              ; over 255: "?"
        mov   cfg_id, val_lo    ; set it
ex_i2:  mov   val_lo, cfg_id    ; reply with the ID
        mov   val_hi, #0
        sjmp  ex_dec
        ;
        ; t [MS]: failsafe in ms, 0-65535, 0 = off. Same pattern as i.
        ;
ex_t:   cjne  a, #0x74, ex_v    ; 't'?
        mov   a, nd
        jz    ex_t2             ; no number: just report
        mov   cfg_fs_lo, val_lo ; set it
        mov   cfg_fs_hi, val_hi
ex_t2:  mov   val_lo, cfg_fs_lo ; reply with the failsafe
        mov   val_hi, cfg_fs_hi
        sjmp  ex_dec
        ;
        ; v: version. Prints "relay16 1L id " from code memory, then the ID
        ; through the i reply path (ex_i2).
        ;
ex_v:   cjne  a, #0x76, ex_q    ; 'v'? no: unknown command, "?"
        mov   a, nd
        jnz   ex_q              ; no argument allowed
        mov   dptr, #version
ex_v2:  clr   a
        movc  a, @a+dptr        ; next byte of the string
        jz    ex_i2             ; 0 terminator: go print the ID
        acall putc
        inc   dptr
        sjmp  ex_v2
        ;
        ; Decimal reply, then the common valid-command ending.
        ;
ex_dec: acall putdec            ; val in decimal
ex_ok:  clr   a                 ; a valid command: restart the failsafe
        mov   idle_lo, a
        mov   idle_hi, a
crlf:   mov   a, #0x0D          ; CR
        acall putc
        mov   a, #0x0A          ; LF, then fall into putc and return
        ;
        ; putc: send the byte in a and wait until it has gone. Uses a only.
        ;
putc:   mov   SBUF, a           ; start sending
putc_w: jnb   TI, putc_w        ; wait for the last bit to leave
        clr   TI
        ret

; ----------------------------------------------------------------------------
; relay_bit: relay number in val (1-16) -> its mask bit in r4:r5
; ----------------------------------------------------------------------------
;
; r5 is the low byte, r4 the high. Carry is clear on success, set if there
; was no number or it was outside 1-16. Uses a, r3, r4, r5.

relay_bit:
        mov   a, nd
        jz    rb_bad            ; no number given
        mov   a, val_hi
        jnz   rb_bad            ; 256 or more
        mov   a, val_lo
        jz    rb_bad            ; relay 0 doesn't exist
        add   a, #0x100-17      ; carry if val >= 17
        jc    rb_bad
        ;
        ; Start with relay 1's bit (0x0001) and shift it left val - 1 times.
        ; djnz decrements first, so loading val runs the shift val - 1 times.
        ;
        mov   r3, val_lo        ; loop count
        mov   r5, #1            ; r4:r5 = 0x0001
        mov   r4, #0
rb_lp:  djnz  r3, rb_sh         ; more shifting to do?
        clr   c                 ; done: success
        ret
rb_sh:  mov   a, r5             ; r4:r5 <<= 1
        add   a, r5             ;   low byte doubled, top bit into carry
        mov   r5, a
        mov   a, r4
        rlc   a                 ;   carry into the high byte
        mov   r4, a
        sjmp  rb_lp
rb_bad: setb  c                 ; invalid relay number
        ret

; ----------------------------------------------------------------------------
; Output helpers
; ----------------------------------------------------------------------------

        ;
        ; puthex2: the byte in a as two uppercase hex digits. Uses a.
        ;
puthex2:
        push  ACC               ; keep the byte for the low nibble
        swap  a                 ; high nibble first
        acall hexnib
        pop   ACC               ; then fall into hexnib for the low nibble
        ;
        ; hexnib: the low nibble of a as one hex digit, '0'-'9' or 'A'-'F'.
        ;
        ; For 0-9: nibble - 10 doesn't carry; + 0x3A brings it back to
        ; '0' + nibble. For 10-15: it carries, + 7 skips the punctuation
        ; between '9' and 'A' in ASCII, and + 0x3A lands on 'A' + nibble - 10.
        ;
hexnib: anl   a, #0x0F          ; just the low nibble
        add   a, #0x100-10      ; carry if nibble >= 10
        jnc   hn_dig            ; 0-9
        add   a, #7             ; A-F: skip ':' through '@'
hn_dig: add   a, #0x3A          ; back to ASCII
        sjmp  putc              ; send it (putc returns for us)

        ;
        ; putdec: val (0-65535) in decimal, no leading zeros. Destroys val.
        ;
        ; Repeated subtraction of 10000, 1000, 100, 10, 1: count how many
        ; times each power of ten fits, which is that digit. No division, so
        ; no multiply/divide library. Uses a, r1-r4, r6, r7, dptr.
        ;
putdec:
        mov   r2, #0            ; r2 = 1 once a non-zero digit has printed
        mov   r3, #5            ; r3 = digits left to do
        mov   dptr, #pow10      ; table of 16-bit powers of ten, low byte first
pd_dig: clr   a
        movc  a, @a+dptr        ; this power of ten, low byte
        mov   r6, a
        mov   a, #1
        movc  a, @a+dptr        ; and high byte
        mov   r7, a
        inc   dptr              ; step to the next table entry
        inc   dptr
        mov   r1, #0x30         ; r1 = the digit, starting at '0'
pd_sub: clr   c                 ; val - power, 16-bit
        mov   a, val_lo
        subb  a, r6
        mov   r4, a             ; (low byte of the difference, kept in r4
        mov   a, val_hi         ;   until we know the subtraction fits)
        subb  a, r7
        jc    pd_out            ; borrow: the power doesn't fit any more
        mov   val_hi, a         ; it fits: keep the difference
        mov   val_lo, r4
        inc   r1                ; and count it
        sjmp  pd_sub
        ;
        ; Print the digit unless it's a leading zero. The last digit always
        ; prints, so 0 comes out as "0".
        ;
pd_out: cjne  r1, #0x30, pd_prt ; non-zero digit: print
        mov   a, r2
        jnz   pd_prt            ; zero after a non-zero digit: print
        cjne  r3, #1, pd_nxt    ; leading zero: skip, unless it's the last
pd_prt: mov   r2, #1            ; from here on, zeros print
        mov   a, r1
        acall putc
pd_nxt: djnz  r3, pd_dig        ; next power of ten
        ret

; ----------------------------------------------------------------------------
; apply: drive state_lo/state_hi out to the 16 relay pins
; ----------------------------------------------------------------------------
;
; The board's wiring scatters the relays over three ports (see the pin map at
; the top), so this sorts the bits out one at a time. For relays 1-8, rlc
; rotates the top bit of a into carry, and "mov bit, c" copies carry onto the
; pin. Starting from bit 7 (relay 8) that lands on P3.0, P3.1 ... P3.5, then
; P5.4 and P5.5, exactly the order the relays are wired. Each pin write is a
; single bit write, so the UART pins on P3.6/P3.7 are never touched.
;
; For relays 9-16, port 1 is nearly in order: only relays 9 and 10 are
; swapped (K9 on P1.1, K10 on P1.0). Copy the byte to B, swap those two bits
; back via carry, and write all of port 1 at once.
;
; Uses a, b.

apply:  mov   a, state_lo       ; relays 1-8
        rlc   a                 ; bit 7: relay 8
        mov   P3_0, c
        rlc   a                 ; bit 6: relay 7
        mov   P3_1, c
        rlc   a                 ; bit 5: relay 6
        mov   P3_2, c
        rlc   a                 ; bit 4: relay 5
        mov   P3_3, c
        rlc   a                 ; bit 3: relay 4
        mov   P3_4, c
        rlc   a                 ; bit 2: relay 3
        mov   P3_5, c
        rlc   a                 ; bit 1: relay 2
        mov   P5_4, c
        rlc   a                 ; bit 0: relay 1
        mov   P5_5, c
        mov   a, state_hi       ; relays 9-16
        mov   b, a              ; a copy to read bits 0 and 1 from
        mov   c, B_0            ; relay 9 (bit 0) ...
        mov   ACC_1, c          ;   ... goes out on P1.1
        mov   c, B_1            ; relay 10 (bit 1) ...
        mov   ACC_0, c          ;   ... goes out on P1.0
        mov   P1, a             ; relays 11-16 are already in place on P1.2-P1.7
        ret

; ----------------------------------------------------------------------------
; Settings in EEPROM
; ----------------------------------------------------------------------------
;
; The block is 69 bytes, laid out like the full firmware's cfg_t (see the
; top of the file). Lite only cares about the first four bytes: magic, ID and
; the failsafe. The other 64 belong to the full firmware's pulse and max-on
; tables; lite writes them as zeros, which the full firmware reads as "unset".

        ;
        ; cfg_load: read the block, and keep the header only if it checks out.
        ;
        ; One pass over bytes 0-67 sums them into r5 (seeded with CFG_SEED) and
        ; copies the first four into cfg_magic..cfg_fs_hi through r1. Then the
        ; stored checksum at 68 has to match the sum and the magic has to be
        ; 0xA5; otherwise (blank, never written, or corrupt) everything goes
        ; back to defaults: ID 0 (unassigned) and failsafe off.
        ;
        ; Uses a, r1, r2, r5 (and whatever the ee_ routines use).
        ;
cfg_load:
        mov   r2, #0            ; r2 = EEPROM address
        mov   r5, #CFG_SEED     ; r5 = running checksum
        mov   r1, #cfg_magic    ; r1 = where the header bytes go
cl_lp:  acall ee_read           ; a = EEPROM[r2]
        cjne  r2, #4, cl_x      ; sets carry if r2 < 4 (target is the next line
cl_x:   jnc   cl_sum            ;   either way): past the header, just sum it
        mov   @r1, a            ; header byte: keep a copy
        inc   r1
cl_sum: add   a, r5             ; add to the checksum
        mov   r5, a
        inc   r2
        cjne  r2, #CFG_SUM, cl_lp ; up to, not including, the checksum byte
        acall ee_read           ; a = stored checksum (r2 = 68)
        xrl   a, r5             ; matches what we summed?
        jnz   cl_def            ;   no: defaults
        mov   a, cfg_magic
        cjne  a, #CFG_MAGIC, cl_def ; and is it one of ours?
        ret                     ; good block: keep ID and failsafe
cl_def: clr   a                 ; bad or blank block: defaults
        mov   cfg_id, a         ; unassigned
        mov   cfg_fs_lo, a      ; failsafe off
        mov   cfg_fs_hi, a
        ret

        ;
        ; cfg_save: erase the sector and write the whole block back.
        ;
        ; Bytes 0-3 come from cfg_magic..cfg_fs_hi (magic forced to 0xA5),
        ; bytes 4-67 are zeros, and the checksum goes last at 68, so a save
        ; that is interrupted part way leaves a block that fails its checksum
        ; rather than one that looks valid.
        ;
        ; Uses a, r1, r2, r5, r6 (and whatever the ee_ routines use).
        ;
cfg_save:
        mov   cfg_magic, #CFG_MAGIC
        mov   r2, #0            ; erase the sector holding address 0
        acall ee_erase          ;   (every byte reads 0xFF afterwards)
        mov   r5, #CFG_SEED     ; r5 = running checksum
        mov   r1, #cfg_magic    ; r1 = header bytes to write
cs_lp:  clr   a                 ; default: write 0
        cjne  r2, #4, cs_x      ; carry if r2 < 4 (target is the next line)
cs_x:   jnc   cs_wr             ; past the header: write the 0
        mov   a, @r1            ; header: the byte from RAM
        inc   r1
cs_wr:  mov   r6, a             ; keep the byte
        add   a, r5             ; add it to the checksum
        mov   r5, a
        mov   a, r6
        acall ee_write          ; EEPROM[r2] = a
        inc   r2
        cjne  r2, #CFG_SUM, cs_lp
        mov   a, r5             ; the checksum, written at 68 by falling
                                ;   straight into ee_write below

; ----------------------------------------------------------------------------
; EEPROM primitives
; ----------------------------------------------------------------------------
;
; ee_read   a = EEPROM[r2]
; ee_write  EEPROM[r2] = a   (flash: can only clear bits, so erase first)
; ee_erase  erase the 512-byte sector containing r2 (all bytes -> 0xFF)
;
; All three preserve r1, r2, r5 and r6, which cfg_load and cfg_save rely on.

.if SIM
        ;
        ; ucsim has no STC EEPROM, so XRAM page 0 stands in for it. The write
        ; ANDs the new byte into the old one, just like flash, so a save
        ; without an erase would fail the same way it would on the chip.
        ;
ee_write:
        mov   r4, a             ; the byte to write
        acall ee_ptr            ; dptr = r2
        movx  a, @dptr          ; old value
        anl   a, r4             ; flash only clears bits
        movx  @dptr, a
        ret
ee_read:
        acall ee_ptr            ; dptr = r2
        movx  a, @dptr
        ret
ee_erase:
        mov   DPH, #0           ; whole page to 0xFF
        mov   r3, #0            ; 256 bytes: r3 counts 0, 255, 254 ... 1
        mov   a, #0xFF
ee_er1: mov   DPL, r3
        movx  @dptr, a
        djnz  r3, ee_er1
        ret
ee_ptr: mov   DPH, #0           ; XRAM address = r2
        mov   DPL, r2
        ret
.else
        ;
        ; The STC15's EEPROM is a separate flash area reached through the IAP
        ; registers, addressed from 0. Each operation: enable IAP with the
        ; wait states for our clock, load command, address and data, then
        ; write the 0x5A, 0xA5 trigger sequence. The CPU stalls until the
        ; flash operation finishes (an erase takes milliseconds), and the
        ; data register then holds the result of a read.
        ;
        ; r3 = command, r4 = data. Afterwards IAP is disabled and its address
        ; parked at 0x8000, outside the EEPROM, so a stray trigger can't hit it.
        ;
ee_write:
        mov   r4, a             ; data to write
        mov   r3, #2            ; command 2: program byte
        sjmp  iap
ee_read:
        mov   r3, #1            ; command 1: read byte
        sjmp  iap
ee_erase:
        mov   r3, #3            ; command 3: erase sector
iap:    mov   IAP_CONTR, #0x81  ; IAPEN, wait states for <= 24 MHz
        mov   IAP_CMD, r3       ; what to do
        mov   IAP_ADDRH, #0     ; where: our block is at the start
        mov   IAP_ADDRL, r2
        mov   IAP_DATA, r4      ; the byte (ignored by read and erase)
        mov   IAP_TRIG, #0x5A   ; trigger sequence, part 1
        mov   IAP_TRIG, #0xA5   ; part 2: the CPU stalls here until done
        nop                     ; one cycle for IAP_DATA to settle
        mov   a, IAP_DATA       ; read result (harmless after write/erase)
        mov   IAP_CONTR, #0     ; disable IAP
        mov   IAP_CMD, #0       ; and clear everything back out
        mov   IAP_TRIG, #0
        mov   IAP_ADDRH, #0x80  ; park the address outside the EEPROM
        mov   IAP_ADDRL, #0
        ret
.endif

; ----------------------------------------------------------------------------
; Constant tables (code memory, read with movc)
; ----------------------------------------------------------------------------

        ; powers of ten for putdec, 16-bit, low byte first:
        ; 10000 = 0x2710, 1000 = 0x03E8, 100 = 0x0064, 10 = 0x000A, 1 = 0x0001
pow10:  .db   0x10, 0x27, 0xE8, 0x03, 0x64, 0x00, 0x0A, 0x00, 0x01, 0x00
        ; the start of the v reply; execute prints the ID after it
version:
        .ascii "relay16 1L id "
        .db   0

code_end:                       ; the Makefile checks this is <= 1024
