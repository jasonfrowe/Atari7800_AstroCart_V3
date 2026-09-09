# Primary clock constraint for Tang Nano 9K 27MHz onboard oscillator
# 27 MHz => 37.037 ns period
create_clock -name clk -period 37.037 [get_ports {clk}]

# clk_cart (u_pll_cart, ~81MHz, clocks ram_block_2k's Port A read port) and
# the femtorv_service_soc PLL's outputs (svc_clk/clk_81m ~54MHz and its
# CLKOUTP/CLKOUTD/CLKOUTD3) both derive from clk, but via two SEPARATE,
# independent rPLL instances -- sharing a source does not give them a fixed
# phase relationship in silicon. The only paths crossing between these two
# domains (game_chunk_roff -> ram_block_2k Port A address, and Port A's
# read data feeding the purely-combinational Atari-bus output path) are
# deliberately asynchronous by design: there's no clocked handshake, the
# design just relies on the read settling well before the async Atari bus
# samples it. Declare the domains as async clock groups so STA doesn't
# report spurious synchronous-timing violations across a boundary that was
# never meant to be synchronous in the first place.
create_clock -name clk_cart -period 12.346 [get_pins {u_pll_cart/pll_inst/CLKOUT}]
create_clock -name svc_clk -period 18.518 [get_pins {gen_h5_sideband.u_service/u_pll/pll_inst/CLKOUT}]

set_clock_groups -asynchronous -group [get_clocks {clk_cart}] -group [get_clocks {clk svc_clk}]
