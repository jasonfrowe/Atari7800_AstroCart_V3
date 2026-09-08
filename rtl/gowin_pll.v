module gowin_pll (
    input clkin,
    output clkout,
    output clkoutp,
    output clkoutd,
    output lock
);

    wire clkoutd3_unused;

    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW1NR-9C"),
        .IDIV_SEL(0),
        .FBDIV_SEL(2),
        .ODIV_SEL(8),
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
        .CLKOUTP(clkoutp),
        .CLKOUTD(clkoutd),
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
endmodule
