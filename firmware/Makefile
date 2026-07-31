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
	$(PYTHON) -c "import sys; data=open('firmware.bin','rb').read(); [print(f'{b:02x}') for b in data]" > $(TARGET).hex
	@echo "==> RISC-V Firmware binary compiled successfully ($$(wc -l < $(TARGET).hex) bytes)"

clean:
	rm -f $(TARGET).elf $(TARGET).bin $(TARGET).hex
