// ============================================================================
// Module: atari_cart_femtorv_test_top
// Description: Standalone test top for FemtoRV + Petit FatFs SRAM bring-up.
//              Exposes command/status/debug window without changing default top.
// ============================================================================

`default_nettype none

module atari_cart_femtorv_test_top #(
    parameter FIRMWARE_HEX = "femtorv_firmware.hex"
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
    output wire [5:0]  led
);

    reg [11:0] por_counter = 12'd0;
    reg        rst_n = 1'b0;

    always @(posedge clk) begin
        if (por_counter < 12'd4095) begin
            por_counter <= por_counter + 1'b1;
            rst_n <= 1'b0;
        end else begin
            rst_n <= 1'b1;
        end
    end

    reg [1:0] phi2_pipe;
    reg [2:0] rw_pipe;
    reg [15:0] a_pipe;
    reg [15:0] a_sync;
    reg [7:0] d_in_sync;
    reg       phi2_clean;

    always @(posedge clk) begin
        phi2_pipe <= {phi2_pipe[0], phi2};
        rw_pipe <= {rw_pipe[1:0], rw};
        a_pipe <= a;
        if (a_pipe == a)
            a_sync <= a;
        d_in_sync <= d;
        phi2_clean <= phi2_pipe[1];
    end

    wire phi2_high = phi2_clean;
    wire rw_is_read = rw_pipe[1];

    wire trigger_write = phi2_high && !rw_is_read && (a_sync == 16'h2200);

    reg trigger_wr_prev;
    reg [7:0] trigger_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trigger_wr_prev <= 1'b0;
            trigger_val <= 8'h00;
        end else begin
            trigger_wr_prev <= trigger_write;
            if (trigger_write && !trigger_wr_prev)
                trigger_val <= d_in_sync;
        end
    end

    (* syn_keep = 1 *) wire [7:0] status_val;
    (* syn_keep = 1 *) wire [7:0] debug0;
    (* syn_keep = 1 *) wire [7:0] debug1;
    (* syn_keep = 1 *) wire [7:0] debug2;
    (* syn_keep = 1 *) wire [7:0] cpu_probe;
    (* syn_keep = 1 *) wire [7:0] menu_meta_rdata;

    (* keep = "true", syn_keep = 1, dont_touch = "true" *) femtorv_service_soc #(
        .FIRMWARE_HEX(FIRMWARE_HEX)
    ) u_service (
        .clk        (clk),
        .rst_n      (rst_n),
        .trigger_val(trigger_val),
        .status_val (status_val),
        .debug0     (debug0),
        .debug1     (debug1),
        .debug2     (debug2),
        .cart_addr  (a_sync),
        .cart_rdata (menu_meta_rdata),
        .cpu_probe  (cpu_probe),
        .sd_cs      (sd_cs),
        .sd_mosi    (sd_mosi),
        .sd_miso    (sd_miso),
        .sd_clk     (sd_clk)
    );

    wire is_debug_addr = (a_sync == 16'h7FF0) ||
                         (a_sync == 16'h7FF1) ||
                         (a_sync == 16'h7FF2) ||
                         (a_sync == 16'h7FF3);
    wire is_meta_addr = ((a_sync >= 16'hE800) && (a_sync <= 16'hE9FF));

    wire [7:0] debug_data_out = (a_sync == 16'h7FF0) ? status_val :
                                (a_sync == 16'h7FF1) ? debug0 :
                                (a_sync == 16'h7FF2) ? debug1 :
                                (a_sync == 16'h7FF3) ? debug2 : 8'hFF;
    wire [7:0] cart_data_out = is_meta_addr ? menu_meta_rdata : debug_data_out;

    wire is_cart_addr = (a_sync >= 16'h4000);
    wire is_bus_read = rw_is_read && (is_cart_addr || is_debug_addr);

    assign buf_dir = is_bus_read;
    assign buf_oe = 1'b0;
    assign d = (is_bus_read && (buf_dir == 1'b1)) ? cart_data_out : 8'hZZ;

    assign irq = 1'b0;
    assign audio = 1'b0;

    // LED map keeps both 7800 bus status and FemtoRV probe activity visible.
    assign led[0] = ~status_val[7];
    assign led[1] = ~trigger_val[7];
    assign led[2] = ~trigger_val[0];
    assign led[3] = ~cpu_probe[7];
    assign led[4] = ~cpu_probe[6];
    assign led[5] = ~(cpu_probe[5] ^ halt ^ phi2_high ^ rw_is_read);

endmodule

`default_nettype wire
