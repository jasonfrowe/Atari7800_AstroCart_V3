#!/usr/bin/env python3
"""
pack_menu_4k.py
1. Emits the 4x 2KB chunks (menu_chunk_00..03.hex) from the 8KB menu.bas.bin
   for instantiation in FPGA BSRAM blocks 20..23 ($E000-$FFFF).
2. Generates menu_4k.bin, menu_4k.a78, and menu_4k.hex for standalone testing.
"""

import os
import sys
import subprocess

def process_menu(script_dir, project_dir):
    bin_path = os.path.join(script_dir, "menu.bas.bin")
    if not os.path.exists(bin_path):
        print(f"Error: {bin_path} not found")
        return False

    with open(bin_path, "rb") as f:
        data = f.read()

    if len(data) != 8192:
        print(f"Error: expected 8192 bytes, got {len(data)}")
        return False

    # 1. Emit 4x 2KB chunks (8KB total) for BSRAM blocks 20..23
    for i in range(4):
        chunk = data[i * 2048 : (i + 1) * 2048]
        hex_text = "".join(f"{b:02X}\n" for b in chunk)
        for dest_dir in [script_dir, os.path.join(project_dir, "sim"), project_dir]:
            out_file = os.path.join(dest_dir, f"menu_chunk_{i:02d}.hex")
            with open(out_file, "w") as f:
                f.write(hex_text)

    print("✓ Successfully generated menu_chunk_00..03.hex (4x 2048 bytes).")
    return True

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.abspath(os.path.join(script_dir, ".."))
    process_menu(script_dir, project_dir)
