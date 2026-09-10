# Primary clock constraint for Tang Nano 9K 27MHz onboard oscillator
# 27 MHz => 37.037 ns period
create_clock -name clk -period 37.037 [get_ports {clk}]

# clk_cart: second PLL output (~81MHz), drives the cart bus-facing pipeline
# and BRAM Port A. svc_clk: femtorv_service_soc's own PLL output (~54MHz),
# drives FemtoRV/PSRAM and BRAM Port B. Both are internally generated, so
# they're constrained on the PLL primitive's CLKOUT net rather than a port.
create_generated_clock -name clk_cart -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 3 [get_pins {u_pll_cart/pll_inst/CLKOUT}]
create_generated_clock -name svc_clk -source [get_ports {clk}] -master_clock clk -divide_by 1 -multiply_by 2 [get_pins {gen_h5_sideband.u_service/u_pll/pll_inst/CLKOUT}]

# clk_cart and svc_clk are independent, unrelated-phase PLLs (and clk_cart
# doesn't sample any signal generated on svc_clk directly, or vice versa --
# every crossing between them goes through an explicit synchronizer in
# atari_cart_top.v). Treat all three clock groups as mutually asynchronous
# so the tool doesn't apply a false single-clock timing relationship across
# them.
set_clock_groups -asynchronous -group [get_clocks {clk_cart}] -group [get_clocks {clk svc_clk}]
