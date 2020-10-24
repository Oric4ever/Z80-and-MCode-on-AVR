AVRBIN=~/arduino-1.8.9/hardware/tools/avr/bin

GCCOPTS= -std=c99 -Os -Wall -ffunction-sections -fdata-sections
AVROPTS= -DF_CPU=18432000L -mmcu=atmega162 -DUART=0
LINKOPTS= -Wl,--gc-sections
OBJCOPYOPTS= --set-section-flags=.eeprom=alloc,load --no-change-warnings --change-section-lma .eeprom=0

SRCS= z80.S interface.S main.c uart0.c
OBJS= ../pff/obj/spi.o ../pff/obj/mmcbbp.o ../pff/obj/pff.o ../Keyboard/keyboard.o ../Keyboard/us_english.o

emu80.hex: emu80.elf
	$(AVRBIN)/avr-objcopy -O ihex -j .eeprom $(OBJCOPYOPTS) emu80.elf emu80.eep
	$(AVRBIN)/avr-objcopy -O ihex -R .eeprom emu80.elf emu80.hex
	$(AVRBIN)/avr-size emu80.elf
	nm emu80.elf | grep Align | sort

emu80.elf: $(SRCS) $(OBJS)
	$(AVRBIN)/avr-gcc $(GCCOPTS) $(AVROPTS) $(LINKOPTS) -o emu80.elf $(SRCS) $(OBJS)

z80.s: z80.S
	$(AVRBIN)/avr-gcc $(GCCOPTS) $(AVROPTS) -E z80.S > z80.s

z80.o: z80.S
	$(AVRBIN)/avr-gcc $(GCCOPTS) $(AVROPTS) -c z80.S
	$(AVRBIN)/avr-size z80.o

CPM.BIN: ccp.bin bdos.bin z80bios.bin
	cat ccp.bin bdos.bin z80bios.bin > CPM.BIN

upload: emu80.hex
	$(AVRBIN)/avrdude -C /etc/avrdude.conf -p m162 -c usbasp -b 38400 \
		-u -V -U flash:w:emu80.hex

clean:
	rm emu80.elf emu80.hex emu80.eep
