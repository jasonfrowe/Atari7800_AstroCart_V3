# Trace Replay Format

The Verilator harness supports replaying Atari 7800 bus cycles captured from an external source such as an instrumented A7800 emulator.

Run it with:

```bash
make -C sim trace TRACE_FILE=traces/reset_vector.trace
make -C sim trace A78_FILE=../menu/menu.bas.a78 HEX_FILE=menu_payload.hex TRACE_FILE=traces/reset_vector.trace
python3 sim/a7800_trace_to_replay.py exported_bus.csv sim/traces/a7800_boot.trace
make -C sim trace-convert CONVERT_INPUT=exported_bus.csv CONVERT_OUTPUT=traces/a7800_boot.trace
```

Each non-empty, non-comment line in the trace file is:

```text
<addr> <R|W> <write_data> <halt> <expected|?> [<IN|OUT>]
```

Fields:

- `addr`: 16-bit CPU or MARIA bus address. Hex (`0xFFFC`) and decimal are both accepted.
- `R|W`: `R` for read cycles, `W` for write cycles.
- `write_data`: Data byte driven by the console during write cycles. Use `0x00` for reads.
- `halt`: `1` means MARIA owns the bus (`HALT` asserted on the cart edge), `0` means normal CPU bus ownership.
- `expected|?`: Optional expected read byte. Use `?` to auto-derive expected data from the loaded ROM payload for cartridge-space reads.
- `IN|OUT`: Optional explicit transceiver direction expectation. `OUT` means the cartridge should be driving the bus, `IN` means it should be listening.

Example:

```text
# Reset vector fetch and first opcode reads
0xFFFC R 0x00 0 ? OUT
0xFFFD R 0x00 0 ? OUT
0xC000 R 0x00 0 ? OUT
0xC001 R 0x00 0 ? OUT

# Example POKEY write on the CPU bus
0x4001 W 0x3F 0 ? IN

# Example MARIA DMA read
0x8000 R 0x00 1 ? OUT
```

What replay currently checks:

- Cartridge reads in `$4000-$FFFF` return the expected ROM byte.
- Writes in cartridge space keep the transceiver in input mode.
- Non-cartridge addresses do not put the cartridge in drive mode.
- Optional `IN` / `OUT` tokens can pin down the expected transceiver direction per cycle.

What replay does not yet do:

- It does not embed the A7800 emulator in-process.
- It does not yet model TIA, RIOT, or BIOS side effects.
- It does not yet compare full-system frame output.

That makes this a good intermediate step: the emulator can supply real Sally/MARIA bus sequences, and Verilator can verify the cartridge responds correctly before hardware bring-up.

The simulation harness also accepts `--rom-hex <file>` directly, and the Makefile passes `HEX_FILE` through to the testbench. That lets you swap between Astrowings, the menu ROM, and future fixed-ROM images without editing the harness.

If your emulator can export bus cycles as CSV, TSV, or JSON Lines, use `sim/a7800_trace_to_replay.py` to map those logs into replay traces. The converter looks for common field names such as `addr`, `rw`, `data`, `halt`, `expected_data`, and `drive_mode`.

There is also a small fixture at `sim/traces/example_a7800_export.csv` that shows the expected CSV header and field naming.