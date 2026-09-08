#!/usr/bin/env python3
"""Generate 32-bit word chunk HEX files from existing 8-bit chunk HEX files.

Input format: one byte (2 hex chars) per line, 2048 lines per chunk.
Output format: one 32-bit word (8 hex chars) per line, 2048 lines per 8KB chunk.
Word packing is little-endian by byte address (b0 + b1<<8 + b2<<16 + b3<<24).
"""

from pathlib import Path


BYTES_PER_2K_CHUNK = 2048
BYTES_PER_WORD = 4
GROUP_CHUNKS = 4
BYTES_PER_8K_GROUP = BYTES_PER_2K_CHUNK * GROUP_CHUNKS
WORDS_PER_8K_GROUP = BYTES_PER_8K_GROUP // BYTES_PER_WORD


def read_byte_chunk(path: Path) -> list[int]:
    lines = [line.strip() for line in path.read_text().splitlines() if line.strip()]
    if len(lines) != BYTES_PER_2K_CHUNK:
        raise ValueError(f"{path} expected {BYTES_PER_2K_CHUNK} bytes, found {len(lines)}")
    data: list[int] = []
    for idx, token in enumerate(lines):
        if len(token) > 2:
            raise ValueError(f"{path}:{idx+1} expected byte hex, got '{token}'")
        data.append(int(token, 16) & 0xFF)
    return data


def write_word_chunk(path: Path, data: list[int]) -> None:
    if len(data) != BYTES_PER_8K_GROUP:
        raise ValueError(f"{path} expected {BYTES_PER_8K_GROUP} input bytes, got {len(data)}")
    words: list[str] = []
    for i in range(0, len(data), BYTES_PER_WORD):
        w = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)
        words.append(f"{w:08x}")
    if len(words) != WORDS_PER_8K_GROUP:
        raise ValueError(f"{path} expected {WORDS_PER_8K_GROUP} words, got {len(words)}")
    path.write_text("\n".join(words) + "\n")


def build_grouped_chunks(base: Path, in_prefix: str, out_prefix: str, out_count: int) -> None:
    for out_idx in range(out_count):
        in_start = out_idx * GROUP_CHUNKS
        merged: list[int] = []
        for in_idx in range(in_start, in_start + GROUP_CHUNKS):
            src = base / f"{in_prefix}_{in_idx:02d}.hex"
            merged.extend(read_byte_chunk(src))
        dst = base / f"{out_prefix}_{out_idx:02d}.hex"
        write_word_chunk(dst, merged)


def main() -> None:
    base = Path(__file__).resolve().parent
    build_grouped_chunks(base, "rom_chunk", "rom_word_chunk", out_count=6)
    build_grouped_chunks(base, "menu_chunk", "menu_word_chunk", out_count=1)


if __name__ == "__main__":
    main()
