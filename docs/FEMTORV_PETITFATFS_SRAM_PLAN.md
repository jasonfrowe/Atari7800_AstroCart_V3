# FemtoRV + Petit FatFs + SRAM Plan

## Branch Intent

This branch tracks migration from the Hazard5 SD service plane toward a smaller
service core path using:

1. FemtoRV-class RV32I core for minimal LUT/FF footprint.
2. SRAM-backed firmware/data buffers for deterministic access.
3. Petit FatFs for read-only FAT directory/file access (.A78 discovery first).

## Why This Route

1. Keeps FAT complexity in firmware (easier to debug than large RTL FAT FSMs).
2. Targets Tang Nano 9K resource limits with a smaller core than full-featured soft CPUs.
3. Preserves existing 6502 command/status handover model already used by this project.

## Non-Goals (Phase 0)

1. No ROM payload swapping yet.
2. No write support to SD.
3. No LFN support.
4. No mapper expansion beyond header telemetry.

## Phase 0 Deliverable

A synthesizable test core that:

1. Accepts command byte writes at 0x2200.
2. Scans FAT root (and optional ROMS subfolder).
3. Reads first .A78 header.
4. Exposes status/debug bytes at 0x7FF0..0x7FF3.

## Existing Contract Reuse

Command byte at 0x2200:

1. Bit 7: valid scan command.
2. Bit 0: 0 = root scan, 1 = ROMS subfolder scan.

Readback window:

1. 0x7FF0: status byte.
2. 0x7FF1: A78 header version.
3. 0x7FF2: A78 mapper byte.
4. 0x7FF3: A78 audio byte.

## SRAM Budget (Initial)

Recommended service-memory partition:

1. 8 KB instruction SRAM for FemtoRV firmware.
2. 4 KB data SRAM for stack + state.
3. 1 KB sector window cache metadata.
4. 512 B active SD sector buffer.

Notes:

1. Keep only one active 512-byte sector buffer in Phase 0.
2. Pull additional sectors on-demand.

## Petit FatFs Integration Shape

Planned files under firmware/petitfatfs:

1. pff.c / pff.h (upstream library import, read-only use).
2. diskio_glue.c (project-specific SPI sector read bridge).
3. scan_a78.c (FAT directory scan + A78 header extraction).
4. service_main.c (command loop + CSR updates).

## RTL Integration Shape

1. Add a FemtoRV service wrapper module with:
   - SPI SD MMIO
   - CSR bridge for status/debug/command
   - local SRAM blocks
2. Keep cart datapath isolated from service core during Phase 0.
3. Use existing sideband-style pin routing strategy only.

## Build Milestones

1. M0: Add FemtoRV RTL + SRAM blocks, synth only.
2. M1: Boot service firmware from SRAM, status heartbeat.
3. M2: SD init + CMD17 sector read via disk I/O glue.
4. M3: FAT root scan and first .A78 header telemetry.
5. M4: ROMS subfolder option and robust error classes.

## Bring-Up Checks

1. Build target compiles/synthesizes on Tang 9K.
2. 0x7FF0 enters expected stage progression.
3. 0x7FF1..0x7FF3 change when valid A78 header found.
4. 0x2200 command toggles root vs ROMS behavior.

## Immediate Next Implementation Tasks

1. Import FemtoRV RTL into rtl/femtorv/.
2. Add dedicated top wrapper: atari_cart_femtorv_test_top.
3. Add Makefile target for FemtoRV firmware image generation.
4. Wire diskio sector-read shim to existing SPI register model.
5. Port current FAT scan flow from firmware/main.c into service_main.c.

## Current Branch Status (2026-09-07)

Completed:

1. FemtoRV core imported and wired in femtorv_service_soc.
2. Petit FatFs vendored under firmware/petitfatfs and built into a dedicated FemtoRV firmware target.
3. CMD17-based SD sector read path implemented in diskio glue.
4. 0x2200 command + 0x7FF0..0x7FF3 telemetry contract connected through FemtoRV MMIO.
5. Dedicated synthesis target works: ./build.sh --gowin-femtorv-test.
6. Clock-constraint warning cleanup: timing.sdc added and consumed by generated Gowin project.

Open:

1. Integrate menu selection index to resolved file path metadata for launch flow.
2. Add file key metadata per slot (for deterministic post-selection open/load).
3. Add stronger retry/error policy for mixed-valid directories.

## Full Plan: SD Card -> A78 Header -> Menu Population

### Phase A: Stabilize Service-Core Contract

Goal:

1. Freeze service command/status behavior so menu code can depend on it.

Tasks:

1. Keep 0x2200 command semantics fixed:
   - bit7 = start scan
   - bit0 = root/ROMS select
2. Keep 0x7FF0 stage/error values fixed and documented.
3. Keep 0x7FF1..0x7FF3 as last parsed header summary for quick diagnostics.
4. Add one read-only service version byte (optional) to detect protocol mismatches.

Exit criteria:

1. Three consecutive synthesis runs with identical stage map behavior.

### Phase B: Build a Menu Metadata Shared-Memory Window

Goal:

1. Make discovered title/metadata visible to the 6502 menu in cart address space.

Tasks:

1. Define fixed slot structure for 8 entries (phase-1 target):
   - title[32]
   - mapper
   - audio
   - flags/status
2. Reserve a deterministic read window in cartridge-visible memory for these slots.
3. Add a validity bitmap and entry count byte.
4. Add scan-in-progress and scan-done bits in status for menu polling.

Exit criteria:

1. Menu can read static test payload from this window with no SD dependency.

Implemented layout (current):

1. Window base: 0xE800-0xE9FF (read-only in current Phase B implementation).
2. Header bytes:
   - 0xE800: signature[0] = 'M'
   - 0xE801: signature[1] = 'D'
   - 0xE802: format_version = 0x01
   - 0xE803: scan_flags (bit0 busy, bit1 done, bit2 error)
   - 0xE804: entry_count
   - 0xE805: valid_bitmap (bit N = slot N valid)
   - 0xE806: last_error
3. Slot table:
   - slot_base = 0xE820
   - slot_stride = 36 bytes
   - slot fields:
     - +0..+31: title[32]
     - +32: mapper
     - +33: audio
     - +34: slot_flags
     - +35: reserved
4. Static payload includes two valid demo slots for no-SD smoke testing.

### Phase C: Expand FAT Scan from First-Match to Multi-Entry Enumeration

Goal:

1. Enumerate multiple .A78 files and populate menu slots.

Tasks:

1. Use pf_opendir + pf_readdir loop to gather first N .A78 files.
2. For each file:
   - pf_open
   - pf_read first 128 bytes
   - validate magic/version/rom-size
3. Prefer header title when valid; fallback to 8.3 filename.
4. Write normalized title and parsed mapper/audio into shared window.
5. Stop cleanly at slot limit and set overflow flag when more files exist.

Exit criteria:

1. Slots 0..N-1 contain valid, deterministic entries across repeated scans.

Status:

1. Implemented on FemtoRV test path.
2. Metadata slots are now populated dynamically from FAT directory enumeration and A78 header parsing.
3. Entry count, validity bitmap, overflow flag, and last-error fields are updated by firmware after each scan.

### Phase D: Connect 7800basic Menu to Dynamic Slot Data

Goal:

1. Render scanned titles instead of fixed placeholders.

Tasks:

1. In menu program, poll status until scan-done or timeout.
2. Read entry count + slot strings from shared window.
3. Populate displayed list from slot buffer.
4. Show fallback message when scan fails or no files found.

Exit criteria:

1. Power-on menu displays SD-derived titles without manual edits.

Status:

1. Implemented on menu.bas path.
2. Menu now issues rescan command (0x2200 = 0x81), polls metadata flags, reads entry count, and renders slot titles from 0xE820+.
3. Empty/fail/timeout fallback strings are shown when no valid entries are available.

### Phase E: Selection-to-Launch Metadata Bridge

Goal:

1. Tie selected menu item to resolved file identity for downstream loader.

Tasks:

1. Add per-slot file key payload (short path token or directory index tuple).
2. On selection, write command/select index to service registers.
3. Service acknowledges selected entry and stages launcher metadata.
4. Preserve existing handover contract compatibility for future ROM streaming.

Exit criteria:

1. Selection handshake succeeds for every populated menu slot.

### Phase F: Reliability and Regression Gates

Goal:

1. Ensure stable behavior across cards and repeated resets.

Tasks:

1. Cold boot scans on at least two SD cards.
2. Repeat scan command 20+ times and compare slot output consistency.
3. Verify root vs ROMS mode switching via bit0 command.
4. Add regression checklist entries for:
   - no stuck busy state
   - valid entry count bounds
   - no malformed titles crossing slot boundaries

Exit criteria:

1. Deterministic slot output and no lockups in repeated command cycles.

## Implementation Order (Practical)

1. Shared-memory window definition and static read test.
2. Multi-entry FAT enumeration and header parse loop.
3. Menu consumption of dynamic slots.
4. Selection metadata bridge.
5. Reliability pass.

## Risk Assessment for This Direction

Likelihood of success:

1. High for header-scan + menu-population milestone.

Primary risks:

1. SD-card variability (timing/token behavior).
2. Slot memory-map mismatches between service firmware and menu reader.
3. Long directory scans exceeding menu wait expectations.

Mitigations:

1. Keep strict stage/error telemetry and timeout handling.
2. Lock slot struct layout in one header and mirror in menu docs.
3. Use bounded slot count and progressive status updates.
