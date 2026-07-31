# V1 Sprint 0 Checklist (M0 BIOS Milestone)

Objective:

1. Get Tang 9K V3 core to reach Atari 7800 BIOS screen on real hardware.

Scope guard:

1. No new feature work outside M0.
2. No PSRAM-path reintroduction; keep BSRAM architecture.

## Task Board

- [ ] S0-1 Bus direction and tri-state hardening
- [ ] S0-2 Mapper write sampling timing alignment
- [ ] S0-3 Address translation window audit
- [ ] S0-4 POKEY decode/read-path parity check
- [ ] S0-5 Hardware M0 validation loop

Current status note:

1. S0-1 RTL patch applied in `rtl/atari_cart_top.v` (PHI2-windowed OE/data drive).
2. S0-2 RTL patch applied in `rtl/mapper_supergame.v` (settled PHI2-high mapper write sampling).
3. S0-1/S0-2 remain unchecked until required simulation gates pass.

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
