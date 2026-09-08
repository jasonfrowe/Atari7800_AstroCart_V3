// ============================================================================
// Module: femtorv_service_soc
// Description: FemtoRV32-based service plane with local SRAM and MMIO bridge
//              for SD/FAT header probing telemetry and menu metadata window.
// ============================================================================

`default_nettype none

(* keep_hierarchy = "yes" *) module femtorv_service_soc #(
    parameter FIRMWARE_HEX = "femtorv_firmware.hex"
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] trigger_val,
    output reg  [7:0] status_val,
    output reg  [7:0] debug0,
    output reg  [7:0] debug1,
    output reg  [7:0] debug2,
    input  wire [15:0] cart_addr,
    output reg  [7:0] cart_rdata,
    output wire [7:0] cpu_probe,
    output wire       sd_cs,
    output wire       sd_mosi,
    input  wire       sd_miso,
    output wire       sd_clk
);

    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wmask;
    reg  [31:0] mem_rdata;
    wire        mem_rstrb;
    reg         mem_rbusy;
    wire        mem_wbusy;

    wire is_iram = (mem_addr[31:13] == 19'h00000);
    wire is_dram = (mem_addr[31:13] == 19'h00001);
    wire is_spi  = (mem_addr[31:28] == 4'h4);
    wire is_csr  = (mem_addr[31:28] == 4'hC);

    reg [10:0] iram_ad;
    reg [3:0]  iram_wre;
    reg [31:0] iram_din;
    wire [31:0] iram_dout;

    reg [10:0] dram_ad;
    reg [3:0]  dram_wre;
    reg [31:0] dram_din;
    wire [31:0] dram_dout;

    reg        read_pending;
    reg [2:0]  read_source;
    reg [31:0] read_addr;

    localparam [2:0] RD_NONE = 3'd0;
    localparam [2:0] RD_IRAM = 3'd1;
    localparam [2:0] RD_DRAM = 3'd2;
    localparam [2:0] RD_SPI  = 3'd3;
    localparam [2:0] RD_CSR  = 3'd4;

    reg        spi_cs_req;
    reg        spi_we_req;
    reg [1:0]  spi_addr_req;
    reg [7:0]  spi_wdata_req;

    wire [7:0] spi_rdata;
    wire is_meta = (mem_addr[31:28] == 4'hE);

    wire [7:0] cart_meta_off = cart_addr[7:0];
    wire       cart_meta_sel = (cart_addr[15:8] == 8'hE8) || (cart_addr[15:8] == 8'hE9);

    reg        meta_we;
    reg [8:0]  meta_addr;
    reg [7:0]  meta_wdata;
    reg [7:0]  meta_raddr_cart;
    reg        meta_bank_cart;

    wire [7:0] meta0_rdata;
    wire [7:0] meta1_rdata;

    wire       meta0_we = meta_we && (meta_addr[8] == 1'b0);
    wire       meta1_we = meta_we && (meta_addr[8] == 1'b1);

    // Export live bus activity bits; include SPI readback bit to keep the SPI
    // bridge in-use for synthesis even before full firmware bring-up.
    assign cpu_probe = {mem_rstrb, (|mem_wmask), mem_addr[4:0], spi_rdata[0]};

    always @(*) begin
        if (cart_meta_sel) begin
            cart_rdata = meta_bank_cart ? meta1_rdata : meta0_rdata;
        end else begin
            cart_rdata = 8'hFF;
        end
    end

    (* keep = "true" *) FemtoRV32 #(
        .RESET_ADDR(32'h0000_0000),
        .ADDR_WIDTH(32)
    ) u_femtorv (
        .clk      (clk),
        .mem_addr (mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask),
        .mem_rdata(mem_rdata),
        .mem_rstrb(mem_rstrb),
        .mem_rbusy(mem_rbusy),
        .mem_wbusy(mem_wbusy),
        .reset    (rst_n)
    );

    gowin_sp_be32 #(
        .INIT_FILE(FIRMWARE_HEX)
    ) u_iram (
        .clk   (clk),
        .ce    (1'b1),
        .oce   (1'b1),
        .reset (~rst_n),
        .ad    (iram_ad),
        .din   (iram_din),
        .wre   (iram_wre),
        .dout  (iram_dout)
    );

    gowin_sp_be32 #(
        .INIT_FILE("")
    ) u_dram (
        .clk   (clk),
        .ce    (1'b1),
        .oce   (1'b1),
        .reset (~rst_n),
        .ad    (dram_ad),
        .din   (dram_din),
        .wre   (dram_wre),
        .dout  (dram_dout)
    );

    gowin_sdpb_mailbox u_meta_bank0 (
        .clk    (clk),
        .rst    (~rst_n),
        .a_we   (meta0_we),
        .a_addr (meta_addr[7:0]),
        .a_wdata(meta_wdata),
        .b_addr (meta_raddr_cart),
        .b_rdata(meta0_rdata)
    );

    gowin_sdpb_mailbox u_meta_bank1 (
        .clk    (clk),
        .rst    (~rst_n),
        .a_we   (meta1_we),
        .a_addr (meta_addr[7:0]),
        .a_wdata(meta_wdata),
        .b_addr (meta_raddr_cart),
        .b_rdata(meta1_rdata)
    );

    (* keep = "true", syn_keep = 1, dont_touch = "true" *) spi_sd u_spi (
        .clk     (clk),
        .rst_n   (rst_n),
        .cs      (spi_cs_req),
        .we      (spi_we_req),
        .addr    (spi_addr_req),
        .wdata   (spi_wdata_req),
        .rdata   (spi_rdata),
        .sd_cs   (sd_cs),
        .sd_mosi (sd_mosi),
        .sd_miso (sd_miso),
        .sd_clk  (sd_clk)
    );

    assign mem_wbusy = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status_val   <= 8'h00;
            debug0       <= 8'h00;
            debug1       <= 8'h00;
            debug2       <= 8'h00;
            iram_ad      <= 11'd0;
            iram_wre     <= 4'b0000;
            iram_din     <= 32'h0;
            dram_ad      <= 11'd0;
            dram_wre     <= 4'b0000;
            dram_din     <= 32'h0;
            mem_rdata    <= 32'h0;
            mem_rbusy    <= 1'b0;
            read_pending <= 1'b0;
            read_source  <= RD_NONE;
            read_addr    <= 32'h0;
            meta_we      <= 1'b0;
            meta_addr    <= 9'h000;
            meta_wdata   <= 8'h00;
            meta_raddr_cart <= 8'h00;
            meta_bank_cart  <= 1'b0;
            spi_cs_req   <= 1'b0;
            spi_we_req   <= 1'b0;
            spi_addr_req <= 2'b00;
            spi_wdata_req <= 8'h00;
        end else begin
            iram_wre   <= 4'b0000;
            dram_wre   <= 4'b0000;
            meta_we    <= 1'b0;

            // Continuously sample cart metadata read address for synchronous RAM B-port.
            meta_raddr_cart <= cart_meta_off;
            meta_bank_cart  <= cart_addr[8];

            // Optional external SPI probe mode via trigger bit 6.
            spi_cs_req <= trigger_val[6];
            spi_we_req <= 1'b0;
            if (trigger_val[6]) begin
                spi_addr_req <= 2'b00;
                spi_wdata_req <= 8'hFF;
            end

            if ((|mem_wmask) && is_iram) begin
                iram_ad  <= mem_addr[12:2];
                iram_din <= mem_wdata;
                iram_wre <= mem_wmask;
            end else if ((|mem_wmask) && is_dram) begin
                dram_ad  <= mem_addr[12:2];
                dram_din <= mem_wdata;
                dram_wre <= mem_wmask;
            end else if ((|mem_wmask) && is_meta) begin
                // Phase C firmware writes metadata window via byte stores.
                if (mem_wmask[0]) begin
                    meta_we    <= 1'b1;
                    meta_addr  <= mem_addr[8:0];
                    meta_wdata <= mem_wdata[7:0];
                end else if (mem_wmask[1]) begin
                    meta_we    <= 1'b1;
                    meta_addr  <= mem_addr[8:0] + 9'd1;
                    meta_wdata <= mem_wdata[15:8];
                end else if (mem_wmask[2]) begin
                    meta_we    <= 1'b1;
                    meta_addr  <= mem_addr[8:0] + 9'd2;
                    meta_wdata <= mem_wdata[23:16];
                end else if (mem_wmask[3]) begin
                    meta_we    <= 1'b1;
                    meta_addr  <= mem_addr[8:0] + 9'd3;
                    meta_wdata <= mem_wdata[31:24];
                end
            end else if ((|mem_wmask) && is_spi) begin
                spi_cs_req    <= 1'b1;
                spi_we_req    <= 1'b1;
                spi_addr_req  <= mem_addr[3:2];
                spi_wdata_req <= mem_wdata[7:0];
            end else if ((|mem_wmask) && is_csr) begin
                case (mem_addr[5:2])
                    4'h1: status_val <= mem_wdata[7:0];
                    4'h3: debug0 <= mem_wdata[7:0];
                    4'h4: debug1 <= mem_wdata[7:0];
                    4'h5: debug2 <= mem_wdata[7:0];
                    default: begin
                    end
                endcase
            end

            if (!read_pending && mem_rstrb) begin
                mem_rbusy <= 1'b1;
                read_addr <= mem_addr;
                if (is_iram) begin
                    iram_ad <= mem_addr[12:2];
                    read_source <= RD_IRAM;
                end else if (is_dram) begin
                    dram_ad <= mem_addr[12:2];
                    read_source <= RD_DRAM;
                end else if (is_meta) begin
                    read_source <= RD_NONE;
                end else if (is_spi) begin
                    spi_cs_req <= 1'b1;
                    spi_we_req <= 1'b0;
                    spi_addr_req <= mem_addr[3:2];
                    read_source <= RD_SPI;
                end else if (is_csr) begin
                    read_source <= RD_CSR;
                end else begin
                    read_source <= RD_NONE;
                end
                read_pending <= 1'b1;
            end else if (read_pending) begin
                case (read_source)
                    RD_IRAM: mem_rdata <= iram_dout;
                    RD_DRAM: mem_rdata <= dram_dout;
                    RD_SPI:  mem_rdata <= {24'h0, spi_rdata};
                    RD_CSR: begin
                        case (read_addr[5:2])
                            4'h1: mem_rdata <= {24'h0, status_val};
                            4'h2: mem_rdata <= {24'h0, trigger_val};
                            4'h3: mem_rdata <= {24'h0, debug0};
                            4'h4: mem_rdata <= {24'h0, debug1};
                            4'h5: mem_rdata <= {24'h0, debug2};
                            default: mem_rdata <= 32'h0;
                        endcase
                    end
                    default: mem_rdata <= 32'h0;
                endcase

                read_pending <= 1'b0;
                read_source  <= RD_NONE;
                mem_rbusy    <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
