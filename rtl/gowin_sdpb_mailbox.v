// ============================================================================
// Module: gowin_sdpb_mailbox
// Description: 256 x 8 simple dual-port mailbox RAM.
//              Uses generated Gowin_SDPB for synthesis and a behavioral model
//              under Verilator for simulation compatibility.
// ============================================================================

`default_nettype none

module gowin_sdpb_mailbox (
    input  wire       clk,
    input  wire       rst,
    input  wire       a_we,
    input  wire [7:0] a_addr,
    input  wire [7:0] a_wdata,
    input  wire [7:0] b_addr,
    output wire [7:0] b_rdata
);

`ifdef VERILATOR
    reg [7:0] mem [0:255];
    reg [7:0] b_rdata_r;

    always @(posedge clk) begin
        if (a_we) begin
            mem[a_addr] <= a_wdata;
        end
        b_rdata_r <= mem[b_addr];
    end

    assign b_rdata = b_rdata_r;

`else
    Gowin_SDPB u_mailbox (
        .dout   (b_rdata),
        .clka   (clk),
        .cea    (1'b1),
        .reseta (rst),
        .clkb   (clk),
        .ceb    (1'b1),
        .resetb (rst),
        .oce    (1'b1),
        .ada    (a_addr),
        .din    (a_wdata),
        .adb    (b_addr)
    );
`endif

endmodule

`default_nettype wire
