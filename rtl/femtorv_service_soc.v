// ============================================================================
// Module: femtorv_service_soc
// Description: FemtoRV32 service plane with PSRAM execution, SD/FAT streaming,
//              cartridge RAM write port, and dual-port metadata window.
//              Consumes ZERO BSRAM blocks (firmware in PSRAM, metadata in LUTs).
// ============================================================================

`default_nettype none

(* keep_hierarchy = "yes" *) module femtorv_service_soc #(
    parameter FIRMWARE_HEX = "femtorv_firmware.hex"
)(
    input  wire        clk,           // 27 MHz onboard clock
    input  wire        rst_n,         // Active low reset
    input  wire [7:0]  trigger_val,   // From Atari write to $2200
    output reg  [7:0]  status_val,    // To Atari read of $7FF0
    output reg  [7:0]  debug0,        // To Atari read of $7FF1
    output reg  [7:0]  debug1,        // To Atari read of $7FF2
    output reg  [7:0]  debug2,        // To Atari read of $7FF3
    output reg  [7:0]  config_val = 8'h03, // POKEY enable/addr config from firmware
    input  wire [15:0] cart_addr,     // Atari address for metadata window ($E800-$E9FF)
    output reg  [7:0]  cart_rdata,    // Atari read data for metadata window
    output wire [7:0]  cpu_probe,

    // SD Card SPI interface
    output wire        sd_cs,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_clk,

    // Cartridge Game RAM write port (Loader stream)
    output reg         cart_ram_we,
    output reg  [15:0] cart_ram_addr,
    output reg  [7:0]  cart_ram_wdata,

    // Game RAM bootloader read port (DMA copy from Game RAM to PSRAM at power-on)
    output reg  [12:0] boot_raddr,
    input  wire [7:0]  boot_rdata,
    output reg         boot_busy,

    // PSRAM physical interface
    output wire [0:0]  O_psram_ck,
    output wire [0:0]  O_psram_ck_n,
    output wire [0:0]  O_psram_cs_n,
    inout  wire [0:0]  IO_psram_rwds,
    inout  wire [7:0]  IO_psram_dq,

    // 81 MHz clock output for Cartridge Game RAM clocking
    output wire        clk_81m_out
);

    // ------------------------------------------------------------------------
    // Clock Generation: 27 MHz -> 81 MHz via Gowin PLL
    // ------------------------------------------------------------------------
    wire clk_81m;
    wire clk_81m_p;
    wire pll_lock;

    gowin_pll u_pll (
        .clkin  (clk),
        .clkout (clk_81m),
        .clkoutp(clk_81m_p),
        .clkoutd(),
        .lock   (pll_lock)
    );

    assign clk_81m_out = clk_81m;
    wire soc_rst_n = rst_n & pll_lock;

    // ------------------------------------------------------------------------
    // PSRAM Controller Instance
    // ------------------------------------------------------------------------
    reg         psram_read;
    reg         psram_write;
    reg  [21:0] psram_addr;
    reg  [15:0] psram_din;
    reg         psram_bw;
    wire [15:0] psram_dout;
    wire        psram_busy;

    PsramController #(
        .FREQ   (81_000_000),
        .LATENCY(3)
    ) u_psram_ctrl (
        .clk          (clk_81m),
        .clk_p        (clk_81m_p),
        .resetn       (soc_rst_n),
        .read         (psram_read),
        .write        (psram_write),
        .addr         (psram_addr),
        .din          (psram_din),
        .byte_write   (psram_bw),
        .dout         (psram_dout),
        .busy         (psram_busy),
        .O_psram_ck   (O_psram_ck),
        .O_psram_ck_n (O_psram_ck_n),
        .IO_psram_rwds(IO_psram_rwds),
        .IO_psram_dq  (IO_psram_dq),
        .O_psram_cs_n (O_psram_cs_n)
    );

    // ------------------------------------------------------------------------
    // Power-On DMA Bootloader:
    // Copies 8KB (8192 bytes) from Game RAM blocks 0..3 into PSRAM address 0.
    // Takes ~0.5ms at 81MHz, then releases FemtoRV reset.
    // ------------------------------------------------------------------------
    reg [3:0]  dma_state;
    reg [12:0] boot_idx;
    reg [15:0] dma_calib_cnt;
    reg [7:0]  b0;
    reg [7:0]  b1;
    reg        femtorv_rst_n;

    localparam [3:0] DMA_WAIT_INIT = 4'd0;
    localparam [3:0] DMA_R0        = 4'd1;
    localparam [3:0] DMA_R0_WAIT   = 4'd2;
    localparam [3:0] DMA_R1        = 4'd3;
    localparam [3:0] DMA_R1_WAIT   = 4'd4;
    localparam [3:0] DMA_R2        = 4'd5;
    localparam [3:0] DMA_W0        = 4'd6;
    localparam [3:0] DMA_W1        = 4'd7;
    localparam [3:0] DMA_W2        = 4'd8;
    localparam [3:0] DMA_DONE      = 4'd9;

    // ------------------------------------------------------------------------
    // FemtoRV32 CPU Signals
    // ------------------------------------------------------------------------
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wmask;
    reg  [31:0] mem_rdata;
    wire        mem_rstrb;
    reg         mem_rbusy;
    reg         mem_wbusy;

    wire is_psram    = (mem_addr[31:28] == 4'h0);
    wire is_spi      = (mem_addr[31:28] == 4'h4);
    wire is_csr      = (mem_addr[31:28] == 4'hC);
    wire is_cart_ram = (mem_addr[31:28] == 4'hD);
    wire is_meta     = (mem_addr[31:28] == 4'hE);

    // ------------------------------------------------------------------------
    // FemtoRV <-> PSRAM Bridge Signals
    // ------------------------------------------------------------------------
    reg [3:0]  f_state;
    reg [15:0] r_word0;
    reg [31:0] latch_wdata;
    reg [3:0]  latch_wmask;
    reg [21:0] req_addr;

    localparam [3:0] F_IDLE     = 4'd0;
    localparam [3:0] F_RD0_REQ  = 4'd1;
    localparam [3:0] F_RD0_WAIT = 4'd2;
    localparam [3:0] F_RD1_REQ  = 4'd3;
    localparam [3:0] F_RD1_WAIT = 4'd4;
    localparam [3:0] F_WR0_REQ  = 4'd5;
    localparam [3:0] F_WR0_WAIT = 4'd6;
    localparam [3:0] F_WR1_REQ  = 4'd7;
    localparam [3:0] F_WR1_WAIT = 4'd8;


    // ------------------------------------------------------------------------
    // Metadata Window Storage: Legacy port tie-off (menu reads direct from Cart RAM)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        cart_rdata <= 8'h00;
    end

    // ------------------------------------------------------------------------
    // SPI MicroSD Controller (81 MHz)
    // ------------------------------------------------------------------------
    reg        spi_cs_req;
    reg        spi_we_req;
    reg [1:0]  spi_addr_req;
    reg [7:0]  spi_wdata_req;
    wire [7:0] spi_rdata;

    (* keep = "true", syn_keep = 1 *) spi_sd u_spi (
        .clk     (clk_81m),
        .rst_n   (soc_rst_n),
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

    // ------------------------------------------------------------------------
    // FemtoRV32 Processor Core
    // ------------------------------------------------------------------------
    (* keep = "true" *) FemtoRV32 #(
        .RESET_ADDR(32'h0000_0000),
        .ADDR_WIDTH(32)
    ) u_femtorv (
        .clk      (clk_81m),
        .mem_addr (mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask),
        .mem_rdata(mem_rdata),
        .mem_rstrb(mem_rstrb),
        .mem_rbusy(mem_rbusy),
        .mem_wbusy(mem_wbusy),
        .reset    (femtorv_rst_n)
    );

    assign cpu_probe = {mem_rstrb, (|mem_wmask), mem_addr[4:0], spi_rdata[0]};

    // ------------------------------------------------------------------------
    // Main FSM: DMA Bootloader + FemtoRV PSRAM Arbitration + MMIO
    // ------------------------------------------------------------------------
    reg        mmio_rd_pending;
    reg [2:0]  mmio_rd_src;
    reg [31:0] mmio_rd_addr;

    localparam [2:0] MMIO_NONE = 3'd0;
    localparam [2:0] MMIO_SPI  = 3'd1;
    localparam [2:0] MMIO_CSR  = 3'd2;

    always @(posedge clk_81m or negedge soc_rst_n) begin
        if (!soc_rst_n) begin
            boot_busy       <= 1'b1;
            boot_raddr      <= 13'd0;
            boot_idx        <= 13'd0;
            dma_state       <= DMA_WAIT_INIT;
            dma_calib_cnt   <= 16'd0;
            femtorv_rst_n   <= 1'b0;

            psram_read      <= 1'b0;
            psram_write     <= 1'b0;
            psram_addr      <= 22'd0;
            psram_din       <= 16'd0;
            psram_bw        <= 1'b0;

            f_state         <= F_IDLE;
            r_word0         <= 16'd0;
            latch_wdata     <= 32'd0;
            latch_wmask     <= 4'd0;
            req_addr        <= 22'd0;
            mem_rbusy       <= 1'b0;
            mem_wbusy       <= 1'b0;
            mem_rdata       <= 32'd0;

            status_val      <= 8'h00;
            debug0          <= 8'h00;
            debug1          <= 8'h00;
            debug2          <= 8'h00;
            config_val      <= 8'h03;

            cart_ram_we     <= 1'b0;
            cart_ram_addr   <= 16'd0;
            cart_ram_wdata  <= 8'h00;

            spi_cs_req      <= 1'b0;
            spi_we_req      <= 1'b0;
            spi_addr_req    <= 2'b00;
            spi_wdata_req   <= 8'h00;
            mmio_rd_pending <= 1'b0;
            mmio_rd_src     <= MMIO_NONE;
            mmio_rd_addr    <= 32'd0;
        end else begin
            cart_ram_we <= 1'b0;
            spi_we_req  <= 1'b0;

            // ================================================================
            // PHASE 1: DMA Bootloader (Game RAM -> PSRAM)
            // ================================================================
            if (boot_busy) begin
                case (dma_state)
                    DMA_WAIT_INIT: begin
                        // Wait ~250us (20,000 cycles at 81MHz) for PSRAM internal calibration
`ifdef VERILATOR
                        if (dma_calib_cnt < 16'd10) begin
`else
                        if (dma_calib_cnt < 16'd20000) begin
`endif
                            dma_calib_cnt <= dma_calib_cnt + 1'b1;
                        end else begin
                            boot_idx  <= 13'd0;
                            dma_state <= DMA_R0;
                        end
                    end

                    DMA_R0: begin
                        boot_raddr <= boot_idx;
                        dma_state  <= DMA_R0_WAIT;
                    end

                    DMA_R0_WAIT: begin
                        dma_state  <= DMA_R1;
                    end

                    DMA_R1: begin
                        b0         <= boot_rdata;
                        boot_raddr <= boot_idx + 13'd1;
                        dma_state  <= DMA_R1_WAIT;
                    end

                    DMA_R1_WAIT: begin
                        dma_state  <= DMA_R2;
                    end

                    DMA_R2: begin
                        b1        <= boot_rdata;
                        dma_state <= DMA_W0;
                    end

                    DMA_W0: begin
                        psram_write <= 1'b1;
                        psram_addr  <= {9'd0, boot_idx[12:1], 1'b0};
                        psram_din   <= {b1, b0};
                        psram_bw    <= 1'b0;
                        dma_state   <= DMA_W1;
                    end

                    DMA_W1: begin
                        psram_write <= 1'b0;
                        dma_state   <= DMA_W2;
                    end

                    DMA_W2: begin
                        if (!psram_busy) begin
                            if (boot_idx >= 13'd8190) begin
                                dma_state     <= DMA_DONE;
                                boot_busy     <= 1'b0;
                                femtorv_rst_n <= 1'b1; // Start FemtoRV!
                            end else begin
                                boot_idx  <= boot_idx + 13'd2;
                                dma_state <= DMA_R0;
                            end
                        end
                    end

                    DMA_DONE: begin
                        boot_busy <= 1'b0;
                    end

                    default: dma_state <= DMA_WAIT_INIT;
                endcase

            // ================================================================
            // PHASE 2: FemtoRV Active Execution from PSRAM & MMIO
            // ================================================================
            end else begin

                // --- MMIO Write Handling ---
                if (|mem_wmask) begin
                    if (is_cart_ram) begin
                        cart_ram_we    <= 1'b1;
                        cart_ram_addr  <= mem_addr[15:0];
                        cart_ram_wdata <= mem_wdata[7:0];
                    end else if (is_spi) begin
                        spi_cs_req    <= 1'b1;
                        spi_we_req    <= 1'b1;
                        spi_addr_req  <= mem_addr[3:2];
                        spi_wdata_req <= mem_wdata[7:0];
                    end else if (is_csr) begin
                        case (mem_addr[5:2])
                            4'h1: status_val <= mem_wdata[7:0];
                            4'h3: debug0     <= mem_wdata[7:0];
                            4'h4: debug1     <= mem_wdata[7:0];
                            4'h5: debug2     <= mem_wdata[7:0];
                            4'h6: config_val <= mem_wdata[7:0];
                            default: ;
                        endcase
                    end
                end

                // --- MMIO Read Handling ---
                if (!mmio_rd_pending && mem_rstrb && !is_psram) begin
                    mem_rbusy       <= 1'b1;
                    mmio_rd_pending <= 1'b1;
                    mmio_rd_addr    <= mem_addr;
                    if (is_spi) begin
                        spi_cs_req   <= 1'b1;
                        spi_we_req   <= 1'b0;
                        spi_addr_req <= mem_addr[3:2];
                        mmio_rd_src  <= MMIO_SPI;
                    end else if (is_csr) begin
                        mmio_rd_src  <= MMIO_CSR;
                    end else begin
                        mmio_rd_src  <= MMIO_NONE;
                    end
                end else if (mmio_rd_pending) begin
                    case (mmio_rd_src)
                        MMIO_SPI: mem_rdata <= {24'h0, spi_rdata};
                        MMIO_CSR: begin
                            case (mmio_rd_addr[5:2])
                                4'h1: mem_rdata <= {24'h0, status_val};
                                4'h2: mem_rdata <= {24'h0, trigger_val};
                                4'h3: mem_rdata <= {24'h0, debug0};
                                4'h4: mem_rdata <= {24'h0, debug1};
                                4'h5: mem_rdata <= {24'h0, debug2};
                                4'h6: mem_rdata <= {24'h0, config_val};
                                default: mem_rdata <= 32'h0;
                            endcase
                        end
                        default: mem_rdata <= 32'h0;
                    endcase
                    mmio_rd_pending <= 1'b0;
                    mmio_rd_src     <= MMIO_NONE;
                    mem_rbusy       <= 1'b0;
                end

                // --- PSRAM Access FSM ---
                case (f_state)
                    F_IDLE: begin
                        if (mem_rstrb && is_psram) begin
                            mem_rbusy   <= 1'b1;
                            req_addr    <= mem_addr[21:0];
                            psram_read  <= 1'b1;
                            psram_addr  <= {mem_addr[21:2], 2'b00};
                            f_state     <= F_RD0_REQ;
                        end else if ((|mem_wmask) && is_psram) begin
                            mem_wbusy   <= 1'b1;
                            req_addr    <= mem_addr[21:0];
                            latch_wdata <= mem_wdata;
                            latch_wmask <= mem_wmask;
                            if (mem_wmask[1:0] != 2'b00) begin
                                psram_write <= 1'b1;
                                psram_din   <= (mem_wmask[1:0] == 2'b10) ? {mem_wdata[15:8], 8'h00} : mem_wdata[15:0];
                                psram_bw    <= (mem_wmask[1:0] != 2'b11);
                                psram_addr  <= {mem_addr[21:2], 1'b0, mem_wmask[1] & !mem_wmask[0]};
                                f_state     <= F_WR0_REQ;
                            end else begin
                                psram_write <= 1'b1;
                                psram_din   <= (mem_wmask[3:2] == 2'b10) ? {mem_wdata[31:24], 8'h00} : mem_wdata[31:16];
                                psram_bw    <= (mem_wmask[3:2] != 2'b11);
                                psram_addr  <= {mem_addr[21:2], 1'b1, mem_wmask[3] & !mem_wmask[2]};
                                f_state     <= F_WR1_REQ;
                            end
                        end
                    end

                    F_RD0_REQ: begin
                        psram_read <= 1'b0;
                        f_state    <= F_RD0_WAIT;
                    end

                    F_RD0_WAIT: begin
                        if (!psram_busy) begin
                            r_word0    <= psram_dout;
                            psram_read <= 1'b1;
                            psram_addr <= {req_addr[21:2], 2'b10};
                            f_state    <= F_RD1_REQ;
                        end
                    end

                    F_RD1_REQ: begin
                        psram_read <= 1'b0;
                        f_state    <= F_RD1_WAIT;
                    end

                    F_RD1_WAIT: begin
                        if (!psram_busy) begin
                            mem_rdata <= {psram_dout, r_word0};
                            mem_rbusy <= 1'b0;
                            f_state   <= F_IDLE;
                        end
                    end

                    F_WR0_REQ: begin
                        psram_write <= 1'b0;
                        f_state     <= F_WR0_WAIT;
                    end

                    F_WR0_WAIT: begin
                        if (!psram_busy) begin
                            if (latch_wmask[3:2] != 2'b00) begin
                                psram_write <= 1'b1;
                                psram_din   <= (latch_wmask[3:2] == 2'b10) ? {latch_wdata[31:24], 8'h00} : latch_wdata[31:16];
                                psram_bw    <= (latch_wmask[3:2] != 2'b11);
                                psram_addr  <= {req_addr[21:2], 1'b1, latch_wmask[3] & !latch_wmask[2]};
                                f_state     <= F_WR1_REQ;
                            end else begin
                                mem_wbusy <= 1'b0;
                                f_state   <= F_IDLE;
                            end
                        end
                    end

                    F_WR1_REQ: begin
                        psram_write <= 1'b0;
                        f_state     <= F_WR1_WAIT;
                    end

                    F_WR1_WAIT: begin
                        if (!psram_busy) begin
                            mem_wbusy <= 1'b0;
                            f_state   <= F_IDLE;
                        end
                    end

                    default: f_state <= F_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
