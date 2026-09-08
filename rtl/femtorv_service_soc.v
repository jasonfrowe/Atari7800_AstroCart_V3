// ============================================================================
// Module: femtorv_service_soc
// Description: FemtoRV32-based service plane with local SRAM and MMIO bridge
//              for SD/FAT header probing telemetry and menu metadata window.
// ============================================================================

`default_nettype none

(* keep_hierarchy = "yes" *) module femtorv_service_soc #(
    parameter FIRMWARE_HEX = "femtorv_firmware.hex",
    parameter LOCAL_IRAM_EN = 1'b1,
    parameter MAILBOX_EN = 1'b1
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
    output reg         cart_ram_we,
    output reg  [15:0] cart_ram_addr,
    output reg  [7:0]  cart_ram_wdata,
    output wire [7:0] cpu_probe,
    output wire       sd_cs,
    output wire       sd_mosi,
    input  wire       sd_miso,
        output wire       sd_clk,
        output reg        psram_rd_req,
        output reg        psram_wr_req,
        output reg [21:0] psram_addr,
        output reg [15:0] psram_wdata,
        output reg        psram_byte_write,
        input  wire [15:0] psram_rdata,
        input  wire       psram_busy
);

    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wmask;
    reg  [31:0] mem_rdata;
    wire        mem_rstrb;
    reg         mem_rbusy;
    wire        mem_wbusy;

    wire is_iram = (mem_addr[31:13] == 19'h00000);
    wire is_iram_hit = LOCAL_IRAM_EN && is_iram;
    wire is_spi  = (mem_addr[31:28] == 4'h4);
    wire is_csr  = (mem_addr[31:28] == 4'hC);
        wire is_psram = (mem_addr[31:28] == 4'h2);
    wire is_cart_ram = (mem_addr[31:28] == 4'h8) || (mem_addr[31:28] == 4'hF);

    reg [10:0] iram_ad;
    reg [3:0]  iram_wre;
    reg [31:0] iram_din;
    wire [31:0] iram_dout;

    reg        read_pending;
    reg [2:0]  read_source;
    reg [31:0] read_addr;

    localparam [2:0] RD_NONE = 3'd0;
    localparam [2:0] RD_IRAM = 3'd1;
    localparam [2:0] RD_SPI  = 3'd2;
    localparam [2:0] RD_CSR  = 3'd3;
        localparam [2:0] RD_PSRAM = 3'd4;

        reg       psram_busy_d;
        reg [1:0] psram_rd_step;
        reg [15:0] psram_rd_lo;

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
        if (MAILBOX_EN && cart_meta_sel) begin
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

    generate
        if (LOCAL_IRAM_EN) begin : gen_local_iram
            (* ram_style = "distributed" *) reg [31:0] iram_mem [0:2047];
            reg [31:0] iram_dout_r;

            assign iram_dout = iram_dout_r;

            initial begin
                if (FIRMWARE_HEX != "") begin
                    $readmemh(FIRMWARE_HEX, iram_mem);
                end
            end

            always @(posedge clk) begin
                if (iram_wre[0]) iram_mem[iram_ad][7:0]   <= iram_din[7:0];
                if (iram_wre[1]) iram_mem[iram_ad][15:8]  <= iram_din[15:8];
                if (iram_wre[2]) iram_mem[iram_ad][23:16] <= iram_din[23:16];
                if (iram_wre[3]) iram_mem[iram_ad][31:24] <= iram_din[31:24];
                iram_dout_r <= iram_mem[iram_ad];
            end
        end else begin : gen_no_local_iram
            assign iram_dout = 32'h0000_0000;
        end
    endgenerate

    generate
        if (MAILBOX_EN) begin : gen_mailbox
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
        end else begin : gen_no_mailbox
            assign meta0_rdata = 8'hFF;
            assign meta1_rdata = 8'hFF;
        end
    endgenerate

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
                psram_rd_req <= 1'b0;
                psram_wr_req <= 1'b0;
                psram_addr <= 22'h0;
                psram_wdata <= 16'h0;
                psram_byte_write <= 1'b0;
                psram_busy_d <= 1'b0;
                psram_rd_step <= 2'b00;
                psram_rd_lo <= 16'h0;
            cart_ram_we  <= 1'b0;
            cart_ram_addr <= 16'h0000;
            cart_ram_wdata <= 8'h00;
        end else begin
            iram_wre   <= 4'b0000;
            meta_we    <= 1'b0;
            cart_ram_we <= 1'b0;
                psram_rd_req <= 1'b0;
                psram_wr_req <= 1'b0;
                psram_byte_write <= 1'b0;
                psram_busy_d <= psram_busy;

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

            if ((|mem_wmask) && is_iram_hit) begin
                iram_ad  <= mem_addr[12:2];
                iram_din <= mem_wdata;
                iram_wre <= mem_wmask;
            end else if ((|mem_wmask) && is_cart_ram) begin
                cart_ram_we   <= 1'b1;
                cart_ram_addr <= mem_addr[15:0];
                if (mem_wmask[0]) begin
                    cart_ram_wdata <= mem_wdata[7:0];
                end else if (mem_wmask[1]) begin
                    cart_ram_wdata <= mem_wdata[15:8];
                    cart_ram_addr <= mem_addr[15:0] + 16'd1;
                end else if (mem_wmask[2]) begin
                    cart_ram_wdata <= mem_wdata[23:16];
                    cart_ram_addr <= mem_addr[15:0] + 16'd2;
                end else if (mem_wmask[3]) begin
                    cart_ram_wdata <= mem_wdata[31:24];
                    cart_ram_addr <= mem_addr[15:0] + 16'd3;
                end
            end else if (MAILBOX_EN && (|mem_wmask) && is_meta) begin
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
                if (is_iram_hit) begin
                    iram_ad <= mem_addr[12:2];
                    read_source <= RD_IRAM;
                end else if (is_meta) begin
                    read_source <= RD_NONE;
                end else if (is_spi) begin
                    spi_cs_req <= 1'b1;
                    spi_we_req <= 1'b0;
                    spi_addr_req <= mem_addr[3:2];
                    read_source <= RD_SPI;
                end else if (is_csr) begin
                    read_source <= RD_CSR;
                    end else if (is_psram) begin
                        read_source <= RD_PSRAM;
                        psram_rd_step <= 2'b00;
                end else begin
                    read_source <= RD_NONE;
                end
                read_pending <= 1'b1;
            end else if (read_pending) begin
                case (read_source)
                    RD_IRAM: mem_rdata <= iram_dout;
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
                        RD_PSRAM: begin
                            case (psram_rd_step)
                                2'b00: begin
                                    if (!psram_busy) begin
                                        psram_addr <= {read_addr[21:2], 2'b00};
                                        psram_rd_req <= 1'b1;
                                        psram_rd_step <= 2'b01;
                                    end
                                end
                                2'b01: begin
                                    if (psram_busy_d && !psram_busy) begin
                                        psram_rd_lo <= psram_rdata;
                                        psram_rd_step <= 2'b10;
                                    end
                                end
                                2'b10: begin
                                    if (!psram_busy) begin
                                        psram_addr <= {read_addr[21:2], 2'b00} + 22'd2;
                                        psram_rd_req <= 1'b1;
                                        psram_rd_step <= 2'b11;
                                    end
                                end
                                default: begin
                                    if (psram_busy_d && !psram_busy) begin
                                        mem_rdata <= {psram_rdata, psram_rd_lo};
                                        read_pending <= 1'b0;
                                        read_source  <= RD_NONE;
                                        mem_rbusy    <= 1'b0;
                                        psram_rd_step <= 2'b00;
                                    end
                                end
                            endcase
                        end
                    default: mem_rdata <= 32'h0;
                endcase

                    if (read_source != RD_PSRAM) begin
                        read_pending <= 1'b0;
                        read_source  <= RD_NONE;
                        mem_rbusy    <= 1'b0;
                    end
            end
        end
    end

endmodule

`default_nettype wire
