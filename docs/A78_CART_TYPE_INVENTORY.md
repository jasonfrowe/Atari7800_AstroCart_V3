# A78 Cart Type Inventory (Menu Order)

Generated from files in `carts/` using A78 header fields used by firmware:
- version: byte 0
- magic: bytes 1..9 (`ATARI7800`)
- ROM size: bytes 49..52 (big-endian)
- legacy cart type flags: bytes 53..54 (big-endian)
- v4 mapper: byte 64
- v4 audio: byte 66

## Inventory

| Menu Slot | Cart | Header Title | Version | ROM Size | <=48K Fast Path | v4 Mapper | v4 Audio | Legacy Flags Seen |
|---|---|---|---:|---:|---|---|---|---|
| 1 | ARTI | ARTI_v1.1_digital | 4 | 262144 | No | supergame | none | supergame, pokey0450 |
| 2 | Astro Wing | Astro Wing Startfighter | 4 | 49152 | Yes | linear | none | pokey0450 |
| 3 | Choplifter | Choplifter (NTSC) | 4 | 32768 | Yes | linear | none | none |
| 4 | Commando | Commando (NTSC) | 4 | 131072 | No | supergame | none | supergame, pokey4000 |
| 5 | Food Fight | Food Fight (NTSC) | 4 | 32768 | Yes | linear | none | none |
| 6 | Impossible Mission | Impossible Mission (NTSC) | 4 | 131072 | No | supergame | none | supergame |
| 7 | Jinks | Jinks (NTSC) | 4 | 131072 | No | supergame | none | supergame |
| 8 | Tiger-Heli | "Tiger-Heli 7800" | 4 | 147456 | No | supergame | none | supergame, pokey0450 |

## Immediate Implementation Buckets

### Bucket A: <=48K direct BSRAM copy (first to implement)
- Astro Wing (48K)
- Choplifter (32K)
- Food Fight (32K)

### Bucket B: >48K staged load (BSRAM + PSRAM banking)
- ARTI (256K)
- Commando (128K)
- Impossible Mission (128K)
- Jinks (128K)
- Tiger-Heli (144K)

## Important Header Observation

All eight files are v4 headers, but several carts show Pokey only in legacy flag bits while v4 audio byte is `none`.

Implication for loader policy:
1. Do not rely on v4 audio byte alone.
2. Decode Pokey and mapper from both sources.
3. Prefer v4 fields when non-zero/known, then fall back to legacy flags.
4. Record normalized result per slot for menu and loader handoff.

## Recommended Next Step (Item 2)

Implement "<=48K direct copy" path first:
1. On menu select, pass slot metadata key + selected index to service firmware.
2. Service firmware opens selected file and copies up to 48K payload to BSRAM.
3. Set status done bit at end, preserving current launch handoff.
4. Gate to linear carts first (Astro Wing, Choplifter, Food Fight).

This keeps risk low while using already-supported FPGA behavior for 48K launch.
