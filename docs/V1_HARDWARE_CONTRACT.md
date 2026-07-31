# V1 Hardware Contract and Bring-Up Checklist

## Objective

Define the minimum verifiable requirements for a Tang Nano 9K Atari 7800 cartridge core that runs AstroWing on real hardware with functional parity to the validated emulator/simulation flow.

## Current Baseline

1. Instrumented A7800 emulator build is available and can export cartridge bus CSV traces.
2. Full-trace conversion and `--trace-boot` replay pass in Verilator with zero mismatches.
3. AstroWing gameplay and POKEY audio are confirmed working in emulator.
4. AstroWing is confirmed working on real Atari 7800 hardware using 7800GD (reference cartridge behavior).
5. Current Tang Nano 9K core does not yet boot AstroWing on real hardware (does not reach 7800 BIOS screen).

This contract freezes what v1 must achieve while implementation proceeds from current pre-boot hardware status.

## Immediate Implementation Start Point

The project is now in active implementation mode for Tang 9K AstroWing support.

First milestone (M0) is mandatory before gameplay goals:

1. M0 BIOS visibility milestone:
Reach and sustain the Atari 7800 BIOS screen on real hardware with the Tang 9K cartridge core.

Only after M0 passes should the project advance to AstroWing gameplay milestones.

## V1 In-Scope

1. Cartridge read response in `0x4000-0xFFFF` for AstroWing runtime.
2. Correct CPU and MARIA read visibility in trace/replay parity checks.
3. Mapper behavior required by AstroWing in current cart image.
4. POKEY behavior sufficient for audible parity with current hardware validation.
5. Stable Tang 9K bitstream and reproducible build/program flow.

## V1 Out-of-Scope

1. Universal support for all 7800 mappers and edge-case carts.
2. Full XM board compatibility and unsupported cart windows not required by AstroWing.
3. Performance tuning beyond stable 1x gameplay parity.
4. New features that are not required for AstroWing parity.

## Functional Contract

A v1 build is accepted only if all conditions hold.

0. M0 precondition:
Real hardware reaches BIOS screen with Tang 9K core.
If M0 fails, v1 acceptance cannot be evaluated.

1. Boot and gameplay parity:
AstroWing boots from reset and reaches interactive gameplay on real hardware.
No visible corruption or lockups during a 10-minute play session.
Behavior must match expected reference behavior previously observed with 7800GD.

2. Audio parity:
POKEY audio path is active and subjectively consistent with emulator baseline.
No persistent pops/dropouts attributable to bus contention or timing hazards.

3. Trace parity gates:
A captured full CSV trace from instrumented A7800 converts successfully with `sim/a7800_trace_to_replay.py`.
`./build.sh --trace-boot <trace>` passes with zero mismatches.
Replay summary must show both CPU and MARIA cycles.

4. Bus direction safety:
Cartridge data bus drives only during valid read windows.
Cartridge data bus is high-Z during write windows.
No drive overlap with console-side write cycles.

## Electrical and Timing Contract

1. Pin and level-shifter integrity:
Pin map in `atari.cst` matches board wiring and transceiver direction/OE control assumptions.
5V cart interface signals are level-shifted as designed with no direct overstress paths to FPGA IO.

2. Timing closure:
Synthesis/PnR complete successfully for Tang 9K target.
No unresolved critical timing violations on bus control/data paths required for AstroWing operation.

## Regression Gates (Per RTL Change)

Run these gates before hardware flashing for any bus/mapper/audio-impacting change.

1. `./build.sh --sim`
2. `./build.sh --sim-menu`
3. `./build.sh --trace-boot sim/traces/a7800_boot_full.trace`
4. Optional focused replay traces for specific mapper or MARIA hot paths.

Pass criteria:

1. No assertion failures.
2. No replay mismatches.
3. No new warnings indicating illegal drive behavior in testbench checks.

## Staged Bring-Up Checklist

### Stage A: Build and bitstream sanity

1. `./build.sh --gowin` completes successfully.
2. Bitstream file is generated and version tagged.

### Stage B: Program and reset-vector confidence

1. Program SRAM (`./program.sh sram`) and verify power-on behavior.
2. Confirm reset-vector read behavior matches expected startup path.

### Stage B1: BIOS-screen milestone (M0)

1. Confirm real hardware reaches Atari 7800 BIOS screen with Tang 9K core.
2. Confirm no immediate black-screen lockup before BIOS display.
3. Capture one verification note (date, bitstream, observed behavior).

Gate: if Stage B1 fails, do not proceed to Stage C.

### Stage C: Cartridge read path stability

1. Confirm sustained CPU cart reads under gameplay.
2. Verify no spontaneous lockups during menu->game transitions.

### Stage D: MARIA DMA confidence

1. Confirm MARIA activity is observed in replay parity traces.
2. Verify no MARIA-related corruption under sprite-heavy scenes.

### Stage E: Audio and long-run stability

1. Validate POKEY audio during gameplay interactions.
2. Run 10-minute and 30-minute stability sessions with no hangs/corruption.

## Release Evidence Required for v1 Freeze

Store or reference the following in release notes.

1. Commit hash of RTL/firmware/sim state.
2. Generated bitstream filename and timestamp.
3. One passing full-trace replay log.
4. One Stage B1 BIOS-screen verification note.
5. One short real-hardware AstroWing gameplay verification note.
6. Any known limitations explicitly listed.

## Command Appendix

Reference commands used in this flow.

```bash
# Build and simulation gates
./build.sh --sim
./build.sh --sim-menu
./build.sh --trace-boot sim/traces/a7800_boot_full.trace

# Convert emulator CSV to replay trace
python3 sim/a7800_trace_to_replay.py /tmp/a7800_boot.csv sim/traces/a7800_boot_full.trace

# Synthesize and program
./build.sh --gowin
./program.sh sram
./program.sh flash
```

## Decision Rule

If all functional, electrical/timing, and regression gates pass, freeze v1.
If any gate fails, do not freeze; fix and re-run full gates.

## V2 Research Track (Implementation Input)

Use `/Users/rowe/Software/FPGA/Atari7800_AstroCart_V2` as a behavior reference only.

Known V2 status:

1. AstroWing and POKEY behavior are known-good in V2.
2. V2 PSRAM data path is too slow for target direction in this project.
3. V3 direction is BSRAM-backed cartridge storage.

Porting intent:

1. Reuse proven cart bus ownership and mapper behavior from V2.
2. Do not reuse PSRAM timing assumptions or memory-latency coupling.
3. Keep V3 BSRAM architecture as the storage backend with dynamic menu-to-ROM handover via Zero-Page stub ($80-$85) and $7FF0 status polling.

Menu System & B-SRAM ROM Handover Architecture:
- **Menu Core**: Built with 7800basic (`menu/menu.bas`).
- **Load Trigger**: Menu writes `selected_game + 128` to `$2200`.
- **Status Register**: 6502 polls `$7FF0` until Bit 7 signals ROM payload streaming into B-SRAM is complete.
- **Handover Execution**: 6502 copies 6-byte stub to ZP `$80` (`sta $2200` ; `jmp ($FFFC)`), writes `#$A5` to `$2200` to acknowledge, and jumps to `$80` to launch the newly loaded ROM from B-SRAM.

Priority extraction order from V2:

1. Bus direction/enable logic at cart interface (`rw`, `phi2`, HALT interaction).
2. Mapper/bank register update semantics used by AstroWing.
3. POKEY address decode/read behavior and register gating.
4. Cartridge loader metadata interpretation (mapper type, POKEY location) as behavior reference.

V2-to-V3 implementation checkpoints:

1. Mirror V2 bus-ownership behavior in V3 and verify with trace replay.
2. Mirror V2 mapper switching semantics using V3 BSRAM data path.
3. Mirror V2 POKEY decode/read behavior and validate with gameplay trace hotspot replay.
4. Re-run Stage B1 BIOS-screen milestone after each checkpoint.

Stop conditions for this research track:

1. If a V2 behavior conflicts with trace replay parity, trace parity wins.
2. If a V2 behavior depends on PSRAM latency ordering, redesign for deterministic BSRAM timing instead of copying the mechanism.

## Sprint 0 (M0 BIOS) Implementation Plan

Sprint 0 goal:

1. Reach Atari 7800 BIOS screen on Tang 9K hardware with the V3 BSRAM core.

Timebox:

1. One focused implementation cycle (no feature expansion beyond M0).

Task S0-1: Bus direction and drive ownership hardening

1. Reconcile V3 `buf_dir`, `buf_oe`, and `d` tri-state behavior with proven V2 behavior.
2. Ensure the cartridge only drives reads and never drives writes.
3. Add or tighten simulation assertions for read/write drive overlap.

S0-1 pass criteria:

1. No drive-overlap assertion failures in simulation.
2. Trace replay still passes with zero mismatches.

Task S0-2: Mapper write sampling timing alignment

1. Align bank-register write capture to stable write data timing relative to `phi2` and filtered bus signals.
2. Verify write-capture edge policy with V2 as reference behavior.

S0-2 pass criteria:

1. Bank register changes only on intended write windows.
2. No regressions in trace replay.

Task S0-3: Fixed-bank and switchable-bank address translation audit

1. Validate `mapper_supergame` address mapping and fixed-bank selection assumptions against AstroWing behavior.
2. Confirm read mapping for `$4000-$7FFF`, `$8000-$BFFF`, and `$C000-$FFFF` windows is coherent for current ROM layout.

S0-3 pass criteria:

1. Replay traces touching `CART_40XX_R` continue to pass.
2. No out-of-range or undefined ROM window behavior in simulation.

Task S0-4: POKEY decode/read-path parity check

1. Verify POKEY decode and read-gating behavior at active addresses used by AstroWing.
2. Ensure ROM/POKEY muxing does not disturb baseline BIOS fetch behavior.

S0-4 pass criteria:

1. Replay remains mismatch-free.
2. Hardware reaches BIOS screen and does not lock black-screen pre-boot.

Task S0-5: Hardware M0 validation loop

1. Build bitstream.
2. Program SRAM first.
3. Execute Stage B and Stage B1 checks from this contract.
4. Capture one M0 verification note with bitstream hash and observed outcome.

S0-5 pass criteria:

1. BIOS screen is reached on hardware.
2. Verification note is recorded.

Sprint 0 exit rule:

1. If M0 passes, proceed to Stage C gameplay implementation work.
2. If M0 fails, do not add features; iterate only on S0-1 through S0-4 until BIOS milestone passes.
