# A7800 Bus Export Schema v1

This file defines the recommended bus-log format for instrumenting A7800 so its
CPU and MARIA cartridge accesses can be replayed through the Verilator cart
harness.

The goal is not to snapshot the entire emulator state. The goal is to export the
minimum cycle-level information needed to validate cartridge behavior:

- Which side owned the bus
- Which address was presented to the cartridge
- Whether the cycle was a read or write
- Which data byte the console drove on writes
- Which byte the emulator observed on reads
- Whether the cartridge should be driving or listening

## Required Columns

These columns should be present in every exported row:

```text
cycle,owner,addr,rw,data,halt,expected_data,drive_mode
```

Definitions:

- `cycle`: Monotonic cycle counter from the start of the captured trace.
- `owner`: `CPU` for Sally-owned cycles, `MARIA` for DMA-owned cycles.
- `addr`: 16-bit address on the cartridge bus. Preferred format: `0xFFFF`.
- `rw`: `R` for reads, `W` for writes.
- `data`: Data byte driven by the console on writes. Use `0x00` on reads.
- `halt`: `0` for CPU cycles, `1` for MARIA DMA cycles.
- `expected_data`: Byte observed by the emulator during reads. Leave blank if
  unavailable, but prefer filling it for cartridge-space reads.
- `drive_mode`: `OUT` when the cartridge should drive the bus, `IN` when it
  should listen.

## Optional Columns

These columns are useful for debugging but are not required by the current
converter:

```text
phi2,phi2_rise,source,region,scanline,color_clock,opcode_pc,opcode_byte,comment
```

Suggested meanings:

- `phi2`: Current sampled PHI2 level at the moment the cart bus is considered valid.
- `phi2_rise`: `1` on the edge that begins a valid bus phase.
- `source`: More specific source tag such as `RESET_VECTOR`, `OPCODE_FETCH`,
  `POKEY_WRITE`, `MARIA_DMA`, `BANKSWITCH`.
- `region`: High-level phase such as `BOOT`, `FRAME_0`, `FRAME_1`.
- `scanline`: MARIA scanline for DMA cycles if known.
- `color_clock`: Horizontal position within the scanline if known.
- `opcode_pc`: CPU program counter associated with opcode fetches if known.
- `opcode_byte`: Opcode byte seen by the emulator.
- `comment`: Freeform text for diagnostics.

## CSV Example

```csv
cycle,owner,addr,rw,data,halt,expected_data,drive_mode,source,opcode_pc
0,CPU,0xFFFC,R,0x00,0,0x00,OUT,RESET_VECTOR,
1,CPU,0xFFFD,R,0x00,0,0xC0,OUT,RESET_VECTOR,
2,CPU,0xC000,R,0x00,0,0x78,OUT,OPCODE_FETCH,0xC000
3,CPU,0xC001,R,0x00,0,0xD8,OUT,OPCODE_FETCH,0xC001
4,MARIA,0x8000,R,0x00,1,0xA9,OUT,MARIA_DMA,
5,CPU,0x4001,W,0x3F,0,,IN,POKEY_WRITE,
```

## Boot Trace Contract

For an initial bring-up trace, capture at least this sequence:

1. Reset vector reads at `$FFFC` and `$FFFD`
2. At least 8 subsequent CPU opcode fetch reads in cartridge space
3. At least 1 MARIA DMA read with `halt=1`
4. At least 1 cartridge-space write cycle if the boot ROM performs one

That is enough to answer the first hardware question: does the FPGA cart respond
correctly to early Sally boot and MARIA DMA bus ownership?

## Why This Schema

This schema is intentionally flat and CSV-friendly:

- It is easy to emit from emulator code without introducing a new dependency.
- It can be converted to the replay trace with the current Python tool.
- It keeps room for richer assertions later without breaking the core workflow.

## Recommendation For A7800 Instrumentation

Start with a CSV emitter using exactly the required columns above. Add optional
columns only if they are already cheap to access in the emulator codepath.