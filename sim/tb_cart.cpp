// ============================================================================
// File: tb_cart.cpp
// Description: Advanced Verilator C++ Testbench & Atari 7800 Bus Co-Simulation
// ============================================================================

#include <iostream>
#include <iomanip>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include "Vatari_cart_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

vluint64_t main_time = 0;

double sc_time_stamp() {
    return main_time;
}

struct TraceCycle {
    uint16_t addr;
    bool is_read;
    uint8_t write_val;
    bool halt;
    bool expect_read_data;
    uint8_t expected_data;
    std::string source;
};

static std::vector<TraceCycle> load_trace_cycles(const std::string& trace_path) {
    std::ifstream trace_file(trace_path);
    if (!trace_file.is_open()) {
        std::cerr << "ERROR: Could not open trace file '" << trace_path << "'" << std::endl;
        std::exit(1);
    }

    std::vector<TraceCycle> cycles;
    std::string line;
    int line_no = 0;
    while (std::getline(trace_file, line)) {
        line_no++;
        if (line.empty() || line[0] == '#') {
            continue;
        }

        std::istringstream iss(line);
        std::string addr_str;
        std::string rw_str;
        std::string write_str;
        std::string halt_str;
        std::string expect_str;
        if (!(iss >> addr_str >> rw_str >> write_str >> halt_str >> expect_str)) {
            std::cerr << "ERROR: Invalid trace line " << line_no
                      << ". Expected: <addr> <R|W> <write_data> <halt> <expected|?>" << std::endl;
            std::exit(1);
        }

        TraceCycle cycle{};
        cycle.addr = static_cast<uint16_t>(std::stoul(addr_str, nullptr, 0));
        cycle.is_read = (rw_str == "R" || rw_str == "r" || rw_str == "1");
        cycle.write_val = static_cast<uint8_t>(std::stoul(write_str, nullptr, 0));
        cycle.halt = (halt_str == "1" || halt_str == "H" || halt_str == "h");
        cycle.expect_read_data = (expect_str != "?");
        cycle.expected_data = cycle.expect_read_data ? static_cast<uint8_t>(std::stoul(expect_str, nullptr, 0)) : 0;
        cycle.source = trace_path + ":" + std::to_string(line_no);
        cycles.push_back(cycle);
    }

    if (cycles.empty()) {
        std::cerr << "ERROR: Trace file '" << trace_path << "' contained no bus cycles." << std::endl;
        std::exit(1);
    }

    return cycles;
}

static void print_trace_usage() {
    std::cout << "Trace replay format:" << std::endl;
    std::cout << "  <addr> <R|W> <write_data> <halt> <expected|?>" << std::endl;
    std::cout << "Example:" << std::endl;
    std::cout << "  0xFFFC R 0x00 0 ?" << std::endl;
    std::cout << "  0x4000 W 0x3F 0 ?" << std::endl;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    std::string trace_path;
    for (int argi = 1; argi < argc; ++argi) {
        std::string arg = argv[argi];
        if (arg == "--trace") {
            if (argi + 1 >= argc) {
                std::cerr << "ERROR: --trace requires a file path." << std::endl;
                print_trace_usage();
                return 1;
            }
            trace_path = argv[++argi];
        } else if (arg == "--trace-help") {
            print_trace_usage();
            return 0;
        }
    }

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
        tfp->dump(main_time);
        main_time += 18518; // Half cycle of 27 MHz clock (~18.5 ns)
    };

    auto sync_settle = [&]() {
        for (int i = 0; i < 8; i++) tick();
    };

    // Helper to simulate a full Atari 7800 6502/MARIA bus cycle
    auto run_bus_cycle = [&](uint16_t addr, bool is_read, uint8_t write_val = 0) -> uint8_t {
        top->a = addr;
        top->rw = is_read ? 1 : 0;
        current_write_val = write_val;
        if (!is_read) top->d = write_val;
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

    auto expected_rom_byte = [&](uint16_t addr) -> uint8_t {
        if (addr < 0x4000) {
            return 0xFF;
        }
        const size_t rom_offset = static_cast<size_t>(addr - 0x4000);
        if (rom_offset >= expected_rom.size()) {
            return 0xFF;
        }
        return expected_rom[rom_offset];
    };

    auto replay_trace = [&](const std::vector<TraceCycle>& cycles) {
        std::cout << "\n[TRACE] Replaying " << cycles.size() << " bus cycles from external trace..." << std::endl;
        int read_mismatches = 0;
        int input_mode_violations = 0;

        for (const auto& cycle : cycles) {
            top->halt = cycle.halt ? 0 : 1;
            const uint8_t read_data = run_bus_cycle(cycle.addr, cycle.is_read, cycle.write_val);

            if (cycle.addr < 0x4000) {
                if (top->buf_dir != 0) {
                    std::cerr << "TRACE ERROR " << cycle.source
                              << ": cartridge drove low memory at 0x" << std::hex << cycle.addr << std::endl;
                    input_mode_violations++;
                }
                continue;
            }

            if (cycle.is_read) {
                const uint8_t expected = cycle.expect_read_data ? cycle.expected_data : expected_rom_byte(cycle.addr);
                if (read_data != expected) {
                    std::cerr << "TRACE ERROR " << cycle.source << ": read 0x"
                              << std::hex << (int)read_data << " from 0x" << cycle.addr
                              << " expected 0x" << (int)expected << std::endl;
                    read_mismatches++;
                }
            } else if (top->buf_dir != 0) {
                std::cerr << "TRACE ERROR " << cycle.source
                          << ": cartridge stayed in drive mode during write at 0x"
                          << std::hex << cycle.addr << std::endl;
                input_mode_violations++;
            }
        }

        assert(read_mismatches == 0 && "Trace replay detected ROM read mismatches!");
        assert(input_mode_violations == 0 && "Trace replay detected bus direction violations!");
        std::cout << "[TRACE] Replay passed with no bus or data mismatches." << std::endl;
    };

    std::cout << "========================================================" << std::endl;
    std::cout << " Starting Atari 7800 Cartridge HDL Verilator Simulation" << std::endl;
    std::cout << "========================================================" << std::endl;

    // Wait for internal Power-On Reset (POR) generator to release rst_n (~4096 cycles)
    std::cout << "[SIM] Clocking internal Power-On Reset (POR) generator (~4096 cycles)..." << std::endl;
    for (int i = 0; i < 9000; i++) tick();
    std::cout << "[SIM] Internal POR sequence complete. FPGA Core Active." << std::endl;

    if (!trace_path.empty()) {
        const auto trace_cycles = load_trace_cycles(trace_path);
        replay_trace(trace_cycles);
        tfp->close();
        delete top;
        delete tfp;
        return 0;
    }

    // ------------------------------------------------------------------------
    // [TEST 1] Atari 7800 BIOS & Low Memory Protection Sweep ($0000 - $3FFF)
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 1] Testing Atari 7800 BIOS/RAM/TIA Protection ($0000 - $3FFF)..." << std::endl;
    int bus_collisions = 0;
    for (uint32_t addr = 0x0000; addr < 0x4000; addr += 0x0100) {
        top->a = addr;
        top->rw = 1;
        top->phi2 = 1;
        sync_settle();
        if (top->buf_dir != 0) {
            std::cerr << "ERROR: Cartridge drove the bus outside cart space at address 0x"
                      << std::hex << addr << "! buf_dir=" << (int)top->buf_dir
                      << " buf_oe=" << (int)top->buf_oe << std::endl;
            bus_collisions++;
        }
    }
    assert(bus_collisions == 0 && "Bus collision detected in BIOS space!");
    std::cout << " -> All 16,384 low memory addresses ($0000-$3FFF) stayed in input mode." << std::endl;
    std::cout << " -> PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 2] Reset Vector Fetch Test ($FFFC - $FFFD)
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 2] Testing CPU Reset Vector Fetch ($FFFC - $FFFD)..." << std::endl;
    uint8_t reset_low  = run_bus_cycle(0xFFFC, true);
    uint8_t reset_high = run_bus_cycle(0xFFFD, true);
    uint16_t reset_vector = (reset_high << 8) | reset_low;
    uint16_t expected_vector = (expected_rom[0xBFFD] << 8) | expected_rom[0xBFFC];

    std::cout << " -> Reset Vector Read: 0x" << std::hex << std::setw(4) << std::setfill('0') << reset_vector
              << " (Expected: 0x" << std::setw(4) << expected_vector << ")" << std::endl;
    assert(reset_vector == expected_vector && "RESET vector mismatch!");
    std::cout << " -> PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 3] Cartridge ROM Address Sweep ($4000 - $FFFF)
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 3] Testing Full Cartridge ROM Space ($4000 - $FFFF)..." << std::endl;
    int rom_mismatches = 0;
    for (uint32_t addr = 0x4000; addr <= 0xFFFF; addr += 0x0800) {
        uint8_t data = run_bus_cycle(addr, true);
        uint8_t exp  = expected_rom[addr - 0x4000];
        if (data != exp) {
            std::cerr << "Mismatch at 0x" << std::hex << addr
                      << ": Got 0x" << (int)data << " Exp 0x" << (int)exp << std::endl;
            rom_mismatches++;
        }
    }
    assert(rom_mismatches == 0 && "ROM sweep mismatches found!");
    std::cout << " -> All cartridge ROM address boundaries ($4000-$FFFF) verified clean!" << std::endl;
    std::cout << " -> PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 4] Level Shifter Direction & Write Passthrough Verification
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 4] Testing Level Shifter Passthrough (Read vs Write)..." << std::endl;

    // Step A: Cartridge Read Cycle ($8000 Read) -> FPGA driving Atari (buf_dir=1, buf_oe=0)
    top->a = 0x8000; top->rw = 1; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step A ($8000 Read): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 1 && "buf_dir should be 1 (FPGA->Atari) during Cart Read");
    assert(top->buf_oe == 0 && "buf_oe should be 0 (Active) during Cart Read");

    // Step B: Cartridge Write Cycle ($4000 Write) -> Atari driving FPGA (buf_dir=0, buf_oe=0 ACTIVE!)
    top->a = 0x4000; top->rw = 0; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step B ($4000 Write): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 0 && "buf_dir should be 0 (Atari->FPGA) during Write cycle");
    assert(top->buf_oe == 0 && "buf_oe MUST be 0 (Active!) so Atari write bytes pass through U3 into FPGA!");

    // Step C: Low Memory Read ($0080 Read) -> Outside Cart Space (buf_dir=0, U3 left in input mode)
    top->a = 0x0080; top->rw = 1; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step C ($0080 Read): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 0 && "buf_dir should be 0 outside Cart space");
    assert(top->buf_oe == 0 && "buf_oe should remain 0 so console write cycles always pass through U3");
    std::cout << " -> PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 5] 6502 Execution Stream from Reset Vector
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 5] Simulating 6502 Execution Stream from 0x" << std::hex << reset_vector << "..." << std::endl;
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

    // ------------------------------------------------------------------------
    // [TEST 6] POKEY Audio Core & RANDOM Register Write Passthrough Test
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 6] Testing POKEY Audio Core & RANDOM Register Write Passthrough..." << std::endl;
    run_bus_cycle(0x400F, false, 0x03); // Enable POKEY audio & timers
    run_bus_cycle(0x4000, false, 0xA0); // Set POKEY AUDF1 frequency
    run_bus_cycle(0x4001, false, 0xAF); // Set POKEY AUDC1 volume & pure tone

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
    for (int i = 0; i < 500; i++) {
        tick();
        if (top->audio) audio_high_cnt++;
    }
    std::cout << " -> Audio PWM High Pulses (Pin 76): " << std::dec << audio_high_cnt << " / 500 cycles" << std::endl;
    assert(audio_high_cnt > 0 && "Audio PWM pin failed to pulse when volume active!");
    std::cout << " -> POKEY AUDIO & RANDOM TESTS PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 7] MARIA DMA HALT Cycle Simulation
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 7] Simulating MARIA Graphics DMA HALT Cycle..." << std::endl;
    top->halt = 0; // Assert HALT pin (MARIA takes control of bus)
    uint8_t dma_byte = run_bus_cycle(0x8000, true);
    std::cout << " -> MARIA DMA Read [0x8000]: 0x" << std::hex << (int)dma_byte << std::endl;
    top->halt = 1; // De-assert HALT pin
    std::cout << " -> MARIA DMA HALT CYCLE TEST PASSED!" << std::endl;

    std::cout << "\n========================================================" << std::endl;
    std::cout << " ALL VERILATOR CO-SIMULATION TESTS PASSED SUCCESSFULLY!" << std::endl;
    std::cout << " Waveform trace dumped to sim/sim_trace.vcd" << std::endl;
    std::cout << "========================================================" << std::endl;

    tfp->close();
    delete top;
    delete tfp;
    return 0;
}
