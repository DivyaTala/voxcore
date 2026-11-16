# Build VoxCore firmware -> firmware.hex ($readmemh format, one 32-bit word per line)
CROSS ?= riscv64-unknown-elf-
CFLAGS = -march=rv32i_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -nostartfiles -Wall

firmware.hex: firmware.bin
	python3 bin2hex.py firmware.bin firmware.hex 4096

firmware.bin: firmware.elf
	$(CROSS)objcopy -O binary $< $@

firmware.elf: start.S main.c vc_mac.h link.ld
	$(CROSS)gcc $(CFLAGS) -T link.ld start.S main.c -lgcc -o $@
	$(CROSS)size $@

clean:
	rm -f firmware.elf firmware.bin firmware.hex
