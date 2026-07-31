#!/bin/bash
# ============================================================================
# Program script for Tang Nano 9K using openFPGALoader
# Flashes the Atari 7800 Multi-Cart V3 bitstream to the FPGA
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Programming Tang Nano 9K (V3 Cart)${NC}"
echo -e "${GREEN}======================================${NC}"

BITSTREAM="Atari7800_AstroCart_V3.fs"

if [ ! -f "$BITSTREAM" ]; then
    echo -e "${RED}Error: Bitstream file not found: $BITSTREAM${NC}"
    echo "Please run ./build.sh --gowin first."
    exit 1
fi

if ! command -v openFPGALoader &> /dev/null; then
    echo -e "${RED}Error: openFPGALoader not found${NC}"
    echo "Install it via Homebrew: brew install openfpgaloader"
    exit 1
fi

echo -e "\n${YELLOW}Detecting Tang Nano 9K...${NC}"
if ! openFPGALoader --detect 2>&1 | grep -q "Gowin"; then
    echo -e "${RED}Error: Tang Nano 9K not detected${NC}"
    echo "Please check:"
    echo "  1. Tang Nano 9K USB-C cable is attached to your Mac"
    echo "  2. Cable supports data (not power-only)"
    exit 1
fi

echo -e "${GREEN}✓ Tang Nano 9K Board detected${NC}"

MODE="${1:-sram}"

if [ "$MODE" = "flash" ]; then
    echo -e "${YELLOW}Programming to Flash (permanent across power cycles)...${NC}"
    openFPGALoader -b tangnano9k -f "$BITSTREAM"
else
    echo -e "${YELLOW}Programming to SRAM (fast, temporary for testing)...${NC}"
    openFPGALoader -b tangnano9k "$BITSTREAM"
fi

echo -e "\n${GREEN}======================================${NC}"
echo -e "${GREEN}Programming Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
