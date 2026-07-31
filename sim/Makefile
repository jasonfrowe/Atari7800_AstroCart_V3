# ============================================================================
# Makefile for Atari 7800 Multi-Cart Verilator Simulation
# ============================================================================

VERILATOR = verilator
PYTHON    = python3
MKDIR     = mkdir -p

RTL_DIR   = ../rtl
SIM_DIR   = .
FW_DIR    = ../firmware

V_TOP     = atari_cart_top
V_SRC     = $(RTL_DIR)/atari_cart_top.v \
            $(RTL_DIR)/rom_block_2k.v \
            $(RTL_DIR)/pokey_synth.v \
            $(RTL_DIR)/audio_pwm.v \
            $(RTL_DIR)/spi_sd.v \
            $(RTL_DIR)/hazard5_soc.v \
            $(RTL_DIR)/mapper_supergame.v \
            $(RTL_DIR)/hazard5/hdl/hazard5_cpu_1port.v \
            $(RTL_DIR)/hazard5/hdl/hazard5_core.v \
            $(RTL_DIR)/hazard5/hdl/hazard5_csr.v \
            $(RTL_DIR)/hazard5/hdl/hazard5_decode.v \
            $(RTL_DIR)/hazard5/hdl/hazard5_frontend.v \
            $(RTL_DIR)/hazard5/hdl/hazard5_instr_decompress.v \
            $(RTL_DIR)/hazard5/hdl/hazard5_regfile_1w2r.v \
            $(RTL_DIR)/hazard5/hdl/arith/hazard5_alu.v \
            $(RTL_DIR)/hazard5/hdl/arith/hazard5_mul_fast.v \
            $(RTL_DIR)/hazard5/hdl/arith/hazard5_muldiv_seq.v \
            $(RTL_DIR)/hazard5/hdl/arith/hazard5_priority_encode.v \
            $(RTL_DIR)/hazard5/hdl/arith/hazard5_shift_barrel.v

CPP_TB    = tb_cart.cpp
HEX_FILE  ?= cart_payload.hex
FW_HEX    = firmware.hex
A78_FILE  ?= ../carts/astrowing.a78
TRACE_FILE ?= traces/reset_vector.trace
MENU_A78_FILE ?= ../menu/menu.bas.a78
MENU_HEX_FILE ?= menu_payload.hex

VERILATOR_FLAGS = -Wall -Wno-fatal -Wno-CASEOVERLAP --cc --exe --trace \
                  -I$(RTL_DIR) \
                  -I$(RTL_DIR)/hazard5/hdl \
                  -I$(RTL_DIR)/hazard5/hdl/arith \
                  -GFW_INIT_FILE=\"$(FW_HEX)\" \
                  --top-module $(V_TOP)

.PHONY: all run trace menu-run menu-trace clean

all: run

rom_chunk_00.hex: $(A78_FILE) convert_a78_split.py convert_a78.py
	@echo "==> Converting .a78 binary payload into 24x 2KB chunks..."
	$(PYTHON) convert_a78.py $(A78_FILE) $(HEX_FILE)
	$(PYTHON) convert_a78_split.py $(A78_FILE)

$(FW_HEX): $(FW_DIR)/main.c $(FW_DIR)/crt0.S $(FW_DIR)/link.ld
	@echo "==> Compiling RISC-V C firmware..."
	$(MAKE) -C $(FW_DIR)
	cp $(FW_DIR)/firmware.hex $(FW_HEX)

obj_dir/V$(V_TOP): $(V_SRC) $(CPP_TB) rom_chunk_00.hex $(FW_HEX)
	@echo "==> Running Verilator and building simulation binary..."
	$(VERILATOR) $(VERILATOR_FLAGS) $(V_SRC) $(CPP_TB)
	$(MAKE) -C obj_dir -f V$(V_TOP).mk V$(V_TOP)

run: obj_dir/V$(V_TOP) rom_chunk_00.hex $(FW_HEX)
	@echo "==> Executing Verilator simulation..."
	./obj_dir/Vatari_cart_top --rom-hex $(HEX_FILE)

trace: obj_dir/V$(V_TOP) rom_chunk_00.hex $(FW_HEX)
	@echo "==> Replaying external Atari bus trace: $(TRACE_FILE)"
	./obj_dir/Vatari_cart_top --rom-hex $(HEX_FILE) --trace $(TRACE_FILE)

menu-run:
	@echo "==> Executing Verilator simulation with menu ROM..."
	$(MAKE) run A78_FILE=$(MENU_A78_FILE) HEX_FILE=$(MENU_HEX_FILE)

menu-trace:
	@echo "==> Replaying external Atari bus trace against menu ROM..."
	$(MAKE) trace A78_FILE=$(MENU_A78_FILE) HEX_FILE=$(MENU_HEX_FILE) TRACE_FILE=$(TRACE_FILE)

clean:
	rm -rf obj_dir $(HEX_FILE) rom_chunk_*.hex $(FW_HEX) sim_trace.vcd
	$(MAKE) -C $(FW_DIR) clean
