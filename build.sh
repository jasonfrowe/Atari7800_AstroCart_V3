#!/bin/bash
# ============================================================================
# Build Script for Atari 7800 Multi-Cart V3 (Tang Nano 9K FPGA)
# Usage:
#   ./build.sh          - Default: Runs Verilator co-simulation test suite
#   ./build.sh --sim    - Runs Verilator co-simulation test suite
#   ./build.sh --gowin  - Synthesizes FPGA design with Gowin EDA tools
#   ./build.sh --all    - Runs full simulation and Gowin FPGA synthesis
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

MODE="${1:---sim}"

PROJECT_DIR="$(pwd)"
GOWIN_IDE="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin"
IDE_LIB="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/lib"

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

# Function: Run Gowin EDA Synthesis & Bitstream Generation
run_gowin_synthesis() {
    echo -e "\n${YELLOW}[Phase 5] Running Gowin EDA Synthesis & PnR...${NC}"

    if [ ! -d "$GOWIN_IDE" ]; then
        echo -e "${RED}Error: Gowin IDE not found at $GOWIN_IDE${NC}"
        exit 1
    fi

    # Ensure memory hex files exist
    make -C sim astrowing.hex
    make -C firmware

    cp sim/astrowing.hex "$PROJECT_DIR/astrowing.hex"
    cp firmware/firmware.hex "$PROJECT_DIR/firmware.hex"

    BUILD_TCL="$PROJECT_DIR/build.tcl"
    cat > "$BUILD_TCL" << EOF
# Gowin IDE Synthesis TCL Script for Atari 7800 Multi-Cart V3
set_device GW1NR-LV9QN88PC6/I5 -name GW1NR-9C
add_file -type verilog "$PROJECT_DIR/rtl/atari_cart_top.v"
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
set_option -param C_INIT_FILE="$PROJECT_DIR/astrowing.hex"
set_option -param FW_INIT_FILE="$PROJECT_DIR/firmware.hex"
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
    cd - > /dev/null

    if [ $RESULT -eq 0 ]; then
        echo -e "${GREEN}✓ Gowin Synthesis & PnR Complete!${NC}"
    else
        echo -e "${RED}Gowin Synthesis failed with code $RESULT${NC}"
        exit $RESULT
    fi
}

case "$MODE" in
    --sim)
        run_simulation
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
        echo "Usage: ./build.sh [--sim | --gowin | --all]"
        exit 1
        ;;
esac

echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN} Build Completed Successfully! ${NC}"
echo -e "${GREEN}==============================================${NC}"
