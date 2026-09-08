# Gowin IP Usage Map (Tang 9K)

## Current Status
This repository now uses a custom Gowin primitive wrapper for firmware RAM, includes generated Gowin IP files in synthesis inputs, and instantiates a sideband Hazard5 path for trigger/status/SD routing.

## What Contributes Today
1. Firmware RAM path:
   - Source: rtl/gowin_sp_be32.v
   - Use: 2K x 32 single-port memory with byte write enables using 4 x SP byte lanes.
   - Reason: generated gowin_sp core does not expose byte-write enables in current wizard settings.

2. Top-level ROM path:
   - Source: rtl/rom_block_2k.v
   - Use: inferred 2K x 8 ROM blocks loaded by INIT_FILE.
   - Reason: generated pROM core as configured does not consume per-instance INIT_FILE for chunked ROM payloads.

3. Sideband service-plane path:
   - Source: rtl/atari_cart_top.v + rtl/hazard5_soc.v
   - Use: Hazard5 instantiation routes trigger/status and SD pins only.
   - Constraint: no ROM read-mux or mapper datapath changes in this stage.

4. Mailbox RAM plumbing:
   - Source: rtl/gowin_sdpb_mailbox.v
   - Use: 256 x 8 mailbox region mapped in hazard5_soc (0xD000_0000..0xD000_00FF).
   - Note: intended for staged metadata exchange; functional usage depends on firmware access.

## What Is Included But Not Yet Functionally Used
1. rtl/ip/gowin/gowin_prom/gowin_prom.v
2. rtl/ip/gowin/gowin_sp/gowin_sp.v
3. rtl/ip/gowin/gowin_sdpb/gowin_sdpb.v

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
