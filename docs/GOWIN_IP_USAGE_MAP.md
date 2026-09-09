# Gowin IP Usage Map (Tang 9K)

## Current Status (updated 2026-09-09)
**The sideband service plane described below as "Hazard5" is stale and no longer accurate.** `rtl/hazard5_soc.v` (and the `gowin_sp_be32`/`gowin_sdpb_mailbox` paths it uses) is still present in the repo and in the synthesis file list, but is **not instantiated anywhere in the current `rtl/atari_cart_top.v`** -- confirmed by grepping for `hazard5_soc` instantiation in the top-level and its variants and finding none. The actual, currently-active sideband service plane is `rtl/femtorv_service_soc.v`, a FemtoRV32 ("quark") RISC-V softcore running C firmware (`firmware/femtorv_service_main.c` + PetitFatFS) that does the FAT32 SD-card scan/load, gated by the `H5_SIDEBAND_EN` parameter (the name is a historical holdover from when Hazard5 filled this role; it now gates the FemtoRV path instead). SD-card SPI transport is `rtl/sd_controller.v` (ported from the AstroCart V2 project), not any Hazard5-driven SPI logic. The `hazard5/` core itself remains in the repo for potential future use but is currently dead code in the shipping bitstream.

## What Contributes Today
1. Firmware RAM path:
   - Source: `rtl/ram_block_2k.v` instances inside `rtl/atari_cart_top.v` (24 chunks form the shared 48KB "Cartridge Game RAM" array; 4 more chunks hold the FemtoRV firmware image, loaded into PSRAM at boot).
   - Note: `rtl/gowin_sp_be32.v` (2Kx32 single-port memory with byte write enables) exists but is only used inside `rtl/hazard5_soc.v`, which is not currently instantiated.

2. Top-level ROM/RAM path:
   - Source: rtl/rom_block_2k.v (used by some wrapper variants) and rtl/ram_block_2k.v (used by the current default top, since these blocks must be both INIT_FILE-loadable at synthesis time and runtime-writable for SD-card game loads).
   - Reason: generated pROM/SP cores as configured do not consume per-instance INIT_FILE for chunked ROM payloads and/or don't expose the needed write behavior.

3. Sideband service-plane path:
   - Source: `rtl/atari_cart_top.v` + `rtl/femtorv_service_soc.v` (NOT `rtl/hazard5_soc.v` -- see Current Status above).
   - Use: FemtoRV32 quark core runs firmware that scans the SD card's FAT32 filesystem, populates the menu's title-list window, and streams a selected `.a78` cartridge image into the shared cart-RAM array on request.
   - Constraint: no ROM read-mux or mapper datapath changes in this stage.

4. Mailbox/metadata RAM plumbing:
   - `rtl/gowin_sdpb_mailbox.v` exists but is **not currently instantiated** by `femtorv_service_soc.v` or `atari_cart_top.v`. Menu title/metadata exchange instead happens by having firmware write directly into the shared cart-RAM array (via the `CART_RAM_BASE` MMIO write port) at the address range the menu's `plotchars` calls read from ($E800-$E9FF) -- no separate mailbox RAM is in the current datapath.

## What Is Included But Not Yet Functionally Used
1. rtl/ip/gowin/gowin_prom/gowin_prom.v
2. rtl/ip/gowin/gowin_sp/gowin_sp.v
3. rtl/ip/gowin/gowin_sdpb/gowin_sdpb.v
4. rtl/hazard5_soc.v and the full rtl/hazard5/ core (superseded by rtl/femtorv_service_soc.v for the SD-loading role; kept in the file list/repo but not elaborated into the current default top-level build)
5. rtl/gowin_sdpb_mailbox.v (see item 4 above)

These are now in the synthesis file list so their presence is traceable in Gowin logs. They are not yet driving active datapaths in the frozen top-level behavior.

## How To Verify Usage In A Build
Run:

./build.sh --gowin-ip-report

This reports:
1. which memory/IP-related source files were analyzed,
2. module compile/use markers,
3. sweep warnings that indicate optimized-away blocks.

Elaboration probe mode:

./build.sh --gowin-h5-sideband

This uses a dedicated top wrapper that forces H5 sideband on for reproducible synthesis experiments.

Full matrix probe mode:

./build.sh --gowin-h5-matrix

This sweeps all 8 sideband combinations for:
1. FW RAM enable
2. Mailbox enable
3. SPI enable

Matrix results are written to:

impl/gwsynthesis/h5_sideband_matrix_report.txt

Report interpretation:
1. "Analyzing Verilog file" means source is present in the project.
2. "Compiling module" means module was elaborated into active logic for that top build.

## Planned Functional Adoption
1. gowin_sdpb:
   - Planned role: metadata mailbox RAM between Hazard5 service plane and menu-visible window.
2. gowin_prom:
   - Planned role: optional future replacement path for fixed ROM chunks after init-data strategy is solved.
3. gowin_sp:
   - Not used directly for firmware RAM unless a byte-write-capable configuration becomes available.

## Why This Staging Is Intentional
The frozen 9K baseline is sensitive to inference changes. We are introducing IP in auditable, reversible steps that preserve known-good behavior while reducing risky synthesis paths.
