#!/usr/bin/env python3
# ============================================================================
# Script: convert_a78_split.py
# Description: Converts .a78 file into 24 2KB hex files (2048 lines each)
#              for 1-to-1 Gowin BSRAM hardware block mapping.
# ============================================================================

import sys

from a78_header import parse_a78_header, payload_from_a78

WINDOW_BYTES = 24 * 2048

def convert_a78_split(input_a78):
    with open(input_a78, 'rb') as f:
        data = f.read()

    header = parse_a78_header(data)
    rom_data = payload_from_a78(data, header)
    print(f"[CONVERT] Extracted {len(rom_data)} bytes of ROM data.")

    if not header.magic_ok:
        print("[CONVERT] Warning: A78 magic text mismatch at offset 0x01.")
    if not header.end_magic_ok:
        print("[CONVERT] Warning: A78 end magic mismatch at offset 0x64.")

    if len(rom_data) > WINDOW_BYTES:
        print(f"ERROR: ROM size {len(rom_data)} exceeds current 48KB cartridge window ({WINDOW_BYTES} bytes).")
        sys.exit(1)

    if len(rom_data) < WINDOW_BYTES:
        pad_len = WINDOW_BYTES - len(rom_data)
        print(f"[CONVERT] Padding ROM image with {pad_len} bytes of 0xFF to fill the 48KB cartridge window.")
        rom_data = rom_data + bytes([0xFF]) * pad_len

    for i in range(24):
        chunk = rom_data[i*2048 : (i+1)*2048]
        out_name = f"rom_chunk_{i:02d}.hex"
        with open(out_name, 'w') as f:
            for b in chunk:
                f.write(f"{b:02x}\n")
        print(f"[CONVERT] Generated {out_name} (2048 lines).")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 convert_a78_split.py <input.a78>")
        sys.exit(1)
    convert_a78_split(sys.argv[1])
