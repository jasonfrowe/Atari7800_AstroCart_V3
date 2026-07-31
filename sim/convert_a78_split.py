#!/usr/bin/env python3
# ============================================================================
# Script: convert_a78_split.py
# Description: Converts .a78 file into 24 2KB hex files (2048 lines each)
#              for 1-to-1 Gowin BSRAM hardware block mapping.
# ============================================================================

import sys

from a78_header import parse_a78_header, payload_from_a78

GAME_WINDOW_BYTES = 24 * 2048
MENU_WINDOW_BYTES = 4 * 2048

def _load_payload(path):
    with open(path, 'rb') as f:
        data = f.read()

    header = parse_a78_header(data)
    rom_data = payload_from_a78(data, header)
    print(f"[CONVERT] Extracted {len(rom_data)} bytes of ROM data from {path}.")

    if not header.magic_ok:
        print("[CONVERT] Warning: A78 magic text mismatch at offset 0x01.")
    if not header.end_magic_ok:
        print("[CONVERT] Warning: A78 end magic mismatch at offset 0x64.")

    return rom_data


def _emit_chunks(prefix, data, chunk_count):
    for i in range(chunk_count):
        chunk = data[i * 2048:(i + 1) * 2048]
        out_name = f"{prefix}_{i:02d}.hex"
        with open(out_name, 'w') as f:
            for b in chunk:
                f.write(f"{b:02x}\n")
        print(f"[CONVERT] Generated {out_name} (2048 lines).")


def convert_a78_split(game_a78, menu_a78):
    game_data = _load_payload(game_a78)
    menu_data = _load_payload(menu_a78)

    if len(game_data) > GAME_WINDOW_BYTES:
        print(f"ERROR: Game ROM size {len(game_data)} exceeds 48KB window ({GAME_WINDOW_BYTES} bytes).")
        sys.exit(1)

    if len(menu_data) > MENU_WINDOW_BYTES:
        print(f"ERROR: Menu ROM size {len(menu_data)} exceeds 8KB window ({MENU_WINDOW_BYTES} bytes).")
        sys.exit(1)

    if len(game_data) < GAME_WINDOW_BYTES:
        pad_len = GAME_WINDOW_BYTES - len(game_data)
        print(f"[CONVERT] Padding game ROM with {pad_len} bytes of 0xFF to fill 48KB.")
        game_data = game_data + bytes([0xFF]) * pad_len

    if len(menu_data) < MENU_WINDOW_BYTES:
        pad_len = MENU_WINDOW_BYTES - len(menu_data)
        print(f"[CONVERT] Padding menu ROM with {pad_len} bytes of 0xFF to fill 8KB.")
        menu_data = menu_data + bytes([0xFF]) * pad_len

    _emit_chunks("rom_chunk", game_data, 24)
    _emit_chunks("menu_chunk", menu_data, 4)

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python3 convert_a78_split.py <game.a78> <menu.a78>")
        sys.exit(1)
    convert_a78_split(sys.argv[1], sys.argv[2])
