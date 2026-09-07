# A7800 Instrumentation Plan

This plan describes how to use a pinned A7800 checkout as an external emulator
module so the exporter can feed the Verilator replay harness with real Sally
and MARIA access sequences.

The target output schema is defined in [A7800_EXPORT_SCHEMA.md](A7800_EXPORT_SCHEMA.md).

## Objective

Emit a CSV log of cartridge-visible bus cycles during boot and early execution,
with enough fidelity to answer these questions:

1. Does the cartridge deliver the correct reset vector?
2. Does Sally fetch the first opcodes correctly from cartridge space?
3. Does MARIA DMA see valid cartridge data with `HALT` asserted?
4. Does the cartridge remain in input mode during writes such as POKEY or mapper writes?

## Scope For v1

Only export cartridge-relevant cycles:

- CPU reads and writes where `addr >= 0x4000`
- MARIA DMA reads that target cartridge space
- Optional low-memory probes near reset if you want context, but they are not required

Do not try to export every TIA, RIOT, or RAM cycle in the first pass.

## Exporter Design

Implement one small logger object with three responsibilities:

1. Open an output CSV file when tracing is enabled
2. Append one row per cartridge-visible cycle
3. Stop after a configurable capture budget such as the first 2,000 relevant cycles

Suggested runtime flags:

- `-cartbuslog <file.csv>` to enable logging
- `-cartbuslimit <n>` to stop after `n` emitted rows
- `-cartbusboot` to start at reset and stop after the first frame or row limit

## Current Patch Status

The first exporter slice is now implemented in the SDK-pinned external module
checkout at:

```text
third_party/a7800/src/mame/drivers/a7800.cpp
```

Current behavior of that patch:

- It logs main cartridge window reads and writes in the `$4000-$FFFF` path.
- It logs reset-vector reads through the `bios_or_cart_r` path when BIOS is not selected.
- It infers `owner=MARIA` from the existing `m_dmaactive` flag during DMA.
- It writes CSV when the environment variable `A7800_CARTBUS_LOG` is set.
- It honors an optional row limit from `A7800_CARTBUS_LIMIT`.

Current limitation of that first patch:

- It does not yet log auxiliary cartridge windows below `$4000` such as `read_04xx`, `read_08xx`, `read_10xx`, or `read_30xx`.
- That is acceptable for the first boot-trace milestone because reset-vector fetch, early opcode streaming, and MARIA DMA for fixed-ROM carts all happen through the main `$4000-$FFFF` path.

## Preferred Checkout

The preferred A7800 checkout in this repo is the pinned submodule copy:

```text
third_party/a7800
```

It keeps the emulator version pinned alongside the Atari 7800 platform work,
which is a better fit than a loose local install.

## Current Working Build Command

The preferred A7800 checkout now builds on this machine with the following command:

```text
cd third_party/a7800
make -j$(sysctl -n hw.ncpu)
```

Resulting emulator binary:

```text
third_party/a7800/mame64
```

## Required Hook Points

You do not need a global event system. Add two narrow hooks near the existing memory-access codepaths.

### 1. Sally CPU Cartridge Access Hook

Hook immediately after the emulator resolves a CPU cartridge read or write.

Required values to capture:

- `owner=CPU`
- `addr`
- `rw`
- `data`
  On writes: the byte the CPU drove
  On reads: `0x00`
- `halt=0`
- `expected_data`
  On reads: the byte returned to the CPU
  On writes: blank
- `drive_mode`
  `OUT` on reads in cartridge space
  `IN` on writes in cartridge space

Placement rule:

- Reads: emit after the emulator has the returned data byte
- Writes: emit after the emulator has the final write byte and target address, but before any higher-level debug filtering discards the event

### 2. MARIA DMA Cartridge Fetch Hook

Hook immediately after the emulator resolves a MARIA DMA fetch from cartridge space.

Required values to capture:

- `owner=MARIA`
- `addr`
- `rw=R`
- `data=0x00`
- `halt=1`
- `expected_data` equal to the byte returned to MARIA
- `drive_mode=OUT`

Placement rule:

- Emit once the fetched byte is known
- Only log DMA reads that actually hit cartridge space

## Boot Capture Rules

For the first useful trace, start logging at machine reset and stop after all of these have happened:

1. CPU read from `$FFFC`
2. CPU read from `$FFFD`
3. At least 8 subsequent CPU reads from cartridge space
4. At least 1 MARIA DMA read from cartridge space

If it is simpler in A7800, just stop after a fixed count like 256 emitted rows. The replay harness can ignore extra rows.

## Row Construction Rules

Use these exact semantics when writing rows:

- `owner`
  `CPU` for Sally accesses, `MARIA` for DMA fetches
- `rw`
  `R` or `W` only
- `data`
  For writes: write byte from the console side
  For reads: `0x00`
- `expected_data`
  For reads: the byte observed by the emulator from cartridge memory or device logic
  For writes: leave blank
- `drive_mode`
  `OUT` when the cartridge is expected to drive the bus
  `IN` when the cartridge is expected to listen

## Minimal Pseudocode

```cpp
if (cartbus_logger.enabled() && addr >= 0x4000) {
    cartbus_logger.emit({
        .cycle = cycle_counter,
        .owner = is_maria ? "MARIA" : "CPU",
        .addr = addr,
        .rw = is_write ? "W" : "R",
        .data = is_write ? write_byte : 0x00,
        .halt = is_maria ? 1 : 0,
        .expected_data = is_write ? std::nullopt : std::optional<uint8_t>(read_byte),
        .drive_mode = is_write ? "IN" : "OUT",
    });
}
```

## Validation Loop

Once A7800 emits the CSV:

1. Convert it with `make -C sim trace-convert CONVERT_INPUT=... CONVERT_OUTPUT=...`
2. Run `./build.sh --trace-boot sim/traces/a7800_boot.trace`
3. Fix any reset-vector, opcode, DMA, or direction mismatches in RTL

For the current separate-checkout patch, the minimal runtime configuration is:

```text
A7800_CARTBUS_LOG=/path/to/a7800_boot.csv
A7800_CARTBUS_LIMIT=256
```

Set those in the environment before launching the instrumented emulator build.

## Memory Layout Notes

The Verilator replay harness and the A7800 export path both assume the Atari
7800's real cartridge layout:

1. Main cartridge ROM window: `0x4000-0xFFFF`.
2. Atari 7800 internal RAM window: `0x1800-0x27FF`.
3. POKEY decode windows used by this project: `0x4000`, `0x0450`, and `0x0800`.

That matters because the exporter should report real cartridge-visible cycles,
while the replay harness should only compare bytes against ROM payload for the
addresses that are actually ROM-backed. RAM, TIA, RIOT, and other console-owned
regions should remain outside the ROM comparison path.

## Recommendation On Repo Layout

Keep the emulator source external, but pinned.

Use the SDK's `third_party/a7800` checkout while developing the exporter so:

- this repo stays focused on HDL and replay tooling
- A7800 build churn does not pollute the FPGA workspace
- the exporter patch can stabilize before you decide whether this project depends on a pinned emulator fork

If the emulator becomes a long-term dependency for this repo specifically,
mirror the same pinned-external-module approach here rather than relying on an
untracked local install.