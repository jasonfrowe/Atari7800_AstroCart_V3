#!/usr/bin/env python3
# ============================================================================
# Script: convert_a78_split.py
# Description: Converts .a78 file into 24 2KB hex files (2048 lines each)
#              for 1-to-1 Gowin BSRAM hardware block mapping.
# ============================================================================

import sys

def convert_a78_split(input_a78):
    with open(input_a78, 'rb') as f:
        data = f.read()

    # Skip 128-byte A78 header
    rom_data = data[128:]
    print(f"[CONVERT] Extracted {len(rom_data)} bytes of ROM data.")

    if len(rom_data) < 49152:
        print("ERROR: ROM size less than 48KB!")
        sys.exit(1)

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
