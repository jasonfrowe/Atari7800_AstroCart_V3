# Makefile for RISC-V Service Firmware Images

RISCV_CC = riscv64-elf-gcc
RISCV_OBJCOPY = riscv64-elf-objcopy
PYTHON = python3

CFLAGS = -march=rv32im -mabi=ilp32 -O2 -nostdlib -nostartfiles -T link.ld
CFLAGS_FEMTORV = -march=rv32i -mabi=ilp32 -Os -nostdlib -nostartfiles -ffreestanding -fno-builtin -Ipetitfatfs -T link.ld

SRCS = crt0.S main.c
TARGET = firmware

FEMTORV_SRCS = crt0.S femtorv_service_main.c petitfatfs/pff.c petitfatfs/diskio_glue.c
FEMTORV_TARGET = femtorv_firmware

.PHONY: all clean

all: $(TARGET).hex

femtorv: $(FEMTORV_TARGET).hex

$(TARGET).elf: $(SRCS) link.ld
	$(RISCV_CC) $(CFLAGS) $(SRCS) -o $(TARGET).elf

$(TARGET).bin: $(TARGET).elf
	$(RISCV_OBJCOPY) -O binary $(TARGET).elf $(TARGET).bin

$(TARGET).hex: $(TARGET).bin
	$(PYTHON) -c "import struct; data=open('firmware.bin','rb').read(); data += b'\x00'*(8192-len(data)); words=[struct.unpack('<I', data[i:i+4])[0] for i in range(0,8192,4)]; [print(f'{w:08x}') for w in words]" > $(TARGET).hex
	@echo "==> RISC-V Firmware hex generated successfully ($$(wc -l < $(TARGET).hex) 32-bit words)"

$(FEMTORV_TARGET).elf: $(FEMTORV_SRCS) link.ld
	$(RISCV_CC) $(CFLAGS_FEMTORV) $(FEMTORV_SRCS) -lgcc -o $(FEMTORV_TARGET).elf

$(FEMTORV_TARGET).bin: $(FEMTORV_TARGET).elf
	$(RISCV_OBJCOPY) -O binary $(FEMTORV_TARGET).elf $(FEMTORV_TARGET).bin

$(FEMTORV_TARGET).hex: $(FEMTORV_TARGET).bin
	$(PYTHON) -c "import struct; data=open('$(FEMTORV_TARGET).bin','rb').read(); data += b'\x00'*(8192-len(data)); words=[struct.unpack('<I', data[i:i+4])[0] for i in range(0,8192,4)]; [print(f'{w:08x}') for w in words]" > $(FEMTORV_TARGET).hex
	@echo "==> FemtoRV firmware hex generated successfully ($$(wc -l < $(FEMTORV_TARGET).hex) 32-bit words)"

clean:
	rm -f $(TARGET).elf $(TARGET).bin $(TARGET).hex
	rm -f $(FEMTORV_TARGET).elf $(FEMTORV_TARGET).bin $(FEMTORV_TARGET).hex
