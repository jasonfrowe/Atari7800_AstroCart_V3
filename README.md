# Atari 7800 Multi-Cart Project (Tang Nano 9K)

## 1. Project Viability Assessment

**Status: VIABLE AND FEASIBLE.**

The Sipeed Tang Nano 9K FPGA board (Gowin GW1NR-9) is fully capable of driving an Atari 7800 Multi-cart system.

### Resource & Hardware Budget
- **Logic Cells**: 8,640 LUT4s / Flip-Flops available.
  - **Hazard5 RISC-V Core**: ~1,200 - 1,500 LUTs
  - **POKEY Audio Synthesizer**: ~800 - 1,000 LUTs
  - **Atari 7800 Bus Interface & Bankswitch Logic**: ~500 LUTs
  - **SPI SD-Card Controller**: ~300 LUTs
  - **PSRAM Controller & Cache**: ~800 - 1,000 LUTs
  - **Total Estimated Logic**: ~4,000 LUTs (~46% of FPGA capacity).
- **Block RAM**: 26 BSRAM blocks (58.5 KB).
  - Internal BRAM is sufficient to load 32KB/48KB cartridges (such as `astrowing.a78`, 48KB) directly without latency.
- **PSRAM**: 8 MB embedded PSRAM.
  - Provides storage for large multi-bank cartridges (128KB, 256KB, 512KB SuperGame, RAM expansion carts).
- **Timing Margin**: Atari 7800 CPU clock ($\text{PHI2}$) is ~1.79 MHz ($\approx 558\text{ ns}$ cycle, $\approx 280\text{ ns}$ high pulse). With Tang Nano 9K running at 27 MHz / 54 MHz / 108 MHz, the FPGA has 15 to 60 system clock cycles per bus transaction, guaranteeing reliable address decoding and data response within <100 ns.

---

## 2. Hardware Interface & Level Shifting ([PINS.md](PINS.md))

Per [PINS.md](PINS.md), the hardware interface uses SN74LVC level-translator ICs:
- **U3 (SN74LVC245)**: Bi-directional Data Bus (`D[7:0]`). Controlled dynamically by FPGA signals `U3_DIR` (pin 40) and `U3_OE` (pin 35).
- **U2 & U4 (SN74LVC245)**: Uni-directional Address Bus (`A[13:0]`). Hardwired Atari -> FPGA (`DIR=GND`, `~OE=GND`).
- **U5 (SN74LVC8T245)**: Dual-supply (1.8V <-> 5V) translator for Control signals (`PHI2`, `R_NW`, `HALT`, `A14`, `A15`, `UIP_0`, `UIP_1`).
- **Audio (Pin 76)**: Ext audio pin `T_EAUD` connected to 1.8V FPGA bank for POKEY PWM/Sigma-Delta output.

---

## 3. Co-Simulation Strategy Comparison & Recommended Choice

We evaluated two co-simulation approaches to validate the design before hardware deployment:

| Criteria | Option A: A7800 Emulator Integration | Option B: Standalone Verilator Bus Harness | Recommended Hybrid Approach |
| :--- | :--- | :--- | :--- |
| **Concept** | Connect A7800 6502/MARIA core callbacks directly to Verilated HDL model | Pure C++ testbench simulating 6502 bus cycles (`PHI2`, `R_NW`, `A[15:0]`) | **Start with Option B, transition to Option A** |
| **Setup Speed** | Moderate (extracting A7800 bus hooks) | **Extremely Fast** (Zero dependencies) | **Fastest path to working code** |
| **Execution Speed**| ~60 FPS full frame simulation | **Millions of cycles/sec** | High speed unit testing + full verification |
| **Use Case** | End-to-end game rendering & audio verification | Pin timing, state machines, POKEY regs, buffer direction | Combined pin-level & full system confidence |
| **Waveform Debug**| Full frame traces | Small, focused `.vcd`/`.fst` GTKWave traces | Ideal for debugging bus contention |

### **Recommendation: Phased Hybrid Approach**
1. **Phase 1 (Immediate)**: Implement **Option B (Standalone Verilator Harness)**. This allows us to rapidly verify 48K address decoding (`astrowing.a78`), level-shifter bus direction (`U3_DIR`, `U3_OE`), POKEY register writes, and Hazard5 memory loading within minutes.
2. **Phase 2 (Full System Validation)**: Integrate **Option A (A7800 Bus Bridge)** to execute the actual `astrowing.a78` ROM with full graphics and POKEY sound output.

---

## 4. System Architecture Diagram

```
+-----------------------------------------------------------------------------------+
|                                Tang Nano 9K FPGA                                  |
|                                                                                   |
|  +------------------------+      SPI Bus     +---------------------------------+  |
|  | MicroSD Card (FAT32)   | <--------------> | Hazard5 RISC-V Softcore         |  |
|  +------------------------+                  | (UI, Menu, A78 Header Parser)   |  |
|                                              +---------------------------------+  |
|                                                              |                    |
|                                                              v                    |
|  +------------------------+      Internal    +---------------------------------+  |
|  | 8MB PSRAM / BRAM       | <--------------> | Cartridge Engine & Mapper Logic |  |
|  | (Cart ROM / RAM buffer)|                  | (Flat 48K, SuperGame, Banking)  |  |
|  +------------------------+                  +---------------------------------+  |
|                                                              |                    |
|                                         +--------------------+-----------------+  |
|                                         |                                      |  |
|                                         v                                      v  |
|                         +-------------------------------+    +-----------------+  |
|                         | POKEY Sound Synthesizer Core  |    | Atari 7800 Bus  |  |
|                         | (Addresses $4000-$400F)       |    | Interface       |  |
|                         +-------------------------------+    +-----------------+  |
|                                         |                            |            |
+-----------------------------------------|----------------------------|------------+
                                          v                            v
                                    PWM Audio Out              Cartridge Port
                                  (Pin 76, T_EAUD)          (A[15:0], D[7:0], PHI2)
```

---

## 5. Feature Matrix & Cartridge Support Plan

| Feature / Scheme | Target Specification | Initial Implementation State |
| :--- | :--- | :--- |
| **Test Cartridge** | `astrowing.a78` (Astro Wing Starfighter) | 48KB Flat ROM ($4000-$FFFF) |
| **A78 Header Parser** | 128-Byte A78 Header Decoded in Firmware | Detects ROM size, POKEY flag, Mapper |
| **POKEY Support** | HDL Synthesizer at $4000-$400F | 4-Channel Audio, AUDC/AUDF/AUDCTL, PWM out |
| **Bankswitching** | SuperGame 128K / 256K / 512K + RAM | Bank register writes at $8000-$8003 |
| **Softcore CPU** | Hazard5 RISC-V (Luke Wren) | SD Card FAT32 loader & configuration CSRs |
| **Simulation** | Verilator C++ Harness & A7800 Bridge | Cycle-accurate simulation before hardware deployment |

---

## 6. Development Roadmap

### Phase 1: Verilator Bus Harness (Option B) & Pin Interface
- Establish Verilator test fixture in C++.
- Model buffer controls (`U3_DIR`, `U3_OE`) per [PINS.md](PINS.md).
- Load `carts/astrowing.a78` into simulation memory and simulate 6502 read cycles.

### Phase 2: Cartridge Engine & POKEY HDL Modules
- Implement `cart_top.v` handling Atari 7800 address decoding ($4000-$FFFF).
- Implement `pokey_synth.v` for 4-channel POKEY audio at $4000-$400F with PWM output.
- Validate via Verilator harness.

### Phase 3: Hazard5 Softcore & SD Card Firmware Integration
- Integrate Hazard5 RV32IMAC RISC-V core into FPGA top-level.
- Implement SPI SD Card controller in Verilog.
- Write firmware in C (`riscv64-elf-gcc`) to mount FAT32, parse `.a78` header, and stream cart binary into FPGA BRAM / PSRAM.

### Phase 4: A7800 Co-simulation (Option A) & Banking Support
- Hook A7800 emulator bus callbacks into Verilated HDL.
- Add SuperGame mapper (128K, 256K, 512K bank selection).
- Support optional 8K/16K Cartridge RAM at $4000.

### Phase 5: Gowin Synthesis & Hardware Validation
- Write Gowin Tcl synthesis script (`build.tcl`) utilizing `/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh`.
- Validate pin constraints in `atari.cst` matching [PINS.md](PINS.md).
- Generate `.fs` bitstream and program Tang Nano 9K board.
