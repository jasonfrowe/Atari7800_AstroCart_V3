// ============================================================================
// Module: ram_block_2k
// Description: 2KB Gowin Dual-Port BSRAM Block Module
//              Port A: Read-only port (Atari bus / DMA bootloader)
//              Port B: Write port (SD ROM streaming loader)
// ============================================================================

`default_nettype none

module ram_block_2k #(
    parameter INIT_FILE = ""
)(
    // Port A (Read)
    input  wire        clka,
    input  wire [10:0] a_addr,
    output reg  [7:0]  a_rdata,

    // Port B (Write)
    input  wire        clkb,
    input  wire        b_we,
    input  wire [10:0] b_addr,
    input  wire [7:0]  b_wdata
);

    reg [7:0] mem [0:2047];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clka) begin
        a_rdata <= mem[a_addr];
    end

    always @(posedge clkb) begin
        if (b_we) begin
            mem[b_addr] <= b_wdata;
        end
    end

endmodule

`default_nettype wire
