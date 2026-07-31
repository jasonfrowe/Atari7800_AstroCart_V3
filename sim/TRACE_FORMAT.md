# Trace Replay Format

The Verilator harness supports replaying Atari 7800 bus cycles captured from an external source such as an instrumented A7800 emulator.

Run it with:

```bash
make -C sim trace TRACE_FILE=traces/reset_vector.trace
```

Each non-empty, non-comment line in the trace file is:

```text
<addr> <R|W> <write_data> <halt> <expected|?>
```

Fields:

- `addr`: 16-bit CPU or MARIA bus address. Hex (`0xFFFC`) and decimal are both accepted.
- `R|W`: `R` for read cycles, `W` for write cycles.
- `write_data`: Data byte driven by the console during write cycles. Use `0x00` for reads.
- `halt`: `1` means MARIA owns the bus (`HALT` asserted on the cart edge), `0` means normal CPU bus ownership.
- `expected|?`: Optional expected read byte. Use `?` to auto-derive expected data from the loaded ROM payload for cartridge-space reads.

Example:

```text
# Reset vector fetch and first opcode reads
0xFFFC R 0x00 0 ?
0xFFFD R 0x00 0 ?
0xC000 R 0x00 0 ?
0xC001 R 0x00 0 ?

# Example POKEY write on the CPU bus
0x4001 W 0x3F 0 ?

# Example MARIA DMA read
0x8000 R 0x00 1 ?
```

What replay currently checks:

- Cartridge reads in `$4000-$FFFF` return the expected ROM byte.
- Writes in cartridge space keep the transceiver in input mode.
- Non-cartridge addresses do not put the cartridge in drive mode.

What replay does not yet do:

- It does not embed the A7800 emulator in-process.
- It does not yet model TIA, RIOT, or BIOS side effects.
- It does not yet compare full-system frame output.

That makes this a good intermediate step: the emulator can supply real Sally/MARIA bus sequences, and Verilator can verify the cartridge responds correctly before hardware bring-up.