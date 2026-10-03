; relay16_lite.asm - relay16 lite firmware, 8051 assembly, fits 1 KB
;
; Target: STC15W401AS on the SainSmart 101-70-208 (stock chip).
; Protocol: docs/PROTOCOL.md, lite subset: r s c h t i w v
; (no p/d/m: no pulses, no max-on interlock).
;
; EEPROM layout matches the full firmware (core.c cfg_t): magic, id,
; failsafe lo/hi, 64 bytes of pulse/max-on (written as 0), checksum at 68.
; A board keeps its ID and failsafe across lite <-> full reflashes.
;
; Assembled through hw.asm (SIM = 0, the board) or sim.asm (SIM = 1, ucsim).
; SIM swaps only: baud clock (T1), 1 ms tick (T0 mode 1), EEPROM (XRAM).
;
; Relay -> pin (ULN2803, pin high = relay on):
;   K1 P5.5  K2 P5.4  K3 P3.5  K4 P3.4  K5 P3.3  K6 P3.2  K7 P3.1  K8 P3.0
;   K9 P1.1  K10 P1.0 K11-K16 P1.2-P1.7
; UART1 on P3.6/P3.7 (CH340), 115200 8N1, internal RC trimmed to 22.1184 MHz.

        .module relay16_lite

; ---------------------------------------------------------------- SFRs

SP        = 0x81
DPL       = 0x82
DPH       = 0x83
PCON      = 0x87
TCON      = 0x88
TMOD      = 0x89
TL0       = 0x8A
TH0       = 0x8C
TH1       = 0x8D
AUXR      = 0x8E
P1        = 0x90
P1M1      = 0x91
P1M0      = 0x92
SCON      = 0x98
SBUF      = 0x99
P_SW1     = 0xA2
P2        = 0xA0
P3        = 0xB0
P3M1      = 0xB1
P3M0      = 0xB2
WDT_CONTR = 0xC1
IAP_DATA  = 0xC2
IAP_ADDRH = 0xC3
IAP_ADDRL = 0xC4
IAP_CMD   = 0xC5
IAP_TRIG  = 0xC6
IAP_CONTR = 0xC7
P5        = 0xC8
P5M1      = 0xC9
P5M0      = 0xCA
T2H       = 0xD6
T2L       = 0xD7
ACC       = 0xE0
B         = 0xF0

; bits
TR0       = 0x8C
TF0       = 0x8D
TR1       = 0x8E
RI        = 0x98
TI        = 0x99
P3_0      = 0xB0
P3_1      = 0xB1
P3_2      = 0xB2
P3_3      = 0xB3
P3_4      = 0xB4
P3_5      = 0xB5
P5_4      = 0xCC
P5_5      = 0xCD
ACC_0     = 0xE0
ACC_1     = 0xE1
B_0       = 0xF0
B_1       = 0xF1

; ---------------------------------------------------------------- RAM

state_lo  = 0x08            ; relay mask, bit0 = relay 1
state_hi  = 0x09
val_lo    = 0x0A            ; number being parsed / printed
val_hi    = 0x0B
idle_lo   = 0x0C            ; ms since last valid command
idle_hi   = 0x0D
cmd       = 0x0E            ; command letter, lowercase
nd        = 0x0F            ; digits seen
st        = 0x10            ; 0 idle, 1 in command, 2 after number, 3 junk
cfg_magic = 0x11            ; first 4 bytes of the EEPROM block
cfg_id    = 0x12
cfg_fs_lo = 0x13
cfg_fs_hi = 0x14
STACK     = 0x20

CFG_MAGIC = 0xA5
CFG_SEED  = 0x5A
CFG_SUM   = 68              ; offset of the checksum byte

; 1 ms at 22.1184 MHz: STC timer 0 in 1T mode, the simulator's in 12T mode
.if SIM
T0_RELOAD = 0x10000 - 1843
.else
T0_RELOAD = 0x10000 - 22118
.endif
T2_RELOAD = 0x10000 - 48    ; 115200 baud, 1T

; ================================================================ code

        .area CODE (ABS)
        .org  0

start:  mov   SP, #STACK-1
        clr   a                 ; clear RAM 0x7F..0x01
        mov   r0, #0x7F
clr_lp: mov   @r0, a
        djnz  r0, clr_lp

        ; relay outputs low, then push-pull (P3.6 RX stays quasi-bidir)
        mov   P1, #0x00
        mov   P3, #0xC0
        anl   P5, #0xCF
        mov   P1M1, #0x00
        mov   P1M0, #0xFF
        mov   P3M1, #0x00
        mov   P3M0, #0xBF
        anl   P5M1, #0xCF
        orl   P5M0, #0x30

        mov   WDT_CONTR, #0x33  ; watchdog on, ~280 ms

        mov   SCON, #0x50       ; UART mode 1, receive on
        mov   TL0, #<T0_RELOAD
        mov   TH0, #>T0_RELOAD
.if SIM
        mov   TMOD, #0x21       ; T1 8-bit auto-reload baud, T0 16-bit
        mov   TH1, #0xFF        ; 115200 with SMOD at 22.1184 MHz
        orl   PCON, #0x80
        setb  TR1
.else
        mov   P_SW1, #0x40      ; UART1 -> P3.6/P3.7
        mov   T2L, #<T2_RELOAD
        mov   T2H, #>T2_RELOAD
        mov   AUXR, #0x95       ; T0 1T, T2 run, T2 1T, UART1 baud from T2
.endif
        setb  TR0

        acall cfg_load
        acall apply             ; all relays off

; ---------------------------------------------------------------- main loop

loop:   mov   WDT_CONTR, #0x33  ; feed the watchdog
        jbc   TF0, tick
        jbc   RI, rx
        sjmp  loop

; ---------------------------------------------------------------- 1 ms tick
; failsafe: all off once idle reaches cfg_fs (0 = disabled)

tick:
.if SIM
        mov   TL0, #<T0_RELOAD  ; mode 1 has no auto-reload
        mov   TH0, #>T0_RELOAD
.endif
        mov   a, cfg_fs_lo
        orl   a, cfg_fs_hi
        jz    loop
        mov   a, idle_lo        ; stop counting at the limit
        cjne  a, cfg_fs_lo, tk_inc
        mov   a, idle_hi
        cjne  a, cfg_fs_hi, tk_inc
        sjmp  loop
tk_inc: inc   idle_lo
        mov   a, idle_lo
        jnz   tk_cmp
        inc   idle_hi
tk_cmp: cjne  a, cfg_fs_lo, loop
        mov   a, idle_hi
        cjne  a, cfg_fs_hi, loop
        mov   a, state_lo
        orl   a, state_hi
        jz    loop
        clr   a
        mov   state_lo, a
        mov   state_hi, a
        acall apply
        sjmp  loop

; ---------------------------------------------------------------- receive
; one character at a time, no line buffer

rx:     mov   a, SBUF
        mov   r7, a
        cjne  a, #0x0D, rx_nl
        sjmp  rx_eol
rx_nl:  cjne  a, #0x0A, rx_chr
rx_eol: mov   a, st
        jz    loop              ; blank line: ignore
        acall execute
        mov   st, #0
        sjmp  loop

rx_chr: mov   a, st
        cjne  a, #3, rx_sp
        sjmp  loop              ; junk line: wait for its end
rx_sp:  mov   a, r7
        cjne  a, #0x20, rx_tab
        sjmp  rx_ws
rx_tab: cjne  a, #0x09, rx_prn
rx_ws:  mov   a, nd
        jz    loop
        mov   st, #2            ; space after a number
        sjmp  loop

rx_prn: add   a, #0x100-0x21    ; printable '!'..'~' only
        jnc   rx_bad
        add   a, #0x100-0x5E
        jc    rx_bad
        mov   a, r7
        orl   a, #0x20          ; lowercase
        mov   r7, a
        mov   a, st
        jnz   rx_arg
        mov   cmd, r7           ; first character: the command
        clr   a
        mov   val_lo, a
        mov   val_hi, a
        mov   nd, a
        mov   st, #1
        ajmp  loop

rx_arg: cjne  a, #2, rx_dig     ; a second argument is junk
rx_bad: mov   st, #3
        ajmp  loop

rx_dig: mov   a, r7
        add   a, #0x100-0x30    ; '0'..'9'
        mov   r6, a
        add   a, #0x100-10
        jnc   rx_dec
        mov   a, cmd            ; 'a'..'f' only for h
        cjne  a, #0x68, rx_bad
        mov   a, r7
        add   a, #0x100-0x61
        mov   r6, a
        add   a, #0x100-6
        jc    rx_bad
        mov   a, r6
        add   a, #10
        mov   r6, a
        sjmp  rx_hex
rx_dec: mov   a, cmd
        cjne  a, #0x68, rx_mul
rx_hex: mov   a, nd             ; val = val << 4 | digit, max 4 digits
        cjne  a, #4, rx_h4
        sjmp  rx_bad
rx_h4:  mov   a, val_hi
        swap  a
        anl   a, #0xF0
        mov   r5, a
        mov   a, val_lo
        swap  a
        mov   r4, a
        anl   a, #0x0F
        orl   a, r5
        mov   val_hi, a
        mov   a, r4
        anl   a, #0xF0
        orl   a, r6
        mov   val_lo, a
        sjmp  rx_cnt

rx_mul: mov   a, val_lo         ; val = val * 10 + digit, max 65535
        mov   b, #10
        mul   ab
        add   a, r6
        mov   val_lo, a
        mov   a, b
        addc  a, #0
        mov   r5, a
        mov   a, val_hi
        mov   b, #10
        mul   ab
        xch   a, b
        jnz   rx_bad
        mov   a, b
        add   a, r5
        jc    rx_bad
        mov   val_hi, a
rx_cnt: inc   nd
        ajmp  loop

; ---------------------------------------------------------------- execute
; one reply line per command; "?" for anything invalid

execute:
        mov   a, st
        cjne  a, #3, ex_r
        sjmp  ex_q
ex_r:   mov   a, cmd
        cjne  a, #0x72, ex_w    ; r
        mov   a, nd
        jnz   ex_q
        sjmp  ex_show

ex_w:   cjne  a, #0x77, ex_h    ; w: save, only with all relays off
        mov   a, nd
        jnz   ex_q
        mov   a, state_lo
        orl   a, state_hi
        jnz   ex_q
        acall cfg_save
        sjmp  ex_show

ex_h:   cjne  a, #0x68, ex_s    ; h XXXX
        mov   a, nd
        jz    ex_q
        sjmp  ex_set

ex_s:   cjne  a, #0x73, ex_c    ; s N
        acall relay_bit
        jc    ex_q
        mov   a, state_lo
        orl   a, r5
        mov   val_lo, a
        mov   a, state_hi
        orl   a, r4
        mov   val_hi, a
        sjmp  ex_set

ex_c:   cjne  a, #0x63, ex_i    ; c N
        acall relay_bit
        jc    ex_q
        mov   a, r5
        cpl   a
        anl   a, state_lo
        mov   val_lo, a
        mov   a, r4
        cpl   a
        anl   a, state_hi
        mov   val_hi, a

ex_set: mov   state_lo, val_lo
        mov   state_hi, val_hi
        acall apply
ex_show:
        mov   a, state_hi
        acall puthex2
        mov   a, state_lo
        acall puthex2
        sjmp  ex_ok

ex_q:   mov   a, #0x3F          ; ?
        acall putc
        sjmp  crlf

ex_i:   cjne  a, #0x69, ex_t    ; i [ID]
        mov   a, nd
        jz    ex_i2
        mov   a, val_hi
        jnz   ex_q              ; ID > 255
        mov   cfg_id, val_lo
ex_i2:  mov   val_lo, cfg_id
        mov   val_hi, #0
        sjmp  ex_dec

ex_t:   cjne  a, #0x74, ex_v    ; t [MS]
        mov   a, nd
        jz    ex_t2
        mov   cfg_fs_lo, val_lo
        mov   cfg_fs_hi, val_hi
ex_t2:  mov   val_lo, cfg_fs_lo
        mov   val_hi, cfg_fs_hi
        sjmp  ex_dec

ex_v:   cjne  a, #0x76, ex_q    ; v
        mov   a, nd
        jnz   ex_q
        mov   dptr, #version
ex_v2:  clr   a
        movc  a, @a+dptr
        jz    ex_i2
        acall putc
        inc   dptr
        sjmp  ex_v2

ex_dec: acall putdec
ex_ok:  clr   a                 ; valid command: restart the failsafe
        mov   idle_lo, a
        mov   idle_hi, a
crlf:   mov   a, #0x0D
        acall putc
        mov   a, #0x0A
putc:   mov   SBUF, a
putc_w: jnb   TI, putc_w
        clr   TI
        ret

; relay number in val (1-16) -> mask in r4:r5 (hi:lo); C = 1 if invalid
relay_bit:
        mov   a, nd
        jz    rb_bad
        mov   a, val_hi
        jnz   rb_bad
        mov   a, val_lo
        jz    rb_bad
        add   a, #0x100-17
        jc    rb_bad
        mov   r3, val_lo
        mov   r5, #1
        mov   r4, #0
rb_lp:  djnz  r3, rb_sh
        clr   c
        ret
rb_sh:  mov   a, r5
        add   a, r5
        mov   r5, a
        mov   a, r4
        rlc   a
        mov   r4, a
        sjmp  rb_lp
rb_bad: setb  c
        ret

; ---------------------------------------------------------------- output

puthex2:                        ; a as two hex digits
        push  ACC
        swap  a
        acall hexnib
        pop   ACC
hexnib: anl   a, #0x0F
        add   a, #0x100-10
        jnc   hn_dig
        add   a, #7
hn_dig: add   a, #0x3A
        sjmp  putc

putdec:                         ; val in decimal, no leading zeros
        mov   r2, #0            ; started
        mov   r3, #5            ; digits left
        mov   dptr, #pow10
pd_dig: clr   a
        movc  a, @a+dptr
        mov   r6, a
        mov   a, #1
        movc  a, @a+dptr
        mov   r7, a
        inc   dptr
        inc   dptr
        mov   r1, #0x30
pd_sub: clr   c
        mov   a, val_lo
        subb  a, r6
        mov   r4, a
        mov   a, val_hi
        subb  a, r7
        jc    pd_out
        mov   val_hi, a
        mov   val_lo, r4
        inc   r1
        sjmp  pd_sub
pd_out: cjne  r1, #0x30, pd_prt ; non-zero digit
        mov   a, r2
        jnz   pd_prt            ; zero after a non-zero digit
        cjne  r3, #1, pd_nxt    ; the last digit always prints
pd_prt: mov   r2, #1
        mov   a, r1
        acall putc
pd_nxt: djnz  r3, pd_dig
        ret

; ---------------------------------------------------------------- relays

apply:  mov   a, state_lo       ; K8..K1 out of bit 7..0
        rlc   a
        mov   P3_0, c
        rlc   a
        mov   P3_1, c
        rlc   a
        mov   P3_2, c
        rlc   a
        mov   P3_3, c
        rlc   a
        mov   P3_4, c
        rlc   a
        mov   P3_5, c
        rlc   a
        mov   P5_4, c
        rlc   a
        mov   P5_5, c
        mov   a, state_hi       ; K9 -> P1.1, K10 -> P1.0, K11-16 straight
        mov   b, a
        mov   c, B_0
        mov   ACC_1, c
        mov   c, B_1
        mov   ACC_0, c
        mov   P1, a
        ret

; ---------------------------------------------------------------- config

cfg_load:                       ; header into cfg_*, verify checksum
        mov   r2, #0
        mov   r5, #CFG_SEED
        mov   r1, #cfg_magic
cl_lp:  acall ee_read
        cjne  r2, #4, cl_x
cl_x:   jnc   cl_sum            ; C set if r2 < 4
        mov   @r1, a
        inc   r1
cl_sum: add   a, r5
        mov   r5, a
        inc   r2
        cjne  r2, #CFG_SUM, cl_lp
        acall ee_read
        xrl   a, r5
        jnz   cl_def
        mov   a, cfg_magic
        cjne  a, #CFG_MAGIC, cl_def
        ret
cl_def: clr   a                 ; invalid or never written: defaults
        mov   cfg_id, a
        mov   cfg_fs_lo, a
        mov   cfg_fs_hi, a
        ret

cfg_save:
        mov   cfg_magic, #CFG_MAGIC
        mov   r2, #0
        acall ee_erase
        mov   r5, #CFG_SEED
        mov   r1, #cfg_magic
cs_lp:  clr   a
        cjne  r2, #4, cs_x
cs_x:   jnc   cs_wr             ; past the header: 0
        mov   a, @r1
        inc   r1
cs_wr:  mov   r6, a
        add   a, r5
        mov   r5, a
        mov   a, r6
        acall ee_write
        inc   r2
        cjne  r2, #CFG_SUM, cs_lp
        mov   a, r5
        ; fall through: write the checksum at CFG_SUM

; EEPROM: address in r2, data in a. Preserves r1, r2, r5, r6.
.if SIM
ee_write:                       ; XRAM stands in; flash only clears bits
        mov   r4, a
        acall ee_ptr
        movx  a, @dptr
        anl   a, r4
        movx  @dptr, a
        ret
ee_read:
        acall ee_ptr
        movx  a, @dptr
        ret
ee_erase:
        mov   DPH, #0
        mov   r3, #0
        mov   a, #0xFF
ee_er1: mov   DPL, r3
        movx  @dptr, a
        djnz  r3, ee_er1
        ret
ee_ptr: mov   DPH, #0
        mov   DPL, r2
        ret
.else
ee_write:
        mov   r4, a
        mov   r3, #2
        sjmp  iap
ee_read:
        mov   r3, #1
        sjmp  iap
ee_erase:
        mov   r3, #3
iap:    mov   IAP_CONTR, #0x81  ; enable, wait states for <= 24 MHz
        mov   IAP_CMD, r3
        mov   IAP_ADDRH, #0
        mov   IAP_ADDRL, r2
        mov   IAP_DATA, r4
        mov   IAP_TRIG, #0x5A
        mov   IAP_TRIG, #0xA5
        nop
        mov   a, IAP_DATA
        mov   IAP_CONTR, #0     ; idle the IAP unit
        mov   IAP_CMD, #0
        mov   IAP_TRIG, #0
        mov   IAP_ADDRH, #0x80
        mov   IAP_ADDRL, #0
        ret
.endif

; ---------------------------------------------------------------- tables

pow10:  .db   0x10, 0x27, 0xE8, 0x03, 0x64, 0x00, 0x0A, 0x00, 0x01, 0x00
version:
        .ascii "relay16 1L id "
        .db   0

code_end:
