// ============================================================================
// Module: gowin_pll_cart
// Description: Second, independent PLL instance producing clk_cart
//              (~81MHz), used only to clock the cart ROM/RAM BRAM read
//              port (ram_block_2k Port A) that serves MARIA/CPU reads of
//              the loaded game. Deliberately separate from gowin_pll.v (the
//              femtorv_service_soc PLL, which stays at 54MHz for
//              FemtoRV/PSRAM) so cart-read bandwidth can be raised without
//              touching FemtoRV/PSRAM timing margins at all.
//              81MHz was tried as a floor, not a ceiling: the
//              game_ram_raddr->clk_cart 2-flop synchronizer (see
//              atari_cart_top.v) costs a fixed few clk_cart CYCLES of added
//              read latency, and a higher clock rate would directly shrink
//              that cost in real time -- worth trying since MARIA's
//              DMA-read graphics corruption survived the CDC fix. But
//              Gowin's own P&R timing report showed clk_cart's *own*
//              critical path does NOT scale with the requested target: at
//              108MHz the achieved Fmax was only 91.8MHz (a violation), at
//              135MHz only 104.254MHz (worse) -- it plateaus somewhere
//              around 90-104MHz regardless of what's asked for. 81MHz is
//              the one target that actually closes with real margin
//              (93.3MHz achieved). So this stays at 81MHz: going higher
//              buys negligible extra latency margin at best, and risks a
//              new category of real timing failure on top of the graphics
//              corruption this was meant to help with. If clk_cart's rate
//              is revisited again, verify the achieved Fmax in the P&R
//              report -- don't assume a higher request is free margin.
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
