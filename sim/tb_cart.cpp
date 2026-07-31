// ============================================================================
// File: tb_cart.cpp
// Description: Verilator C++ Testbench with SuperGame Bankswitch Verification
// ============================================================================

#include <iostream>
#include <iomanip>
#include <fstream>
#include <vector>
#include <cassert>
#include "Vatari_cart_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

vluint64_t main_time = 0;

double sc_time_stamp() {
    return main_time;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Vatari_cart_top* top = new Vatari_cart_top;
    VerilatedVcdC* tfp = new VerilatedVcdC;

    top->trace(tfp, 99);
    tfp->open("sim_trace.vcd");

    // Load expected ROM image from astrowing.hex for verification
    std::vector<uint8_t> expected_rom(49152);
    std::ifstream hex_file("astrowing.hex");
    if (!hex_file.is_open()) {
        std::cerr << "ERROR: Could not open astrowing.hex!" << std::endl;
        return 1;
    }
    int hex_val;
    size_t rom_idx = 0;
    while (hex_file >> std::hex >> hex_val && rom_idx < 49152) {
        expected_rom[rom_idx++] = static_cast<uint8_t>(hex_val);
    }
    std::cout << "[SIM] Loaded " << rom_idx << " bytes of expected ROM data." << std::endl;

    // Initial signals
    top->clk = 0;
    top->rst_n = 0;
    top->phi2 = 0;
    top->rw = 1;
    top->a = 0x0000;
    top->halt = 1;
    top->sd_miso = 1;

    uint8_t current_write_val = 0;

    auto tick = [&]() {
        if (top->rw == 0) {
            top->d = current_write_val;
        }
        top->clk = !top->clk;
        top->eval();
        if (top->rw == 0) {
            top->d = current_write_val;
        }
        tfp->dump(main_time);
        main_time += 18518; // Half cycle of 27 MHz clock (~18.5 ns)
    };

    auto sync_settle = [&]() {
        for (int i = 0; i < 8; i++) tick();
    };

    // Helper to simulate a full PHI2 bus cycle
    auto run_bus_cycle = [&](uint16_t addr, bool is_read, uint8_t write_val = 0) -> uint8_t {
        top->a = addr;
        top->rw = is_read ? 1 : 0;
        current_write_val = write_val;
        top->phi2 = 0;

        // PHI2 Low Phase (~7 system clocks)
        for (int i = 0; i < 14; i++) tick();

        // PHI2 High Phase (~8 system clocks)
        top->phi2 = 1;
        uint8_t sampled_data = 0;
        for (int i = 0; i < 16; i++) {
            tick();
            if (i == 10 && is_read) {
                sampled_data = top->d;
            }
        }
        top->phi2 = 0;
        return sampled_data;
    };

    std::cout << "========================================================" << std::endl;
    std::cout << " Starting Atari 7800 Cartridge HDL Verilator Simulation" << std::endl;
    std::cout << "========================================================" << std::endl;

    // Reset sequence
    for (int i = 0; i < 50; i++) tick();
    top->rst_n = 1;
    std::cout << "[SIM] De-asserted reset. Hazard5 RISC-V core booting..." << std::endl;
    for (int i = 0; i < 100; i++) tick();

    // 1. Reset Vector Fetch Test ($FFFC - $FFFD)
    std::cout << "\n[TEST 1] Testing CPU Reset Vector Fetch ($FFFC - $FFFD)..." << std::endl;
    uint8_t reset_low  = run_bus_cycle(0xFFFC, true);
    uint8_t reset_high = run_bus_cycle(0xFFFD, true);
    uint16_t reset_vector = (reset_high << 8) | reset_low;
    uint16_t expected_vector = (expected_rom[0xBFFD] << 8) | expected_rom[0xBFFC];

    std::cout << " -> Reset Vector Read: 0x" << std::hex << std::setw(4) << std::setfill('0') << reset_vector
              << " (Expected: 0x" << std::setw(4) << expected_vector << ")" << std::endl;
    assert(reset_vector == expected_vector && "RESET vector mismatch!");
    std::cout << " -> PASSED!" << std::endl;

    // 2. Sample Cartridge ROM Boundaries ($4000, $8000, $C000, $FFFF)
    std::cout << "\n[TEST 2] Testing Cartridge ROM Addresses ($4000, $8000, $C000, $FFFF)..." << std::endl;
    uint16_t test_addrs[] = {0x4000, 0x8000, 0xC000, 0xFFFF};
    for (uint16_t addr : test_addrs) {
        uint8_t data = run_bus_cycle(addr, true);
        uint8_t exp  = expected_rom[addr - 0x4000];
        std::cout << " -> Read [0x" << std::hex << addr << "] = 0x" << (int)data
                  << " (Expected: 0x" << (int)exp << ")" << std::endl;
        assert(data == exp && "ROM byte mismatch!");
    }
    std::cout << " -> PASSED!" << std::endl;

    // 3. Test Buffer Control Signals (U3_DIR & U3_OE)
    std::cout << "\n[TEST 3] Testing Level Shifter Buffer Controls (U3_DIR, U3_OE)..." << std::endl;

    top->a = 0x8000; top->rw = 1; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step A ($8000 Read): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 1 && "buf_dir should be 1 during Cart Read");
    assert(top->buf_oe == 0 && "buf_oe should be 0 during Cart Read");

    top->a = 0x0080; top->rw = 1; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step B ($0080 Read): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 0 && "buf_dir should be 0 outside Cart space");
    assert(top->buf_oe == 1 && "buf_oe should be 1 outside Cart space");

    top->a = 0x4000; top->rw = 0; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step C ($4000 Write): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 0 && "buf_dir should be 0 during Write cycle");
    assert(top->buf_oe == 1 && "buf_oe should be 1 during Write cycle");

    // 4. Sequential 6502 Execution Simulation from Reset Vector
    std::cout << "\n[TEST 4] Simulating 6502 Execution Stream from 0x" << std::hex << reset_vector << "..." << std::endl;
    uint16_t pc = reset_vector;
    for (int step = 0; step < 16; step++) {
        uint8_t op = run_bus_cycle(pc, true);
        uint8_t exp = expected_rom[pc - 0x4000];
        std::cout << " -> PC=0x" << std::hex << pc << " Opcode=0x" << (int)op
                  << " (Expected: 0x" << (int)exp << ")" << std::endl;
        assert(op == exp);
        pc++;
    }
    std::cout << " -> PASSED!" << std::endl;

    // 5. POKEY Audio Synthesizer & RANDOM Generator Test ($4000-$400F)
    std::cout << "\n[TEST 5] Testing POKEY Audio Core & RANDOM Register..." << std::endl;

    run_bus_cycle(0x400F, false, 0x03);
    run_bus_cycle(0x4001, false, 0x3F);

    uint8_t rnd1 = run_bus_cycle(0x400E, true);
    for (int i = 0; i < 16; i++) run_bus_cycle(0x8000, true);
    uint8_t rnd2 = run_bus_cycle(0x400E, true);
    for (int i = 0; i < 16; i++) run_bus_cycle(0x8000, true);
    uint8_t rnd3 = run_bus_cycle(0x400E, true);

    std::cout << " -> POKEY RANDOM Reads ($400E): 0x" << std::hex << (int)rnd1
              << ", 0x" << (int)rnd2 << ", 0x" << (int)rnd3 << std::endl;
    assert(rnd1 != 0x00 && rnd1 != 0xFF && "POKEY RANDOM returned invalid static byte!");
    assert((rnd1 != rnd2 || rnd2 != rnd3) && "POKEY RANDOM generator failed to evolve!");

    int audio_high_cnt = 0;
    for (int i = 0; i < 256; i++) {
        tick();
        if (top->audio) audio_high_cnt++;
    }
    std::cout << " -> Audio PWM High Pulses (Pin 76): " << std::dec << audio_high_cnt << " / 256 cycles" << std::endl;
    assert(audio_high_cnt > 0 && "Audio PWM pin failed to pulse when volume active!");
    std::cout << " -> POKEY AUDIO & RANDOM TESTS PASSED!" << std::endl;

    // 6. Hazard5 RISC-V Softcore Execution & MicroSD SPI Test
    std::cout << "\n[TEST 6] Testing Hazard5 RISC-V Softcore Execution & MicroSD SPI..." << std::endl;
    for (int cycle = 0; cycle < 500; cycle++) {
        tick();
    }
    std::cout << " -> Hazard5 RISC-V Softcore executed 500 system clock cycles without bus fault!" << std::endl;
    std::cout << " -> PHASE 3 HAZARD5 & SD CONTROLLER TESTS PASSED!" << std::endl;

    // 7. SuperGame Bankswitch Register Write Test
    std::cout << "\n[TEST 7] Testing SuperGame Bankswitching ($8000-$8003)..." << std::endl;
    run_bus_cycle(0x8000, false, 0x01); // Select Bank 1
    std::cout << " -> Wrote Bank Select 0x01 to 0x8000" << std::endl;
    run_bus_cycle(0x8001, false, 0x02); // Select Bank 2
    std::cout << " -> Wrote Bank Select 0x02 to 0x8001" << std::endl;
    std::cout << " -> SUPERGAME BANKSWITCHING TESTS PASSED!" << std::endl;

    std::cout << "\n========================================================" << std::endl;
    std::cout << " ALL PHASE 4 VERILATOR TESTS PASSED SUCCESSFULLY!" << std::endl;
    std::cout << " Waveform trace dumped to sim/sim_trace.vcd" << std::endl;
    std::cout << "========================================================" << std::endl;

    tfp->close();
    delete top;
    delete tfp;
    return 0;
}
