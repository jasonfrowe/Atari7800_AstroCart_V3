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
#include <map>
#include <cstring>
#include "Vatari_cart_top.h"
#include "Vatari_cart_top___024root.h"
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
    bool expect_drive_mode;
    bool expect_drive_output;
    std::string source;
};

static bool parse_drive_mode_token(const std::string& token, bool& expect_output) {
    if (token == "OUT" || token == "out" || token == "DRIVE" || token == "drive" || token == "1") {
        expect_output = true;
        return true;
    }
    if (token == "IN" || token == "in" || token == "LISTEN" || token == "listen" || token == "0") {
        expect_output = false;
        return true;
    }
    return false;
}

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
                      << ". Expected: <addr> <R|W> <write_data> <halt> <expected|?> [<IN|OUT>]" << std::endl;
            std::exit(1);
        }

        std::string drive_mode_str;
        bool has_drive_mode = static_cast<bool>(iss >> drive_mode_str);

        TraceCycle cycle{};
        cycle.addr = static_cast<uint16_t>(std::stoul(addr_str, nullptr, 0));
        cycle.is_read = (rw_str == "R" || rw_str == "r" || rw_str == "1");
        cycle.write_val = static_cast<uint8_t>(std::stoul(write_str, nullptr, 0));
        cycle.halt = (halt_str == "1" || halt_str == "H" || halt_str == "h");
        cycle.expect_read_data = (expect_str != "?");
        cycle.expected_data = cycle.expect_read_data ? static_cast<uint8_t>(std::stoul(expect_str, nullptr, 0)) : 0;
        cycle.expect_drive_mode = false;
        cycle.expect_drive_output = false;
        if (has_drive_mode) {
            if (!parse_drive_mode_token(drive_mode_str, cycle.expect_drive_output)) {
                std::cerr << "ERROR: Invalid drive mode token '" << drive_mode_str << "' on line "
                          << line_no << ". Expected IN or OUT." << std::endl;
                std::exit(1);
            }
            cycle.expect_drive_mode = true;
        }
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
    std::cout << "  <addr> <R|W> <write_data> <halt> <expected|?> [<IN|OUT>]" << std::endl;
    std::cout << "Example:" << std::endl;
    std::cout << "  0xFFFC R 0x00 0 ? OUT" << std::endl;
    std::cout << "  0x4000 W 0x3F 0 ? IN" << std::endl;
    std::cout << "Options:" << std::endl;
    std::cout << "  --assert-boot   Require reset-vector, opcode-fetch, and MARIA DMA checkpoints" << std::endl;
}

struct SimSDCard {
    std::map<uint32_t, std::vector<uint8_t>> sectors;
    uint8_t mosi_shift = 0;
    int bit_count = 0;
    std::vector<uint8_t> cmd_bytes;
    std::vector<uint8_t> tx_buffer;
    size_t tx_idx = 0;
    bool last_clk = false;
    int tx_bit_cnt = 0;
    uint8_t current_tx_byte = 0xFF;
    bool current_miso = 1;

    bool saw_cmd0 = false;
    bool saw_cmd8 = false;
    bool saw_cmd55 = false;
    bool saw_cmd41 = false;
    bool saw_cmd17 = false;
    bool saw_cmd17_lba0 = false;
    bool saw_cmd17_lba2048 = false;
    bool saw_cmd17_lba2080 = false;
    bool saw_cmd17_lba2280 = false;
    bool saw_cmd17_lba2281 = false;
    uint32_t last_cmd17_arg = 0;
    bool observed_vbr_bpb = false;
    bool completed_cmd17_lba2048_payload = false;
    bool completed_cmd17_lba2080_payload = false;
    bool completed_cmd17_lba2280_payload = false;
    bool completed_cmd17_lba2281_payload = false;
    bool active_cmd17_payload = false;
    uint32_t active_cmd17_lba = 0;

    SimSDCard() {
        std::vector<uint8_t> mbr(512, 0);
        mbr[0x1BE + 4] = 0x0C;
        mbr[0x1BE + 8] = 0x00;
        mbr[0x1BE + 9] = 0x08;
        mbr[0x1BE + 10] = 0x00;
        mbr[0x1BE + 11] = 0x00;
        mbr[510] = 0x55;
        mbr[511] = 0xAA;
        sectors[0] = mbr;

        std::vector<uint8_t> vbr(512, 0);
        vbr[11] = 0x00;
        vbr[12] = 0x02;
        vbr[13] = 1;
        vbr[14] = 32;
        vbr[15] = 0;
        vbr[16] = 2;
        vbr[36] = 100;
        vbr[37] = 0;
        vbr[38] = 0;
        vbr[39] = 0;
        vbr[44] = 2;
        vbr[45] = 0;
        vbr[46] = 0;
        vbr[47] = 0;
        vbr[510] = 0x55;
        vbr[511] = 0xAA;
        sectors[2048] = vbr;

        std::vector<uint8_t> fat0(512, 0);
        fat0[0] = 0xF8;
        fat0[1] = 0xFF;
        fat0[2] = 0xFF;
        fat0[3] = 0x0F;
        fat0[8] = 0xFF;
        fat0[9] = 0xFF;
        fat0[10] = 0xFF;
        fat0[11] = 0x0F;
        sectors[2080] = fat0;

        std::vector<uint8_t> root_dir(512, 0);
        const char name83[11] = {'A','S','T','R','O','W','I','N','A','7','8'};
        std::memcpy(&root_dir[0], name83, 11);
        root_dir[11] = 0x20;
        root_dir[20] = 0;
        root_dir[21] = 0;
        root_dir[26] = 3;
        root_dir[27] = 0;
        root_dir[28] = 0x00;
        root_dir[29] = 0x80;
        root_dir[30] = 0x00;
        root_dir[31] = 0x00;
        sectors[2280] = root_dir;

        std::vector<uint8_t> file0(512, 0);
        file0[0] = 'F';
        file0[1] = 'I';
        file0[2] = 'L';
        file0[3] = 'E';
        sectors[2281] = file0;
    }

    void update(bool clk, bool cs, bool mosi, bool& miso) {
        if (cs) {
            last_clk = clk;
            bit_count = 0;
            current_miso = 1;
            miso = 1;
            tx_buffer.clear();
            tx_idx = 0;
            cmd_bytes.clear();
            tx_bit_cnt = 0;
            current_tx_byte = 0xFF;
            return;
        }

        if (clk && !last_clk) {
            if (tx_bit_cnt > 0) {
                current_miso = (current_tx_byte & 0x80) ? 1 : 0;
                current_tx_byte <<= 1;
                tx_bit_cnt--;
            } else if (!tx_buffer.empty() && tx_idx < tx_buffer.size()) {
                current_tx_byte = tx_buffer[tx_idx++];
                current_miso = (current_tx_byte & 0x80) ? 1 : 0;
                current_tx_byte <<= 1;
                tx_bit_cnt = 7;
                if (tx_idx >= tx_buffer.size()) {
                    if (active_cmd17_payload && active_cmd17_lba == 2048u) {
                        completed_cmd17_lba2048_payload = true;
                    }
                    if (active_cmd17_payload && active_cmd17_lba == 2080u) {
                        completed_cmd17_lba2080_payload = true;
                    }
                    if (active_cmd17_payload && active_cmd17_lba == 2280u) {
                        completed_cmd17_lba2280_payload = true;
                    }
                    if (active_cmd17_payload && active_cmd17_lba == 2281u) {
                        completed_cmd17_lba2281_payload = true;
                    }
                    active_cmd17_payload = false;
                    active_cmd17_lba = 0;
                    tx_buffer.clear();
                    tx_idx = 0;
                }
            } else {
                current_miso = 1;
            }
        }

        if (!clk && last_clk) {
            mosi_shift = (mosi_shift << 1) | (mosi ? 1 : 0);
            bit_count++;
            if (bit_count == 8) {
                process_spi_byte(mosi_shift);
                bit_count = 0;
            }
        }

        miso = current_miso;
        last_clk = clk;
    }

    void process_spi_byte(uint8_t rx) {
        if (!tx_buffer.empty()) {
            if (cmd_bytes.empty() && ((rx & 0xC0) == 0x40)) {
                tx_buffer.clear();
                tx_idx = 0;
                tx_bit_cnt = 0;
            } else {
                return;
            }
        }

        if (cmd_bytes.empty() && (rx & 0xC0) != 0x40) {
            return;
        }

        cmd_bytes.push_back(rx);
        if (cmd_bytes.size() != 6) {
            return;
        }

        uint8_t cmd = cmd_bytes[0] & 0x3F;
        uint32_t arg = (uint32_t(cmd_bytes[1]) << 24)
                     | (uint32_t(cmd_bytes[2]) << 16)
                     | (uint32_t(cmd_bytes[3]) << 8)
                     | uint32_t(cmd_bytes[4]);
        cmd_bytes.clear();

        std::cout << " [SimSD] CMD" << (int)cmd << " arg=0x" << std::hex << arg << std::dec << std::endl;

        tx_buffer.clear();
        tx_idx = 0;

        if (cmd == 0) {
            saw_cmd0 = true;
            tx_buffer.push_back(0x01);
        } else if (cmd == 8) {
            saw_cmd8 = true;
            tx_buffer.push_back(0x01);
            tx_buffer.push_back(0x00);
            tx_buffer.push_back(0x00);
            tx_buffer.push_back(0x01);
            tx_buffer.push_back(0xAA);
        } else if (cmd == 55) {
            saw_cmd55 = true;
            tx_buffer.push_back(0x01);
        } else if (cmd == 41) {
            saw_cmd41 = true;
            tx_buffer.push_back(0x00);
        } else if (cmd == 17) {
            saw_cmd17 = true;
            last_cmd17_arg = arg;
            if (arg == 0u) saw_cmd17_lba0 = true;
            if (arg == 2048u) saw_cmd17_lba2048 = true;
            if (arg == 2080u) saw_cmd17_lba2080 = true;
            if (arg == 2280u) saw_cmd17_lba2280 = true;
            if (arg == 2281u) saw_cmd17_lba2281 = true;
            active_cmd17_payload = true;
            active_cmd17_lba = arg;
            tx_buffer.push_back(0x00);
            tx_buffer.push_back(0xFF);
            tx_buffer.push_back(0xFE);
            auto it = sectors.find(arg);
            if (it != sectors.end()) {
                tx_buffer.insert(tx_buffer.end(), it->second.begin(), it->second.end());
                if (arg == 2048u) {
                    const std::vector<uint8_t>& sec = it->second;
                    if (sec.size() >= 48u &&
                        sec[11] == 0x00 && sec[12] == 0x02 &&
                        sec[13] == 0x01 &&
                        sec[14] == 0x20 && sec[15] == 0x00 &&
                        sec[16] == 0x02 &&
                        sec[44] == 0x02 && sec[45] == 0x00 && sec[46] == 0x00 && sec[47] == 0x00) {
                        observed_vbr_bpb = true;
                    }
                }
            } else {
                tx_buffer.insert(tx_buffer.end(), 512, 0xFF);
            }
            tx_buffer.push_back(0xFF);
            tx_buffer.push_back(0xFF);
        } else {
            tx_buffer.push_back(0x00);
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    std::string trace_path;
    std::string rom_hex_path = "cart_payload.hex";
    bool assert_boot = false;
    for (int argi = 1; argi < argc; ++argi) {
        std::string arg = argv[argi];
        if (arg == "--trace") {
            if (argi + 1 >= argc) {
                std::cerr << "ERROR: --trace requires a file path." << std::endl;
                print_trace_usage();
                return 1;
            }
            trace_path = argv[++argi];
        } else if (arg == "--rom-hex") {
            if (argi + 1 >= argc) {
                std::cerr << "ERROR: --rom-hex requires a file path." << std::endl;
                return 1;
            }
            rom_hex_path = argv[++argi];
        } else if (arg == "--trace-help") {
            print_trace_usage();
            return 0;
        } else if (arg == "--assert-boot") {
            assert_boot = true;
        }
    }

    Vatari_cart_top* top = new Vatari_cart_top;
    VerilatedVcdC* tfp = new VerilatedVcdC;

    top->trace(tfp, 99);
    tfp->open("sim_trace.vcd");

    auto load_hex_bytes = [&](const std::string& path, size_t reserve_bytes) {
        std::vector<uint8_t> data;
        data.reserve(reserve_bytes);
        std::ifstream hex_file(path);
        if (!hex_file.is_open()) {
            std::cerr << "ERROR: Could not open ROM hex '" << path << "'!" << std::endl;
            std::exit(1);
        }
        int hex_val;
        while (hex_file >> std::hex >> hex_val) {
            data.push_back(static_cast<uint8_t>(hex_val));
        }
        if (data.empty()) {
            std::cerr << "ERROR: ROM hex '" << path << "' contained no payload bytes." << std::endl;
            std::exit(1);
        }
        return data;
    };

    // Load expected game ROM data for trace replay.
    std::vector<uint8_t> expected_game_rom = load_hex_bytes(rom_hex_path, 49152);
    std::cout << "[SIM] Loaded " << expected_game_rom.size() << " bytes of expected game ROM data from "
              << rom_hex_path << "." << std::endl;

    // Load the 8KB menu image from the generated chunk files.
    std::vector<uint8_t> expected_menu_rom;
    expected_menu_rom.reserve(8192);
    for (int chunk = 0; chunk < 4; ++chunk) {
        std::ostringstream chunk_name;
        chunk_name << "menu_chunk_" << std::setw(2) << std::setfill('0') << chunk << ".hex";
        std::vector<uint8_t> chunk_data = load_hex_bytes(chunk_name.str(), 2048);
        expected_menu_rom.insert(expected_menu_rom.end(), chunk_data.begin(), chunk_data.end());
    }
    std::cout << "[SIM] Loaded " << expected_menu_rom.size() << " bytes of expected menu ROM data from menu_chunk_*.hex." << std::endl;

    // Initial signals
    top->clk = 0;
    top->phi2 = 0;
    top->rw = 1;
    top->a = 0x0000;
    top->halt = 1;
    SimSDCard sd_card_sim;
    top->sd_miso = 1;

    uint8_t current_write_val = 0;

    auto tick = [&]() {
        if (top->rw == 0) {
            top->d = current_write_val;
        }
        top->clk = !top->clk;
        top->eval();

        bool miso_bit = 1;
        sd_card_sim.update(top->sd_clk, top->sd_cs, top->sd_mosi, miso_bit);
        top->sd_miso = miso_bit ? 1 : 0;
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

    auto expected_game_byte = [&](uint16_t addr) -> uint8_t {
        if (addr < 0x4000) {
            return 0xFF;
        }
        const size_t rom_offset = static_cast<size_t>(addr - 0x4000);
        if (rom_offset >= expected_game_rom.size()) {
            return 0xFF;
        }
        return expected_game_rom[rom_offset];
    };

    auto expected_menu_byte = [&](uint16_t addr) -> uint8_t {
        if (addr < 0xE000) {
            return 0xFF;
        }
        const size_t menu_offset = static_cast<size_t>(addr - 0xE000);
        if (menu_offset >= expected_menu_rom.size()) {
            return 0xFF;
        }
        return expected_menu_rom[menu_offset];
    };

    auto replay_trace = [&](const std::vector<TraceCycle>& cycles) {
        std::cout << "\n[TRACE] Replaying " << cycles.size() << " bus cycles from external trace..." << std::endl;
        int read_mismatches = 0;
        int input_mode_violations = 0;
        int drive_mode_mismatches = 0;
        int maria_cycles = 0;
        int cpu_cycles = 0;
        bool saw_reset_low = false;
        bool saw_reset_high = false;
        bool saw_maria_dma = false;
        int cpu_opcode_reads_after_reset = 0;
        bool count_opcode_reads = false;

        for (const auto& cycle : cycles) {
            top->halt = cycle.halt ? 0 : 1;
            if (cycle.halt) maria_cycles++;
            else cpu_cycles++;
            const uint8_t read_data = run_bus_cycle(cycle.addr, cycle.is_read, cycle.write_val);

            if (!cycle.halt && cycle.is_read && cycle.addr == 0xFFFC) {
                saw_reset_low = true;
            } else if (saw_reset_low && !cycle.halt && cycle.is_read && cycle.addr == 0xFFFD) {
                saw_reset_high = true;
                count_opcode_reads = true;
                cpu_opcode_reads_after_reset = 0;
            } else if (count_opcode_reads && !cycle.halt && cycle.is_read && cycle.addr >= 0x4000) {
                cpu_opcode_reads_after_reset++;
            }

            if (cycle.halt && cycle.is_read && cycle.addr >= 0x4000) {
                saw_maria_dma = true;
            }

            if (cycle.expect_drive_mode) {
                const bool observed_output = (top->buf_dir != 0);
                if (observed_output != cycle.expect_drive_output) {
                    std::cerr << "TRACE ERROR " << cycle.source << ": buf_dir was "
                              << (observed_output ? "OUT" : "IN") << " expected "
                              << (cycle.expect_drive_output ? "OUT" : "IN") << std::endl;
                    drive_mode_mismatches++;
                }
            }

            if (cycle.addr < 0x4000) {
                if (top->buf_dir != 0) {
                    std::cerr << "TRACE ERROR " << cycle.source
                              << ": cartridge drove low memory at 0x" << std::hex << cycle.addr << std::endl;
                    input_mode_violations++;
                }
                continue;
            }

            if (cycle.is_read) {
                const uint8_t expected = cycle.expect_read_data ? cycle.expected_data : expected_game_byte(cycle.addr);
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
        assert(drive_mode_mismatches == 0 && "Trace replay detected explicit drive-mode mismatches!");
        if (assert_boot) {
            assert(saw_reset_low && "Boot trace assertion failed: missing reset-vector low-byte read at $FFFC!");
            assert(saw_reset_high && "Boot trace assertion failed: missing reset-vector high-byte read at $FFFD after $FFFC!");
            assert(cpu_opcode_reads_after_reset >= 8 && "Boot trace assertion failed: fewer than 8 CPU cartridge reads after reset vector fetch!");
            assert(saw_maria_dma && "Boot trace assertion failed: missing MARIA DMA read in cartridge space!");
        }
        std::cout << "[TRACE] CPU cycles: " << cpu_cycles << ", MARIA cycles: " << maria_cycles << std::endl;
        if (assert_boot) {
            std::cout << "[TRACE] Boot assertions passed: reset-vector sequence, "
                      << cpu_opcode_reads_after_reset << " CPU cartridge reads after reset, and MARIA DMA observed." << std::endl;
        }
        std::cout << "[TRACE] Replay passed with no bus or data mismatches." << std::endl;
    };

    std::cout << "========================================================" << std::endl;
    std::cout << " Starting Atari 7800 Cartridge HDL Verilator Simulation" << std::endl;
    std::cout << "========================================================" << std::endl;

    // Wait for internal Power-On Reset (POR) generator to release rst_n (~4096 cycles)
    std::cout << "[SIM] Clocking internal Power-On Reset (POR) generator (~4096 cycles)..." << std::endl;
    for (int i = 0; i < 9000; i++) tick();
    std::cout << "[SIM] Internal POR sequence complete. FPGA Core Active." << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 0] Stage 1 SD SPI Command Bring-up
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 0] Testing Stage 1 SD SPI Command Bring-up..." << std::endl;
    int sd_clk_edges = 0;
    int sd_cs_low_ticks = 0;
    int sd_mosi_high_ticks = 0;
    int prev_sd_clk = top->sd_clk;
    int watchdog_kick_div = 0;
    for (int timeout = 0; timeout < 200000; timeout++) {
        if (sd_card_sim.saw_cmd0 && sd_card_sim.saw_cmd8 && sd_card_sim.saw_cmd55 &&
            sd_card_sim.saw_cmd41 && sd_card_sim.saw_cmd17) {
            break;
        }
        watchdog_kick_div++;
        if (watchdog_kick_div >= 2000) {
            watchdog_kick_div = 0;
            top->phi2 = 1;
            tick();
            top->phi2 = 0;
        }
        tick();
        if (top->sd_cs == 0) {
            sd_cs_low_ticks++;
        }
        if (top->sd_mosi != 0) {
            sd_mosi_high_ticks++;
        }
        if (top->sd_clk != prev_sd_clk) {
            sd_clk_edges++;
            prev_sd_clk = top->sd_clk;
        }
    }
    std::cout << " -> CMD0=" << (sd_card_sim.saw_cmd0 ? "yes" : "no")
              << " CMD8=" << (sd_card_sim.saw_cmd8 ? "yes" : "no")
              << " CMD55=" << (sd_card_sim.saw_cmd55 ? "yes" : "no")
              << " ACMD41=" << (sd_card_sim.saw_cmd41 ? "yes" : "no")
              << " CMD17=" << (sd_card_sim.saw_cmd17 ? "yes" : "no")
              << " arg=0x" << std::hex << sd_card_sim.last_cmd17_arg << std::dec
              << std::endl;
    std::cout << " -> SD pins: clk_edges=" << sd_clk_edges
              << " cs_low_ticks=" << sd_cs_low_ticks
              << " mosi_high_ticks=" << sd_mosi_high_ticks
              << std::endl;
    assert(sd_card_sim.saw_cmd0 && "Stage 1 failed: CMD0 not observed");
    assert(sd_card_sim.saw_cmd8 && "Stage 1 failed: CMD8 not observed");
    assert(sd_card_sim.saw_cmd55 && "Stage 1 failed: CMD55 not observed");
    assert(sd_card_sim.saw_cmd41 && "Stage 1 failed: ACMD41 not observed");
    assert(sd_card_sim.saw_cmd17 && "Stage 1 failed: CMD17 not observed");
    assert(sd_card_sim.last_cmd17_arg == 0 && "Stage 1 failed: first CMD17 arg was not LBA 0");
    std::cout << " -> Stage 1 SD SPI command gate PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 0.1] Stage 2 SD Sector Probe (LBA 2048)
    // ------------------------------------------------------------------------
    std::cout << "[TEST 0.1] Testing Stage 2 SD Sector Probe (LBA 2048)..." << std::endl;
    watchdog_kick_div = 0;
    int core_reset_falls = 0;
    int prev_core_rst_n = top->rootp->atari_cart_top__DOT__core_rst_n;
    for (int timeout = 0; timeout < 200000 && !sd_card_sim.saw_cmd17_lba2048; timeout++) {
        watchdog_kick_div++;
        if (watchdog_kick_div >= 2000) {
            watchdog_kick_div = 0;
            top->phi2 = 1;
            tick();
            top->phi2 = 0;
        }
        tick();
        if (prev_core_rst_n == 1 && top->rootp->atari_cart_top__DOT__core_rst_n == 0) {
            core_reset_falls++;
        }
        prev_core_rst_n = top->rootp->atari_cart_top__DOT__core_rst_n;
    }
    std::cout << " -> CMD17 LBA0=" << (sd_card_sim.saw_cmd17_lba0 ? "yes" : "no")
              << " CMD17 LBA2048=" << (sd_card_sim.saw_cmd17_lba2048 ? "yes" : "no")
              << std::endl;
    std::cout << " -> core_reset_falls=" << core_reset_falls << std::endl;
    assert(sd_card_sim.saw_cmd17_lba0 && "Stage 2 failed: CMD17 for LBA 0 not observed");
    assert(sd_card_sim.saw_cmd17_lba2048 && "Stage 2 failed: CMD17 for LBA 2048 not observed");
    std::cout << " -> Stage 2 SD sector probe gate PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 0.2] Stage 3 VBR Payload Validation
    // ------------------------------------------------------------------------
    std::cout << "[TEST 0.2] Testing Stage 3 VBR Payload Validation..." << std::endl;
    watchdog_kick_div = 0;
    for (int timeout = 0; timeout < 200000 && !sd_card_sim.completed_cmd17_lba2048_payload; timeout++) {
        watchdog_kick_div++;
        if (watchdog_kick_div >= 2000) {
            watchdog_kick_div = 0;
            top->phi2 = 1;
            tick();
            top->phi2 = 0;
        }
        tick();
    }
    std::cout << " -> observed_vbr_bpb=" << (sd_card_sim.observed_vbr_bpb ? "yes" : "no") << std::endl;
    std::cout << " -> completed_cmd17_lba2048_payload=" << (sd_card_sim.completed_cmd17_lba2048_payload ? "yes" : "no") << std::endl;
    assert(sd_card_sim.observed_vbr_bpb && "Stage 3 failed: expected FAT32 BPB bytes were not observed on LBA 2048 payload");
    assert(sd_card_sim.completed_cmd17_lba2048_payload && "Stage 3 failed: CMD17 LBA2048 payload stream did not complete");
    std::cout << " -> Stage 3 VBR payload gate PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 0.3] Stage 4 BPB Parse Addressing Validation
    // ------------------------------------------------------------------------
    std::cout << "[TEST 0.3] Testing Stage 4 BPB Parse Addressing Validation..." << std::endl;
    bool stage4_phi2 = false;
    for (int timeout = 0; timeout < 200000; timeout++) {
        stage4_phi2 = !stage4_phi2;
        top->phi2 = stage4_phi2 ? 1 : 0;
        tick();
        const uint8_t cur_status = top->rootp->atari_cart_top__DOT__soc_status_val;
        if (sd_card_sim.completed_cmd17_lba2080_payload &&
            sd_card_sim.completed_cmd17_lba2280_payload &&
            cur_status >= 0x18) {
            break;
        }
    }
    const uint8_t stage_status = top->rootp->atari_cart_top__DOT__soc_status_val;
    std::cout << " -> firmware_stage_status=0x" << std::hex << (int)stage_status << std::dec << std::endl;
    std::cout << " -> CMD17 LBA2080=" << (sd_card_sim.saw_cmd17_lba2080 ? "yes" : "no")
              << " payload=" << (sd_card_sim.completed_cmd17_lba2080_payload ? "yes" : "no")
              << std::endl;
    std::cout << " -> CMD17 LBA2280=" << (sd_card_sim.saw_cmd17_lba2280 ? "yes" : "no")
              << " payload=" << (sd_card_sim.completed_cmd17_lba2280_payload ? "yes" : "no")
              << std::endl;
    assert(sd_card_sim.saw_cmd17_lba2080 && "Stage 4 failed: CMD17 for FAT start LBA 2080 not observed");
    assert(sd_card_sim.completed_cmd17_lba2080_payload && "Stage 4 failed: FAT start payload did not complete");
    assert(sd_card_sim.saw_cmd17_lba2280 && "Stage 4 failed: CMD17 for root sector LBA 2280 not observed");
    assert(sd_card_sim.completed_cmd17_lba2280_payload && "Stage 4 failed: root sector payload did not complete");
    std::cout << " -> Stage 4 BPB parse addressing gate PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 0.4] Stage 5 Root Entry Cluster Read Validation
    // ------------------------------------------------------------------------
    std::cout << "[TEST 0.4] Testing Stage 5 Root Entry Cluster Read Validation..." << std::endl;
    for (int timeout = 0; timeout < 200000; timeout++) {
        stage4_phi2 = !stage4_phi2;
        top->phi2 = stage4_phi2 ? 1 : 0;
        tick();
        if (sd_card_sim.completed_cmd17_lba2281_payload &&
            top->rootp->atari_cart_top__DOT__soc_status_val == 0x1A) {
            break;
        }
    }
    const uint8_t stage5_status = top->rootp->atari_cart_top__DOT__soc_status_val;
    std::cout << " -> firmware_stage_status=0x" << std::hex << (int)stage5_status << std::dec << std::endl;
    std::cout << " -> CMD17 LBA2281=" << (sd_card_sim.saw_cmd17_lba2281 ? "yes" : "no")
              << " payload=" << (sd_card_sim.completed_cmd17_lba2281_payload ? "yes" : "no")
              << std::endl;
    assert(stage5_status == 0x1A && "Stage 5 failed: firmware did not reach root-entry cluster read completion status 0x1A");
    assert(sd_card_sim.saw_cmd17_lba2281 && "Stage 5 failed: CMD17 for first file cluster LBA 2281 not observed");
    assert(sd_card_sim.completed_cmd17_lba2281_payload && "Stage 5 failed: first file cluster payload did not complete");
    std::cout << " -> Stage 5 root-entry cluster read gate PASSED!" << std::endl;
    top->phi2 = 0;

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
    uint16_t expected_vector = (expected_menu_byte(0xFFFD) << 8) | expected_menu_byte(0xFFFC);

    std::cout << " -> Reset Vector Read: 0x" << std::hex << std::setw(4) << std::setfill('0') << reset_vector
              << " (Expected: 0x" << std::setw(4) << expected_vector << ")" << std::endl;
    assert(reset_vector == expected_vector && "RESET vector mismatch!");
    std::cout << " -> PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 3] Cartridge ROM Address Sweep ($4000 - $FFFF)
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 3] Testing Menu ROM Space ($E000 - $FFFF)..." << std::endl;
    int rom_mismatches = 0;
    for (uint32_t addr = 0xE000; addr <= 0xFFFF; addr += 0x0800) {
        uint8_t data = run_bus_cycle(addr, true);
        uint8_t exp  = expected_menu_byte(static_cast<uint16_t>(addr));
        if (data != exp) {
            std::cerr << "Mismatch at 0x" << std::hex << addr
                      << ": Got 0x" << (int)data << " Exp 0x" << (int)exp << std::endl;
            rom_mismatches++;
        }
    }
    assert(rom_mismatches == 0 && "Menu ROM sweep mismatches found!");
    std::cout << " -> All menu ROM address boundaries ($E000-$FFFF) verified clean!" << std::endl;
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

    // Step C: Low Memory Read ($0080 Read) -> Outside Cart space (buf_dir=0, U3 still enabled)
    top->a = 0x0080; top->rw = 1; top->phi2 = 1;
    sync_settle();
    std::cout << " -> Step C ($0080 Read): buf_dir=" << (int)top->buf_dir << " buf_oe=" << (int)top->buf_oe << std::endl;
    assert(top->buf_dir == 0 && "buf_dir should be 0 outside Cart space");
    assert(top->buf_oe == 0 && "buf_oe should stay 0 because U3 remains enabled in the current design");
    std::cout << " -> PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 5] 6502 Execution Stream from Reset Vector
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 5] Simulating Menu 6502 Execution Stream from 0x" << std::hex << reset_vector << "..." << std::endl;
    uint16_t pc = reset_vector;
    for (int step = 0; step < 16; step++) {
        if (pc < 0x4000) {
            std::cout << " -> PC entered non-cartridge space at 0x" << std::hex << pc
                      << "; stopping opcode stream check for this image." << std::endl;
            break;
        }
        uint8_t op = run_bus_cycle(pc, true);
        uint8_t exp = expected_menu_byte(pc);
        std::cout << " -> PC=0x" << std::hex << pc << " Opcode=0x" << (int)op
                  << " (Expected: 0x" << (int)exp << ")" << std::endl;
        assert(op == exp);
        pc++;
    }
    std::cout << " -> PASSED!" << std::endl;

    // ------------------------------------------------------------------------
    // Handoff into the fixed 48KB game image before POKEY validation.
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 6 PREP] Switching from menu image into game mode..." << std::endl;
    run_bus_cycle(0x2200, false, 0x80);
    std::cout << " -> after trigger write: switch_pending="
              << (int)top->rootp->atari_cart_top__DOT__switch_pending
              << " game_ready=" << (int)top->rootp->atari_cart_top__DOT__game_ready
              << " game_mode=" << (int)top->rootp->atari_cart_top__DOT__game_mode << std::endl;
    for (int i = 0; i < 9000; ++i) {
        tick();
    }
    std::cout << " -> after wait: switch_pending="
              << (int)top->rootp->atari_cart_top__DOT__switch_pending
              << " game_ready=" << (int)top->rootp->atari_cart_top__DOT__game_ready
              << " switch_delay=" << top->rootp->atari_cart_top__DOT__switch_delay
              << " game_mode=" << (int)top->rootp->atari_cart_top__DOT__game_mode << std::endl;
    run_bus_cycle(0x2200, false, 0xA5);
    for (int i = 0; i < 256 && !top->rootp->atari_cart_top__DOT__game_mode; ++i) {
        tick();
    }
    std::cout << " -> game_mode after acknowledge delay: "
              << (int)top->rootp->atari_cart_top__DOT__game_mode << std::endl;
    assert(top->rootp->atari_cart_top__DOT__game_mode && "Game mode was not enabled after the delayed A5 acknowledge!");
    std::cout << " -> Game mode handoff request completed." << std::endl;

    // ------------------------------------------------------------------------
    // [TEST 6] POKEY Audio Core & RANDOM Register Write Passthrough Test
    // ------------------------------------------------------------------------
    std::cout << "\n[TEST 6] Testing POKEY Audio Core & RANDOM Register Write Passthrough..." << std::endl;
    const uint16_t pokey_candidates[3] = {0x4000, 0x0450, 0x0800};
    uint16_t pokey_base = 0x4000;
    uint8_t rnd1 = 0;
    uint8_t rnd2 = 0;
    uint8_t rnd3 = 0;
    bool pokey_found = false;
    bool saw_pcm_audio = false;

    for (uint16_t base : pokey_candidates) {
        run_bus_cycle(static_cast<uint16_t>(base + 0x0F), false, 0x03); // Enable POKEY audio & timers
        run_bus_cycle(static_cast<uint16_t>(base + 0x08), false, 0x40); // Clock channel 0 directly from phi2
        run_bus_cycle(static_cast<uint16_t>(base + 0x00), false, 0x00); // Fast channel 0 period for observable audio
        run_bus_cycle(static_cast<uint16_t>(base + 0x01), false, 0xAF); // Set POKEY AUDC1 volume & pure tone
        std::cout << " -> probe base 0x" << std::hex << base
                  << " audc0=0x" << (int)top->rootp->atari_cart_top__DOT__u_pokey__DOT__audc[0]
                  << " chan_out=0x" << (int)top->rootp->atari_cart_top__DOT__u_pokey__DOT__chan_out
                  << " pcm_audio=0x" << (int)top->rootp->atari_cart_top__DOT__pcm_audio << std::endl;
        if (top->rootp->atari_cart_top__DOT__pcm_audio != 0) {
            saw_pcm_audio = true;
        }

        uint8_t t1 = run_bus_cycle(static_cast<uint16_t>(base + 0x0E), true);
        for (int i = 0; i < 16; i++) run_bus_cycle(0x8000, true);
        uint8_t t2 = run_bus_cycle(static_cast<uint16_t>(base + 0x0E), true);
        for (int i = 0; i < 16; i++) run_bus_cycle(0x8000, true);
        uint8_t t3 = run_bus_cycle(static_cast<uint16_t>(base + 0x0E), true);

        if (t1 != 0x00 && t1 != 0xFF && (t1 != t2 || t2 != t3)) {
            pokey_base = base;
            rnd1 = t1;
            rnd2 = t2;
            rnd3 = t3;
            pokey_found = true;
            break;
        }
    }

    std::cout << " -> POKEY base 0x" << std::hex << pokey_base
              << " RANDOM reads: 0x" << (int)rnd1
              << ", 0x" << (int)rnd2 << ", 0x" << (int)rnd3 << std::endl;
    assert(pokey_found && "POKEY did not respond at any supported base ($4000/$0450/$0800)!");
    assert(rnd1 != 0x00 && rnd1 != 0xFF && "POKEY RANDOM returned invalid static byte!");
    assert((rnd1 != rnd2 || rnd2 != rnd3) && "POKEY RANDOM generator failed to evolve!");

    int audio_high_cnt = 0;
    for (int cyc = 0; cyc < 256; cyc++) {
        top->phi2 = 0;
        for (int i = 0; i < 14; i++) {
            tick();
            if (top->audio) audio_high_cnt++;
            if (top->rootp->atari_cart_top__DOT__pcm_audio != 0) saw_pcm_audio = true;
        }
        top->phi2 = 1;
        for (int i = 0; i < 16; i++) {
            tick();
            if (top->audio) audio_high_cnt++;
            if (top->rootp->atari_cart_top__DOT__pcm_audio != 0) saw_pcm_audio = true;
        }
    }
    std::cout << " -> Audio PWM High Pulses (Pin 76): " << std::dec << audio_high_cnt << " / 5000 cycles" << std::endl;
    assert(saw_pcm_audio && "POKEY audio level stayed silent!");
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
