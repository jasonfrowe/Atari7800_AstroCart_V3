// ============================================================================
// Module: rom_block_2k
// Description: 2KB Gowin BSRAM/pROM Block Module
// ============================================================================

`default_nettype none

module rom_block_2k #(
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire [10:0] raddr,
    output reg  [7:0]  rdata,
    input  wire        we,
    input  wire [10:0] waddr,
    input  wire [7:0]  wdata
);
    reg [7:0] mem [0:2047];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        if (we) begin
            mem[waddr] <= wdata;
        end
        rdata <= mem[raddr];
    end

endmodule
`default_nettype wire
