# Makefile for Hazard5 RISC-V Firmware

RISCV_CC = riscv64-elf-gcc
RISCV_OBJCOPY = riscv64-elf-objcopy
PYTHON = python3

CFLAGS = -march=rv32im -mabi=ilp32 -O2 -nostdlib -nostartfiles -T link.ld

SRCS = crt0.S main.c
TARGET = firmware

.PHONY: all clean

all: $(TARGET).hex

$(TARGET).elf: $(SRCS) link.ld
	$(RISCV_CC) $(CFLAGS) $(SRCS) -o $(TARGET).elf

$(TARGET).bin: $(TARGET).elf
	$(RISCV_OBJCOPY) -O binary $(TARGET).elf $(TARGET).bin

$(TARGET).hex: $(TARGET).bin
	$(PYTHON) -c "import struct; data=open('firmware.bin','rb').read(); data += b'\x00'*(8192-len(data)); words=[struct.unpack('<I', data[i:i+4])[0] for i in range(0,8192,4)]; [print(f'{w:08x}') for w in words]" > $(TARGET).hex
	@echo "==> RISC-V Firmware hex generated successfully ($$(wc -l < $(TARGET).hex) 32-bit words)"

clean:
	rm -f $(TARGET).elf $(TARGET).bin $(TARGET).hex
