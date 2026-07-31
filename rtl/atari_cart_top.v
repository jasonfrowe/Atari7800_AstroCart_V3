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

    // ------------------------------------------------------------------------
    // Noise-Filtered Synchronizers for Atari 7800 Signals (27MHz System Clock)
    // ------------------------------------------------------------------------
    reg [3:0] phi2_pipe;
    reg [2:0] rw_pipe;
    reg [15:0] a_sync;
    reg [7:0] d_in_sync;
    reg       phi2_clean;

    always @(posedge clk) begin
        phi2_pipe <= {phi2_pipe[2:0], phi2};
        rw_pipe   <= {rw_pipe[1:0], rw};
        a_sync    <= a;
        d_in_sync <= d;

        // 3-Sample Majority Filter on PHI2 clock to eliminate level-shifter ringing
        if (phi2_pipe[3:1] == 3'b111)
            phi2_clean <= 1'b1;
        else if (phi2_pipe[3:1] == 3'b000)
            phi2_clean <= 1'b0;
    end

    reg phi2_clean_prev;
    always @(posedge clk) begin
        phi2_clean_prev <= phi2_clean;
    end

    wire phi2_high  = phi2_clean;
    wire phi2_rise  = (phi2_clean && !phi2_clean_prev);
    wire rw_is_read = rw_pipe[1];

    // ------------------------------------------------------------------------
    // Hazard5 RISC-V SoC Softcore Subsystem
    // ------------------------------------------------------------------------
    wire        pokey_enable;
    wire [3:0]  mapper_type;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        cart_ram_we;
    wire [15:0] cart_ram_addr;
    wire [7:0]  cart_ram_wdata;
    /* verilator lint_on UNUSEDSIGNAL */

    hazard5_soc #(
        .FIRMWARE_HEX (FW_INIT_FILE)
    ) u_soc (
        .clk            (clk),
        .rst_n          (rst_n),
        .pokey_enable   (pokey_enable),
        .mapper_type    (mapper_type),
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
    wire is_cart_addr  = (a_sync >= 16'h4000);
    wire is_pokey_addr = (a_sync[15:4] == 12'h400); // $4000 - $400F

    // SuperGame Bankswitch Mapper Module
    wire [18:0] phys_rom_addr;

    mapper_supergame u_mapper (
        .clk            (clk),
        .rst_n          (rst_n),
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
    // Power-On Default Cartridge Memory (24x 2KB Gowin BSRAM Primitives)
    // ------------------------------------------------------------------------
    wire [7:0] chunk_rdata [0:23];

    rom_block_2k #(.INIT_FILE("rom_chunk_00.hex")) u_rom_00 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[0]));
    rom_block_2k #(.INIT_FILE("rom_chunk_01.hex")) u_rom_01 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[1]));
    rom_block_2k #(.INIT_FILE("rom_chunk_02.hex")) u_rom_02 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[2]));
    rom_block_2k #(.INIT_FILE("rom_chunk_03.hex")) u_rom_03 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[3]));
    rom_block_2k #(.INIT_FILE("rom_chunk_04.hex")) u_rom_04 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[4]));
    rom_block_2k #(.INIT_FILE("rom_chunk_05.hex")) u_rom_05 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[5]));
    rom_block_2k #(.INIT_FILE("rom_chunk_06.hex")) u_rom_06 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[6]));
    rom_block_2k #(.INIT_FILE("rom_chunk_07.hex")) u_rom_07 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[7]));
    rom_block_2k #(.INIT_FILE("rom_chunk_08.hex")) u_rom_08 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[8]));
    rom_block_2k #(.INIT_FILE("rom_chunk_09.hex")) u_rom_09 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[9]));
    rom_block_2k #(.INIT_FILE("rom_chunk_10.hex")) u_rom_10 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[10]));
    rom_block_2k #(.INIT_FILE("rom_chunk_11.hex")) u_rom_11 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[11]));
    rom_block_2k #(.INIT_FILE("rom_chunk_12.hex")) u_rom_12 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[12]));
    rom_block_2k #(.INIT_FILE("rom_chunk_13.hex")) u_rom_13 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[13]));
    rom_block_2k #(.INIT_FILE("rom_chunk_14.hex")) u_rom_14 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[14]));
    rom_block_2k #(.INIT_FILE("rom_chunk_15.hex")) u_rom_15 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[15]));
    rom_block_2k #(.INIT_FILE("rom_chunk_16.hex")) u_rom_16 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[16]));
    rom_block_2k #(.INIT_FILE("rom_chunk_17.hex")) u_rom_17 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[17]));
    rom_block_2k #(.INIT_FILE("rom_chunk_18.hex")) u_rom_18 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[18]));
    rom_block_2k #(.INIT_FILE("rom_chunk_19.hex")) u_rom_19 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[19]));
    rom_block_2k #(.INIT_FILE("rom_chunk_20.hex")) u_rom_20 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[20]));
    rom_block_2k #(.INIT_FILE("rom_chunk_21.hex")) u_rom_21 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[21]));
    rom_block_2k #(.INIT_FILE("rom_chunk_22.hex")) u_rom_22 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[22]));
    rom_block_2k #(.INIT_FILE("rom_chunk_23.hex")) u_rom_23 (.clk(clk), .raddr(phys_rom_addr[10:0]), .rdata(chunk_rdata[23]));

    wire [4:0] rom_chunk_sel = phys_rom_addr[15:11];
    wire [7:0] rom_data_out = (rom_chunk_sel < 5'd24) ? chunk_rdata[rom_chunk_sel] : 8'hFF;

    // ------------------------------------------------------------------------
    // POKEY Sound Synthesizer Core Integration
    // ------------------------------------------------------------------------
    wire [7:0] pokey_dout;
    wire [7:0] pcm_audio;

    pokey_synth u_pokey (
        .clk        (clk),
        .rst_n      (rst_n),
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
        .rst_n      (rst_n),
        .level      (pcm_audio),
        .pwm_out    (audio)
    );

    // ------------------------------------------------------------------------
    // Dynamic Data Bus Output Selection & Level Shifter Controls (U3 SN74LVC245)
    // ------------------------------------------------------------------------
    wire is_pokey_read_reg = (a_sync[3:0] == 4'hE); // $400E (RANDOM register)

    // Decode read/write intent from synchronized Atari control signals.
    wire is_cart_read  = is_cart_addr && rw_is_read;
    wire cart_bus_active = phi2_high && is_cart_addr;

    // U3 Buffer Direction (U3_DIR): 1 = FPGA->Atari (Read), 0 = Atari->FPGA (Write/Idle)
    assign buf_dir = is_cart_read;

    // U3 Buffer Enable (U3_OE): only active during valid PHI2 cartridge windows.
    assign buf_oe  = cart_bus_active ? 1'b0 : 1'b1;

    // FPGA Internal Data Bus Drive Logic
    wire drive_pokey = pokey_enable && is_pokey_addr && is_pokey_read_reg && rw_is_read;
    wire [7:0] bus_data_out = drive_pokey ? pokey_dout : rom_data_out;

    // Drive only during active cartridge read windows to avoid low-phase contention.
    assign d   = (cart_bus_active && (buf_dir == 1'b1)) ? bus_data_out : 8'hZZ;
    assign irq = 1'bZ;

    // ------------------------------------------------------------------------
    // Diagnostic LEDs
    // ------------------------------------------------------------------------
    reg [23:0] activity_cnt;
    always @(posedge clk) begin
        if (phi2_rise && is_cart_addr)
            activity_cnt <= activity_cnt + 1'b1;
    end

    assign led = ~{activity_cnt[23:19], is_cart_read};

endmodule
`default_nettype wire
