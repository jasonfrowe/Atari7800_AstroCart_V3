# Primary clock constraint for Tang Nano 9K 27MHz onboard oscillator
# 27 MHz => 37.037 ns period
create_clock -name clk -period 37.037 [get_ports {clk}]
