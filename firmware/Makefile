# relay16 firmware for the SainSmart 101-70-208 (STC15)
#
#   make                 build build/relay16.hex
#   make info PORT=...   read-only bootloader handshake (no erase)
#   make flash PORT=...  program; EEPROM (board ID, settings) is kept
#
# PORT is the USB-TTL adapter on the 4-pin ISP header, not the board's USB.

PORT      ?= /dev/ttyUSB1
CODE_SIZE ?= 8192
STCGAL    ?= $(HOME)/.local/bin/stcgal
TRIM_KHZ  ?= 22118.4

SDCCFLAGS = -mmcs51 --code-size $(CODE_SIZE) --iram-size 256 --xram-size 256 \
            --opt-code-size --std-sdcc11
STCFLAGS  = -P stc15 -p $(PORT)

build/relay16.hex: stc15.c core.c compat.h
	@mkdir -p build
	sdcc $(SDCCFLAGS) -o build/relay16.ihx stc15.c
	packihx build/relay16.ihx > $@ 2>/dev/null
	@n=$$(awk '/ROM\/EPROM/ {print $$4}' build/relay16.mem | tail -1); echo "full: $$n bytes"

info:
	$(STCGAL) $(STCFLAGS)

flash: build/relay16.hex
	$(STCGAL) $(STCFLAGS) -t $(TRIM_KHZ) \
	    -o reset_pin_enabled=false -o eeprom_erase_enabled=false $<

clean:
	rm -rf build

.PHONY: info flash clean
