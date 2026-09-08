// ============================================================================
// Module: rom_block_4k
// Description: 4KB Gowin BSRAM/pROM Block Module (inferred across 2 BSRAMs)
// ============================================================================

`default_nettype none

module rom_block_4k #(
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire [11:0] raddr,
    output reg  [7:0]  rdata
);
    reg [7:0] mem [0:4095];

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
