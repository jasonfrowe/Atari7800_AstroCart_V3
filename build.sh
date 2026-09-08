#!/bin/bash
# ============================================================================
# Build Script for Atari 7800 Multi-Cart V3 (Tang Nano 9K FPGA)
# Usage:
#   ./build.sh                    - Default: Runs Verilator co-simulation test suite
#   ./build.sh --sim              - Runs Verilator co-simulation test suite
#   ./build.sh --sim-menu         - Runs Verilator harness against the prototype menu ROM
#   ./build.sh --trace FILE       - Replays an external Atari bus trace against the default cart ROM
#   ./build.sh --trace-boot FILE  - Replays an external Atari boot trace with boot assertions enabled
#   ./build.sh --trace-menu FILE  - Replays an external Atari bus trace against the prototype menu ROM
#   ./build.sh --gowin            - Synthesizes FPGA design with Gowin EDA tools
#   ./build.sh --gowin-h5-sideband - Synthesizes with Hazard5 sideband top wrapper enabled
#   ./build.sh --gowin-h5-matrix  - Runs full H5 sideband matrix (FW RAM / Mailbox / SPI)
#   ./build.sh --gowin-femtorv-test - Synthesizes FemtoRV SRAM FAT test top wrapper
#   ./build.sh --gowin-ip-report  - Shows whether Gowin/RTL IP modules were used in latest synthesis log
#   ./build.sh --all              - Runs full simulation and Gowin FPGA synthesis
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

MODE="${1:---sim}"
TRACE_FILE="$2"

PROJECT_DIR="$(pwd)"
GOWIN_IDE="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin"
IDE_LIB="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/lib"

resolve_trace_path() {
    local trace_file="$1"
    if [[ "$trace_file" = /* ]]; then
        printf '%s\n' "$trace_file"
    else
        printf '%s\n' "$PROJECT_DIR/$trace_file"
    fi
}

echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN} Atari 7800 Multi-Cart V3 Build System ${NC}"
echo -e "${GREEN}==============================================${NC}"

# Function: Run Verilator Co-Simulation
run_simulation() {
    echo -e "\n${YELLOW}[Phase 1-4] Compiling Firmware & Running Verilator Co-Simulation...${NC}"
    make -C sim clean
    make -C sim
    echo -e "${GREEN}✓ Verilator Simulation Passed Cleanly!${NC}"
}

run_menu_simulation() {
    echo -e "\n${YELLOW}[Phase 1-4] Running Verilator Co-Simulation Against Menu ROM...${NC}"
    make -C sim clean
    make -C sim menu-run
    echo -e "${GREEN}✓ Menu ROM Verilator Simulation Passed Cleanly!${NC}"
}

run_trace_replay() {
    local trace_file="$1"
    if [ -z "$trace_file" ]; then
        echo -e "${RED}Error: --trace requires a trace file path${NC}"
        echo "Usage: ./build.sh --trace sim/traces/a7800_boot.trace"
        exit 1
    fi

    local resolved_trace
    resolved_trace="$(resolve_trace_path "$trace_file")"

    echo -e "\n${YELLOW}[Phase 1-4] Replaying External Atari Bus Trace...${NC}"
    make -C sim trace TRACE_FILE="$resolved_trace"
    echo -e "${GREEN}✓ Trace Replay Passed Cleanly!${NC}"
}

run_boot_trace_replay() {
    local trace_file="$1"
    if [ -z "$trace_file" ]; then
        echo -e "${RED}Error: --trace-boot requires a trace file path${NC}"
        echo "Usage: ./build.sh --trace-boot sim/traces/a7800_boot.trace"
        exit 1
    fi

    local resolved_trace
    resolved_trace="$(resolve_trace_path "$trace_file")"

    echo -e "\n${YELLOW}[Phase 1-4] Replaying External Atari Boot Trace With Assertions...${NC}"
    make -C sim trace-boot TRACE_FILE="$resolved_trace"
    echo -e "${GREEN}✓ Boot Trace Replay Passed Cleanly!${NC}"
}

run_menu_trace_replay() {
    local trace_file="$1"
    if [ -z "$trace_file" ]; then
        echo -e "${RED}Error: --trace-menu requires a trace file path${NC}"
        echo "Usage: ./build.sh --trace-menu sim/traces/a7800_boot.trace"
        exit 1
    fi

    local resolved_trace
    resolved_trace="$(resolve_trace_path "$trace_file")"

    echo -e "\n${YELLOW}[Phase 1-4] Replaying External Atari Bus Trace Against Menu ROM...${NC}"
    make -C sim menu-trace TRACE_FILE="$resolved_trace"
    echo -e "${GREEN}✓ Menu Trace Replay Passed Cleanly!${NC}"
}

report_gowin_ip_usage() {
    local log_path=""
    local prj_path=""
    local cand
    local log_candidates=(
        "$GOWIN_IDE/impl/gwsynthesis/Atari7800_AstroCart_V3.log"
        "$GOWIN_IDE/bin/impl/gwsynthesis/Atari7800_AstroCart_V3.log"
        "$PROJECT_DIR/impl/gwsynthesis/Atari7800_AstroCart_V3.log"
    )

    local prj_candidates=(
        "$GOWIN_IDE/impl/gwsynthesis/Atari7800_AstroCart_V3.prj"
        "$GOWIN_IDE/bin/impl/gwsynthesis/Atari7800_AstroCart_V3.prj"
        "$PROJECT_DIR/impl/gwsynthesis/Atari7800_AstroCart_V3.prj"
    )

    echo -e "\n${YELLOW}[Info] Gowin IP Usage Report (latest synthesis log)${NC}"

    for cand in "${log_candidates[@]}"; do
        if [ -f "$cand" ]; then
            log_path="$cand"
            break
        fi
    done

    for cand in "${prj_candidates[@]}"; do
        if [ -f "$cand" ]; then
            prj_path="$cand"
            break
        fi
    done

    if [ -z "$log_path" ]; then
        echo -e "${RED}No synthesis log found in expected locations:${NC}"
        printf '  - %s\n' "${log_candidates[@]}"
        echo "Run ./build.sh --gowin first, then rerun --gowin-ip-report."
        exit 1
    fi

    echo "Log: $log_path"
    if [ -f "$prj_path" ]; then
        echo "Project list: $prj_path"
    fi

    echo
    echo "[1] Analyzed source files of interest"
    rg -n "Analyzing Verilog file '.*/(rtl/gowin_sp_be32\.v|rtl/ip/gowin/.*/.*\.v|rtl/rom_block_2k\.v|rtl/hazard5_soc\.v)'" "$log_path" || true

    echo
    echo "[2] Module compile/use markers"
    rg -n "Compiling module 'rom_block_2k|Compiling module 'hazard5_soc|Compiling module 'gowin_sp_be32|Compiling module 'gowin_sdpb_mailbox|Gowin_pROM|Gowin_SP|Gowin_SDPB|Extracting RAM for identifier 'mem'" "$log_path" || true

    echo
    echo "[2b] Elaboration summary"
    if rg -q "Compiling module 'hazard5_soc" "$log_path"; then
        echo "hazard5_soc: elaborated"
    else
        echo "hazard5_soc: not elaborated"
    fi
    if rg -q "Compiling module 'gowin_sp_be32" "$log_path"; then
        echo "gowin_sp_be32: elaborated"
    else
        echo "gowin_sp_be32: not elaborated"
    fi
    if rg -q "Compiling module 'gowin_sdpb_mailbox" "$log_path"; then
        echo "gowin_sdpb_mailbox: elaborated"
    else
        echo "gowin_sdpb_mailbox: not elaborated"
    fi
    if rg -q "Compiling module 'Gowin_SDPB" "$log_path"; then
        echo "Gowin_SDPB: elaborated"
    else
        echo "Gowin_SDPB: not elaborated"
    fi

    echo
    echo "[2a] Top-level instantiation check"
    if rg -q "hazard5_soc[[:space:]]*#|hazard5_soc[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(" "$PROJECT_DIR/rtl/atari_cart_top.v"; then
        echo "hazard5_soc appears instantiated in rtl/atari_cart_top.v"
    else
        echo "hazard5_soc is NOT instantiated in rtl/atari_cart_top.v"
        echo "Result: Gowin/Hazard5 mailbox modules can be analyzed but not contribute to live logic."
    fi

    echo
    echo "[3] Sweep warnings for memory blocks"
    rg -n "NL0002.*rom_block_2k|NL0002.*Gowin_" "$log_path" || true
}

emit_h5_matrix_wrapper() {
    local fw_en="$1"
    local mailbox_en="$2"
    local spi_en="$3"
    local wrapper_path="$PROJECT_DIR/rtl/atari_cart_top_h5_matrix.v"

    cat > "$wrapper_path" << EOF
// ============================================================================
// Module: atari_cart_top_h5_matrix
// Description: Auto-generated top wrapper for Hazard5 sideband matrix sweeps.
// ============================================================================

\`default_nettype none

module atari_cart_top_h5_matrix #(
    parameter FW_INIT_FILE = "firmware.hex"
)(
    input  wire        clk,
    input  wire        phi2,
    input  wire        rw,
    input  wire [15:0] a,
    inout  wire [7:0]  d,
    input  wire        halt,
    output wire        irq,
    output wire        buf_dir,
    output wire        buf_oe,
    output wire        audio,
    output wire        sd_cs,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_clk,
    output wire [5:0]  led
);

    atari_cart_top #(
        .FW_INIT_FILE(FW_INIT_FILE),
        .H5_SIDEBAND_EN(1'b1),
        .H5_FW_RAM_EN(1'b${fw_en}),
        .H5_MAILBOX_EN(1'b${mailbox_en}),
        .H5_SPI_EN(1'b${spi_en})
    ) u_top (
        .clk    (clk),
        .phi2   (phi2),
        .rw     (rw),
        .a      (a),
        .d      (d),
        .halt   (halt),
        .irq    (irq),
        .buf_dir(buf_dir),
        .buf_oe (buf_oe),
        .audio  (audio),
        .sd_cs  (sd_cs),
        .sd_mosi(sd_mosi),
        .sd_miso(sd_miso),
        .sd_clk (sd_clk),
        .led    (led)
    );

endmodule

\`default_nettype wire
EOF
}

find_gowin_log_path() {
    local cand
    local log_candidates=(
        "$GOWIN_IDE/impl/gwsynthesis/Atari7800_AstroCart_V3.log"
        "$GOWIN_IDE/bin/impl/gwsynthesis/Atari7800_AstroCart_V3.log"
        "$PROJECT_DIR/impl/gwsynthesis/Atari7800_AstroCart_V3.log"
    )

    for cand in "${log_candidates[@]}"; do
        if [ -f "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done

    return 1
}

# Function: Run Gowin EDA Synthesis & Bitstream Generation
run_gowin_synthesis() {
    local top_module="${1:-atari_cart_top}"
    local h5_fw_ram_en="${2:-1}"
    local h5_mailbox_en="${3:-1}"
    local h5_spi_en="${4:-1}"
    local use_femtorv_fw=0

    if [ "$top_module" = "atari_cart_femtorv_test_top" ]; then
        use_femtorv_fw=1
    fi

    echo -e "\n${YELLOW}[Phase 5] Running Gowin EDA Synthesis & PnR...${NC}"

    if [ ! -d "$GOWIN_IDE" ]; then
        echo -e "${RED}Error: Gowin IDE not found at $GOWIN_IDE${NC}"
        return 1
    fi

    # Ensure memory hex files exist
    make -C sim rom_chunk_00.hex
    make -C firmware
    if [ "$use_femtorv_fw" -eq 1 ]; then
        make -C firmware femtorv
    fi

    # Keep matrix wrapper available for all synthesis modes.
    emit_h5_matrix_wrapper "$h5_fw_ram_en" "$h5_mailbox_en" "$h5_spi_en"

    # Copy memory initialization files to all potential working directories
    mkdir -p impl/gwsynthesis "$GOWIN_IDE/impl/gwsynthesis" "$GOWIN_IDE/impl/pnr"
    cp sim/rom_chunk_*.hex "$PROJECT_DIR/"
    cp sim/menu_chunk_*.hex "$PROJECT_DIR/"
    cp firmware/firmware.hex "$PROJECT_DIR/firmware.hex"
    if [ "$use_femtorv_fw" -eq 1 ]; then
        cp firmware/femtorv_firmware.hex "$PROJECT_DIR/femtorv_firmware.hex"
    fi

    cp sim/rom_chunk_*.hex "$PROJECT_DIR/impl/gwsynthesis/"
    cp sim/menu_chunk_*.hex "$PROJECT_DIR/impl/gwsynthesis/"
    cp firmware/firmware.hex "$PROJECT_DIR/impl/gwsynthesis/firmware.hex"
    if [ "$use_femtorv_fw" -eq 1 ]; then
        cp firmware/femtorv_firmware.hex "$PROJECT_DIR/impl/gwsynthesis/femtorv_firmware.hex"
    fi

    cp sim/rom_chunk_*.hex "$GOWIN_IDE/"
    cp sim/menu_chunk_*.hex "$GOWIN_IDE/"
    cp firmware/firmware.hex "$GOWIN_IDE/firmware.hex"
    if [ "$use_femtorv_fw" -eq 1 ]; then
        cp firmware/femtorv_firmware.hex "$GOWIN_IDE/femtorv_firmware.hex"
    fi

    cp sim/rom_chunk_*.hex "$GOWIN_IDE/impl/gwsynthesis/"
    cp sim/menu_chunk_*.hex "$GOWIN_IDE/impl/gwsynthesis/"
    cp firmware/firmware.hex "$GOWIN_IDE/impl/gwsynthesis/firmware.hex"
    if [ "$use_femtorv_fw" -eq 1 ]; then
        cp firmware/femtorv_firmware.hex "$GOWIN_IDE/impl/gwsynthesis/femtorv_firmware.hex"
    fi

    BUILD_TCL="$PROJECT_DIR/build.tcl"
    cat > "$BUILD_TCL" << EOF
# Gowin IDE Synthesis TCL Script for Atari 7800 Multi-Cart V3
set_device GW1NR-LV9QN88PC6/I5 -name GW1NR-9C
add_file -type verilog "$PROJECT_DIR/rtl/atari_cart_top.v"
add_file -type verilog "$PROJECT_DIR/rtl/atari_cart_top_h5.v"
add_file -type verilog "$PROJECT_DIR/rtl/atari_cart_top_h5_matrix.v"
add_file -type verilog "$PROJECT_DIR/rtl/atari_cart_femtorv_test_top.v"
add_file -type verilog "$PROJECT_DIR/rtl/femtorv_service_soc.v"
add_file -type verilog "$PROJECT_DIR/third_party/femtorv/femtorv32_quark.v"
add_file -type verilog "$PROJECT_DIR/rtl/rom_block_2k.v"
add_file -type verilog "$PROJECT_DIR/rtl/pokey_synth.v"
add_file -type verilog "$PROJECT_DIR/rtl/audio_pwm.v"
add_file -type verilog "$PROJECT_DIR/rtl/spi_sd.v"
add_file -type verilog "$PROJECT_DIR/rtl/gowin_sp_be32.v"
add_file -type verilog "$PROJECT_DIR/rtl/gowin_sdpb_mailbox.v"
add_file -type verilog "$PROJECT_DIR/rtl/ip/gowin/gowin_prom/gowin_prom.v"
add_file -type verilog "$PROJECT_DIR/rtl/ip/gowin/gowin_sp/gowin_sp.v"
add_file -type verilog "$PROJECT_DIR/rtl/ip/gowin/gowin_sdpb/gowin_sdpb.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5_soc.v"
add_file -type verilog "$PROJECT_DIR/rtl/mapper_supergame.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/hazard5_cpu_1port.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/hazard5_core.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/hazard5_csr.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/hazard5_decode.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/hazard5_frontend.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/hazard5_instr_decompress.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/hazard5_regfile_1w2r.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/arith/hazard5_alu.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/arith/hazard5_mul_fast.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/arith/hazard5_muldiv_seq.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/arith/hazard5_priority_encode.v"
add_file -type verilog "$PROJECT_DIR/rtl/hazard5/hdl/arith/hazard5_shift_barrel.v"
add_file -type cst "$PROJECT_DIR/atari.cst"
add_file -type sdc "$PROJECT_DIR/timing.sdc"
set_option -top_module $top_module
set_option -verilog_std sysv2017
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -output_base_name Atari7800_AstroCart_V3
run all
EOF

    export DYLD_LIBRARY_PATH="$IDE_LIB:$DYLD_LIBRARY_PATH"
    export DYLD_FRAMEWORK_PATH="$IDE_LIB:$DYLD_FRAMEWORK_PATH"

    cd "$GOWIN_IDE"
    if ./gw_sh "$BUILD_TCL"; then
        RESULT=0
    else
        RESULT=$?
    fi
    cd "$PROJECT_DIR"

    if [ $RESULT -ne 0 ]; then
        echo -e "${RED}Gowin Synthesis failed with code $RESULT${NC}"
        return $RESULT
    fi

    BITSTREAM_PATH="$GOWIN_IDE/impl/pnr/Atari7800_AstroCart_V3.fs"
    if [ ! -f "$BITSTREAM_PATH" ]; then
        BITSTREAM_PATH="$PROJECT_DIR/impl/pnr/Atari7800_AstroCart_V3.fs"
    fi

    if [ -f "$BITSTREAM_PATH" ]; then
        if [ -e "$PROJECT_DIR/Atari7800_AstroCart_V3.fs" ] && [ ! -w "$PROJECT_DIR/Atari7800_AstroCart_V3.fs" ]; then
            chmod u+w "$PROJECT_DIR/Atari7800_AstroCart_V3.fs"
        fi
        cp "$BITSTREAM_PATH" "$PROJECT_DIR/Atari7800_AstroCart_V3.fs"
        echo -e "${GREEN}✓ Bitstream copied to Atari7800_AstroCart_V3.fs${NC}"
    else
        echo -e "${RED}Error: Bitstream not found at $BITSTREAM_PATH${NC}"
        return 1
    fi

    return 0
}

run_gowin_h5_matrix() {
    local log_path=""
    local matrix_report_path="$PROJECT_DIR/impl/gwsynthesis/h5_sideband_matrix_report.txt"
    local bits
    local fw_en
    local mailbox_en
    local spi_en
    local label
    local result
    local reason
    local -a combos=(
        "000 CORE_ONLY"
        "100 CORE_PLUS_FW"
        "010 CORE_PLUS_MAILBOX"
        "001 CORE_PLUS_SPI"
        "110 CORE_PLUS_FW_MAILBOX"
        "101 CORE_PLUS_FW_SPI"
        "011 CORE_PLUS_MAILBOX_SPI"
        "111 FULL_SIDEBAND"
    )

    echo -e "\n${YELLOW}[Matrix] Hazard5 sideband toggle sweep (FW/Mailbox/SPI)${NC}"
    printf '%-18s %-3s %-3s %-3s %-8s %-12s\n' "CONFIG" "FW" "MB" "SPI" "RESULT" "NOTES"
    printf '%-18s %-3s %-3s %-3s %-8s %-12s\n' "------------------" "---" "---" "---" "--------" "------------"

    mkdir -p "$PROJECT_DIR/impl/gwsynthesis"
    {
        echo "Hazard5 sideband matrix report"
        echo "Generated: $(date)"
        printf '%-18s %-3s %-3s %-3s %-8s %-12s\n' "CONFIG" "FW" "MB" "SPI" "RESULT" "NOTES"
        printf '%-18s %-3s %-3s %-3s %-8s %-12s\n' "------------------" "---" "---" "---" "--------" "------------"
    } > "$matrix_report_path"

    for combo in "${combos[@]}"; do
        bits="${combo%% *}"
        label="${combo#* }"
        fw_en="${bits:0:1}"
        mailbox_en="${bits:1:1}"
        spi_en="${bits:2:1}"

        if run_gowin_synthesis atari_cart_top_h5_matrix "$fw_en" "$mailbox_en" "$spi_en"; then
            result="PASS"
            reason="fit"
        else
            result="FAIL"
            reason="unknown"
        fi

        log_path="$(find_gowin_log_path || true)"
        if [ -n "$log_path" ] && rg -q "ERROR \(IF0008\)" "$log_path"; then
            reason="IF0008"
        elif [ "$result" = "FAIL" ] && [ -n "$log_path" ]; then
            reason="other"
        fi

        printf '%-18s %-3s %-3s %-3s %-8s %-12s\n' "$label" "$fw_en" "$mailbox_en" "$spi_en" "$result" "$reason"
        printf '%-18s %-3s %-3s %-3s %-8s %-12s\n' "$label" "$fw_en" "$mailbox_en" "$spi_en" "$result" "$reason" >> "$matrix_report_path"
    done

    echo
    echo "Saved matrix report: $matrix_report_path"
}

case "$MODE" in
    --sim)
        run_simulation
        ;;
    --sim-menu)
        run_menu_simulation
        ;;
    --trace)
        run_trace_replay "$TRACE_FILE"
        ;;
    --trace-boot)
        run_boot_trace_replay "$TRACE_FILE"
        ;;
    --trace-menu)
        run_menu_trace_replay "$TRACE_FILE"
        ;;
    --gowin)
        run_gowin_synthesis atari_cart_top
        ;;
    --gowin-h5-sideband)
        run_gowin_synthesis atari_cart_top_h5
        ;;
    --gowin-h5-matrix)
        run_gowin_h5_matrix
        ;;
    --gowin-femtorv-test)
        run_gowin_synthesis atari_cart_femtorv_test_top
        ;;
    --gowin-ip-report)
        report_gowin_ip_usage
        ;;
    --all)
        run_simulation
        run_gowin_synthesis
        ;;
    *)
        echo -e "${RED}Unknown mode: $MODE${NC}"
        echo "Usage: ./build.sh [--sim | --sim-menu | --trace FILE | --trace-boot FILE | --trace-menu FILE | --gowin | --gowin-h5-sideband | --gowin-h5-matrix | --gowin-femtorv-test | --gowin-ip-report | --all]"
        exit 1
        ;;
esac

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN} Build Completed Successfully! ${NC}"
echo -e "${GREEN}==============================================${NC}"
