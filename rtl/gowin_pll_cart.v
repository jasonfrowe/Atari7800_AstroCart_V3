// ============================================================================
// Module: gowin_pll_cart
// Description: Second, independent PLL instance producing clk_cart
//              (~135MHz), used only for the cart ROM/RAM BRAM read port
//              (ram_block_2k Port A, MARIA/CPU reads) and its address
//              synchronizer in atari_cart_top.v. Deliberately separate from
//              gowin_pll.v (the femtorv_service_soc PLL, which stays at
//              54MHz for FemtoRV/PSRAM) so cart-read bandwidth can be
//              raised without touching FemtoRV/PSRAM timing margins.
//              clk_cart does NOT sample any external Atari bus pin --
//              those stay on the raw 27MHz `clk` (see atari_cart_top.v's
//              bus-synchronizer comment: two attempts to sample pins
//              directly on clk_cart broke the menu on real hardware,
//              likely a real signal-integrity/setup-time margin issue
//              through the board's SN74LVC8T245 level shifters at ~81MHz,
//              not a logic bug). clk_cart only does internal FPGA-to-FPGA
//              work now (a 2-flop address synchronizer, then the BRAM
//              itself), so raising its rate is safe from that specific
//              failure mode -- MARIA's DMA runs at 7.16MHz (~140ns/fetch;
//              confirmed by the user, who also confirmed the level
//              shifter's own propagation delay is ~4.2ns/hop, not the
//              dominant cost), and the address-to-data latency through the
//              clk-domain glitch filter + this synchronizer + the BRAM
//              read was close enough to that budget to plausibly explain
//              graphics corruption on DMA-heavy games (Choplifter,
//              astrowing) at a predictable moment when assets change.
//              Raised from 81MHz (FBDIV_SEL=2) to ~135MHz (FBDIV_SEL=4,
//              VCO=1080MHz, within the GW1NR-9C rPLL's valid range) to
//              shrink the 2-flop-sync + BRAM-read portion of that budget.
// ============================================================================

module gowin_pll_cart (
    input  clkin,
    output clkout,
    output lock
);

`ifdef VERILATOR
    assign clkout = clkin;
    assign lock   = 1'b1;
`else
    wire clkoutp_unused;
    wire clkoutd_unused;
    wire clkoutd3_unused;

    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW1NR-9C"),
        .IDIV_SEL(0),       // Input divider: 27/(0+1) = 27MHz
        .FBDIV_SEL(4),      // Feedback: 27*5 = 135MHz
        .ODIV_SEL(8),       // VCO = 135 * 8 = 1080MHz
        .DYN_SDIV_SEL(2),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_DA_EN("false"),
        .DUTYDA_SEL("1000"),
        .PSDA_SEL("0100"),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT")
    ) pll_inst (
        .CLKIN(clkin),
        .CLKOUT(clkout),
        .CLKOUTP(clkoutp_unused),
        .CLKOUTD(clkoutd_unused),
        .CLKOUTD3(clkoutd3_unused),
        .LOCK(lock),
        .RESET(1'b0),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );
`endif

endmodule
