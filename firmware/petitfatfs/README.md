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

1. diskio_glue.c implements SD SPI disk_initialize + CMD17-backed disk_readp.
2. femtorv_service_main.c (in firmware root) drives scan command flow and CSR telemetry.

## Contract Targets

1. Command input (latest write at 0x2200) drives scan request.
2. Status/debug output goes to 0x7FF0..0x7FF3.
3. Root and ROMS subfolder scan modes are supported via command bit 0.
