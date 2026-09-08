// ============================================================================
// Module: gowin_sp_be32
// Description: 2K x 32 single-port RAM with byte write enables.
//              Uses Gowin SP primitives for synthesis and a behavioral model
//              under Verilator for simulation compatibility.
// ============================================================================

`default_nettype none

module gowin_sp_be32 #(
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire        ce,
    input  wire        oce,
    input  wire        reset,
    input  wire [10:0] ad,
    input  wire [31:0] din,
    input  wire [3:0]  wre,
    output wire [31:0] dout
);

`ifdef VERILATOR
    reg [31:0] mem [0:2047];
    reg [31:0] dout_r;

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        if (ce) begin
            if (wre[0]) mem[ad][7:0]   <= din[7:0];
            if (wre[1]) mem[ad][15:8]  <= din[15:8];
            if (wre[2]) mem[ad][23:16] <= din[23:16];
            if (wre[3]) mem[ad][31:24] <= din[31:24];
            dout_r <= mem[ad];
        end
    end

    assign dout = dout_r;

`else
    wire [23:0] lane0_pad;
    wire [23:0] lane1_pad;
    wire [23:0] lane2_pad;
    wire [23:0] lane3_pad;
    wire        gw_gnd;

    assign gw_gnd = 1'b0;

    SP sp_lane0 (
        .DO({lane0_pad, dout[7:0]}),
        .CLK(clk),
        .OCE(oce),
        .CE(ce),
        .RESET(reset),
        .WRE(wre[0]),
        .BLKSEL({gw_gnd, gw_gnd, gw_gnd}),
        .AD({ad, gw_gnd, gw_gnd, gw_gnd}),
        .DI({24'h0, din[7:0]})
    );
    defparam sp_lane0.READ_MODE  = 1'b1;
    defparam sp_lane0.WRITE_MODE = 2'b00;
    defparam sp_lane0.BIT_WIDTH  = 8;
    defparam sp_lane0.BLK_SEL    = 3'b000;
    defparam sp_lane0.RESET_MODE = "SYNC";

    SP sp_lane1 (
        .DO({lane1_pad, dout[15:8]}),
        .CLK(clk),
        .OCE(oce),
        .CE(ce),
        .RESET(reset),
        .WRE(wre[1]),
        .BLKSEL({gw_gnd, gw_gnd, gw_gnd}),
        .AD({ad, gw_gnd, gw_gnd, gw_gnd}),
        .DI({24'h0, din[15:8]})
    );
    defparam sp_lane1.READ_MODE  = 1'b1;
    defparam sp_lane1.WRITE_MODE = 2'b00;
    defparam sp_lane1.BIT_WIDTH  = 8;
    defparam sp_lane1.BLK_SEL    = 3'b000;
    defparam sp_lane1.RESET_MODE = "SYNC";

    SP sp_lane2 (
        .DO({lane2_pad, dout[23:16]}),
        .CLK(clk),
        .OCE(oce),
        .CE(ce),
        .RESET(reset),
        .WRE(wre[2]),
        .BLKSEL({gw_gnd, gw_gnd, gw_gnd}),
        .AD({ad, gw_gnd, gw_gnd, gw_gnd}),
        .DI({24'h0, din[23:16]})
    );
    defparam sp_lane2.READ_MODE  = 1'b1;
    defparam sp_lane2.WRITE_MODE = 2'b00;
    defparam sp_lane2.BIT_WIDTH  = 8;
    defparam sp_lane2.BLK_SEL    = 3'b000;
    defparam sp_lane2.RESET_MODE = "SYNC";

    SP sp_lane3 (
        .DO({lane3_pad, dout[31:24]}),
        .CLK(clk),
        .OCE(oce),
        .CE(ce),
        .RESET(reset),
        .WRE(wre[3]),
        .BLKSEL({gw_gnd, gw_gnd, gw_gnd}),
        .AD({ad, gw_gnd, gw_gnd, gw_gnd}),
        .DI({24'h0, din[31:24]})
    );
    defparam sp_lane3.READ_MODE  = 1'b1;
    defparam sp_lane3.WRITE_MODE = 2'b00;
    defparam sp_lane3.BIT_WIDTH  = 8;
    defparam sp_lane3.BLK_SEL    = 3'b000;
    defparam sp_lane3.RESET_MODE = "SYNC";
`endif

endmodule

`default_nettype wire
