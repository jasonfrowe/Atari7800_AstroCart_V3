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
    (* ram_style = "distributed", syn_ramstyle = "logic" *) reg [7:0] mem [0:255];
    reg [7:0] b_rdata_r;

    always @(posedge clk) begin
        if (rst) begin
            b_rdata_r <= 8'h00;
        end else begin
            if (a_we) begin
                mem[a_addr] <= a_wdata;
            end
            b_rdata_r <= mem[b_addr];
        end
    end

    assign b_rdata = b_rdata_r;

endmodule

`default_nettype wire
