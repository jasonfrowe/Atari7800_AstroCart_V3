// ============================================================================
// Module: gowin_pll_cart
// Description: Second, independent PLL instance producing clk_cart
//              (~108MHz), used only for the cart ROM/RAM BRAM read port
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
//              through the board's SN74LVC8T245 level shifters, not a
//              logic bug).
//              81MHz confirmed working (titles load, MARIA graphics still
//              corrupted -- the actual thing this rate needs to fix).
//              135MHz (FBDIV_SEL=4) broke SD-scanned menu titles entirely,
//              vs. just an occasional duplicate at 81MHz -- see
//              atari_cart_top.v's game_ram_raddr comment and
//              ram_block_2k.v: it's a plain inferred dual-clock dual-port
//              RAM with no explicit read-during-write behavior configured,
//              and the SD loader (svc_clk) writing the same region the
//              menu is reading titles from (clk_cart) is a real, vendor-
//              undefined same-address collision risk that gets WORSE as
//              the read rate rises (more read events per unit time = more
//              chances to collide with any given write). Stepping up to
//              ~108MHz (FBDIV_SEL=3) instead of jumping straight back to
//              135MHz, to find how far this can go before the title
//              collision becomes unacceptable, while still meaningfully
//              cutting the address-sync + BRAM-read latency for MARIA's
//              7.16MHz DMA. If this ALSO breaks titles badly, the fix
//              needs to actually address the BRAM collision (explicit
//              defined read/write semantics, or a firmware-side handshake
//              so the loader and the menu's title reads never race) rather
//              than continuing to guess at frequencies.
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
        .FBDIV_SEL(3),      // Feedback: 27*4 = 108MHz
        .ODIV_SEL(8),       // VCO = 108 * 8 = 864MHz
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
