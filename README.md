# Atari 7800 Multi-Cart V3 (Tang Nano 9K FPGA)

A high-performance FPGA Multi-Cart for the Atari 7800 ProSystem featuring cycle-exact POKEY audio synthesis, Hazard5 RISC-V softcore FAT32 SD loader, level-shifter bus control, and SuperGame bankswitching support.

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
 |  |  Hazard5 RISC-V    |  |  SPI SD Controller| | POKEY Audio Synth   |  |
 |  |  Softcore Core     |->|  Pins 36,37,38,39|  | Cycle-Exact Core    |  |
 |  +--------------------+  +------------------+  +---------------------+  |
 |            |                                              |             |
 |  +---------v----------+  +------------------+  +-----------v----------+  |
 |  | Dual-Port Cart BRAM|<--| SuperGame Mapper |->| 1-bit Audio PWM Out  |  |
 |  | 48K/64K Memory     |  | 128K/256K/512K   |  | Pin 76 (T_EAUD)      |  |
 |  +--------------------+  +------------------+  +----------------------+  |
 +-------------------------------------------------------------------------+
```

---

## ⚡ Why Verilator Co-Simulation Protects Us from Repetitive Flashing

FPGA hardware debugging over USB/JTAG is slow and unobservable. When a bug occurs on real hardware, you get a black screen with no console output, requiring a 2-minute cycle of editing HDL, running place-and-route, flashing over USB, and power-cycling the console.

### How Verilator Solves This:
1. **Cycle-Exact Virtual Atari Bus**: In `sim/tb_cart.cpp`, Verilator compiles all Verilog modules (`atari_cart_top.v`, `pokey_synth.v`, `hazard5_soc.v`, `mapper_supergame.v`, `spi_sd.v`) into a high-speed C++ binary that simulates 6502 CPU cycles in milliseconds.
2. **100% Signal Visibility**: Every internal signal, bus handshake, state machine bit, and RISC-V register can be inspected or dumped into VCD waveform traces (`sim_trace.vcd`) viewable in GTKWave.
3. **Software & Firmware Co-Verification**: We compile actual RISC-V C code (`firmware/main.c`) with `riscv64-elf-gcc` and test that the softcore initializes SD SPI, reads `.a78` headers, and populates cartridge BRAM in simulation **before touch silicon**.
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
*This is the intended path toward A7800 integration: capture real Sally/MARIA bus cycles from an emulator, convert them into replay format, and verify that the cartridge RTL responds correctly without flashing hardware.*

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




## ✅ Current Milestone (AstroWing Parity)

AstroWing now has parity across emulator, simulation, and hardware checks:

1. The instrumented A7800 build runs AstroWing fully, including POKEY audio.
2. Emulator-exported bus traces replay in Verilator with boot assertions passing.
3. Real hardware testing reports AstroWing behavior matching expected gameplay.

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
| 2. Tang Nano 9K FPGA & Hazard5 Softcore                                          |
|    - Detects write to $2200 (Bit 7 = 1 signals ROM load request)                  |
|    - Hazard5 RISC-V softcore fetches requested ROM data from SD card / Flash      |
|    - Streams ROM payload directly into Dual-Port Cartridge B-SRAM                  |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
| 3. Handover & Reset Execution                                                     |
|    - 6502 CPU polls status register at $7FF0 until bit 7 signals load complete     |
|    - 6502 copies a 6-byte Zero-Page stub to ZP RAM ($80-$85):                    |
|         sta $2200  ; Acknowledge handover ($A5)                                  |
|         jmp ($FFFC) ; Jump to new game reset vector                              |
|    - 6502 jumps to $80, acknowledging handover and launching selected ROM         |
+-----------------------------------------------------------------------------------+
```

### Handover Protocol Details:
1. **Triggering Load**: The 7800 menu writes `selected_game + 128` to `$2200`. Bit 7 indicates an active load request.
2. **Status Polling**: While B-SRAM is populated, the 6502 loops polling status register `$7FF0` (`lda $7FF0` / `bpl .keep_waiting`).
3. **Zero-Page Handover Stub**: Once `$7FF0` returns negative (load complete), the 6502 copies a 6-byte stub into Zero-Page RAM `$80`, stores `#$A5` to `$2200` to acknowledge handover, and executes `jmp ($FFFC)` to launch the newly loaded ROM directly from B-SRAM.

