# V1 Sprint 0 Checklist (M0 BIOS Milestone)

Objective:

1. Get Tang 9K V3 core to reach Atari 7800 BIOS screen on real hardware.

Scope guard:

1. No new feature work outside M0.
2. No PSRAM-path reintroduction; keep BSRAM architecture.

## Task Board

- [x] S0-1 Bus direction and tri-state hardening
- [x] S0-2 Mapper write sampling timing alignment
- [ ] S0-3 Address translation window audit
- [x] S0-4 POKEY decode/read-path parity check
- [ ] S0-5 Hardware M0 validation loop

Current status note:

1. S0-1 RTL patch applied in `rtl/atari_cart_top.v` (PHI2-windowed OE/data drive).
2. S0-2 RTL patch applied in `rtl/mapper_supergame.v` (settled PHI2-high mapper write sampling).
3. Required simulation gates now pass:
  - `./build.sh --sim`
  - `./build.sh --sim-menu`
  - `./build.sh --trace-boot sim/traces/a7800_boot_full.trace`
4. S0-4 implemented: firmware+RTL now select POKEY base per A78 metadata ($4000/$0450/$0800).
5. Next step is S0-5 hardware M0 validation loop.

## Required Gates Per Iteration

1. `./build.sh --sim`
2. `./build.sh --sim-menu`
3. `./build.sh --trace-boot sim/traces/a7800_boot_full.trace`

All three must pass before flashing hardware.

## Hardware Validation Steps (Each Candidate)

1. Build bitstream: `./build.sh --gowin`
2. Program SRAM: `./program.sh sram`
3. Power-cycle and observe startup
4. Record BIOS visibility result

## Evidence Log

### Candidate 1

- Date: 2026-07-31
- Commit:
- Bitstream: Atari7800_AstroCart_V3.fs generated and staged
- Simulation gates:
  - `--sim`: pass
  - `--sim-menu`: pass
  - `--trace-boot`: pass
- Hardware result:
  - Reaches BIOS screen: no
  - Black-screen lockup: no (yellow screen observed)
- Notes: Candidate validated through all simulation/replay gates after S0-1/S0-2 and simulation harness flow fixes; Gowin synthesis/PnR completed and bitstream staged. Hardware produced yellow screen (likely entered 2600 compatibility path, then faulted).
  A78 audit: Astro Wing header is valid v4 with rom_size=49152 and payload strip is correct; header advertises POKEY at $0450 (v3 bit6 / v4 audio mode2).
  S0-4 update: POKEY base is now selected dynamically from header metadata and decoded in RTL at one active window only ($4000/$0450/$0800).

### Candidate 2

- Date:
- Commit:
- Bitstream:
- Simulation gates:
  - `--sim`: pass/fail
  - `--sim-menu`: pass/fail
  - `--trace-boot`: pass/fail
- Hardware result:
  - Reaches BIOS screen: yes/no
  - Black-screen lockup: yes/no
- Notes:

### Candidate 3

- Date:
- Commit:
- Bitstream:
- Simulation gates:
  - `--sim`: pass/fail
  - `--sim-menu`: pass/fail
  - `--trace-boot`: pass/fail
- Hardware result:
  - Reaches BIOS screen: yes/no
  - Black-screen lockup: yes/no
- Notes:

## Exit Criteria

1. BIOS screen reached on hardware.
2. Matching evidence entry captured.
3. No simulation/replay regressions.

If exit criteria fail, continue Sprint 0 and do not start gameplay-feature work.
