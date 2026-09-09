// ============================================================================
// Module: femtorv_service_soc
// Description: FemtoRV32 service plane with PSRAM execution, SD/FAT streaming,
//              cartridge RAM write port, and dual-port metadata window.
//              Firmware runs from PSRAM; the only BSRAM this module uses is
//              the 512-byte SD sector capture buffer (sd_buffer).
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
    output wire        clk_81m_out,

    // DIAGNOSTIC: exposes the PLL lock signal so the top level can detect
    // any lock glitch, which would silently reset this whole SoC (status,
    // boot state, everything) via soc_rst_n without going through the
    // top-level warm-reset watchdog at all.
    output wire        pll_lock_out
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
    assign pll_lock_out = pll_lock;
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
        .FREQ   (54_000_000), // matches gowin_pll's reduced clk_81m rate (see gowin_pll.v)
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
    wire is_csr      = (mem_addr[31:28] == 4'hC);
    wire is_cart_ram = (mem_addr[31:28] == 4'hD);
    wire is_meta     = (mem_addr[31:28] == 4'hE);
    wire is_sdblk    = (mem_addr[31:28] == 4'h5);
    wire is_sdbuf    = is_sdblk && !mem_addr[9];   // 0x5000_0000-0x5000_01FF: 512-byte sector buffer
    wire is_sdctrl   = is_sdblk &&  mem_addr[9];   // 0x5000_0200+: LBA/trigger/status registers

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
    // Hardware SD block-read controller (ported from AstroCart V2, proven on
    // this exact board). Runs entirely in the clk_81m domain -- V2 needed a
    // separate clk_sd domain with cross-domain synchronizers only because it
    // shared the controller across two different clocks; here everything
    // (sd_controller, the byte-capture buffer, and the MMIO logic below) is
    // single-clock, so no CDC synchronizers are needed for these signals.
    // sd_controller.v internally handles the entire SD init sequence
    // (CMD0/CMD8/CMD55/CMD41) and a full 512-byte sector read autonomously;
    // firmware just supplies an LBA, pulses the trigger, and reads the
    // resulting bytes back out of sd_buffer[].
    // ------------------------------------------------------------------------
    reg  [31:0] sd_lba_reg;
    reg         sd_rd_req;
    reg         sd_op_busy;
    reg         sd_byte_avail_prev;
    wire        sd_ready_w;
    wire [7:0]  sd_dout_w;
    wire        sd_byte_avail_w;

    sd_controller u_sd (
        .cs                  (sd_cs),
        .mosi                (sd_mosi),
        .miso                (sd_miso),
        .sclk                (sd_clk),
        .rd                  (sd_rd_req),
        .dout                (sd_dout_w),
        .byte_available      (sd_byte_avail_w),
        .wr                  (1'b0),
        .din                 (8'h00),
        .ready_for_next_byte (),
        .reset               (!soc_rst_n),
        .ready               (sd_ready_w),
        .address             (sd_lba_reg),
        .clk                 (clk_81m),
        .status              (),
        .recv_data           ()
    );

    reg [9:0] sd_buf_widx;
    reg [7:0] sd_buffer [0:511];
    // sd_buf_widx/sd_buffer writes happen inside the main FSM always block
    // below (reset + trigger-restart + byte-capture all live there, so
    // sd_buf_widx has exactly one driver).

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

    assign cpu_probe = {mem_rstrb, (|mem_wmask), mem_addr[4:0], sd_byte_avail_w};

    // ------------------------------------------------------------------------
    // Main FSM: DMA Bootloader + FemtoRV PSRAM Arbitration + MMIO
    // ------------------------------------------------------------------------
    reg        mmio_rd_pending;
    reg [2:0]  mmio_rd_src;
    reg [31:0] mmio_rd_addr;

    localparam [2:0] MMIO_NONE  = 3'd0;
    localparam [2:0] MMIO_CSR   = 3'd2;
    localparam [2:0] MMIO_SDBUF = 3'd3;
    localparam [2:0] MMIO_SDCTL = 3'd4;

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

            sd_lba_reg      <= 32'd0;
            sd_rd_req       <= 1'b0;
            sd_op_busy      <= 1'b0;
            sd_byte_avail_prev <= 1'b0;
            sd_buf_widx     <= 10'd0;
            mmio_rd_pending <= 1'b0;
            mmio_rd_src     <= MMIO_NONE;
            mmio_rd_addr    <= 32'd0;
        end else begin
            cart_ram_we <= 1'b0;

            // SD hardware controller: capture each streamed byte into the
            // sector buffer, and detect the read-complete edge (sd_ready
            // rising again after having gone low) to clear the busy/request
            // latches. Runs unconditionally; harmless during boot_busy since
            // no read is ever triggered until firmware starts.
            //
            // sd_byte_avail_w is a LEVEL, not a pulse: sd_controller.v only
            // updates it on its own internal clock_enable-gated ticks (which
            // fire far less often than every clk_81m cycle), so it stays
            // high across many clk_81m cycles per byte. Must edge-detect it
            // here, or every one of those cycles re-captures the same byte
            // and corrupts the whole buffer.
            sd_byte_avail_prev <= sd_byte_avail_w;
            if (sd_byte_avail_w && !sd_byte_avail_prev) begin
                sd_buffer[sd_buf_widx[8:0]] <= sd_dout_w;
                sd_buf_widx            <= sd_buf_widx + 1'b1;
            end
            // "Done" is the 512th captured byte, NOT sd_ready_w rising: the
            // latter can (and does) go high slightly before the very last
            // byte has actually landed in sd_buffer, since sd_controller.v's
            // internal state can reach IDLE a cycle or two ahead of when
            // this capture logic reacts to the last byte_available edge --
            // firmware would then read stale/uninitialized tail bytes.
            // Tying completion to the byte counter itself can't race with
            // the capture it's counting.
            if (sd_op_busy && (sd_buf_widx == 10'd512)) begin
                sd_rd_req  <= 1'b0;
                sd_op_busy <= 1'b0;
            end

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
                    end else if (is_csr) begin
                        case (mem_addr[5:2])
                            4'h1: status_val <= mem_wdata[7:0];
                            4'h3: debug0     <= mem_wdata[7:0];
                            4'h4: debug1     <= mem_wdata[7:0];
                            4'h5: debug2     <= mem_wdata[7:0];
                            4'h6: config_val <= mem_wdata[7:0];
                            default: ;
                        endcase
                    end else if (is_sdctrl) begin
                        case (mem_addr[5:2])
                            4'h0: sd_lba_reg[7:0]   <= mem_wdata[7:0];
                            4'h1: sd_lba_reg[15:8]  <= mem_wdata[7:0];
                            4'h2: sd_lba_reg[23:16] <= mem_wdata[7:0];
                            4'h3: sd_lba_reg[31:24] <= mem_wdata[7:0];
                            4'h4: begin
                                // Kick off a hardware sector read using the
                                // LBA assembled via the four writes above.
                                sd_rd_req   <= 1'b1;
                                sd_op_busy  <= 1'b1;
                                sd_buf_widx <= 10'd0;
                            end
                            default: ;
                        endcase
                    end
                end

                // --- MMIO Read Handling ---
                if (!mmio_rd_pending && mem_rstrb && !is_psram) begin
                    mem_rbusy       <= 1'b1;
                    mmio_rd_pending <= 1'b1;
                    mmio_rd_addr    <= mem_addr;
                    if (is_csr) begin
                        mmio_rd_src  <= MMIO_CSR;
                    end else if (is_sdbuf) begin
                        mmio_rd_src  <= MMIO_SDBUF;
                    end else if (is_sdctrl) begin
                        mmio_rd_src  <= MMIO_SDCTL;
                    end else begin
                        mmio_rd_src  <= MMIO_NONE;
                    end
                end else if (mmio_rd_pending) begin
                    case (mmio_rd_src)
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
                        // femtorv32_quark's LBU picks its byte out of mem_rdata
                        // using mem_addr[1:0] as a lane select (see LOAD_byte /
                        // LOAD_halfword in femtorv32_quark.v) -- it does NOT
                        // assume byte 0. MMIO_CSR never hit this because every
                        // CSR address is 4-byte aligned (mem_addr[1:0]==0), but
                        // SDHW_BUF(i) is byte-addressed across all of 0..511,
                        // so 3 out of 4 offsets landed on a lane this register
                        // never populated, reading back as zero. Replicate the
                        // byte into all four lanes so every alignment works.
                        MMIO_SDBUF: mem_rdata <= {4{sd_buffer[mmio_rd_addr[8:0]]}};
                        // bit0 = a firmware-requested sector read is in flight
                        // bit1 = sd_controller's own ready signal (mirrors its
                        //        IDLE state -- 0 until its CMD0-CMD41 init
                        //        sequence completes, independent of bit0)
                        MMIO_SDCTL: mem_rdata <= {30'h0, sd_ready_w, sd_op_busy};
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
