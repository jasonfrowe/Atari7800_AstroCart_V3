# Atari 7800 Multi-Cart V3 (Tang Nano 9K FPGA)

A high-performance FPGA Multi-Cart for the Atari 7800 ProSystem featuring cycle-exact POKEY audio synthesis, a FemtoRV32 RISC-V softcore FAT32 SD loader, level-shifter bus control, and SuperGame bankswitching support.

---

## 🛠 Project Architecture & Co-Simulation Philosophy

```
 +-------------------------------------------------------------------------+
 |                         Atari 7800 Console                              |
 |   6502/Sally CPU (~1.79 MHz)  |  MARIA Graphics  |  TIA Sound / Bus     |
 +-------------------------------------------------------------------------+
                                    |  Cartridge Port (5V Signals)
       +----------------------------v----------------------------+
       |   SN74LVC Level Shifters (U2, U3, U4, U5) & Control     |
       |   U3_DIR (Pin 40)  |  U3_OE (Pin 35)                    |
       +----------------------------+----------------------------+
                                    |  3.3V FPGA Signals
 +----------------------------------v--------------------------------------+
 |                      Sipeed Tang Nano 9K FPGA                           |
 |                                                                         |
 |  +--------------------+  +------------------+  +---------------------+  |
 |  |  FemtoRV32 "quark"  |  |  sd_controller.v | | POKEY Audio Synth   |  |
 |  |  RISC-V softcore +  |->|  hardware SPI    | | Cycle-Exact Core    |  |
 |  |  PetitFatFS (FAT32) |  |  Pins 36,37,38,39|  +---------------------+  |
 |  +--------------------+  +------------------+                          |
 |            |                                              |             |
 |  +---------v----------+  +------------------+  +-----------v----------+  |
 |  | Shared Cart BRAM   |<--| SuperGame Mapper |->| 1-bit Audio PWM Out  |  |
 |  | 48K game RAM +     |  | 128K/256K/512K   |  | Pin 76 (T_EAUD)      |  |
 |  | 8K menu ROM, same  |  +------------------+  +----------------------+  |
 |  | physical BRAM      |                                                 |
 |  +--------------------+                                                 |
 +-------------------------------------------------------------------------+
```

**Note on the softcore:** an earlier design used a Hazard5 RISC-V core
(`rtl/hazard5_soc.v`, still present in the repo) for this role; it was
replaced by the smaller FemtoRV32 "quark" core (`rtl/femtorv_service_soc.v`)
running C firmware (`firmware/femtorv_service_main.c`) against a vendored
PetitFatFS. Hazard5 remains in the file list but is not instantiated by the
current default top-level build. The `H5_SIDEBAND_EN` parameter name in
`rtl/atari_cart_top.v` is a holdover from that era -- it now gates the
FemtoRV path.

**Note on cart RAM:** the menu ROM and the loaded game deliberately share the
same physical BRAM (there wasn't room for a separate execution-source BSRAM
alongside the 48KB game-RAM array) -- see "Handover Protocol Details" below
for why this matters and how the handoff is made safe.

---

## ⚡ Why Verilator Co-Simulation Protects Us from Repetitive Flashing

FPGA hardware debugging over USB/JTAG is slow and unobservable. When a bug occurs on real hardware, you get a black screen with no console output, requiring a 2-minute cycle of editing HDL, running place-and-route, flashing over USB, and power-cycling the console.

### How Verilator Solves This:
1. **Cycle-Exact Virtual Atari Bus**: In `sim/tb_cart.cpp`, Verilator compiles all Verilog modules (`atari_cart_top.v`, `pokey_synth.v`, `hazard5_soc.v`, `mapper_supergame.v`, `spi_sd.v`) into a high-speed C++ binary that simulates 6502 CPU cycles in milliseconds.
2. **100% Signal Visibility**: Every internal signal, bus handshake, state machine bit, and RISC-V register can be inspected or dumped into VCD waveform traces (`sim_trace.vcd`) viewable in GTKWave.
3. **Software & Firmware Co-Verification**: We compile actual RISC-V C code (`firmware/femtorv_service_main.c`, running on the FemtoRV32 "quark" core) with `riscv64-elf-gcc` and test that the softcore initializes the SD card via `rtl/sd_controller.v`, scans the FAT32 filesystem, reads `.a78` headers, and populates cartridge BRAM in simulation **before touching silicon**.
4. **Golden Rule**: We only program the real Tang Nano 9K when 100% of our simulation test suite passes!

---

## 🚀 Build & Test Workflow

### 1. Run Verilator Co-Simulation Test Suite
```bash
./build.sh --sim
```
*Builds the Verilator harness and runs the current cartridge-response checks: reset vector fetch, ROM reads, transceiver direction behavior, opcode stream reads, POKEY RANDOM/audio activity, and basic HALT-path visibility. This does not yet prove Hazard5-driven SD loading or full SuperGame bankswitch operation.*

### 1a. Run The Menu ROM Through The Same Harness
```bash
./build.sh --sim-menu
```
*Converts `menu/menu.bas.a78`, pads it to the current 48KB fixed-ROM window, and runs the same Verilator harness against the menu image instead of Astrowings.*

### 1b. Replay Emulator-Exported Bus Traces
```bash
make -C sim trace-convert CONVERT_INPUT=exported_bus.csv CONVERT_OUTPUT=traces/a7800_boot.trace
./build.sh --trace sim/traces/a7800_boot.trace
./build.sh --trace-boot sim/traces/a7800_boot.trace
```
*This is the intended path toward A7800 integration: capture real Sally/MARIA bus cycles from a pinned external A7800 checkout, convert them into replay format, and verify that the cartridge RTL responds correctly without flashing hardware.*

The recommended A7800 CSV schema is documented in `sim/A7800_EXPORT_SCHEMA.md`.
The recommended A7800 hook strategy is documented in `sim/A7800_INSTRUMENTATION_PLAN.md`.

### 1c. Replay Bus Traces Against The Menu ROM
```bash
./build.sh --trace-menu sim/traces/a7800_boot.trace
```
*Uses the same replay file, but swaps in the prototype menu ROM as the expected cartridge image.*

### 2. Synthesize Gowin FPGA Bitstream
```bash
./build.sh --gowin
```
*Synthesizes all HDL files via Gowin EDA (`gw_sh`), runs Place & Route, and generates `Atari7800_AstroCart_V3.fs`.*

### 3. Program Tang Nano 9K FPGA

Connect your Tang Nano 9K via USB-C to your Mac, then run:

- **SRAM Mode (Fast, Temporary for Testing)**:
  ```bash
  ./program.sh sram
  ```

- **Flash Mode (Permanent across power cycles)**:
  ```bash
  ./program.sh flash
  ```


## 🔎 SD Card Bring-Up Telemetry

The current firmware exposes staged status codes through `CART_CSR_STATUS` to make SD bring-up debuggable on real hardware.

Detailed integration plan (synthesis-safe):

`docs/SD_FAT_ARCHITECTURE_PLAN.md`

### Status/Stage Codes (`CART_CSR_STATUS`, current as of `femtorv_service_main.c`/`diskio_glue.c`)

The `0xF0-0xF4` codes previously documented here belonged to an earlier
software-SPI init sequence (`rtl/spi_sd.v`) that's since been replaced by the
hardware `rtl/sd_controller.v` block-read engine, which handles CMD0/CMD8/
CMD55/ACMD41 init autonomously. The current stage codes are:

- `0x11`: hardware SD controller signaled ready (`disk_initialize` success)
- `0x12`: sector read requested (`disk_readp`)
- `0x13`-`0x1C`: FAT mount/directory-scan progress (opendir, readdir loop,
  per-file header read, scan complete)
- `0x20`-`0x22`: game-load progress (`load_game()`: file open, header read,
  bulk copy loop)
- `0x60`: disk init failed during scan
- `0x62`: mount failed during scan
- `0x69`: SD read error during header/payload read
- `0x6A`: requested file could not be opened
- `0x80`: load complete, ready for handoff (bit 7 set -- this is what
  `menu.bas`'s handoff loop polls `$7FF0` for)

The LED blink-code diagnostic in `rtl/atari_cart_top.v` (`status_blink_code`)
maps the high nibble of a subset of these to a repeating blink count, useful
for reading status without a screen/serial connection.

### Why This Matters

1. Distinguishes transport/init failures from FAT or `.a78` parser issues.
2. Keeps simulation aligned with hardware by exercising the same command sequence through `sd_controller.v` in both `sim/tb_cart.cpp`'s `SimSDCard` model and real hardware.




## ✅ Current Milestone (Dynamic SD-Card Load, Confirmed On Real Hardware)

As of 2026-09-09 (commit `c6a5272`, branch `LinearCartSupport`), confirmed on
a real Tang Nano 9K -- not just in simulation:

1. The menu boots, scans the SD card's FAT32 filesystem via the
   FemtoRV32/PetitFatFS/`sd_controller.v` path, and displays discovered
   `.a78` game titles.
2. Pressing fire triggers a full 48KB SD-card load of `astrowing.a78` into
   cart RAM.
3. The loaded game boots and plays correctly, including POKEY audio.

This replaces an earlier, narrower "AstroWing parity" milestone that covered
emulator/trace-replay/hardware checks for a single statically-baked-in
cartridge image with no SD card involved at all. That path (see
`docs/V1_HARDWARE_CONTRACT.md`, now marked superseded) is no longer the
project's architecture.

Getting here required fixing a real, non-obvious bug: the menu ROM and any
loaded game share the same physical BRAM (see the architecture note above),
so a naive handoff loop that kept calling 7800basic's `restorescreen`/
`drawscreen` kernel routines while the SD load was in progress caused the
still-running menu's own code to be overwritten mid-execution once the copy
reached the last ~8KB of a 48K linear cart -- confirmed via a real-hardware
video recording showing on-screen corruption starting almost exactly when
the transfer would reach that region. The fix (see `menu/menu.bas`'s
`select_game` handoff logic) runs the entire wait-for-load loop from scratch
RAM with MARIA DMA disabled, so nothing touches cart ROM until the freshly
loaded game's own reset vector is jumped to.

## 📋 v1 Hardware Contract + Bring-Up Checklist

The v1 contract and checklist are maintained in:

`docs/V1_HARDWARE_CONTRACT.md`

This document defines:

1. Scope and non-scope for a Tang Nano 9K "v1 release".
2. Functional and electrical acceptance criteria.
3. Trace/simulation regression gates.
4. Staged bring-up steps and stop/go criteria.
5. Release evidence required before freezing a bitstream.

For immediate implementation execution, use:

`docs/V1_SPRINT0_CHECKLIST.md`

---

## 🎮 Menu System & B-SRAM ROM Switching

The Multi-Cart V3 features an integrated menu system compiled with 7800basic (`menu/menu.bas`) that enables seamless switching between ROMs stored in FPGA Block RAM (B-SRAM) and SD storage.

### How B-SRAM ROM Switching Works:

```
+-----------------------------------------------------------------------------------+
| 1. Atari 7800 6502 CPU                                                           |
|    - Displays 7800basic Menu application from initial B-SRAM ($4000-$FFFF)       |
|    - User selects game with Joystick (Up/Down) and presses Fire button            |
|    - Writes game selection to FPGA trigger register: $2200 = selected_game | 0x80 |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
| 2. Tang Nano 9K FPGA & FemtoRV32 "quark" Softcore                                 |
|    - Detects write to $2200 (Bit 7 = 1 signals ROM load request)                  |
|    - FemtoRV32 + PetitFatFS fetches requested .a78 from the SD card               |
|    - Streams ROM payload directly into the shared Cartridge B-SRAM                |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
| 3. Handover & Reset Execution (runs entirely from scratch RAM, NOT cart ROM --    |
|    see the shared-BRAM note above: the menu's own code lives in the same          |
|    memory being overwritten by the load, so nothing here can touch cart ROM)      |
|    - 6502 disables MARIA DMA (sta $3C, #0) so it stops rendering from the         |
|      memory being overwritten                                                     |
|    - 6502 copies the ENTIRE wait+handoff routine to scratch RAM at $2210+         |
|      (not zero page -- $80-$91 collides with 7800basic's own dlendsave            |
|      kernel array) and jumps there to run it:                                     |
|         lda $7FF0        ; poll FPGA status register                             |
|         cmp #$80          ; loop until exactly "ready"                            |
|         bne .wait_loaded                                                          |
|         lda #$A5 : sta $2200  ; acknowledge handover                              |
|         jmp ($FFFC)           ; jump to new game reset vector                     |
+-----------------------------------------------------------------------------------+
```

### Handover Protocol Details:
1. **Triggering Load**: The 7800 menu writes `selected_game + 128` to `$2200`. Bit 7 indicates an active load request.
2. **Shared BRAM constraint**: the menu ROM and the loaded game occupy the same physical BRAM chunks (Atari `$E000-$FFFF`), since both didn't fit at once. `load_game()` overwrites that entire range as its copy reaches the end of a 48K linear cart -- including the memory the menu is still executing from. So from the trigger write onward, nothing can execute out of cart ROM until the new game's reset vector is jumped to.
3. **Scratch-RAM wait+handoff routine**: the 6502 disables MARIA DMA, then copies the *entire* poll-and-handoff routine (not just the final jump) into scratch RAM at `$2210+` and runs it from there -- it has to keep running even after the menu's own compiled code gets overwritten by the tail of the transfer. It polls `$7FF0` for an exact `$80` ("ready"), then stores `#$A5` to `$2200` to acknowledge handover and executes `jmp ($FFFC)` to launch the newly loaded ROM. See `menu/menu.bas`'s `select_game` label for the current, working implementation and its in-line comments for the full story (including why an earlier zero-page-`$80` version of this stub caused a crash: it collided with 7800basic's own `dlendsave` kernel save-buffer array).

---

## 🛠 Prototype Hardware Bodge & KiCad PCB Revision TODO

### Active Prototype Bodge (V3 Board Modification):
- **Purpose**: Enables FPGA-driven CPU halting (`HALT` Pin 2 control) to allow instant, transparent PSRAM ➔ B-SRAM bank switching without CPU bus contention.
- **Modification Steps**:
  1. Lifted **Pin 3 (Drain)** of transistor **Q3 (`BSS138`)** off its PCB pad (disconnecting Q3 from Cartridge Pin 31 `IRQ`).
  2. Soldered a fine jumper wire from **Q3 Pin 3 (Drain)** to **Cartridge Pin 2 (`HALT`)** / **U5 Pin 19 (`B3`)**.
- **FPGA Control**: FPGA Pin 83 (`irq`) controls Q3 Gate:
  - `irq = 1'b1` ➔ Q3 turns ON ➔ pulls `HALT` (Pin 2) LOW (pauses 6502 CPU).
  - `irq = 1'b0` ➔ Q3 turns OFF ➔ `HALT` floats HIGH (+5V) via motherboard pull-up (resumes 6502 CPU).
  - Pin 83 constraint configured with `PULL_MODE=DOWN` in `atari.cst`.

### KiCad Next Revision TODO (V3.1 / V4 PCB):
- [ ] Connect **Q3 Drain** directly to **Cartridge Pin 2 (`HALT`)** in schematic and board layout.
- [ ] Replace spare level-shifter pin **`UIP_1`** on U5 (`SN74LVC8T245`) with **`IRQ` (Cartridge Pin 31)** to restore independent cartridge IRQ drive capability alongside `HALT` control.


