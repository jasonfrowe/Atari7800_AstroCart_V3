# SD FAT Architecture Plan (Synthesis-Safe)

## Status: superseded by what shipped (updated 2026-09-09)
This is a historical planning document. What actually shipped differs in several
ways worth knowing before reading further:
- **Not Hazard5.** The SD service plane is `rtl/femtorv_service_soc.v`, a FemtoRV32
  ("quark") RISC-V softcore, not Hazard5 -- Hazard5 integration was tried and
  abandoned; `rtl/hazard5_soc.v` remains in the repo but is unused by the current
  top-level build. Firmware is `firmware/femtorv_service_main.c`, not
  `firmware/main.c` (which still exists but is a separate, non-SD-loading target).
- **No mailbox RAM, no extended CSR contract.** The elaborate `0x2201-0x2203`
  ARG/SEQ register proposal below was never built. The shipped design kept the
  original minimal contract: `$2200` trigger (bit 7 = load request, low bits =
  slot) and `$7FF0` status (bit 7 = done). Menu titles are written directly into
  the shared cart-RAM array at the address the menu's `plotchars` calls read from
  ($E800-$E9FF), not through a separate mailbox.
- **SD transport is `rtl/sd_controller.v`**, ported from the AstroCart V2 project
  (a proven hardware SPI block-read controller), not the software-bitbanged
  `rtl/spi_sd.v` this plan and the early firmware assumed.
- **The menu ROM and the loaded game share the same physical BRAM** (there wasn't
  room for a separate execution-source BSRAM alongside the 48KB game-RAM array),
  which the two-plane isolation described below does not account for -- see
  `menu/menu.bas`'s handoff comments for how this is actually handled (disable
  MARIA DMA, run the wait/handoff loop from scratch RAM instead of cart ROM).

The constraints and CSR contract below are preserved as a historical record of
the original design intent; treat them as background, not as a description of
the current system.

## Goal
Add FAT-formatted SD browsing and ROM metadata extraction without destabilizing the frozen hardware-good build.

Frozen baseline reference:
- Commit: 4a4b786
- Rule: preserve current 48KB fixed cart ROM topology and existing rom_block_2k inference behavior.

## Non-Negotiable Constraints
1. Do not alter the existing live 7800 cart read datapath timing while menu is running.
2. Do not reintroduce always-on Hazard5 integration into the top-level cart datapath until a synthesis-safe wrapper strategy is proven.
3. Keep PSRAM as storage/staging and BSRAM as execution source.
4. Use HALT-mediated handover for any runtime bulk copy/swap.
5. Keep all changes reversible and small; each stage must have an independent build gate.

## What Already Exists (Useful Baseline)
Firmware in firmware/main.c already has:
- SD SPI init sequence (CMD0, CMD8, ACMD41, CMD58, CMD16 for SDSC).
- Sector reads (CMD17).
- FAT32 BPB parsing.
- Root directory traversal.
- .a78 entry filtering and title extraction.
- Menu title slot writer into cart RAM.

This means the software-side parser is already far ahead of the hardware integration state.

## Recommended Architecture: Two-Plane Design

### Plane A: Stable Atari Cart Plane (unchanged for now)
- Existing cart ROM/menu response logic in rtl/atari_cart_top.v remains the execution path.
- Existing mapper/audio behavior remains untouched.
- No new fanout or gating on cart address/data/control signals in this stage.

### Plane B: SD Service Plane (isolated)
- Hazard5 + SPI SD + firmware act as a metadata service first.
- Service plane communicates through a narrow CSR/mailbox window only.
- No direct write into executable game window until explicit HALT/load stage.

## Control Interface Proposal (Minimal CSR Contract)
Use a narrow, versioned register contract. Keep backward compatibility with existing 0x2200 and 0x7FF0 behavior.

### 6502-visible registers (example mapping)
- 0x2200 CMD: command/ack byte (existing trigger semantics kept)
- 0x2201 ARG0: index or low argument
- 0x2202 ARG1: high argument
- 0x2203 SEQ: sequence number to deglitch host polling
- 0x7FF0 STATUS: busy/done/error flags + stage code
- 0x7FF1 ERR: detailed error code
- 0x7FF2 COUNT: number of discovered ROM entries
- 0x7FF3 CAPS: capability bits (FAT32 ready, load ready, etc.)

### Suggested status bits
- Bit 7: done
- Bit 6: error
- Bit 5: busy
- Bits 4..0: stage/substate

### Suggested command set
- 0x01: scan SD and build ROM catalog
- 0x02: read catalog page N into shared buffer
- 0x03: prepare selected ROM metadata
- 0x10: execute HALT-gated ROM copy to BSRAM (future stage)
- 0xA5: acknowledge completion (aligns with current handover idiom)

## Metadata-First Flow (Stage 1 Target)
1. Power-up: 6502 runs menu ROM exactly as today.
2. Menu issues CMD_SCAN.
3. Hazard5 initializes SD and parses FAT32 root (and optionally one games subfolder).
4. Firmware builds compact catalog entries:
   - short display title
   - ROM size
   - mapper/audio flags
   - start cluster
   - file size
5. Menu reads catalog page(s) via mailbox buffer and renders list.
6. No ROM execution swap yet; this stage proves SD/FAT end-to-end safely.

## Catalog Record Format (compact, fixed-size)
Use fixed records to keep 6502-side code simple.

Proposed 48-byte entry:
- bytes 0..31: title (null-terminated ASCII)
- bytes 32..35: start_cluster (LE32)
- bytes 36..39: file_size_bytes (LE32)
- bytes 40..41: mapper_flags (LE16)
- byte 42: audio_flags
- byte 43: header_version
- bytes 44..47: reserved (future checksum, region, etc.)

With 8 entries per page: 384 bytes payload, fits inside one 512-byte sector-style buffer.

## FAT Strategy Options

### Option A (recommended now): FAT32 only, short names only
- Parse BPB + FAT chain + 8.3 entries.
- Skip LFN for first milestone.
- Fastest route to robust bring-up with low complexity.

### Option B: FAT32 + LFN decode
- Better titles from directory names.
- More parser complexity and corner cases (checksum/order/deleted entries).

### Option C: Host-prebuilt index file on SD
- PC tool precomputes catalog.bin from SD card contents.
- Firmware reads one file directly, minimal FAT traversal.
- Very robust and tiny firmware path, but requires external prep step.

Practical recommendation:
- Ship Option A first.
- Add optional Option C as a fallback/debug mode.
- Add Option B only after load pipeline is stable.

## ROM Load Pipeline (Stage 2+)
After metadata stage is stable, add explicit load path:
1. Menu selects entry index.
2. 6502 writes CMD_PREPARE with index.
3. Hazard5 resolves cluster chain and validates header.
4. 6502 requests CMD_EXEC_LOAD.
5. FPGA asserts HALT.
6. Hazard5 copies file payload into BSRAM banking window by policy.
7. Hazard5 updates mapper config/status.
8. FPGA releases HALT.
9. 6502 executes handover stub and jumps via reset vector.

Key invariant: no partial visibility of in-flight ROM banks to the live CPU.

## Banking Policy Guidance
1. Keep immutable menu region separate from game banks whenever possible.
2. For SuperGame images, map file payload into bank slots explicitly instead of implicit linear assumptions.
3. Reject unsupported mapper/header combos with clear ERR codes rather than attempting best-effort execution.

## Error Model (for menu UX)
Define stable error classes:
- 0x01..0x0F: SD transport/init failures
- 0x10..0x1F: FAT/BPB invalid
- 0x20..0x2F: directory traversal issues
- 0x30..0x3F: unsupported A78/header/mapper
- 0x40..0x4F: load/copy/timeout failures

Menu behavior:
- Show a short message per class.
- Allow retry scan without full power cycle.

## Synthesis-Safe Integration Tactics
1. Keep Hazard5 block physically and logically isolated from the cart read mux.
2. Prefer narrow CDC-safe mailbox signals over wide shared RAM buses in early stages.
3. Avoid changes to rom_block_2k module interface or read process in Stage 1.
4. Gate each integration with build-only check: ./build.sh --gowin.
5. Add one change category per commit (CSR decode, then firmware hook, then menu UI read).

## Incremental Execution Plan

### Milestone M0: Documentation and protocol freeze
- Lock CSR command/status map.
- Lock catalog entry binary format.
- Add comments/constants in firmware and menu code to match.

### Milestone M1: Metadata scan only
- Wire command/status mailbox only.
- Run SD scan and publish catalog page 0.
- Menu displays titles from mailbox, no load/swap.
- Success criteria: stable synthesis + visible titles from SD.

### Milestone M2: Multi-page catalog
- Add pagination and entry count.
- Handle >8 ROM entries.
- Success criteria: deterministic scrolling/listing.

### Milestone M3: Safe load prototype
- Implement HALT-gated copy for one known mapper profile.
- Keep strict timeout/error handling.
- Success criteria: one selected ROM boots reproducibly.

### Milestone M4: Mapper expansion
- Add additional A78 mapper profiles incrementally.
- Reject unsupported profiles cleanly.

## Suggested Immediate Next Edits
1. Add a shared header for command/status constants used by menu and firmware.
2. Replace ad-hoc status literals in firmware/main.c with named enum constants.
3. Implement CMD_SCAN + catalog page export only.
4. Keep atari_cart_top.v read path untouched while proving command/status mailbox plumbing.

## Test Strategy (Build-First)
1. Build gate every change with ./build.sh --gowin.
2. Add simulation checks for mailbox protocol semantics before ROM swapping.
3. Preserve golden frozen bitstream as rollback reference.

## Open Decisions
1. Directory scope:
   - root only, or /ROMS + root fallback?
2. File system scope:
   - FAT32 only for v1, or FAT16 read-only too?
3. UI naming:
   - A78 title field first, filename fallback, optional LFN later?
4. Max catalog size:
   - fixed cap (for deterministic RAM budget) vs dynamic paging.

## Gowin IP Core Generator Plan (Tang 9K)
Yes, this can help on 9K. The biggest win is replacing inferred memories with explicit memory IP so synthesis does not remap them into LUT-heavy structures.

### Why these cores first
1. Block Memory ROM for cart/menu chunks can reduce fragile inference behavior in the current rom_block_2k fanout.
2. Block Memory SP or SDP for Hazard5 firmware RAM can stabilize mapping for fw_ram.
3. Small dual-port mailbox RAM can isolate menu/firmware metadata exchange with deterministic resource use.

### Core set to generate now
1. ROM 2K x 8 template:
   - Type: Block Memory ROM
   - Depth: 2048
   - Width: 8
   - Read mode: synchronous
   - Output register: enabled if available
   - Init file support: enabled (hex/mem)
2. Firmware RAM 2K x 32 template:
   - Type: Block Memory SP or SDP RAM
   - Depth: 2048
   - Width: 32
   - Byte write enable: enabled if available
   - Read-during-write mode: keep tool default unless mismatch is observed
3. Mailbox RAM template:
   - Type: Block Memory DP or SDP RAM
   - Depth: 128 or 256
   - Width: 8
   - Port A: Hazard5 write/read
   - Port B: menu-side read

### Repository placement contract
Place generated output under:
- rtl/ip/gowin/

Keep one folder per core so regenerated outputs do not overwrite each other unexpectedly.

### Integration order (safe)
1. Swap only rom_block_2k implementation to a wrapper around generated ROM IP.
2. Build check.
3. Swap only hazard5 fw_ram implementation to generated RAM IP.
4. Build check.
5. Add mailbox RAM IP only when starting M1 metadata command/status flow.

### What to commit
1. Commit generated Verilog wrapper/stub files and any required parameter/config files from IP Generator.
2. Do not commit temporary IDE project cache/output directories.

### What I need from you
Please run Gowin IP Core Generator and generate the three cores above for GW1NR-9C, then drop the generated source files into rtl/ip/gowin/.

After that, I will do the integration edits in this repo so the current behavior is preserved while memory inference pressure is reduced.

## Bottom Line
The shortest safe path is metadata-first SD/FAT integration through a narrow mailbox contract, while keeping the proven cart execution datapath frozen. Once scan/listing is stable and synthesis remains green, add HALT-gated ROM loading in tightly scoped steps.
