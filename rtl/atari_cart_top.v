// ============================================================================
// Module: atari_cart_top
// Description: Atari 7800 Multi-Cart Top Level HDL for Tang Nano 9K
// Target: Sipeed Tang Nano 9K (Gowin GW1NR-9)
// ============================================================================

`default_nettype none

module atari_cart_top #(
    parameter C_INIT_FILE = "astrowing.hex"
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

    // Debug LEDs
    output wire [5:0]  led
);

    // ------------------------------------------------------------------------
    // Synchronizers for Atari 7800 Signals (27MHz System Clock Domain)
    // ------------------------------------------------------------------------
    reg [2:0] phi2_sync;
    reg [2:0] rw_sync;
    reg [15:0] a_sync;

    always @(posedge clk) begin
        phi2_sync <= {phi2_sync[1:0], phi2};
        rw_sync   <= {rw_sync[1:0], rw};
        a_sync    <= a;
    end

    wire phi2_high = phi2_sync[1];
    wire phi2_rise = (phi2_sync[2:1] == 2'b01);
    wire rw_is_read = rw_sync[1];

    // ------------------------------------------------------------------------
    // Address Decoding (Atari 7800 Cartridge Memory Map)
    // - Flat 48KB ROM: $4000-$FFFF (Addresses $4000 to $FFFF mapped to 0..49151)
    // ------------------------------------------------------------------------
    wire is_cart_addr = (a_sync >= 16'h4000);
    wire [15:0] rom_addr = a_sync - 16'h4000; // 0x0000 .. 0xBFFF (48 KB)

    // ------------------------------------------------------------------------
    // Cartridge ROM Storage (48KB Dual-Port RAM/ROM initialized with astrowing)
    // ------------------------------------------------------------------------
    reg [7:0] rom_mem [0:49151];
    reg [7:0] rom_data_out;

    initial begin
        if (C_INIT_FILE != "") begin
            $readmemh(C_INIT_FILE, rom_mem);
        end
    end

    // Fast synchronous read from internal block RAM
    always @(posedge clk) begin
        if (is_cart_addr) begin
            rom_data_out <= rom_mem[rom_addr[15:0]];
        end
    end

    // ------------------------------------------------------------------------
    // Tri-state Data Bus & Buffer Controls (U3 SN74LVC245)
    // ------------------------------------------------------------------------
    // Drive bus during PHI2 HIGH when reading from Cartridge address space ($4000-$FFFF)
    wire drive_bus = phi2_high && rw_is_read && is_cart_addr;

    assign d       = drive_bus ? rom_data_out : 8'hZZ;
    assign buf_dir = drive_bus;          // 1 = FPGA driving Atari
    assign buf_oe  = ~drive_bus;         // 0 = Active output enable

    // Default outputs for open-drain / unasserted signals
    assign irq   = 1'bZ;
    assign audio = 1'b0;

    // ------------------------------------------------------------------------
    // Diagnostic LEDs (Activity counters)
    // ------------------------------------------------------------------------
    reg [23:0] activity_cnt;
    always @(posedge clk) begin
        if (phi2_rise && is_cart_addr)
            activity_cnt <= activity_cnt + 1'b1;
    end

    assign led = ~{activity_cnt[23:19], drive_bus}; // Active-low LEDs on Tang Nano 9K

endmodule
`default_nettype wire
