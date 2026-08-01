// ============================================================================
// Module: atari_cart_top
// Description: Atari 7800 Multi-Cart Top Level HDL with Full Write Passthrough
// Target: Sipeed Tang Nano 9K (Gowin GW1NR-9)
// ============================================================================

`default_nettype none

module atari_cart_top #(
    parameter FW_INIT_FILE = "firmware.hex"
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

    localparam [15:0] POST_ACK_DELAY = 16'd120;

    wire is_trigger_write = phi2_high && !rw_is_read && (a_sync == 16'h2200);

    assign pokey_enable = game_mode;

    reg [7:0] trigger_val;

    // Hazard5 RISC-V SoC Integration
    wire        soc_pokey_enable;
    wire [1:0]  soc_pokey_addr_sel;
    wire [3:0]  soc_mapper_type;
    wire [7:0]  soc_status_val;
    wire        cart_ram_we;
    wire [15:0] cart_ram_addr;
    wire [7:0]  cart_ram_wdata;

    hazard5_soc #(
        .FIRMWARE_HEX(FW_INIT_FILE)
    ) u_soc (
        .clk            (clk),
        .rst_n          (rst_n),
        .pokey_enable   (soc_pokey_enable),
        .pokey_addr_sel (soc_pokey_addr_sel),
        .mapper_type    (soc_mapper_type),
        .trigger_val    (trigger_val),
        .status_val     (soc_status_val),
        .cart_ram_we    (cart_ram_we),
        .cart_ram_addr  (cart_ram_addr),
        .cart_ram_wdata (cart_ram_wdata),
        .sd_cs          (sd_cs),
        .sd_mosi        (sd_mosi),
        .sd_miso        (sd_miso),
        .sd_clk         (sd_clk)
    );

    // ------------------------------------------------------------------------
    // Address Decoding & Memory Mapping
    // ------------------------------------------------------------------------
    wire is_cart_addr   = (a_sync >= 16'h4000);
    wire is_status_addr = (a_sync == 16'h7FF0);
    wire is_menu_addr   = (a_sync >= 16'hE000);
    wire is_pokey_4000  = (a_sync[15:4] == 12'h400); // $4000-$400F
    wire is_pokey_0450  = (a_sync[15:4] == 12'h045); // $0450-$045F
    wire is_pokey_0800  = (a_sync[15:4] == 12'h080); // $0800-$080F

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
    wire [7:0] menu_chunk_rdata [0:3];

    // Write access to menu ROM chunk 1 ($E800-$EFF7) from RISC-V loader when in menu mode
    wire menu_ram_we = cart_ram_we && (!game_mode) && (cart_ram_addr >= 16'hE800 && cart_ram_addr <= 16'hE8FF);
    wire [10:0] menu_ram_waddr = cart_ram_addr[10:0];
    wire [7:0]  menu_ram_wdata = cart_ram_wdata;

    always @(posedge clk) begin
        if (menu_ram_we) begin
            $display("[MENU_ROM_WRITE] addr=0x%04h waddr=0x%03h data=0x%02h ('%c')", cart_ram_addr, menu_ram_waddr, cart_ram_wdata, cart_ram_wdata);
        end
        if (phi2_rise && rw_is_read && a_sync >= 16'hE800 && a_sync <= 16'hE81F) begin
            $display("[MENU_ROM_READ] addr=0x%04h data=0x%02h ('%c')", a_sync, menu_data_out, menu_data_out);
        end
    end

    rom_block_2k #(.INIT_FILE("rom_chunk_00.hex")) u_rom_00 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[0]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_01.hex")) u_rom_01 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[1]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_02.hex")) u_rom_02 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[2]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_03.hex")) u_rom_03 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[3]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_04.hex")) u_rom_04 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[4]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_05.hex")) u_rom_05 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[5]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_06.hex")) u_rom_06 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[6]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_07.hex")) u_rom_07 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[7]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_08.hex")) u_rom_08 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[8]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_09.hex")) u_rom_09 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[9]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_10.hex")) u_rom_10 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[10]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_11.hex")) u_rom_11 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[11]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_12.hex")) u_rom_12 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[12]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_13.hex")) u_rom_13 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[13]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_14.hex")) u_rom_14 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[14]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_15.hex")) u_rom_15 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[15]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_16.hex")) u_rom_16 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[16]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_17.hex")) u_rom_17 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[17]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_18.hex")) u_rom_18 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[18]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_19.hex")) u_rom_19 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[19]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_20.hex")) u_rom_20 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[20]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_21.hex")) u_rom_21 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[21]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_22.hex")) u_rom_22 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[22]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("rom_chunk_23.hex")) u_rom_23 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[23]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));

    rom_block_2k #(.INIT_FILE("menu_chunk_00.hex")) u_menu_rom_00 (.clk(clk), .raddr(a_sync[10:0]), .rdata(menu_chunk_rdata[0]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("menu_chunk_01.hex")) u_menu_rom_01 (.clk(clk), .raddr(a_sync[10:0]), .rdata(menu_chunk_rdata[1]), .we(menu_ram_we), .waddr(menu_ram_waddr), .wdata(menu_ram_wdata));
    rom_block_2k #(.INIT_FILE("menu_chunk_02.hex")) u_menu_rom_02 (.clk(clk), .raddr(a_sync[10:0]), .rdata(menu_chunk_rdata[2]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));
    rom_block_2k #(.INIT_FILE("menu_chunk_03.hex")) u_menu_rom_03 (.clk(clk), .raddr(a_sync[10:0]), .rdata(menu_chunk_rdata[3]), .we(1'b0), .waddr(11'd0), .wdata(8'd0));

    wire [4:0] rom_chunk_sel = phys_rom_addr[15:11];
    wire [7:0] rom_data_out = (rom_chunk_sel < 5'd24) ? chunk_rdata[rom_chunk_sel] : 8'hFF;

    wire [1:0] menu_chunk_sel = a_sync[12:11];
    wire [7:0] menu_data_out = menu_chunk_rdata[menu_chunk_sel];

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
    wire [7:0] status_data_out = (soc_status_val[7] || game_ready) ? 8'h80 : 8'h00;
    wire [7:0] menu_bus_data_out = is_status_addr ? status_data_out :
                                   (is_menu_addr ? menu_data_out : 8'hFF);
    wire [7:0] bus_data_out = game_mode ? (drive_pokey ? pokey_dout : rom_data_out)
                                        : menu_bus_data_out;

    // Drive when this cart owns a read cycle.
    assign d   = (is_bus_read && (buf_dir == 1'b1)) ? bus_data_out : 8'hZZ;
    assign irq = 1'b0; // Drive 0V to Q3 Gate (Transistor OFF -> HALT floats HIGH via 5V motherboard pull-up)

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            game_mode        <= 1'b0;
            switch_pending   <= 1'b0;
            switch_delay     <= 16'd0;
            game_ready       <= 1'b0;
            post_ack_pending <= 1'b0;
            post_ack_delay   <= 16'd0;
            trig_wr_prev     <= 1'b0;
            trigger_val      <= 8'h00;
        end else begin
            trig_wr_prev <= is_trigger_write;

            if (is_trigger_write && !trig_wr_prev) begin
                trigger_val <= d_in_sync;
            end

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
                end else if (d_in_sync[7]) begin
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
