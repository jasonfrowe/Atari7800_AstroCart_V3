// ============================================================================
// File: tb_cart.cpp
// Description: Verilator C++ Testbench for Atari 7800 Cartridge Interface
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
    top->rst_n = 1;
    top->phi2 = 0;
    top->rw = 1;
    top->a = 0x0000;
    top->halt = 1;

    auto tick = [&]() {
        top->clk = !top->clk;
        top->eval();
        tfp->dump(main_time);
        main_time += 18518; // Half cycle of 27 MHz clock (~18.5 ns)
    };

    auto sync_settle = [&]() {
        for (int i = 0; i < 8; i++) tick();
    };

    // Helper to simulate a full PHI2 bus cycle
    auto run_bus_cycle = [&](uint16_t addr, bool is_read) -> uint8_t {
        top->a = addr;
        top->rw = is_read ? 1 : 0;
        top->phi2 = 0;

        // PHI2 Low Phase (~7 system clocks)
        for (int i = 0; i < 14; i++) tick();

        // PHI2 High Phase (~8 system clocks)
        top->phi2 = 1;
        uint8_t sampled_data = 0;
        for (int i = 0; i < 16; i++) {
            tick();
            if (i == 10) { // Sample data near the end of PHI2 high pulse
                sampled_data = top->d;
            }
        }
        top->phi2 = 0;
        return sampled_data;
    };

    std::cout << "========================================================" << std::endl;
    std::cout << " Starting Atari 7800 Cartridge HDL Verilator Simulation" << std::endl;
    std::cout << "========================================================" << std::endl;

    // Reset initial phase
    for (int i = 0; i < 20; i++) tick();

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

    // Step A: Inside Cart space ($8000 Read): U3_DIR should be 1 (FPGA->Atari), U3_OE should be 0 (Active)
    top->a = 0x8000; top->rw = 1; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step A ($8000 Read): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 1 && "buf_dir should be 1 during Cart Read");
    assert(top->buf_oe == 0 && "buf_oe should be 0 during Cart Read");

    // Step B: Outside Cart space ($0080 TIA/RAM Read): U3_DIR should be 0 (Atari->FPGA), U3_OE should be 1 (Disabled)
    top->a = 0x0080; top->rw = 1; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step B ($0080 Read): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 0 && "buf_dir should be 0 outside Cart space");
    assert(top->buf_oe == 1 && "buf_oe should be 1 outside Cart space");

    // Step C: Write cycle to Cart space ($4000 Write): U3_DIR should be 0, U3_OE should be 1
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

    std::cout << "\n========================================================" << std::endl;
    std::cout << " ALL PHASE 1 VERILATOR TESTS PASSED SUCCESSFULLY!" << std::endl;
    std::cout << " Waveform trace dumped to sim/sim_trace.vcd" << std::endl;
    std::cout << "========================================================" << std::endl;

    tfp->close();
    delete top;
    delete tfp;
    return 0;
}
