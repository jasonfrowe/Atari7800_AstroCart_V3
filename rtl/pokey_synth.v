// ============================================================================
// Module: pokey_synth
// Description: Cycle-Exact POKEY Sound Synthesizer Core for Atari 7800
// Target: Tang Nano 9K / Verilator Simulation
// ============================================================================

`default_nettype none

module pokey_synth (
    input  wire       clk,          // System clock (27 MHz)
    input  wire       rst_n,        // Active low reset
    input  wire       phi2_rise,    // Atari CPU clock rise edge trigger (~1.79 MHz)

    // Bus Interface
    input  wire       cs,           // Chip select ($4000-$400F)
    input  wire       rw,           // 1 = Read, 0 = Write
    input  wire [3:0] addr,         // Register address [3:0]
    input  wire [7:0] din,          // Data input from CPU
    output reg  [7:0] dout,         // Data output to CPU (RANDOM / status)

    // Synthesized Audio Output
    output reg  [7:0] audio_out     // 8-bit combined PCM audio sample
);

    // ------------------------------------------------------------------------
    // POKEY Register Set
    // ------------------------------------------------------------------------
    reg [7:0] audf [0:3];     // Channel 0..3 Frequency dividers
    reg [7:0] audc [0:3];     // Channel 0..3 Control (Distortion & Volume)
    /* verilator lint_off UNUSEDSIGNAL */
    reg [7:0] audctl;         // Audio Master Control
    reg [7:0] skctl;          // Serial/Key Control
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------------
    // Polynomial Noise Generators (LFSRs)
    // ------------------------------------------------------------------------
    reg [16:0] lfsr17;
    reg [8:0]  lfsr9;
    reg [4:0]  lfsr5;
    reg [3:0]  lfsr4;

    wire poly17_reset = (skctl[1:0] == 2'b00);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr17 <= 17'h12345;
            lfsr9  <= 9'h155;
            lfsr5  <= 5'h15;
            lfsr4  <= 4'hA;
        end else if (poly17_reset) begin
            lfsr17 <= 17'h12345;
            lfsr9  <= 9'h155;
            lfsr5  <= 5'h15;
            lfsr4  <= 4'hA;
        end else if (phi2_rise) begin
            lfsr17 <= {lfsr17[15:0], lfsr17[16] ^ lfsr17[13]};
            lfsr9  <= {lfsr9[7:0],   lfsr9[8]   ^ lfsr9[4]};
            lfsr5  <= {lfsr5[3:0],   lfsr5[4]   ^ lfsr5[2]};
            lfsr4  <= {lfsr4[2:0],   lfsr4[3]   ^ lfsr4[2]};
        end
    end

    // ------------------------------------------------------------------------
    // POKEY Register Writes & Reads
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audf[0] <= 8'h00; audc[0] <= 8'h00;
            audf[1] <= 8'h00; audc[1] <= 8'h00;
            audf[2] <= 8'h00; audc[2] <= 8'h00;
            audf[3] <= 8'h00; audc[3] <= 8'h00;
            audctl  <= 8'h00;
            skctl   <= 8'h00;
        end else if (cs && !rw && phi2_rise) begin
            case (addr)
                4'h0: audf[0] <= din;
                4'h1: audc[0] <= din;
                4'h2: audf[1] <= din;
                4'h3: audc[1] <= din;
                4'h4: audf[2] <= din;
                4'h5: audc[2] <= din;
                4'h6: audf[3] <= din;
                4'h7: audc[3] <= din;
                4'h8: audctl  <= din;
                4'hF: skctl   <= din;
                default: ;
            endcase
        end
    end

    // Read registers ($400E = RANDOM)
    always @(*) begin
        if (cs && rw) begin
            case (addr)
                4'hE: dout = audctl[7] ? lfsr9[7:0] : lfsr17[15:8];
                default: dout = 8'hFF;
            endcase
        end else begin
            dout = 8'hFF;
        end
    end

    // ------------------------------------------------------------------------
    // 4-Channel Frequency Dividers & Tone Generators
    // ------------------------------------------------------------------------
    reg [7:0] div_cnt [0:3];
    reg       chan_out [0:3];

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_chan
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    div_cnt[i]  <= 8'h00;
                    chan_out[i] <= 1'b0;
                end else if (phi2_rise) begin
                    if (div_cnt[i] == 8'h00) begin
                        div_cnt[i]  <= audf[i];
                        chan_out[i] <= ~chan_out[i];
                    end else begin
                        div_cnt[i] <= div_cnt[i] - 1'b1;
                    end
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Channel Distortion / Poly Noise Selection & Mixer
    // ------------------------------------------------------------------------
    wire [7:0] raw_audio [0:3];

    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_mix
            wire volume_only = audc[i][5];   // Bit 5 = Volume only mode (force high)
            wire [3:0] vol   = audc[i][3:0]; // Bits [3:0] = Volume level (0..15)

            wire noise_gate = volume_only ? 1'b1 :
                             (audc[i][7] ? lfsr5[0] : 1'b1) &
                             (audc[i][6] ? chan_out[i] : lfsr4[0]);

            assign raw_audio[i] = noise_gate ? {4'b0000, vol} : 8'h00;
        end
    endgenerate

    // Combine 4 channels safely into 8-bit output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            audio_out <= 8'h00;
        else
            audio_out <= raw_audio[0] + raw_audio[1] + raw_audio[2] + raw_audio[3];
    end

endmodule
`default_nettype wire
