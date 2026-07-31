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

# Function: Run Gowin EDA Synthesis & Bitstream Generation
run_gowin_synthesis() {
    echo -e "\n${YELLOW}[Phase 5] Running Gowin EDA Synthesis & PnR...${NC}"

    if [ ! -d "$GOWIN_IDE" ]; then
        echo -e "${RED}Error: Gowin IDE not found at $GOWIN_IDE${NC}"
        exit 1
    fi

    # Ensure memory hex files exist
    make -C sim rom_chunk_00.hex
    make -C firmware

    # Copy memory initialization files to all potential working directories
    mkdir -p impl/gwsynthesis "$GOWIN_IDE/impl/gwsynthesis" "$GOWIN_IDE/impl/pnr"
    cp sim/rom_chunk_*.hex "$PROJECT_DIR/"
    cp firmware/firmware.hex "$PROJECT_DIR/firmware.hex"

    cp sim/rom_chunk_*.hex "$PROJECT_DIR/impl/gwsynthesis/"
    cp firmware/firmware.hex "$PROJECT_DIR/impl/gwsynthesis/firmware.hex"

    cp sim/rom_chunk_*.hex "$GOWIN_IDE/"
    cp firmware/firmware.hex "$GOWIN_IDE/firmware.hex"

    cp sim/rom_chunk_*.hex "$GOWIN_IDE/impl/gwsynthesis/"
    cp firmware/firmware.hex "$GOWIN_IDE/impl/gwsynthesis/firmware.hex"

    BUILD_TCL="$PROJECT_DIR/build.tcl"
    cat > "$BUILD_TCL" << EOF
# Gowin IDE Synthesis TCL Script for Atari 7800 Multi-Cart V3
set_device GW1NR-LV9QN88PC6/I5 -name GW1NR-9C
add_file -type verilog "$PROJECT_DIR/rtl/atari_cart_top.v"
add_file -type verilog "$PROJECT_DIR/rtl/rom_block_2k.v"
add_file -type verilog "$PROJECT_DIR/rtl/pokey_synth.v"
add_file -type verilog "$PROJECT_DIR/rtl/audio_pwm.v"
add_file -type verilog "$PROJECT_DIR/rtl/spi_sd.v"
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
set_option -top_module atari_cart_top
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
    ./gw_sh "$BUILD_TCL"
    RESULT=$?
    cd "$PROJECT_DIR"

    if [ $RESULT -ne 0 ]; then
        echo -e "${RED}Gowin Synthesis failed with code $RESULT${NC}"
        exit $RESULT
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
        exit 1
    fi
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
        run_gowin_synthesis
        ;;
    --all)
        run_simulation
        run_gowin_synthesis
        ;;
    *)
        echo -e "${RED}Unknown mode: $MODE${NC}"
        echo "Usage: ./build.sh [--sim | --sim-menu | --trace FILE | --trace-boot FILE | --trace-menu FILE | --gowin | --all]"
        exit 1
        ;;
esac

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN} Build Completed Successfully! ${NC}"
echo -e "${GREEN}==============================================${NC}"
