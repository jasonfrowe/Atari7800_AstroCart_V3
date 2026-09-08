// ============================================================================
// Module: atari_cart_top_h5_matrix
// Description: Auto-generated top wrapper for Hazard5 sideband matrix sweeps.
// ============================================================================

`default_nettype none

module atari_cart_top_h5_matrix #(
    parameter FW_INIT_FILE = "femtorv_firmware.hex"
)(
    input  wire        clk,
    input  wire        phi2,
    input  wire        rw,
    input  wire [15:0] a,
    inout  wire [7:0]  d,
    input  wire        halt,
    output wire        irq,
    output wire        buf_dir,
    output wire        buf_oe,
    output wire        audio,
    output wire        sd_cs,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_clk,
    output wire [0:0]  O_psram_ck,
    output wire [0:0]  O_psram_ck_n,
    output wire [0:0]  O_psram_cs_n,
    output wire [0:0]  O_psram_reset_n,
    inout  wire [0:0]  IO_psram_rwds,
    inout  wire [7:0]  IO_psram_dq,
    output wire [5:0]  led
);

    atari_cart_top #(
        .FW_INIT_FILE(FW_INIT_FILE),
        .H5_SIDEBAND_EN(1'b1),
        .H5_FW_RAM_EN(1'b1),
        .H5_MAILBOX_EN(1'b1),
        .H5_SPI_EN(1'b1)
    ) u_top (
        .clk    (clk),
        .phi2   (phi2),
        .rw     (rw),
        .a      (a),
        .d      (d),
        .halt   (halt),
        .irq    (irq),
        .buf_dir(buf_dir),
        .buf_oe (buf_oe),
        .audio  (audio),
        .sd_cs  (sd_cs),
        .sd_mosi(sd_mosi),
        .sd_miso(sd_miso),
        .sd_clk (sd_clk),
        .O_psram_ck(O_psram_ck),
        .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_rwds(IO_psram_rwds),
        .IO_psram_dq(IO_psram_dq),
        .led    (led)
    );

endmodule

`default_nettype wire
