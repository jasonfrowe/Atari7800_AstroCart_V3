#!/usr/bin/env python3
"""Convert emulator bus logs into the Verilator replay trace format.

Accepted inputs:
- CSV/TSV with a header row
- JSON Lines, one object per line

Required logical fields:
- address / addr / a
- read-write direction via one of:
  - rw / r_w / read_write with values like R/W, read/write, 1/0
  - is_read / read with boolean-like values

Optional fields:
- data / write_data / din / value
- halt / maria_halt / dma_halt
- expected / expected_data / dout

Output format:
    <addr> <R|W> <write_data> <halt> <expected|?>
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Dict, Iterable, Iterator, Optional


ADDRESS_KEYS = ("address", "addr", "a")
OWNER_KEYS = ("owner", "bus_owner", "master")
RW_KEYS = ("rw", "r_w", "read_write", "direction")
READ_BOOL_KEYS = ("is_read", "read")
DATA_KEYS = ("data", "write_data", "din", "value")
HALT_KEYS = ("halt", "maria_halt", "dma_halt")
EXPECTED_KEYS = ("expected", "expected_data", "dout", "read_data")
DRIVE_MODE_KEYS = ("drive_mode", "expect_drive", "expected_drive", "buf_dir", "direction_expect")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="CSV/TSV/JSONL bus log exported from an emulator")
    parser.add_argument("output", help="Replay trace to write")
    parser.add_argument(
        "--format",
        choices=("auto", "csv", "tsv", "jsonl"),
        default="auto",
        help="Input file format. Default: auto-detect from extension.",
    )
    return parser.parse_args()


def normalize_key_map(row: Dict[str, object]) -> Dict[str, object]:
    return {str(key).strip().lower(): value for key, value in row.items()}


def first_present(row: Dict[str, object], keys: Iterable[str]) -> Optional[object]:
    for key in keys:
        if key in row and row[key] not in (None, ""):
            return row[key]
    return None


def parse_int(value: object, default: int = 0) -> int:
    if value in (None, ""):
        return default
    text = str(value).strip()
    if not text:
        return default
    if text.startswith("$"):
        return int(text[1:], 16)
    return int(text, 0)


def parse_bool(value: object, default: bool = False) -> bool:
    if value in (None, ""):
        return default
    text = str(value).strip().lower()
    if text in ("1", "true", "t", "yes", "y", "halt", "h", "read", "r"):
        return True
    if text in ("0", "false", "f", "no", "n", "write", "w"):
        return False
    raise ValueError(f"cannot interpret boolean value: {value!r}")


def parse_is_read(row: Dict[str, object]) -> bool:
    rw_value = first_present(row, RW_KEYS)
    if rw_value is not None:
        text = str(rw_value).strip().lower()
        if text in ("r", "read", "1"):
            return True
        if text in ("w", "write", "0"):
            return False
        raise ValueError(f"unsupported read/write token: {rw_value!r}")

    read_value = first_present(row, READ_BOOL_KEYS)
    if read_value is not None:
        return parse_bool(read_value)

    raise ValueError("missing read/write field")


def parse_halt(row: Dict[str, object]) -> int:
    halt_value = first_present(row, HALT_KEYS)
    if halt_value is not None:
        return 1 if parse_bool(halt_value, default=False) else 0

    owner_value = first_present(row, OWNER_KEYS)
    if owner_value is not None:
        text = str(owner_value).strip().lower()
        if text in ("maria", "dma", "graphics"):
            return 1
        if text in ("cpu", "sally"):
            return 0
        raise ValueError(f"unsupported owner token for halt inference: {owner_value!r}")

    return 0


def detect_format(path: Path, requested: str) -> str:
    if requested != "auto":
        return requested
    suffix = path.suffix.lower()
    if suffix in (".jsonl", ".ndjson"):
        return "jsonl"
    if suffix == ".tsv":
        return "tsv"
    return "csv"


def iter_rows(path: Path, fmt: str) -> Iterator[Dict[str, object]]:
    if fmt in ("csv", "tsv"):
        delimiter = "\t" if fmt == "tsv" else ","
        with path.open("r", newline="") as handle:
            reader = csv.DictReader(handle, delimiter=delimiter)
            for row in reader:
                yield normalize_key_map(row)
        return

    if fmt == "jsonl":
        with path.open("r") as handle:
            for line_no, line in enumerate(handle, start=1):
                text = line.strip()
                if not text:
                    continue
                obj = json.loads(text)
                if not isinstance(obj, dict):
                    raise ValueError(f"line {line_no}: expected JSON object")
                yield normalize_key_map(obj)
        return

    raise ValueError(f"unsupported input format: {fmt}")


def format_row(row: Dict[str, object]) -> str:
    address = first_present(row, ADDRESS_KEYS)
    if address is None:
        raise ValueError("missing address field")

    is_read = parse_is_read(row)
    write_data = parse_int(first_present(row, DATA_KEYS), default=0) & 0xFF
    halt = parse_halt(row)

    expected_value = first_present(row, EXPECTED_KEYS)
    expected_token = "?" if expected_value in (None, "") else f"0x{parse_int(expected_value) & 0xFF:02X}"

    drive_mode_value = first_present(row, DRIVE_MODE_KEYS)
    drive_mode_token = ""
    if drive_mode_value not in (None, ""):
        text = str(drive_mode_value).strip().lower()
        if text in ("1", "out", "drive", "output"):
            drive_mode_token = " OUT"
        elif text in ("0", "in", "listen", "input"):
            drive_mode_token = " IN"
        else:
            raise ValueError(f"unsupported drive-mode token: {drive_mode_value!r}")

    return f"0x{parse_int(address) & 0xFFFF:04X} {'R' if is_read else 'W'} 0x{write_data:02X} {halt} {expected_token}{drive_mode_token}"


def main() -> int:
    args = parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output)
    fmt = detect_format(input_path, args.format)

    rows = list(iter_rows(input_path, fmt))
    if not rows:
        raise SystemExit(f"no rows found in {input_path}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as handle:
        handle.write("# Converted emulator bus trace\n")
        for row in rows:
            handle.write(format_row(row))
            handle.write("\n")

    print(f"Converted {len(rows)} bus cycles from {input_path} to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())