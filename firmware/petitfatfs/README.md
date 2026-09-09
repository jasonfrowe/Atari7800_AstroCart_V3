# Petit FatFs Integration

This folder contains the FemtoRV + Petit FatFs firmware path.

## Vendored Upstream Files

1. pff.c
2. pff.h
3. pffconf.h
4. diskio.h
5. LICENSE-elm-chan.txt

Source provenance is mirrored in third_party/petitfatfs/pff3a.

## Project Glue

1. diskio_glue.c implements `disk_initialize`/`disk_readp` as a thin wrapper
   around the hardware `rtl/sd_controller.v` block-read engine (MMIO at
   `0x5000_0000`: write an LBA + trigger byte, poll a busy bit, read the
   512-byte sector buffer). It does not bit-bang SPI commands in software --
   `sd_controller.v` runs the CMD0/CMD8/CMD55/ACMD41 init sequence and CMD17
   sector reads autonomously in hardware. (An earlier version of this file
   did software SPI directly against `rtl/spi_sd.v`; that path was replaced
   this project by a hardware controller ported from the AstroCart V2
   project, for reliability.)
2. femtorv_service_main.c (in firmware root) drives scan command flow and CSR telemetry.

## Contract Targets

1. Command input (latest write at 0x2200) drives scan request.
2. Status/debug output goes to 0x7FF0..0x7FF3.
3. Root and ROMS subfolder scan modes are supported via command bit 0.
