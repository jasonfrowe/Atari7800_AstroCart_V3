// ============================================================================
// Module: atari_cart_top
// Description: Atari 7800 Multi-Cart Top Level HDL with SuperGame Bankswitching
// Target: Sipeed Tang Nano 9K (Gowin GW1NR-9)
// ============================================================================

`default_nettype none

module atari_cart_top #(
    parameter C_INIT_FILE = "astrowing.hex",
    parameter FW_INIT_FILE = "firmware.hex"
)(
    // System Clock & Resets
    input  wire        clk,          // 27 MHz onboard clock
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        rst_n,        // Active low reset
    /* verilator lint_on UNUSEDSIGNAL */

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
    // Synchronizers for Atari 7800 Signals (27MHz System Clock Domain)
    // ------------------------------------------------------------------------
    reg [2:0] phi2_sync;
    reg [2:0] rw_sync;
    reg [15:0] a_sync;
    reg [7:0] d_in_sync;

    always @(posedge clk) begin
        phi2_sync <= {phi2_sync[1:0], phi2};
        rw_sync   <= {rw_sync[1:0], rw};
        a_sync    <= a;
        d_in_sync <= d;
    end

    wire phi2_high  = phi2_sync[1];
    wire phi2_rise  = (phi2_sync[2:1] == 2'b01);
    wire rw_is_read = rw_sync[1];

    // ------------------------------------------------------------------------
    // Hazard5 RISC-V SoC Softcore Subsystem
    // ------------------------------------------------------------------------
    wire        pokey_enable;
    wire [3:0]  mapper_type;
    wire        cart_ram_we;
    wire [15:0] cart_ram_addr;
    wire [7:0]  cart_ram_wdata;

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
        .phi2_rise      (phi2_rise),
        .cs             (is_cart_addr),
        .rw             (rw_is_read),
        .addr           (a_sync),
        .din            (d_in_sync),
        .mapper_type    (mapper_type),
        .phys_rom_addr  (phys_rom_addr)
    );

    // ------------------------------------------------------------------------
    // Cartridge Dual-Port RAM (Read by 7800 Bus, Written by Hazard5 Loader)
    // ------------------------------------------------------------------------
    reg [7:0] rom_mem [0:49151];
    reg [7:0] rom_data_out;

    initial begin
        if (C_INIT_FILE != "") begin
            $readmemh(C_INIT_FILE, rom_mem);
        end
    end

    // Port A: Read by Atari 7800 Bus
    always @(posedge clk) begin
        if (is_cart_addr) begin
            rom_data_out <= rom_mem[phys_rom_addr[15:0]];
        end
    end

    // Port B: Write by Hazard5 RISC-V Loader
    always @(posedge clk) begin
        if (cart_ram_we && cart_ram_addr < 16'hC000) begin
            rom_mem[cart_ram_addr] <= cart_ram_wdata;
        end
    end

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
    // Dynamic Data Bus Output Selection & Buffer Controls
    // ------------------------------------------------------------------------
    wire is_pokey_read_reg = (a_sync[3:0] == 4'hE); // $400E (RANDOM register)
    wire drive_pokey = pokey_enable && is_pokey_addr && is_pokey_read_reg && rw_is_read && phi2_high;
    wire drive_rom   = is_cart_addr && (!is_pokey_addr || !pokey_enable || !is_pokey_read_reg) && rw_is_read && phi2_high;
    wire drive_bus   = drive_pokey || drive_rom;

    wire [7:0] bus_data_out = drive_pokey ? pokey_dout : rom_data_out;

    assign d       = drive_bus ? bus_data_out : 8'hZZ;
    assign buf_dir = drive_bus;          // 1 = FPGA driving Atari
    assign buf_oe  = ~drive_bus;         // 0 = Active output enable
    assign irq     = 1'bZ;

    // ------------------------------------------------------------------------
    // Diagnostic LEDs
    // ------------------------------------------------------------------------
    reg [23:0] activity_cnt;
    always @(posedge clk) begin
        if (phi2_rise && is_cart_addr)
            activity_cnt <= activity_cnt + 1'b1;
    end

    assign led = ~{activity_cnt[23:19], drive_bus};

endmodule
`default_nettype wire
