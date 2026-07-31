#!/usr/bin/env python3
"""A78 header parsing helpers shared by conversion scripts."""

from __future__ import annotations

from dataclasses import dataclass

A78_HEADER_SIZE = 128
MAGIC_TEXT = b"ATARI7800"
END_MAGIC_TEXT = b"ACTUAL CART DATA STARTS HERE"

CART_POKEY_4000 = 1 << 0
CART_SUPERGAME = 1 << 1
CART_ACTIVISION = 1 << 8
CART_ABSOLUTE = 1 << 9
CART_POKEY_440 = 1 << 10
CART_POKEY_800 = 1 << 15

V4_MAPPER_LINEAR = 0
V4_MAPPER_SUPERGAME = 1
V4_MAPPER_ACTIVISION = 2
V4_MAPPER_ABSOLUTE = 3

# v4 audio field (bits 0-2): 0=none, 1=@440, 2=@450, 3=@450+@440, 4=@800, 5=@4000
V4_AUDIO_POKEY_MASK = 0x0007
V4_AUDIO_POKEY_440 = 1
V4_AUDIO_POKEY_450 = 2
V4_AUDIO_POKEY_450_440 = 3
V4_AUDIO_POKEY_800 = 4
V4_AUDIO_POKEY_4000 = 5


@dataclass(frozen=True)
class A78Header:
    version: int
    title: str
    rom_size: int
    cart_type: int
    ctrl1: int
    ctrl2: int
    tv_type: int
    save_device: int
    slot_passthrough: int
    v4_mapper: int
    v4_mapper_opts: int
    v4_audio: int
    v4_interrupt: int
    magic_ok: bool
    end_magic_ok: bool


def _decode_title(raw: bytes) -> str:
    return raw.rstrip(b"\x00 ").decode("ascii", errors="replace")


def parse_a78_header(image: bytes) -> A78Header:
    if len(image) < A78_HEADER_SIZE:
        raise ValueError(f"file too small for A78 header: {len(image)} bytes")

    h = image[:A78_HEADER_SIZE]
    return A78Header(
        version=h[0],
        title=_decode_title(h[17:49]),
        rom_size=int.from_bytes(h[49:53], "big"),
        cart_type=int.from_bytes(h[53:55], "big"),
        ctrl1=h[55],
        ctrl2=h[56],
        tv_type=h[57],
        save_device=h[58],
        slot_passthrough=h[63],
        v4_mapper=h[64],
        v4_mapper_opts=h[65],
        v4_audio=int.from_bytes(h[66:68], "big"),
        v4_interrupt=int.from_bytes(h[68:70], "big"),
        magic_ok=h[1:10] == MAGIC_TEXT,
        end_magic_ok=h[100:128] == END_MAGIC_TEXT,
    )


def payload_from_a78(image: bytes, header: A78Header) -> bytes:
    payload = image[A78_HEADER_SIZE:]
    if header.rom_size == 0:
        return payload
    if header.rom_size > len(payload):
        raise ValueError(
            f"header rom_size={header.rom_size} exceeds payload length={len(payload)}"
        )
    if header.rom_size != len(payload):
        # Keep conversion deterministic by honoring the declared ROM length.
        return payload[:header.rom_size]
    return payload


def detect_mapper_type(header: A78Header) -> int:
    # Project-local mapper_type encoding in hazard5 CSR:
    # 0 = Flat 48K (linear), 1 = SuperGame, 2 = Flat 32K
    if header.version >= 4:
        if header.v4_mapper == V4_MAPPER_SUPERGAME:
            return 1
        if header.v4_mapper in (V4_MAPPER_LINEAR, V4_MAPPER_ACTIVISION, V4_MAPPER_ABSOLUTE):
            return 0

    if header.cart_type & CART_SUPERGAME:
        return 1

    if header.rom_size and header.rom_size <= 32768:
        return 2

    return 0


def detect_pokey_selector(header: A78Header) -> tuple[bool, int | None]:
    # Selector values match RTL/firmware CSR encoding:
    # 0=$4000, 1=$0450, 2=$0800
    if header.version >= 4:
        pokey_mode = header.v4_audio & V4_AUDIO_POKEY_MASK
        if pokey_mode == V4_AUDIO_POKEY_4000:
            return True, 0
        if pokey_mode in (V4_AUDIO_POKEY_450, V4_AUDIO_POKEY_450_440):
            return True, 1
        if pokey_mode == V4_AUDIO_POKEY_800:
            return True, 2
        return False, None

    if header.cart_type & CART_POKEY_4000:
        return True, 0
    if header.cart_type & 0x40:
        return True, 1
    if header.cart_type & CART_POKEY_800:
        return True, 2
    return False, None


def pokey_location_summary(header: A78Header) -> str:
    locations = []
    if header.cart_type & CART_POKEY_4000:
        locations.append("v3:$4000")
    if header.cart_type & CART_POKEY_440:
        locations.append("v3:$0440")
    if header.cart_type & 0x40:
        locations.append("v3:$0450")
    if header.cart_type & CART_POKEY_800:
        locations.append("v3:$0800")

    if header.version >= 4:
        pokey_mode = header.v4_audio & V4_AUDIO_POKEY_MASK
        locations.append(f"v4:mode{pokey_mode}")

    return ", ".join(locations) if locations else "none"
