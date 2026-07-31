# ============================================================================
# Makefile for Atari 7800 Multi-Cart Verilator Simulation
# ============================================================================

VERILATOR = verilator
PYTHON    = python3
MKDIR     = mkdir -p

RTL_DIR   = ../rtl
SIM_DIR   = .

V_TOP     = atari_cart_top
V_SRC     = $(RTL_DIR)/atari_cart_top.v
CPP_TB    = tb_cart.cpp
HEX_FILE  = astrowing.hex
A78_FILE  = ../carts/astrowing.a78

VERILATOR_FLAGS = -Wall -Wno-fatal --cc --exe --trace \
                  -I$(RTL_DIR) \
                  -GC_INIT_FILE=\"$(HEX_FILE)\" \
                  --top-module $(V_TOP)

.PHONY: all run clean

all: run

$(HEX_FILE): $(A78_FILE) convert_a78.py
	@echo "==> Converting .a78 binary payload..."
	$(PYTHON) convert_a78.py $(A78_FILE) $(HEX_FILE)

obj_dir/V$(V_TOP): $(V_SRC) $(CPP_TB) $(HEX_FILE)
	@echo "==> Running Verilator and building simulation binary..."
	$(VERILATOR) $(VERILATOR_FLAGS) $(V_SRC) $(CPP_TB)
	$(MAKE) -C obj_dir -f V$(V_TOP).mk V$(V_TOP)

run: obj_dir/V$(V_TOP) $(HEX_FILE)
	@echo "==> Executing Verilator simulation..."
	./obj_dir/V$(V_TOP)

clean:
	rm -rf obj_dir $(HEX_FILE) sim_trace.vcd
