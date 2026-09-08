// ============================================================================
// Module: menu_block_8k
// Description: 8KB menu ROM backed by a 32-bit word array initialized from
//              menu_word_chunk_00.hex. Byte reads are selected by address LSBs.
// ============================================================================

`default_nettype none

module menu_block_8k #(
    parameter INIT_FILE = "menu_word_chunk_00.hex"
)(
    input  wire        clk,
    input  wire [12:0] raddr,
    output reg  [7:0]  rdata
);
    (* ram_style = "block", syn_ramstyle = "block_ram" *) reg [31:0] mem [0:2047];
    reg [31:0] word_r;
    reg [1:0]  byte_sel_r;

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        word_r <= mem[raddr[12:2]];
        byte_sel_r <= raddr[1:0];

        case (byte_sel_r)
            2'b00: rdata <= word_r[7:0];
            2'b01: rdata <= word_r[15:8];
            2'b10: rdata <= word_r[23:16];
            default: rdata <= word_r[31:24];
        endcase
    end

endmodule

`default_nettype wire
