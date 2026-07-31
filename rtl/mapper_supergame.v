// ============================================================================
// Module: mapper_supergame
// Description: Atari 7800 SuperGame Bankswitch Mapper (128K, 256K, 512K)
// Target: Tang Nano 9K / Verilator Simulation
// ============================================================================

`default_nettype none

module mapper_supergame (
    input  wire        clk,           // System clock
    input  wire        rst_n,         // Active low reset
    input  wire        phi2_high,     // CPU clock high level
    input  wire        phi2_rise,     // CPU clock rise edge

    // Bus Interface
    input  wire        cs,            // Cartridge active ($4000-$FFFF)
    input  wire        rw,            // 1 = Read, 0 = Write
    input  wire [15:0] addr,          // Address bus [15:0]
    input  wire [7:0]  din,           // Data byte written by CPU
    input  wire [3:0]  mapper_type,   // 0=Flat 48K, 1=SuperGame, 2=Flat 32K

    // Translated Physical ROM Address Output
    output reg  [18:0] phys_rom_addr  // Up to 512 KB ROM (19-bit address)
);

    reg [4:0] bank_reg; // 5-bit bank selection (up to 32 16KB banks = 512KB)
    reg       write_arm;

    // Bank register write latch ($8000-$8003)
    // Arm on PHI2 rise, then sample one system clock later during PHI2-high
    // so synchronized address/data have a full cycle to settle.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_reg <= 5'd0;
            write_arm <= 1'b0;
        end else begin
            if (phi2_rise)
                write_arm <= 1'b1;
            else if (!phi2_high)
                write_arm <= 1'b0;

            if (write_arm && phi2_high && cs && !rw && (addr >= 16'h8000) && (addr <= 16'h8003)) begin
                bank_reg <= din[4:0];
                write_arm <= 1'b0;
            end
        end
    end

    // Physical ROM Address Translation Logic
    always @(*) begin
        case (mapper_type)
            4'h1: begin // SuperGame Bankswitching
                if (addr >= 16'hC000) begin
                    // Fixed Top Bank ($C000-$FFFF) -> Fixed to Bank 7 (128K) or Bank 31 (512K)
                    phys_rom_addr = {5'd7, addr[13:0]};
                end else if (addr >= 16'h8000) begin
                    // Swappable Bank ($8000-$BFFF)
                    phys_rom_addr = {bank_reg, addr[13:0]};
                end else begin
                    // Lower Bank ($4000-$7FFF)
                    phys_rom_addr = {5'd0, addr[13:0]};
                end
            end

            default: begin // Flat 48K ROM ($4000-$FFFF mapped 0..49151)
                phys_rom_addr = {3'b000, addr - 16'h4000};
            end
        endcase
    end

endmodule
`default_nettype wire
