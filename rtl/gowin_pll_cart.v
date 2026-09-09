// ============================================================================
// Module: gowin_pll_cart
// Description: Second, independent PLL instance producing clk_cart
//              (~81MHz), used only for the cart ROM/RAM BRAM read port
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
//              vs. just an occasional duplicate at 81MHz. Tried 108MHz
//              (FBDIV_SEL=3) as a smaller step -- titles broke completely
//              there too, not gradually worse, which doesn't fit a "less
//              margin at higher frequency" story on its own. See
//              atari_cart_top.v's game_ram_raddr comment and
//              ram_block_2k.v: it's a plain inferred dual-clock dual-port
//              RAM with no explicit read-during-write behavior configured
//              -- the SD loader (svc_clk) writing the same region the menu
//              reads titles from (clk_cart) is a real, vendor-undefined
//              same-address collision risk, most likely made worse mainly
//              by clk_cart no longer being a "nice" ratio of svc_clk once
//              it isn't 81MHz (81/54 = 1.5; 108/54 = 2.0 is nominally
//              cleaner but these are independent, unrelated-phase PLLs so
//              a clean ratio doesn't actually guarantee anything -- the
//              cliff-like behavior is not yet fully explained). Reverted
//              to 81MHz, the only value confirmed to keep titles usable.
//              Don't raise this again without either fixing the BRAM
//              collision properly (explicit defined read/write semantics,
//              or a firmware-side handshake so the loader and the menu's
//              title reads never overlap in time) or determining titles
//              aren't sensitive to it after all.
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
