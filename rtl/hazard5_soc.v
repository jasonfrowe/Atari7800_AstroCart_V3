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
    output reg         pokey_enable,   // 1 = POKEY active at selected address window
    output reg  [1:0]  pokey_addr_sel, // 0=$4000, 1=$0450, 2=$0800
    output reg  [3:0]  mapper_type,    // Bankswitch mapper selection

    // Handover & Status CSRs
    input  wire [7:0]  trigger_val,    // Value written by 6502 to $2200
    output reg  [7:0]  status_val,     // Status register value read by 6502 at $7FF0

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
    wire [31:0] cpu_hrdata;
    wire        cpu_hready;
    wire        cpu_hresp;

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
    // - 0x0000_0000 - 0x0000_1FFF: 8 KB Firmware RAM (2048 x 32-bit words)
    // - 0x4000_0000 - 0x4000_000F: SPI MicroSD Controller
    // - 0x8000_0000 - 0x8000_FFFF: Cartridge RAM Write Target
    // - 0xC000_0000 - 0xC000_000F: Cartridge CSRs
    // ------------------------------------------------------------------------
    wire is_fw_ram   = (cpu_haddr[31:28] == 4'h0);
    wire is_spi_sd   = (cpu_haddr[31:28] == 4'h4);
    wire is_cart_ram = (cpu_haddr[31:28] == 4'h8 || cpu_haddr[31:28] == 4'hF);
    wire is_csr      = (cpu_haddr[31:28] == 4'hC);

    wire ahb_transfer = (cpu_htrans[1] == 1'b1); // HTRANS_NONSEQ or HTRANS_SEQ

    // ------------------------------------------------------------------------
    // 8 KB Firmware Memory (Block RAM)
    // ------------------------------------------------------------------------
    reg [31:0] fw_ram [0:2047];
    reg [31:0] fw_ram_rdata;

    initial begin
        if (FIRMWARE_HEX != "") begin
            $readmemh(FIRMWARE_HEX, fw_ram);
            $display("[SOC_INIT] Loaded FW RAM: word 0 = 0x%08h", fw_ram[0]);
        end
    end

    wire fw_we = is_fw_ram && ahb_transfer && cpu_hwrite;
    wire [3:0] fw_wstrb = (cpu_hsize == 2'b10) ? 4'b1111 :
                          (cpu_hsize == 2'b01) ? (cpu_haddr[1] ? 4'b1100 : 4'b0011) :
                          (4'b0001 << cpu_haddr[1:0]);

    always @(posedge clk) begin
        if (fw_we) begin
            if (fw_wstrb[0]) fw_ram[cpu_haddr[12:2]][ 7: 0] <= cpu_hwdata[ 7: 0];
            if (fw_wstrb[1]) fw_ram[cpu_haddr[12:2]][15: 8] <= cpu_hwdata[15: 8];
            if (fw_wstrb[2]) fw_ram[cpu_haddr[12:2]][23:16] <= cpu_hwdata[23:16];
            if (fw_wstrb[3]) fw_ram[cpu_haddr[12:2]][31:24] <= cpu_hwdata[31:24];
        end
        fw_ram_rdata <= fw_ram[cpu_haddr[12:2]];
    end

    // ------------------------------------------------------------------------
    // SPI MicroSD Controller Integration
    // ------------------------------------------------------------------------
    reg       spi_write_phase;
    reg [1:0] spi_write_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_write_phase <= 1'b0;
            spi_write_addr  <= 2'b00;
        end else begin
            spi_write_phase <= is_spi_sd && ahb_transfer && cpu_hwrite;
            spi_write_addr  <= cpu_haddr[3:2];
        end
    end

    // ------------------------------------------------------------------------
    // AHB Read Address Phase Pipelining
    // ------------------------------------------------------------------------
    reg is_fw_ram_rphase;
    reg is_spi_sd_rphase;
    reg is_csr_rphase;
    reg [1:0] spi_raddr_reg;
    reg [1:0] csr_raddr_reg;
    reg [1:0] fw_raddr_offset_reg;
    reg [1:0] fw_rsize_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_fw_ram_rphase    <= 1'b0;
            is_spi_sd_rphase    <= 1'b0;
            is_csr_rphase       <= 1'b0;
            spi_raddr_reg       <= 2'b00;
            csr_raddr_reg       <= 2'b00;
            fw_raddr_offset_reg <= 2'b00;
            fw_rsize_reg        <= 2'b00;
        end else begin
            if (ahb_transfer && !cpu_hwrite) begin
                is_fw_ram_rphase    <= is_fw_ram;
                is_spi_sd_rphase    <= is_spi_sd;
                is_csr_rphase       <= is_csr;
                spi_raddr_reg       <= cpu_haddr[3:2];
                csr_raddr_reg       <= cpu_haddr[3:2];
                fw_raddr_offset_reg <= cpu_haddr[1:0];
                fw_rsize_reg        <= cpu_hsize;
            end else if (ahb_transfer && cpu_hwrite) begin
                is_fw_ram_rphase <= 1'b0;
                is_spi_sd_rphase <= 1'b0;
                is_csr_rphase    <= 1'b0;
            end
        end
    end

    wire [7:0] spi_rdata;

    spi_sd u_spi (
        .clk      (clk),
        .rst_n    (rst_n),
        .cs       (spi_write_phase || is_spi_sd_rphase || (is_spi_sd && ahb_transfer && !cpu_hwrite)),
        .we       (spi_write_phase),
        .addr     (spi_write_phase ? spi_write_addr : is_spi_sd_rphase ? spi_raddr_reg : cpu_haddr[3:2]),
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
    reg        cart_ram_write_phase;
    reg [15:0] cart_ram_write_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cart_ram_write_phase <= 1'b0;
            cart_ram_write_addr  <= 16'h0000;
        end else begin
            cart_ram_write_phase <= is_cart_ram && ahb_transfer && cpu_hwrite;
            cart_ram_write_addr  <= cpu_haddr[15:0];
        end
    end

    always @(posedge clk) begin
        if (cpu_hwrite && ahb_transfer) begin
            $display("[EVERY_WRITE] haddr=0x%08h hwdata=0x%08h is_cart=%b", cpu_haddr, cpu_hwdata, is_cart_ram);
        end
        if (cart_ram_write_phase) begin
            $display("[CART_RAM_WRITE] addr=0x%04h wdata=0x%02h ('%c')", cart_ram_write_addr, cart_ram_wdata, cart_ram_wdata);
        end
    end

    assign cart_ram_we    = cart_ram_write_phase;
    assign cart_ram_addr  = cart_ram_write_addr;
    assign cart_ram_wdata = cpu_hwdata[7:0] | cpu_hwdata[15:8] | cpu_hwdata[23:16] | cpu_hwdata[31:24];

    // ------------------------------------------------------------------------
    // Cartridge Control CSRs
    // 0xC000_0000 (0x0): CSR_CTRL   [7:4]=mapper_type, [2:1]=pokey_addr_sel, [0]=pokey_enable
    // 0xC000_0004 (0x1): CSR_STATUS status_val (writable by Hazard5, read by 6502 at $7FF0)
    // 0xC000_0008 (0x2): CSR_TRIGGER trigger_val (read-only from 6502 $2200 write)
    // ------------------------------------------------------------------------
    reg       csr_write_phase;
    reg [1:0] csr_write_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_write_phase <= 1'b0;
            csr_write_addr  <= 2'b00;
        end else begin
            csr_write_phase <= is_csr && ahb_transfer && cpu_hwrite;
            csr_write_addr  <= cpu_haddr[3:2];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pokey_enable   <= 1'b1;
            pokey_addr_sel <= 2'b00;
            mapper_type    <= 4'h0;
            status_val     <= 8'h00;
        end else if (csr_write_phase) begin
            $display("[SOC_CSR_WRITE] addr=%0d data=0x%02h", csr_write_addr, cpu_hwdata[7:0]);
            if (csr_write_addr == 2'b00) begin
                pokey_enable   <= cpu_hwdata[0];
                pokey_addr_sel <= cpu_hwdata[2:1];
                mapper_type    <= cpu_hwdata[7:4];
            end else if (csr_write_addr == 2'b01) begin
                status_val     <= cpu_hwdata[7:0];
            end
        end
    end

    // ------------------------------------------------------------------------
    // AHB Read Multiplexer
    // ------------------------------------------------------------------------
    reg [31:0] csr_rdata;
    always @(*) begin
        case (csr_raddr_reg)
            2'b00: csr_rdata = {24'h0, mapper_type, 1'b0, pokey_addr_sel, pokey_enable};
            2'b01: csr_rdata = {24'h0, status_val};
            2'b10: csr_rdata = {24'h0, trigger_val};
            default: csr_rdata = 32'h0;
        endcase
    end

    assign cpu_hrdata = is_fw_ram_rphase ? fw_ram_rdata :
                        is_spi_sd_rphase ? {24'h0, spi_rdata} :
                        is_csr_rphase    ? csr_rdata : 32'h0;

    assign cpu_hready = 1'b1; // Zero wait-state bus
    assign cpu_hresp  = 1'b0; // OKAY response

endmodule
`default_nettype wire
