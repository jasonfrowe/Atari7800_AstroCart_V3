// ============================================================================
// Module: gowin_pll_cart
// Description: Second, independent PLL instance producing clk_cart (~81MHz),
//              used only to clock the cart ROM/RAM BRAM read port
//              (ram_block_2k Port A) that serves MARIA/CPU reads of the
//              loaded game. Deliberately separate from gowin_pll.v (the
//              femtorv_service_soc PLL, which stays at 54MHz for
//              FemtoRV/PSRAM) so cart-read bandwidth can be raised without
//              touching FemtoRV/PSRAM timing margins at all.
//              Params match AstroCart V2's single 81MHz PLL exactly
//              (FBDIV_SEL=2, ODIV_SEL=8 off the same 27MHz input) -- proven
//              to lock and run at this rate on this exact board.
// ============================================================================

`default_nettype none

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
        .FBDIV_SEL(2),      // Feedback: 27*3 = 81MHz
        .ODIV_SEL(8),       // VCO = 81 * 8 = 648MHz
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

`default_nettype wire
