// ============================================================================
// Module: spi_sd
// Description: Memory-Mapped SPI Controller for MicroSD Card Interface
// Target: Tang Nano 9K / Verilator Simulation
// ============================================================================

`default_nettype none

module spi_sd (
    input  wire        clk,        // System clock (27 MHz)
    input  wire        rst_n,      // Active low reset

    // Memory-Mapped Interface (RISC-V Bus)
    input  wire        cs,         // Peripheral Chip Select
    input  wire        we,         // Write Enable
    input  wire [1:0]  addr,       // 00=DATA, 01=CTRL, 10=DIVISOR
    input  wire [7:0]  wdata,      // Write Data
    output reg  [7:0]  rdata,      // Read Data

    // MicroSD Hardware Pins per PINS.md
    output reg         sd_cs,      // Active low CS (pin 38)
    output reg         sd_mosi,    // MOSI (pin 37)
    input  wire        sd_miso,    // MISO (pin 39)
    output reg         sd_clk      // SCLK (pin 36)
);

    reg [7:0]  shift_reg;
    reg [7:0]  rx_reg;
    reg [2:0]  bit_cnt;
    reg [7:0]  clk_div;
    reg [7:0]  clk_cnt;
    reg        busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_cs     <= 1'b1;     // Active low CS (disabled by default)
            sd_mosi   <= 1'b1;
            sd_clk    <= 1'b0;
            shift_reg <= 8'hFF;
            rx_reg    <= 8'hFF;
            bit_cnt   <= 3'd0;
            clk_div   <= 8'd33;    // Initial ~400 kHz clock for SD init
            clk_cnt   <= 8'd0;
            busy      <= 1'b0;
        end else begin
            // Register writes
            if (cs && we) begin
                case (addr)
                    2'b00: begin // WRITE DATA -> Start SPI transfer
                        if (!busy) begin
                            shift_reg <= wdata;
                            busy      <= 1'b1;
                            bit_cnt   <= 3'd7;
                            clk_cnt   <= 8'd0;
                            sd_clk    <= 1'b0;
                        end
                    end
                    2'b01: begin // WRITE CONTROL (bit 0 = CS output)
                        sd_cs <= wdata[0];
                    end
                    2'b10: begin // WRITE DIVISOR
                        clk_div <= wdata;
                    end
                    default: ;
                endcase
            end

            // SPI State Machine
            if (busy) begin
                if (clk_cnt == clk_div) begin
                    clk_cnt <= 8'd0;
                    if (!sd_clk) begin
                        // Rising edge of SPI SCLK -> Output MOSI bit
                        sd_clk  <= 1'b1;
                        sd_mosi <= shift_reg[bit_cnt];
                    end else begin
                        // Falling edge of SPI SCLK -> Sample MISO bit
                        sd_clk <= 1'b0;
                        rx_reg[bit_cnt] <= sd_miso;
                        if (bit_cnt == 3'd0) begin
                            busy <= 1'b0; // Transfer complete
                        end else begin
                            bit_cnt <= bit_cnt - 1'b1;
                        end
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1'b1;
                end
            end
        end
    end

    // Register reads
    always @(*) begin
        if (cs) begin
            case (addr)
                2'b00: rdata = rx_reg;
                2'b01: rdata = {6'b000000, busy, sd_cs};
                2'b10: rdata = clk_div;
                default: rdata = 8'h00;
            endcase
        end else begin
            rdata = 8'h00;
        end
    end

endmodule
`default_nettype wire
