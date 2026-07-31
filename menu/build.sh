#!/bin/bash
# Build script for Atari 7800 menu program (8KB ROM Version)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASIC_PATH="/Users/rowe/Software/Atari7800/7800basic"

echo "Building Atari 7800 Menu Program (8KB ROM)..."
echo "============================================="

cd "${SCRIPT_DIR}"

# Ensure 8KB variable redefinition in 7800basic_variable_redefs.h
sed -i '' 's/ROM32K = 1/ROM8K = 1/g' 7800basic_variable_redefs.h 2>/dev/null || true

# Preprocess menu.bas with 7800basic
${BASIC_PATH}/7800basic.sh menu.bas > /dev/null 2>&1 || true

# Generate menu_8k.asm
python3 "${SCRIPT_DIR}/convert_8k.py"

# Assemble 8KB ROM using DASM
echo "Assembling 8KB ROM with DASM..."
${BASIC_PATH}/dasm menu_8k.asm -I${BASIC_PATH}/includes -f3 -lmenu_8k.list.txt -p20 -smenu_8k.symbol.txt -omenu.bas.bin

if [ $? -eq 0 ]; then
    echo "Signing ROM..."
    ${BASIC_PATH}/7800sign -w menu.bas.bin
    
    echo "Creating A78 header..."
    ${BASIC_PATH}/7800header -o -f a78info.cfg menu.bas.bin
    
    echo ""
    echo "✓ Compilation successful!"
    echo ""
    echo "Output files:"
    ls -lh menu.bas.bin menu.bas.a78
    echo ""
    echo "Menu ROM size: $(wc -c < menu.bas.bin | tr -d ' ') bytes"
    echo ""
    echo "To test in emulator or harness:"
    echo "  open menu.bas.a78"
    echo ""
else
    echo ""
    echo "✗ Compilation failed!"
    echo "Check errors above."
    exit 1
fi
