// ============================================================================
// Module: hazard5_soc
// Description: System-on-Chip Interconnect for Hazard5 RISC-V & Peripherals
// Target: Tang Nano 9K / Verilator Simulation
// ============================================================================

`default_nettype none

module hazard5_soc #(
    parameter FIRMWARE_HEX = "firmware.hex"
)(
    input  wire        clk,            // System clock (27 MHz)
    input  wire        rst_n,          // Active low reset

    // Cartridge Bus Control / Config CSRs
    output reg         pokey_enable,   // 1 = POKEY active at $4000-$400F
    output reg  [3:0]  mapper_type,    // Bankswitch mapper selection

    // Cartridge RAM Write Bus (from RISC-V loader)
    output reg         cart_ram_we,    // Write enable
    output reg  [15:0] cart_ram_addr,  // Address
    output reg  [7:0]  cart_ram_wdata, // Data byte

    // MicroSD Hardware Pins per PINS.md
    output wire        sd_cs,          // Pin 38
    output wire        sd_mosi,        // Pin 37
    input  wire        sd_miso,        // Pin 39
    output wire        sd_clk          // Pin 36
);

    // ------------------------------------------------------------------------
    // Hazard5 CPU Single-Port AHB-Lite Bus Signals
    // ------------------------------------------------------------------------
    wire [31:0] cpu_haddr;
    wire        cpu_hwrite;
    wire [1:0]  cpu_htrans;
    wire [2:0]  cpu_hsize;
    wire [2:0]  cpu_hburst;
    wire [3:0]  cpu_hprot;
    wire        cpu_hmastlock;
    wire [31:0] cpu_hwdata;
    reg  [31:0] cpu_hrdata;
    reg         cpu_hready = 1'b1;
    reg         cpu_hresp  = 1'b0;

    // Instantiate Hazard5 1-Port Processor Core
    hazard5_cpu_1port #(
        .EXTENSION_C(1),
        .EXTENSION_M(1),
        .RESET_VECTOR(32'h0000_0000)
    ) u_cpu (
        .clk             (clk),
        .rst_n           (rst_n),
        .ahblm_haddr     (cpu_haddr),
        .ahblm_hwrite    (cpu_hwrite),
        .ahblm_htrans    (cpu_htrans),
        .ahblm_hsize     (cpu_hsize),
        .ahblm_hburst    (cpu_hburst),
        .ahblm_hprot     (cpu_hprot),
        .ahblm_hmastlock (cpu_hmastlock),
        .ahblm_hready    (cpu_hready),
        .ahblm_hresp     (cpu_hresp),
        .ahblm_hwdata    (cpu_hwdata),
        .ahblm_hrdata    (cpu_hrdata),
        .irq             (16'h0000)
    );

    // ------------------------------------------------------------------------
    // Memory Map Address Decoder
    // - 0x0000_0000 - 0x0000_3FFF: 16 KB Firmware RAM
    // - 0x4000_0000 - 0x4000_000F: SPI MicroSD Controller
    // - 0x8000_0000 - 0x8000_FFFF: Cartridge RAM Write Target
    // - 0xC000_0000 - 0xC000_000F: Cartridge CSRs
    // ------------------------------------------------------------------------
    wire is_fw_ram   = (cpu_haddr[31:28] == 4'h0);
    wire is_spi_sd   = (cpu_haddr[31:28] == 4'h4);
    wire is_cart_ram = (cpu_haddr[31:28] == 4'h8);
    wire is_csr      = (cpu_haddr[31:28] == 4'hC);

    wire ahb_transfer = (cpu_htrans[1] == 1'b1); // HTRANS_NONSEQ or HTRANS_SEQ

    // ------------------------------------------------------------------------
    // 16 KB Firmware Memory (Block RAM)
    // ------------------------------------------------------------------------
    reg [31:0] fw_ram [0:4095];
    reg [31:0] fw_ram_rdata;

    initial begin
        if (FIRMWARE_HEX != "") begin
            $readmemh(FIRMWARE_HEX, fw_ram);
        end
    end

    always @(posedge clk) begin
        if (is_fw_ram && ahb_transfer) begin
            if (cpu_hwrite) begin
                fw_ram[cpu_haddr[13:2]] <= cpu_hwdata;
            end
            fw_ram_rdata <= fw_ram[cpu_haddr[13:2]];
        end
    end

    // ------------------------------------------------------------------------
    // SPI MicroSD Controller Integration
    // ------------------------------------------------------------------------
    wire [7:0] spi_rdata;

    spi_sd u_spi (
        .clk      (clk),
        .rst_n    (rst_n),
        .cs       (is_spi_sd && ahb_transfer),
        .we       (cpu_hwrite),
        .addr     (cpu_haddr[3:2]),
        .wdata    (cpu_hwdata[7:0]),
        .rdata    (spi_rdata),
        .sd_cs    (sd_cs),
        .sd_mosi  (sd_mosi),
        .sd_miso  (sd_miso),
        .sd_clk   (sd_clk)
    );

    // ------------------------------------------------------------------------
    // Cartridge RAM Write Output Logic
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cart_ram_we    <= 1'b0;
            cart_ram_addr  <= 16'h0000;
            cart_ram_wdata <= 8'h00;
        end else begin
            cart_ram_we    <= is_cart_ram && ahb_transfer && cpu_hwrite;
            cart_ram_addr  <= cpu_haddr[15:0];
            cart_ram_wdata <= cpu_hwdata[7:0];
        end
    end

    // ------------------------------------------------------------------------
    // Cartridge Control CSRs
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pokey_enable <= 1'b1;
            mapper_type  <= 4'h0;
        end else if (is_csr && ahb_transfer && cpu_hwrite) begin
            pokey_enable <= cpu_hwdata[0];
            mapper_type  <= cpu_hwdata[7:4];
        end
    end

    // Bus Read Multiplexer
    always @(*) begin
        if (is_fw_ram)
            cpu_hrdata = fw_ram_rdata;
        else if (is_spi_sd)
            cpu_hrdata = {24'h000000, spi_rdata};
        else if (is_csr)
            cpu_hrdata = {24'h000000, mapper_type, 3'b000, pokey_enable};
        else
            cpu_hrdata = 32'h0000_0000;
    end

endmodule
`default_nettype wire
