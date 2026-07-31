#!/usr/bin/env python3
import sys

def convert_a78_to_hex(a78_path, hex_path):
    with open(a78_path, "rb") as f:
        data = f.read()

    # Verify A78 header signature
    if data[:9] != b"\x04ATARI7800" and data[1:10] != b"ATARI7800":
        print(f"Warning: Header signature in {a78_path} might not be standard A78, proceeding anyway.")

    # A78 header is 128 bytes
    header = data[:128]
    payload = data[128:]

    print(f"Loaded '{a78_path}': Header=128 bytes, Payload={len(payload)} bytes")

    with open(hex_path, "w") as f:
        for b in payload:
            f.write(f"{b:02x}\n")

    print(f"Successfully generated memory initialization file: '{hex_path}' ({len(payload)} lines)")

if __name__ == "__main__":
    a78_input = sys.argv[1] if len(sys.argv) > 1 else "../carts/astrowing.a78"
    hex_output = sys.argv[2] if len(sys.argv) > 2 else "astrowing.hex"
    convert_a78_to_hex(a78_input, hex_output)
