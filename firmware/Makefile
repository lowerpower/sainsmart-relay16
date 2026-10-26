# relay16 firmware for the SainSmart 101-70-208
#
#   make lite                 lite build, 8051 asm, fits the stock 1 KB STC15W401AS
#   make full                 full build, C, ~2.2 KB: needs an STC15W404AS/408AS
#   make info PORT=...        read-only bootloader handshake (no erase)
#   make flash-lite PORT=...  program the lite build; EEPROM (ID, settings) kept
#   make flash PORT=...       program the full build;  EEPROM kept
#
# PORT is the USB-TTL adapter on the 4-pin ISP header, not the board's USB.
# Lite and full share the EEPROM layout, so a board keeps its ID either way.

# default: the first serial adapter that is not a CH340 (the board's own USB).
# ttyUSB numbers swap when devices are plugged in; by-id names do not.
PORT      ?= $(firstword $(filter-out %1a86%,$(wildcard /dev/serial/by-id/*)))
CODE_SIZE ?= 8192
STCGAL    ?= $(HOME)/.local/bin/stcgal
TRIM_KHZ  ?= 22118.4

SDCCFLAGS = -mmcs51 --code-size $(CODE_SIZE) --iram-size 256 --xram-size 256 \
            --opt-code-size --std-sdcc11
STCFLAGS  = -P stc15 -p $(PORT)
STCOPTS   = -t $(TRIM_KHZ) -o reset_pin_enabled=false -o eeprom_erase_enabled=false

LITE_SRC  = lite/relay16_lite.asm

all: lite full

lite: build/relay16-lite.hex build/relay16-lite-sim.ihx

full: build/relay16.hex

# lite: board build, checked against the 1 KB limit
build/relay16-lite.hex: lite/hw.asm $(LITE_SRC)
	@mkdir -p build
	sdas8051 -plosgff build/relay16-lite.rel lite/hw.asm
	sdld -i build/relay16-lite.ihx build/relay16-lite.rel >/dev/null
	packihx build/relay16-lite.ihx > $@ 2>/dev/null
	@end=$$(sed -n 's/.*code_end *\([0-9A-F]*\) .*/\1/p' build/relay16-lite.sym); \
	 n=$$((0x$$end)); echo "lite: $$n of 1024 bytes"; test $$n -le 1024

# lite: ucsim build for the tests (different baud clock, tick and EEPROM backing)
build/relay16-lite-sim.ihx: lite/sim.asm $(LITE_SRC)
	@mkdir -p build
	sdas8051 -plosgff build/relay16-lite-sim.rel lite/sim.asm
	sdld -i build/relay16-lite-sim.ihx build/relay16-lite-sim.rel >/dev/null

build/relay16.hex: stc15.c core.c compat.h
	@mkdir -p build
	sdcc $(SDCCFLAGS) -o build/relay16.ihx stc15.c
	packihx build/relay16.ihx > $@ 2>/dev/null
	@n=$$(awk '/ROM\/EPROM/ {print $$4}' build/relay16.mem | tail -1); echo "full: $$n bytes"

info:
	$(STCGAL) $(STCFLAGS)

flash-lite: build/relay16-lite.hex
	$(STCGAL) $(STCFLAGS) $(STCOPTS) $<

flash: build/relay16.hex
	$(STCGAL) $(STCFLAGS) $(STCOPTS) $<

clean:
	rm -rf build

.PHONY: all lite full info flash-lite flash clean
