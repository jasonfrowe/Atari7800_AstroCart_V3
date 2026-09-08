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

    # 2. Pack 4KB menu representation
    packed = bytearray(4096)
    # Font graphics: 8 scanlines x 128 bytes = 1024 bytes (0x000 .. 0x3FF)
    for scanline in range(8):
        src_offset = scanline * 256
        dst_offset = scanline * 128
        packed[dst_offset : dst_offset + 128] = data[src_offset : src_offset + 128]
    packed[0x400 : 0x500] = data[0x800 : 0x900]   # Gamelist buffer ($E800-$E8FF)
    packed[0x500 : 0x900] = data[0x900 : 0xD00]   # Menu code ($E900-$ECFF)
    packed[0x900 : 0xF00] = data[0x1000 : 0x1600] # Runtime code ($F000-$F5FF)
    packed[0xF00 : 0xF80] = data[0x1F80 : 0x2000] # Signature & Vectors ($FF80-$FFFF)

    # Write menu_4k.bin and menu_4k.hex
    out_bin_4k = os.path.join(script_dir, "menu_4k.bin")
    with open(out_bin_4k, "wb") as f:
        f.write(packed)

    out_hex_4k = os.path.join(script_dir, "menu_4k.hex")
    with open(out_hex_4k, "w") as f:
        for b in packed:
            f.write(f"{b:02X}\n")

    sim_hex_4k = os.path.join(project_dir, "sim", "menu_4k.hex")
    with open(sim_hex_4k, "w") as f:
        for b in packed:
            f.write(f"{b:02X}\n")

    # 3. Create menu_4k.a78 with 7800header if available
    header_tool = "/Users/rowe/Software/Atari7800/7800basic/7800header"
    cfg_file = os.path.join(script_dir, "a78info.cfg")
    if os.path.exists(header_tool) and os.path.exists(cfg_file):
        cmd = [header_tool, "-o", "-f", cfg_file, out_bin_4k]
        try:
            subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=script_dir)
            print(f"✓ Successfully generated: {os.path.join(script_dir, 'menu_4k.a78')}")
        except Exception as e:
            print(f"Notice: 7800header error: {e}")

    print(f"✓ Successfully generated menu_4k.bin and menu_4k.hex (4096 bytes).")
    return True

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.abspath(os.path.join(script_dir, ".."))
    process_menu(script_dir, project_dir)
