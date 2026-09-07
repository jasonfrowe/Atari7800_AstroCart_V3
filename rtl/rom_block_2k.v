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
    output reg  [7:0]  rdata
);
    reg [7:0] mem [0:2047];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        rdata <= mem[raddr];
    end

endmodule
`default_nettype wire
