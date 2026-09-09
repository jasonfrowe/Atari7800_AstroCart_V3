// ============================================================================
// Module: atari_cart_top
// Description: Atari 7800 Multi-Cart Top Level HDL with SD Card Loading
// Target: Sipeed Tang Nano 9K (Gowin GW1NR-9)
// ============================================================================

`default_nettype none

module atari_cart_top #(
    parameter FW_INIT_FILE = "femtorv_firmware.hex",
    parameter H5_SIDEBAND_EN = 1'b1,
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

    // PSRAM interface pins (hardwired to internal MCP die)
    output wire [0:0]  O_psram_ck,
    output wire [0:0]  O_psram_ck_n,
    output wire [0:0]  O_psram_cs_n,
    output wire [0:0]  O_psram_reset_n,
    inout  wire [0:0]  IO_psram_rwds,
    inout  wire [7:0]  IO_psram_dq,

    // Debug LEDs
    output wire [5:0]  led
);

    assign O_psram_reset_n = 1'b1;

    // ------------------------------------------------------------------------
    // Cart ROM/RAM BRAM read clock: independent ~81MHz PLL, decoupled from
    // femtorv_service_soc's own 54MHz svc_clk (FemtoRV/PSRAM). This is the
    // clock for ram_block_2k's Port A (MARIA/CPU reads of the loaded game) --
    // svc_clk was the shared read-port clock before, and 54MHz wasn't enough
    // read bandwidth for MARIA's DMA during heavy sprite action (Choplifter).
    // Port B (the SD loader's write port) stays on svc_clk unchanged; Gowin's
    // dual-port BSRAM natively supports independent clocks per port, so no
    // CDC synchronizers are needed at the BRAM itself. See gowin_pll_cart.v.
    // ------------------------------------------------------------------------
    wire clk_cart;
    wire cart_pll_lock;

    gowin_pll_cart u_pll_cart (
        .clkin (clk),
        .clkout(clk_cart),
        .lock  (cart_pll_lock)
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
    // Widened from 20 bits (~38.8ms @ 27MHz) to 25 bits (~1.24s): the shorter
    // window could be spuriously tripped by a brief PHI2 hiccup right as the
    // Atari's own oscillator stabilizes at power-on, force-resetting the
    // whole SoC (wiping out an in-progress or just-finished SD scan/load)
    // seconds into normal operation -- long after cart RAM already has stale
    // menu titles displayed from the scan that ran before that reset fired.
    reg [24:0] phi2_idle_ctr = 25'd0;
    reg [11:0] warm_rst_ctr  = 12'd0;
    reg        warm_rst_n    = 1'b0;

    // ------------------------------------------------------------------------
    // Noise-Filtered Synchronizers for Atari 7800 Signals (27MHz System Clock)
    //
    // Deliberately kept on `clk`, NOT clk_cart: two independent attempts to
    // sample the raw Atari bus pins (a/phi2/rw/d) directly on clk_cart
    // (~81MHz) both failed identically on real hardware (menu never boots,
    // crashes right after the Atari splash, regardless of what else was or
    // wasn't also moved to clk_cart alongside it) -- while this exact
    // clk-domain version has booted reliably every single time it's been
    // tested, across many hardware rounds. That pattern points at the raw
    // pin capture itself, not any downstream logic: likely a real signal-
    // integrity/setup-time margin issue specific to sampling the Atari
    // bus (through its external level shifters) at ~81MHz on this board,
    // not a logic bug fixable by more RTL changes to what consumes a_sync.
    // Only the cart-read address path (phys_rom_addr -> game_ram_raddr)
    // gets synchronized into clk_cart below, via a proper 2-flop
    // synchronizer -- the same pattern already proven reliable, not a new
    // one -- rather than moving the front-end sampling itself.
    // ------------------------------------------------------------------------
    reg [1:0] phi2_pipe;
    reg [2:0] rw_pipe;
    reg [15:0] a_sync;
    reg [7:0] d_in_sync;
    reg       phi2_clean;

    // a_sync used to be a 2-stage "wait for 2 consecutive matching raw
    // samples" glitch filter (a_pipe<=a; if(a_pipe==a) a_sync<=a_pipe;),
    // which cost 1-2 full clk periods (~37-74ns, ~55ns average) on EVERY
    // address change, not just when a real bounce happened -- the second
    // stage always has to wait one more cycle to confirm stability even
    // when the value was already clean. That's a real, structural tax
    // against MARIA's ~140ns DMA budget. Simplified to plain single-stage
    // registration, matching d_in_sync just below (the data bus has always
    // been treated this way in this file, no glitch filter) -- the level
    // shifters (SN74LVC8T245) are a tightly-matched octal buffer, so real
    // inter-bit skew should be well within a single 37ns clk period. If
    // this turns out to be wrong (occasional torn-address reads reappear),
    // the 2-stage filter above is the fallback to restore.
    always @(posedge clk) begin
        phi2_pipe <= {phi2_pipe[0], phi2};
        rw_pipe   <= {rw_pipe[1:0], rw};
        a_sync    <= a;
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
            phi2_idle_ctr <= 25'd0;
        else if (phi2_idle_ctr != 25'h1FFFFFF)
            phi2_idle_ctr <= phi2_idle_ctr + 1'b1;

        if (phi2_idle_ctr == 25'h1FFFFFF) begin
            warm_rst_n   <= 1'b0;
            warm_rst_ctr <= 12'd0;
        end else if (!warm_rst_n) begin
            if (warm_rst_ctr < 12'd4095)
                warm_rst_ctr <= warm_rst_ctr + 1'b1;
            else
                warm_rst_n <= 1'b1;
        end
    end

    // DIAGNOSTIC: counts every time the warm-reset watchdog fires. This
    // register is NOT reset by warm_rst_n itself (only by the one-shot POR),
    // so it survives across any number of warm resets and lets us tell
    // "core reset once at boot" apart from "core keeps getting reset".
    reg [3:0] warm_reset_count = 4'd0;
    reg       warm_rst_n_prev  = 1'b1;
    always @(posedge clk) begin
        warm_rst_n_prev <= warm_rst_n;
        if (warm_rst_n_prev && !warm_rst_n && (warm_reset_count != 4'hF))
            warm_reset_count <= warm_reset_count + 1'b1;
    end

    // ------------------------------------------------------------------------
    // Menu-first dual-image mode & Handover
    // ------------------------------------------------------------------------
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

    // ------------------------------------------------------------------------
    // Sideband Service Plane Routing (FemtoRV32 + PSRAM + MicroSD)
    // ------------------------------------------------------------------------
    wire       sideband_sd_cs;
    wire       sideband_sd_mosi;
    wire       sideband_sd_clk;
    wire [7:0] sideband_status_val;
    wire [7:0] sideband_meta_rdata;
    wire [7:0] sideband_config_val;
    wire [7:0] sideband_debug0;
    wire [15:0] loader_cart_ram_addr;
    wire [7:0]  loader_cart_ram_wdata;
    wire        loader_cart_ram_we;
    wire [12:0] boot_raddr;
    wire [7:0]  boot_rdata;
    wire        boot_busy;
    wire        svc_clk;
    wire        sideband_pll_lock;

    // Exported status signal for simulation testbench
    wire [7:0] soc_status_val /* verilator public */ = sideband_status_val;

    generate
        if (H5_SIDEBAND_EN) begin : gen_h5_sideband
            wire       svc_sd_cs;
            wire       svc_sd_mosi;
            wire       svc_sd_clk;
            wire [7:0] svc_status_val;
            wire [7:0] svc_meta_rdata;
            wire [7:0] svc_config_val;
            wire [7:0] svc_debug0;
            wire [15:0] svc_ram_addr;
            wire [7:0]  svc_ram_wdata;
            wire        svc_ram_we;
            wire [12:0] svc_boot_raddr;
            wire        svc_boot_busy;
            wire        svc_clk_out;
            wire        svc_pll_lock;

            femtorv_service_soc #(
                .FIRMWARE_HEX(FW_INIT_FILE)
            ) u_service (
                .clk           (clk),
                .rst_n         (core_rst_n),
                .trigger_val   (trigger_val_sideband),
                .status_val    (svc_status_val),
                .debug0        (svc_debug0),
                .debug1        (),
                .debug2        (),
                .config_val    (svc_config_val),
                .cart_addr     (a_sync),
                .cart_rdata    (svc_meta_rdata),
                .cpu_probe     (),
                .sd_cs         (svc_sd_cs),
                .sd_mosi       (svc_sd_mosi),
                .sd_miso       (sd_miso),
                .sd_clk        (svc_sd_clk),
                .cart_ram_we   (svc_ram_we),
                .cart_ram_addr (svc_ram_addr),
                .cart_ram_wdata(svc_ram_wdata),
                .boot_raddr    (svc_boot_raddr),
                .boot_rdata    (boot_rdata),
                .boot_busy     (svc_boot_busy),
                .O_psram_ck    (O_psram_ck),
                .O_psram_ck_n  (O_psram_ck_n),
                .O_psram_cs_n  (O_psram_cs_n),
                .IO_psram_rwds (IO_psram_rwds),
                .IO_psram_dq   (IO_psram_dq),
                .clk_81m_out   (svc_clk_out),
                .pll_lock_out  (svc_pll_lock)
            );

            assign sideband_sd_cs        = svc_sd_cs;
            assign sideband_sd_mosi      = svc_sd_mosi;
            assign sideband_sd_clk       = svc_sd_clk;
            assign sideband_status_val   = svc_status_val;
            assign sideband_meta_rdata   = svc_meta_rdata;
            assign sideband_config_val   = svc_config_val;
            assign sideband_debug0       = svc_debug0;
            assign loader_cart_ram_addr  = svc_ram_addr;
            assign loader_cart_ram_wdata = svc_ram_wdata;
            assign loader_cart_ram_we    = svc_ram_we;
            assign boot_raddr            = svc_boot_raddr;
            assign boot_busy             = svc_boot_busy;
            assign svc_clk               = svc_clk_out;
            assign sideband_pll_lock     = svc_pll_lock;
        end else begin : gen_no_h5_sideband
            assign sideband_sd_cs        = 1'b1;
            assign sideband_sd_mosi      = 1'b0;
            assign sideband_sd_clk       = 1'b0;
            assign sideband_status_val   = game_ready ? 8'h80 : 8'h00;
            assign sideband_meta_rdata   = 8'hFF;
            assign sideband_config_val   = 8'h03; // Default $0450 POKEY
            assign sideband_debug0       = 8'h00;
            assign loader_cart_ram_addr  = 16'h0000;
            assign loader_cart_ram_wdata = 8'h00;
            assign loader_cart_ram_we    = 1'b0;
            assign boot_raddr            = 13'd0;
            assign boot_busy             = 1'b0;
            assign svc_clk               = clk;
            assign sideband_pll_lock     = 1'b1;
            assign O_psram_ck            = 1'b0;
            assign O_psram_ck_n          = 1'b0;
            assign O_psram_cs_n          = 1'b1;
            assign IO_psram_rwds         = 1'bz;
            assign IO_psram_dq           = 8'hzz;
        end
    endgenerate

    assign sd_cs   = sideband_sd_cs;
    assign sd_mosi = sideband_sd_mosi;
    assign sd_clk  = sideband_sd_clk;

    // DIAGNOSTIC: counts every time the femtorv_service_soc PLL lock drops.
    // soc_rst_n inside that module is (rst_n & pll_lock) -- a lock glitch
    // resets that WHOLE SoC (status_val, boot_busy, everything) completely
    // independently of core_rst_n/warm_rst_n, so warm_reset_count above
    // cannot see it at all. sideband_pll_lock crosses from the femtorv
    // service's own clk_81m-adjacent logic, so it's double-synchronized here.
    reg [1:0] pll_lock_sync = 2'b11;
    reg       pll_lock_prev = 1'b1;
    reg [3:0] pll_unlock_count = 4'd0;
    always @(posedge clk) begin
        pll_lock_sync <= {pll_lock_sync[0], sideband_pll_lock};
        pll_lock_prev <= pll_lock_sync[1];
        if (pll_lock_prev && !pll_lock_sync[1] && (pll_unlock_count != 4'hF))
            pll_unlock_count <= pll_unlock_count + 1'b1;
    end

    // Dynamic POKEY and Mapper configuration (from A78 header via FemtoRV)
    reg        pokey_cfg_enable;
    reg  [1:0] pokey_cfg_addr_sel;
    reg  [3:0] mapper_cfg_type;

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            pokey_cfg_enable   <= 1'b1;
            pokey_cfg_addr_sel <= 2'b01; // default $0450
            mapper_cfg_type    <= 4'h0;  // default linear
        end else if (H5_SIDEBAND_EN) begin
            pokey_cfg_enable   <= sideband_config_val[0];
            pokey_cfg_addr_sel <= sideband_config_val[2:1];
            mapper_cfg_type    <= sideband_config_val[6:3];
        end
    end

    wire pokey_enable = game_mode && pokey_cfg_enable;
    wire [1:0] pokey_addr_sel = pokey_cfg_addr_sel;
    wire [3:0] mapper_type = game_mode ? mapper_cfg_type : 4'h0;

    // ------------------------------------------------------------------------
    // Address Decoding & Memory Mapping
    // ------------------------------------------------------------------------
    wire is_cart_addr   = (a_sync >= 16'h4000);
    wire is_status_addr = (a_sync == 16'h7FF0);
    // $7FF1: SD-scanned title count (entry_count), written by firmware via
    // femtorv_service_soc's debug0 CSR right after run_fat_scan() completes.
    // Mirrors the existing $7FF0 status-byte pattern exactly -- debug0 was
    // already routed out of femtorv_service_soc (port comment: "To Atari
    // read of $7FF1") but never actually wired to this decode until now.
    wire is_debug0_addr = (a_sync == 16'h7FF1);
    wire is_menu_addr   = (a_sync >= 16'hE000);
    wire is_pokey_4000  = (a_sync[15:4] == 12'h400); // $4000-$400F
    wire is_pokey_0450  = (a_sync[15:4] == 12'h045); // $0450-$045F
    wire is_pokey_0800  = (a_sync[15:4] == 12'h080); // $0800-$080F
    wire is_pokey_0440  = (a_sync[15:4] == 12'h044); // $0440-$044F

    wire is_pokey_addr = (pokey_addr_sel == 2'b00) ? is_pokey_4000 :
                         (pokey_addr_sel == 2'b01) ? is_pokey_0450 :
                         (pokey_addr_sel == 2'b10) ? is_pokey_0800 :
                         (pokey_addr_sel == 2'b11) ? is_pokey_0440 :
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
    // Cartridge Game RAM (48KB across 24 BSRAM blocks)
    // ------------------------------------------------------------------------
    wire [15:0] game_ram_raddr = boot_busy ? {3'b000, boot_raddr} : phys_rom_addr[15:0];

    // ------------------------------------------------------------------------
    // Address synchronizer: game_ram_raddr is registered in the `clk`
    // (27MHz) domain (via mapper_supergame/a_sync, kept there deliberately
    // -- see the bus-synchronizer comment above) or the svc_clk-domain boot
    // DMA FSM's boot_raddr, and crosses here into clk_cart, a separate,
    // independent PLL instance from both. Despite sharing a 27MHz
    // reference, two independent PLLs have no fixed, guaranteed phase
    // relationship, so this is a genuine asynchronous multi-bit bus
    // crossing -- a raw wire straight into the BRAMs' own address register
    // has no stage to let a metastable capture resolve before use. Double-
    // register the whole bus in clk_cart before any BRAM sees it, and
    // derive the output mux's selector (is_menu_addr_cart below) from this
    // SAME synchronized value rather than from the raw `clk`-domain
    // a_sync, so the mux selector always stays paired with the address
    // that was actually presented to the BRAMs -- this specific
    // selector/data mismatch (not just raw synchronizer latency) is the
    // leading suspect for the graphics corruption seen in earlier testing.
    // ------------------------------------------------------------------------
    reg [15:0] game_ram_raddr_cart_r1, game_ram_raddr_cart_s;
    always @(posedge clk_cart) begin
        game_ram_raddr_cart_r1 <= game_ram_raddr;
        game_ram_raddr_cart_s  <= game_ram_raddr_cart_r1;
    end

    wire [4:0]  game_chunk_rsel = game_ram_raddr_cart_s[15:11];
    wire [10:0] game_chunk_roff = game_ram_raddr_cart_s[10:0];

    wire [15:0] eff_loader_cart_ram_addr = (loader_cart_ram_addr >= 16'hE000) ?
                                           (loader_cart_ram_addr - 16'h4000) :
                                           loader_cart_ram_addr;
    wire [4:0]  loader_chunk_wsel = eff_loader_cart_ram_addr[15:11];
    wire [10:0] loader_chunk_woff = eff_loader_cart_ram_addr[10:0];

    wire [7:0] chunk_rdata [0:23];

    // Blocks 0..3: Initialized with FemtoRV firmware image for power-on bootloader copy to PSRAM
    ram_block_2k #(.INIT_FILE("femtorv_chunk_00.hex")) u_game_ram_00 (
        .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[0]),
        .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == 5'd0)), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
    );
    ram_block_2k #(.INIT_FILE("femtorv_chunk_01.hex")) u_game_ram_01 (
        .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[1]),
        .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == 5'd1)), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
    );
    ram_block_2k #(.INIT_FILE("femtorv_chunk_02.hex")) u_game_ram_02 (
        .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[2]),
        .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == 5'd2)), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
    );
    ram_block_2k #(.INIT_FILE("femtorv_chunk_03.hex")) u_game_ram_03 (
        .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[3]),
        .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == 5'd3)), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
    );

    // Blocks 4..19: Initialized empty
    genvar gi;
    generate
        for (gi = 4; gi < 20; gi = gi + 1) begin : gen_game_ram
            ram_block_2k #(.INIT_FILE("")) u_game_ram (
                .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[gi]),
                .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == gi[4:0])), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
            );
        end
    endgenerate

    // Blocks 20..23: Initialized with 8KB Menu ROM ($E000-$FFFF)
    ram_block_2k #(.INIT_FILE("menu_chunk_00.hex")) u_game_ram_20 (
        .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[20]),
        .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == 5'd20)), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
    );
    ram_block_2k #(.INIT_FILE("menu_chunk_01.hex")) u_game_ram_21 (
        .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[21]),
        .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == 5'd21)), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
    );
    ram_block_2k #(.INIT_FILE("menu_chunk_02.hex")) u_game_ram_22 (
        .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[22]),
        .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == 5'd22)), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
    );
    ram_block_2k #(.INIT_FILE("menu_chunk_03.hex")) u_game_ram_23 (
        .clka(clk_cart), .a_addr(game_chunk_roff), .a_rdata(chunk_rdata[23]),
        .clkb(svc_clk), .b_we(loader_cart_ram_we && (loader_chunk_wsel == 5'd23)), .b_addr(loader_chunk_woff), .b_wdata(loader_cart_ram_wdata)
    );

    assign boot_rdata = (game_chunk_rsel < 5'd4) ? chunk_rdata[game_chunk_rsel] : 8'h00;
    wire [7:0] rom_data_out = (game_chunk_rsel < 5'd24) ? chunk_rdata[game_chunk_rsel] : 8'hFF;


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
    wire is_fpga_response_addr = is_cart_addr || (pokey_enable && is_pokey_addr);
    wire is_bus_read           = is_fpga_response_addr && rw_is_read;

    assign buf_dir = is_bus_read;
    assign buf_oe  = 1'b0;

    wire drive_pokey = pokey_enable && is_pokey_addr && rw_is_read;
    wire [7:0] status_data_out = game_ready ? 8'h80 : sideband_status_val;

    // is_menu_addr (above, from the raw `clk`-domain a_sync) would select
    // rom_data_out immediately on an address change, while rom_data_out
    // itself (from chunk_rdata, via the clk_cart-synchronized
    // game_ram_raddr_cart_s a few cycles above) still reflects the OLD
    // address for a few clk_cart cycles after that -- a real window where
    // the mux selector and the data it's selecting disagree about which
    // address is current. Deriving the selector from game_chunk_rsel
    // instead keeps it paired with whatever address was actually used to
    // produce the CURRENT rom_data_out, eliminating that mismatch at the
    // menu/cart-vs-nothing boundary specifically (chunks 20-23 hold the
    // menu ROM -- see the BRAM instances above).
    wire is_menu_addr_cart = (game_chunk_rsel >= 5'd20);
    wire [7:0] menu_bus_data_out = is_status_addr ? status_data_out :
                                   (is_debug0_addr ? sideband_debug0 :
                                   (is_menu_addr_cart ? rom_data_out : 8'hFF));
    wire [7:0] bus_data_out = game_mode ? (drive_pokey ? pokey_dout : rom_data_out)
                                        : menu_bus_data_out;

    assign d   = (is_bus_read && (buf_dir == 1'b1)) ? bus_data_out : 8'hZZ;
    assign irq = 1'b0;

    // ------------------------------------------------------------------------
    // Handover & Mode Switch State Machine
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            game_mode            <= 1'b0;
            switch_pending       <= 1'b0;
            switch_delay         <= 16'd0;
            game_ready           <= 1'b0;
            post_ack_pending     <= 1'b0;
            post_ack_delay       <= 16'd0;
            trig_wr_prev         <= 1'b0;
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
                if (H5_SIDEBAND_EN ? (sideband_status_val == 8'h80) : (switch_delay == 16'd4095))
                    game_ready <= 1'b1;
                else if (switch_delay != 16'hFFFF)
                    switch_delay <= switch_delay + 1'b1;
            end

            if (is_trigger_write && !trig_wr_prev) begin
                if (d_in_sync == 8'hA5) begin
                    game_mode        <= 1'b1;
                    switch_pending   <= 1'b0;
                    game_ready       <= 1'b0;
                    post_ack_pending <= 1'b0;
                    post_ack_delay   <= 16'd0;
                end else if (d_in_sync[7]) begin
                    switch_pending <= 1'b1;
                    switch_delay   <= 16'd0;
                    game_ready     <= 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Status LEDs -- DEBUG LAYOUT, blink-coded (a 6-bit binary snapshot is too
    // easy to misread, especially if any bit is toggling fast enough to look
    // dim/off to the eye instead of clearly on).
    //
    // led[4] = slow 1Hz heartbeat -- steady blink proves the clock is alive.
    //          If this ISN'T blinking, none of the rest means anything.
    // led[5] = the firmware status "stage" blinked out as a repeating count,
    //          re-sampled fresh at the start of every cycle, separated by a
    //          long pause so you can tell where one count ends and the next
    //          begins:
    //            1 blink  = idle / load_game() never ran
    //            2 blinks = still in run_fat_scan() (titles being scanned)
    //            3 blinks = load_game() running (opened file / copying)
    //            4 blinks = A78 header validation error
    //            5 blinks = disk/mount/open/read error
    //            6 blinks = ready (0x80) -- waiting on the game_mode ack
    //            7 blinks = anything else / unexpected value
    // led[0] = u_pll_cart (clk_cart, ~81MHz cart ROM/RAM BRAM read clock)
    //          lock status -- steady ON means locked. If this is OFF/dark,
    //          the second PLL never locked; core_rst_n no longer depends on
    //          it (see cart_pll_lock below) specifically so a failure here
    //          is visible instead of silently holding the whole SoC in
    //          reset forever, as it did before this LED was added.
    // led[1:3] are unused (off) in this layout.
    // ------------------------------------------------------------------------
    reg [23:0] heartbeat_ctr = 24'd0;
    reg        heartbeat_led = 1'b0;
    localparam [23:0] HEARTBEAT_HALF = 24'd13_500_000; // ~0.5s @ 27MHz
    always @(posedge clk) begin
        if (heartbeat_ctr >= HEARTBEAT_HALF) begin
            heartbeat_ctr <= 24'd0;
            heartbeat_led <= ~heartbeat_led;
        end else begin
            heartbeat_ctr <= heartbeat_ctr + 1'b1;
        end
    end

    function [2:0] status_blink_code;
        input [3:0] nibble;
        begin
            case (nibble)
                4'h0:    status_blink_code = 3'd1;
                4'h1:    status_blink_code = 3'd2;
                4'h2:    status_blink_code = 3'd3;
                4'h5:    status_blink_code = 3'd4;
                4'h6:    status_blink_code = 3'd5;
                4'h8:    status_blink_code = 3'd6;
                default: status_blink_code = 3'd7;
            endcase
        end
    endfunction

    localparam [25:0] BLINK_HALF = 26'd8_100_000;  // ~0.3s @ 27MHz (on or off)
    localparam [25:0] GAP_LEN    = 26'd40_500_000; // ~1.5s @ 27MHz pause between cycles

    reg [25:0] blink_phase_timer   = 26'd0;
    reg [3:0]  blink_halves_done   = 4'd0;
    reg [2:0]  blink_target        = 3'd0;
    reg        blink_out           = 1'b0;
    wire [3:0] blink_target_halves = {blink_target, 1'b0}; // 2 * blink_target

    always @(posedge clk) begin
        if (blink_halves_done < blink_target_halves) begin
            if (blink_phase_timer >= BLINK_HALF) begin
                blink_phase_timer <= 26'd0;
                blink_halves_done <= blink_halves_done + 1'b1;
                blink_out         <= ~blink_out;
            end else begin
                blink_phase_timer <= blink_phase_timer + 1'b1;
            end
        end else begin
            blink_out <= 1'b0;
            if (blink_phase_timer >= GAP_LEN) begin
                blink_phase_timer <= 26'd0;
                blink_halves_done <= 4'd0;
                blink_target      <= status_blink_code(sideband_status_val[7:4]);
            end else begin
                blink_phase_timer <= blink_phase_timer + 1'b1;
            end
        end
    end

    assign led[0]   = ~cart_pll_lock;
    assign led[3:1] = 3'b111;
    assign led[4]   = ~heartbeat_led;
    assign led[5]   = ~blink_out;

endmodule

`default_nettype wire
