# Gowin IDE Synthesis TCL Script for Atari 7800 Multi-Cart V3
set_device GW1NR-LV9QN88PC6/I5 -name GW1NR-9C
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/atari_cart_top.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/rom_block_2k.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/pokey_synth.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/audio_pwm.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/spi_sd.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5_soc.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/mapper_supergame.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/hazard5_cpu_1port.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/hazard5_core.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/hazard5_csr.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/hazard5_decode.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/hazard5_frontend.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/hazard5_instr_decompress.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/hazard5_regfile_1w2r.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/arith/hazard5_alu.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/arith/hazard5_mul_fast.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/arith/hazard5_muldiv_seq.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/arith/hazard5_priority_encode.v"
add_file -type verilog "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/rtl/hazard5/hdl/arith/hazard5_shift_barrel.v"
add_file -type cst "/Users/rowe/Software/FPGA/Atari7800_AstroCart_V3/atari.cst"
set_option -top_module atari_cart_top
set_option -verilog_std sysv2017
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -output_base_name Atari7800_AstroCart_V3
run all
