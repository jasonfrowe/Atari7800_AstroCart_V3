#!/usr/bin/env python3
import sys

from a78_header import (
    detect_pokey_selector,
    detect_mapper_type,
    parse_a78_header,
    payload_from_a78,
    pokey_location_summary,
)

def convert_a78_to_hex(a78_path, hex_path):
    with open(a78_path, "rb") as f:
        data = f.read()

    header = parse_a78_header(data)
    payload = payload_from_a78(data, header)

    if not header.magic_ok:
        print(f"Warning: {a78_path} missing A78 magic text at offset 0x01.")
    if not header.end_magic_ok:
        print(f"Warning: {a78_path} missing end magic text at offset 0x64.")

    print(f"Loaded '{a78_path}': Header=128 bytes, Payload={len(payload)} bytes")
    print(
        "Header info: "
        f"ver={header.version}, title='{header.title}', rom_size={header.rom_size}, "
        f"mapper_type={detect_mapper_type(header)}, pokey={pokey_location_summary(header)}"
    )

    pokey_enabled, pokey_sel = detect_pokey_selector(header)
    if pokey_enabled:
        pokey_base = {0: "$4000", 1: "$0450", 2: "$0800"}.get(pokey_sel, "unknown")
        print(f"Resolved POKEY selector: enabled at {pokey_base}")
    elif "pokey" in pokey_location_summary(header).lower():
        print("Warning: Header requests unsupported POKEY location(s) for current RTL.")

    with open(hex_path, "w") as f:
        for b in payload:
            f.write(f"{b:02x}\n")

    print(f"Successfully generated memory initialization file: '{hex_path}' ({len(payload)} lines)")

if __name__ == "__main__":
    a78_input = sys.argv[1] if len(sys.argv) > 1 else "../carts/astrowing.a78"
    hex_output = sys.argv[2] if len(sys.argv) > 2 else "cart_payload.hex"
    convert_a78_to_hex(a78_input, hex_output)
