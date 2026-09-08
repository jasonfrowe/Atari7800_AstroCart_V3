// ============================================================================
// Module: atari_cart_top
// Description: Atari 7800 Multi-Cart Top Level HDL with Full Write Passthrough
// Target: Sipeed Tang Nano 9K (Gowin GW1NR-9)
// ============================================================================

`default_nettype none

module atari_cart_top #(
    parameter FW_INIT_FILE = "firmware.hex",
    parameter H5_SIDEBAND_EN = 1'b0,
    parameter H5_FW_RAM_EN = 1'b1,
    parameter H5_MAILBOX_EN = 1'b1,
    parameter H5_SPI_EN = 1'b1
)(
    // System Clock & Resets
    input  wire        clk,          // 27 MHz onboard clock

    // Atari 7800 Bus Pins (via SN74LVC level shifters per PINS.md)
    input  wire        phi2,         // Atari CPU Phase 2 clock (~1.79 MHz)
    input  wire        rw,           // Read (1) / Write (0)
    input  wire [15:0] a,            // Address bus [15:0]
    inout  wire [7:0]  d,            // Data bus [7:0] (bidirectional)
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        halt,         // MARIA HALT input
    /* verilator lint_on UNUSEDSIGNAL */
    output wire        irq,          // Active low IRQ output (open-drain / tri-state high)

    // SN74LVC245 Buffer Control Signals (U3)
    output wire        buf_dir,      // U3_DIR: 1 = FPGA->Atari (Read), 0 = Atari->FPGA (Write/Idle)
    output wire        buf_oe,       // U3_OE: 0 = Active, 1 = Tri-state/High-Z

    // Audio Output Pin
    output wire        audio,        // T_EAUD audio pin (PWM/Delta-Sigma)

    // MicroSD Card SPI Hardware Pins per PINS.md
    output wire        sd_cs,        // Pin 38
    output wire        sd_mosi,      // Pin 37
    input  wire        sd_miso,      // Pin 39
    output wire        sd_clk,       // Pin 36

    // On-board HyperRAM/PSRAM interface
    output wire [0:0]  O_psram_ck,
    output wire [0:0]  O_psram_ck_n,
    output wire [0:0]  O_psram_cs_n,
    output wire [0:0]  O_psram_reset_n,
    inout  wire [0:0]  IO_psram_rwds,
    inout  wire [7:0]  IO_psram_dq,

    // Debug LEDs
    output wire [5:0]  led
);

    // ------------------------------------------------------------------------
    // Internal Power-On Reset (POR) Generator
    // Holds rst_n Low for ~4,096 cycles (~151 us) after FPGA bitstream boot,
    // then smoothly releases rst_n to High continuously.
    // ------------------------------------------------------------------------
    reg [11:0] por_counter = 12'd0;
    reg        rst_n = 1'b0;

    always @(posedge clk) begin
        if (por_counter < 12'd4095) begin
            por_counter <= por_counter + 1'b1;
            rst_n       <= 1'b0;
        end else begin
            rst_n       <= 1'b1;
        end
    end

    // Console warm-reset assist: if PHI2 disappears for a long window,
    // force an internal reset pulse so the cart cleanly re-initializes when PHI2 returns.
    reg [19:0] phi2_idle_ctr = 20'd0;
    reg [11:0] warm_rst_ctr  = 12'd0;
    reg        warm_rst_n    = 1'b0;

    // ------------------------------------------------------------------------
    // Noise-Filtered Synchronizers for Atari 7800 Signals (27MHz System Clock)
    // ------------------------------------------------------------------------
    reg [1:0] phi2_pipe;
    reg [2:0] rw_pipe;
    reg [15:0] a_pipe;
    reg [15:0] a_sync;
    reg [7:0] d_in_sync;
    reg       phi2_clean;

    always @(posedge clk) begin
        phi2_pipe <= {phi2_pipe[0], phi2};
        rw_pipe   <= {rw_pipe[1:0], rw};
        a_pipe    <= a;
        if (a_pipe == a)
            a_sync <= a;
        d_in_sync <= d;

        // Use a fast synchronized PHI2 view; longer majority filtering proved too slow
        // on MARIA-heavy fetch bursts.
        phi2_clean <= phi2_pipe[1];
    end

    reg phi2_clean_prev;
    always @(posedge clk) begin
        phi2_clean_prev <= phi2_clean;
    end

    wire phi2_high  = phi2_clean;
    wire phi2_rise  = (phi2_clean && !phi2_clean_prev);
    wire rw_is_read = rw_pipe[1];
    wire core_rst_n = rst_n && warm_rst_n;

    always @(posedge clk) begin
        if (phi2_rise)
            phi2_idle_ctr <= 20'd0;
        else if (phi2_idle_ctr != 20'hFFFFF)
            phi2_idle_ctr <= phi2_idle_ctr + 1'b1;

        if (phi2_idle_ctr == 20'hFFFFF) begin
            warm_rst_n   <= 1'b0;
            warm_rst_ctr <= 12'd0;
        end else if (!warm_rst_n) begin
            if (warm_rst_ctr < 12'd4095)
                warm_rst_ctr <= warm_rst_ctr + 1'b1;
            else
                warm_rst_n <= 1'b1;
        end
    end

    // ------------------------------------------------------------------------
    // Menu-first dual-image mode
    // ------------------------------------------------------------------------
    localparam [15:0] GAME_BYTES = 16'd49152; // 48KB Astrowing payload
    localparam [15:0] MENU_BYTES = 16'd8192;  // 8KB menu payload

    wire       pokey_enable;
    wire [1:0] pokey_addr_sel = 2'b01; // $0450 per Astrowing A78 header
    wire [3:0] mapper_type    = 4'h0;  // Flat linear mapping

    reg        game_mode;
    reg        switch_pending;
    reg [15:0] switch_delay;
    reg        game_ready;
    reg        post_ack_pending;
    reg [15:0] post_ack_delay;
    reg        trig_wr_prev;
    reg [7:0]  trigger_val_sideband;

    localparam [15:0] POST_ACK_DELAY = 16'd120;

    wire is_trigger_write = phi2_high && !rw_is_read && (a_sync == 16'h2200);

    assign pokey_enable = game_mode;

    // ------------------------------------------------------------------------
    // Sideband service plane routing.
    // Enable H5_SIDEBAND_EN=1 to source status + metadata window from FemtoRV.
    // ------------------------------------------------------------------------
    wire       sideband_sd_cs;
    wire       sideband_sd_mosi;
    wire       sideband_sd_clk;
    wire [7:0] sideband_status_val;
    wire [7:0] sideband_meta_rdata;
    wire       sideband_cart_ram_we;
    wire [15:0] sideband_cart_ram_addr;
    wire [7:0] sideband_cart_ram_wdata;
    wire       sideband_psram_rd_req;
    wire       sideband_psram_wr_req;
    wire [21:0] sideband_psram_addr;
    wire [15:0] sideband_psram_wdata;
    wire       sideband_psram_byte_write;
    wire [15:0] sideband_psram_rdata;
    wire       sideband_psram_busy;

    generate
        if (H5_SIDEBAND_EN) begin : gen_h5_sideband
            wire       svc_sd_cs;
            wire       svc_sd_mosi;
            wire       svc_sd_clk;
            wire [7:0] svc_status_val;
            wire [7:0] svc_meta_rdata;
            wire       svc_cart_ram_we;
            wire [15:0] svc_cart_ram_addr;
            wire [7:0] svc_cart_ram_wdata;
            wire       svc_psram_rd_req;
            wire       svc_psram_wr_req;
            wire [21:0] svc_psram_addr;
            wire [15:0] svc_psram_wdata;
            wire       svc_psram_byte_write;
            wire [15:0] svc_psram_rdata;
            wire       svc_psram_busy;

            femtorv_service_soc #(
                .FIRMWARE_HEX(FW_INIT_FILE),
                .LOCAL_IRAM_EN(H5_FW_RAM_EN),
                .MAILBOX_EN(H5_MAILBOX_EN)
            ) u_service (
                .clk        (clk),
                .rst_n      (core_rst_n),
                .trigger_val(trigger_val_sideband),
                .status_val (svc_status_val),
                .debug0     (),
                .debug1     (),
                .debug2     (),
                .cart_addr  (a_sync),
                .cart_rdata (svc_meta_rdata),
                .cart_ram_we(svc_cart_ram_we),
                .cart_ram_addr(svc_cart_ram_addr),
                .cart_ram_wdata(svc_cart_ram_wdata),
                .cpu_probe  (),
                .sd_cs      (svc_sd_cs),
                .sd_mosi    (svc_sd_mosi),
                .sd_miso    (sd_miso),
                .sd_clk     (svc_sd_clk),
                .psram_rd_req(svc_psram_rd_req),
                .psram_wr_req(svc_psram_wr_req),
                .psram_addr (svc_psram_addr),
                .psram_wdata(svc_psram_wdata),
                .psram_byte_write(svc_psram_byte_write),
                .psram_rdata(svc_psram_rdata),
                .psram_busy (svc_psram_busy)
            );

            // Service-only PSRAM controller path. Atari bus reads remain on BSRAM chunks.
            PsramController #(
                .FREQ(27_000_000),
                .LATENCY(3)
            ) u_service_psram (
                .clk(clk),
                .clk_p(clk),
                .resetn(core_rst_n),
                .read(svc_psram_rd_req),
                .write(svc_psram_wr_req),
                .addr(svc_psram_addr),
                .din(svc_psram_wdata),
                .byte_write(svc_psram_byte_write),
                .dout(svc_psram_rdata),
                .busy(svc_psram_busy),
                .O_psram_ck(O_psram_ck),
                .O_psram_ck_n(O_psram_ck_n),
                .IO_psram_rwds(IO_psram_rwds),
                .IO_psram_dq(IO_psram_dq),
                .O_psram_cs_n(O_psram_cs_n)
            );

            assign sideband_sd_cs      = svc_sd_cs;
            assign sideband_sd_mosi    = svc_sd_mosi;
            assign sideband_sd_clk     = svc_sd_clk;
            assign sideband_status_val = svc_status_val;
            assign sideband_meta_rdata = svc_meta_rdata;
            assign sideband_cart_ram_we = svc_cart_ram_we;
            assign sideband_cart_ram_addr = svc_cart_ram_addr;
            assign sideband_cart_ram_wdata = svc_cart_ram_wdata;
            assign sideband_psram_rd_req = svc_psram_rd_req;
            assign sideband_psram_wr_req = svc_psram_wr_req;
            assign sideband_psram_addr = svc_psram_addr;
            assign sideband_psram_wdata = svc_psram_wdata;
            assign sideband_psram_byte_write = svc_psram_byte_write;
            assign sideband_psram_rdata = svc_psram_rdata;
            assign sideband_psram_busy = svc_psram_busy;
        end else begin : gen_no_h5_sideband
            assign sideband_sd_cs      = 1'b1;
            assign sideband_sd_mosi    = 1'b0;
            assign sideband_sd_clk     = 1'b0;
            assign sideband_status_val = 8'h00;
            assign sideband_meta_rdata = 8'hFF;
            assign sideband_cart_ram_we = 1'b0;
            assign sideband_cart_ram_addr = 16'h0000;
            assign sideband_cart_ram_wdata = 8'h00;
            assign sideband_psram_rd_req = 1'b0;
            assign sideband_psram_wr_req = 1'b0;
            assign sideband_psram_addr = 22'h0;
            assign sideband_psram_wdata = 16'h0;
            assign sideband_psram_byte_write = 1'b0;
            assign sideband_psram_rdata = 16'h0;
            assign sideband_psram_busy = 1'b0;
            assign O_psram_ck[0] = 1'b0;
            assign O_psram_ck_n[0] = 1'b1;
            assign O_psram_cs_n[0] = 1'b1;
            assign IO_psram_dq = 8'hZZ;
            assign IO_psram_rwds[0] = 1'bZ;
        end
    endgenerate

    assign O_psram_reset_n[0] = 1'b1;

    assign sd_cs   = sideband_sd_cs;
    assign sd_mosi = sideband_sd_mosi;
    assign sd_clk  = sideband_sd_clk;

    // ------------------------------------------------------------------------
    // Address Decoding & Memory Mapping
    // ------------------------------------------------------------------------
    wire is_cart_addr  = (a_sync >= 16'h4000);
    wire is_status_addr = (a_sync == 16'h7FF0);
    wire is_meta_addr = (a_sync >= 16'hE800) && (a_sync <= 16'hE9FF);
    wire is_menu_addr = (a_sync >= 16'hE000);
    wire is_pokey_4000 = (a_sync[15:4] == 12'h400); // $4000-$400F
    wire is_pokey_0450 = (a_sync[15:4] == 12'h045); // $0450-$045F
    wire is_pokey_0800 = (a_sync[15:4] == 12'h080); // $0800-$080F

    wire is_pokey_addr = (pokey_addr_sel == 2'b00) ? is_pokey_4000 :
                         (pokey_addr_sel == 2'b01) ? is_pokey_0450 :
                         (pokey_addr_sel == 2'b10) ? is_pokey_0800 :
                                                     1'b0;

    // SuperGame Bankswitch Mapper Module
    wire [18:0] phys_rom_addr;

    mapper_supergame u_mapper (
        .clk            (clk),
        .rst_n          (core_rst_n),
        .phi2_high      (phi2_high),
        .phi2_rise      (phi2_rise),
        .cs             (is_cart_addr),
        .rw             (rw_is_read),
        .addr           (a_sync),
        .din            (d_in_sync),
        .mapper_type    (mapper_type),
        .phys_rom_addr  (phys_rom_addr)
    );

    // ------------------------------------------------------------------------
    // Cartridge ROM Memory
    // ------------------------------------------------------------------------
    wire [7:0] chunk_rdata [0:23];
    wire [7:0] menu_data_out;
    wire [7:0] menu_data_from_chunks;
    wire [7:0] menu_data_from_block;
    wire [4:0] cart_wr_chunk_sel = sideband_cart_ram_addr[15:11];
    wire [10:0] cart_wr_addr = sideband_cart_ram_addr[10:0];

    generate
        if (H5_SIDEBAND_EN) begin : gen_sideband_menu_overlay_init
            cart_block_2k #(.INIT_FILE("menu_chunk_00.hex")) u_rom_00 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[0]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd0)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
            cart_block_2k #(.INIT_FILE("menu_chunk_01.hex")) u_rom_01 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[1]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd1)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
            cart_block_2k #(.INIT_FILE("menu_chunk_02.hex")) u_rom_02 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[2]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd2)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
            cart_block_2k #(.INIT_FILE("menu_chunk_03.hex")) u_rom_03 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[3]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd3)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
        end else begin : gen_default_game_init_low
            cart_block_2k #(.INIT_FILE("rom_chunk_00.hex")) u_rom_00 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[0]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd0)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
            cart_block_2k #(.INIT_FILE("rom_chunk_01.hex")) u_rom_01 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[1]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd1)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
            cart_block_2k #(.INIT_FILE("rom_chunk_02.hex")) u_rom_02 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[2]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd2)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
            cart_block_2k #(.INIT_FILE("rom_chunk_03.hex")) u_rom_03 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[3]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd3)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
        end
    endgenerate
    cart_block_2k #(.INIT_FILE("rom_chunk_04.hex")) u_rom_04 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[4]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd4)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_05.hex")) u_rom_05 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[5]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd5)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_06.hex")) u_rom_06 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[6]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd6)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_07.hex")) u_rom_07 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[7]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd7)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_08.hex")) u_rom_08 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[8]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd8)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_09.hex")) u_rom_09 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[9]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd9)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_10.hex")) u_rom_10 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[10]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd10)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_11.hex")) u_rom_11 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[11]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd11)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_12.hex")) u_rom_12 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[12]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd12)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_13.hex")) u_rom_13 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[13]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd13)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_14.hex")) u_rom_14 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[14]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd14)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_15.hex")) u_rom_15 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[15]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd15)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_16.hex")) u_rom_16 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[16]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd16)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_17.hex")) u_rom_17 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[17]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd17)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_18.hex")) u_rom_18 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[18]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd18)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_19.hex")) u_rom_19 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[19]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd19)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_20.hex")) u_rom_20 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[20]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd20)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_21.hex")) u_rom_21 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[21]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd21)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_22.hex")) u_rom_22 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[22]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd22)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));
    cart_block_2k #(.INIT_FILE("rom_chunk_23.hex")) u_rom_23 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[23]), .we(sideband_cart_ram_we && (cart_wr_chunk_sel == 5'd23)), .waddr(cart_wr_addr), .wdata(sideband_cart_ram_wdata));

    wire [1:0] menu_chunk_sel = a_sync[12:11];
    assign menu_data_from_chunks = chunk_rdata[menu_chunk_sel];

    generate
        if (H5_SIDEBAND_EN) begin : gen_menu_from_chunks
            assign menu_data_out = menu_data_from_chunks;
        end else begin : gen_menu_from_block
            menu_block_8k #(.INIT_FILE("menu_word_chunk_00.hex")) u_menu_rom (
                .clk(clk),
                .raddr(a_sync[12:0]),
                .rdata(menu_data_from_block)
            );
            assign menu_data_out = menu_data_from_block;
        end
    endgenerate

    wire [4:0] rom_chunk_sel = phys_rom_addr[15:11];
    wire [7:0] rom_data_out = (rom_chunk_sel < 5'd24) ? chunk_rdata[rom_chunk_sel] : 8'hFF;

    // ------------------------------------------------------------------------
    // POKEY Sound Synthesizer Core Integration
    // ------------------------------------------------------------------------
    wire [7:0] pokey_dout;
    wire [7:0] pcm_audio;

    pokey_synth u_pokey (
        .clk        (clk),
        .rst_n      (core_rst_n),
        .phi2_rise  (phi2_rise),
        .cs         (pokey_enable && is_pokey_addr),
        .rw         (rw_is_read),
        .addr       (a_sync[3:0]),
        .din        (d_in_sync),
        .dout       (pokey_dout),
        .audio_out  (pcm_audio)
    );

    // Audio PWM Modulator on Pin 76 (T_EAUD)
    audio_pwm u_pwm (
        .clk        (clk),
        .rst_n      (core_rst_n),
        .level      (pcm_audio),
        .pwm_out    (audio)
    );

    // ------------------------------------------------------------------------
    // Dynamic Data Bus Output Selection & Level Shifter Controls (U3 SN74LVC245)
    // ------------------------------------------------------------------------
    // The cart responds in normal cartridge space plus the selected POKEY window.
    wire is_fpga_response_addr = is_cart_addr || (pokey_enable && is_pokey_addr);

    // Decode read/write intent from synchronized Atari control signals.
    wire is_bus_read  = is_fpga_response_addr && rw_is_read;

    // U3 Buffer Direction (U3_DIR): 1 = FPGA->Atari (Read), 0 = Atari->FPGA (Write/Idle)
    assign buf_dir = is_bus_read;

    // Keep transceiver enabled continuously; direction + FPGA tri-state controls who drives.
    assign buf_oe  = 1'b0;

    // FPGA Internal Data Bus Drive Logic
    wire drive_pokey = pokey_enable && is_pokey_addr && rw_is_read;
    wire [7:0] status_data_out = sideband_status_val;
    wire [7:0] menu_meta_data_out = (H5_SIDEBAND_EN && is_meta_addr) ? sideband_meta_rdata : menu_data_out;
    wire [7:0] menu_bus_data_out = is_status_addr ? status_data_out :
                                   (is_menu_addr ? menu_meta_data_out : 8'hFF);
    wire [7:0] bus_data_out = game_mode ? (drive_pokey ? pokey_dout : rom_data_out)
                                        : menu_bus_data_out;

    // Drive when this cart owns a read cycle.
    assign d   = (is_bus_read && (buf_dir == 1'b1)) ? bus_data_out : 8'hZZ;
    assign irq = 1'b0; // Drive 0V to Q3 Gate (Transistor OFF -> HALT floats HIGH via 5V motherboard pull-up)

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            game_mode      <= 1'b0;
            switch_pending <= 1'b0;
            switch_delay   <= 16'd0;
            game_ready     <= 1'b0;
            post_ack_pending <= 1'b0;
            post_ack_delay <= 16'd0;
            trig_wr_prev   <= 1'b0;
            trigger_val_sideband <= 8'h00;
        end else begin
            trig_wr_prev <= is_trigger_write;

            if (is_trigger_write && !trig_wr_prev)
                trigger_val_sideband <= d_in_sync;

            if (post_ack_pending) begin
                if (post_ack_delay >= POST_ACK_DELAY) begin
                    game_mode        <= 1'b1;
                    post_ack_pending <= 1'b0;
                    post_ack_delay   <= 16'd0;
                end else begin
                    post_ack_delay <= post_ack_delay + 1'b1;
                end
            end

            if (switch_pending && !game_ready) begin
                if (switch_delay == 16'd4095)
                    game_ready <= 1'b1;
                else
                    switch_delay <= switch_delay + 1'b1;
            end

            if (is_trigger_write && !trig_wr_prev) begin
                if ((d_in_sync == 8'hA5) && switch_pending && game_ready) begin
                    game_mode        <= 1'b1;
                    switch_pending   <= 1'b0;
                    switch_delay     <= 16'd0;
                    game_ready       <= 1'b0;
                    post_ack_pending <= 1'b0;
                    post_ack_delay   <= 16'd0;
                end else if (d_in_sync == 8'h40) begin
                    game_mode      <= 1'b0;
                    switch_pending <= 1'b0;
                    switch_delay   <= 16'd0;
                    game_ready     <= 1'b0;
                    post_ack_pending <= 1'b0;
                    post_ack_delay <= 16'd0;
                end else if (H5_SIDEBAND_EN && d_in_sync[7] && (d_in_sync[6:3] == 4'b0001)) begin
                    // Arm handover only for slot load commands 0x88..0x8F.
                    switch_pending <= 1'b1;
                    switch_delay   <= 16'd0;
                    game_ready     <= 1'b0;
                    post_ack_pending <= 1'b0;
                    post_ack_delay <= 16'd0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Diagnostic LEDs
    // ------------------------------------------------------------------------
    reg [23:0] activity_cnt;
    always @(posedge clk) begin
        if (phi2_rise && is_cart_addr)
            activity_cnt <= activity_cnt + 1'b1;
    end

    assign led = ~{activity_cnt[23:19], is_bus_read};

endmodule
`default_nettype wire
