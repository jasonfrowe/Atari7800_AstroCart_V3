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

    reg [7:0] audf [0:3];
    reg [7:0] audc [0:3];
    reg [7:0] audctl;
    reg [7:0] skctl;

    reg [3:0]  poly4;
    reg [4:0]  poly5;
    reg [16:0] poly17;
    reg [8:0]  poly9;

    reg [15:0] counter [0:3];
    reg [3:0]  chan_out;

    reg [4:0] count_64k;
    reg [6:0] count_15k;
    reg tick_64khz;
    reg tick_15khz;

    reg channel_tick;
    reg [5:0] mixed_audio;

    integer i;
    integer k;

    wire p4_next  = !(poly4[3]  ^ poly4[2]);
    wire p5_next  = !(poly5[4]  ^ poly5[2]);
    wire p17_next = !(poly17[16] ^ poly17[4]);
    wire p9_next  = !(poly9[8] ^ poly9[4]);

    wire link_12   = audctl[4];
    wire link_34   = audctl[3];
    wire use_15khz = audctl[0];
    wire poly17_reset = (skctl[1:0] == 2'b00);

    // Generate 64kHz and 15kHz clocks from POKEY 1.79MHz reference.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_64k  <= 5'd0;
            count_15k  <= 7'd0;
            tick_64khz <= 1'b0;
            tick_15khz <= 1'b0;
        end else begin
            tick_64khz <= 1'b0;
            tick_15khz <= 1'b0;
            if (phi2_rise) begin
                if (count_64k == 5'd27) begin
                    count_64k  <= 5'd0;
                    tick_64khz <= 1'b1;
                end else begin
                    count_64k <= count_64k + 1'b1;
                end

                if (count_15k == 7'd113) begin
                    count_15k  <= 7'd0;
                    tick_15khz <= 1'b1;
                end else begin
                    count_15k <= count_15k + 1'b1;
                end
            end
        end
    end

    // Register writes.
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

    // POKEY noise generators run on 1.79MHz reference.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            poly4  <= 4'b1011;
            poly5  <= 5'b10101;
            poly17 <= 17'b10101010101010101;
            poly9  <= 9'b101010101;
        end else if (poly17_reset) begin
            poly4  <= 4'b1011;
            poly5  <= 5'b10101;
            poly17 <= 17'b10101010101010101;
            poly9  <= 9'b101010101;
        end else if (phi2_rise) begin
            poly4  <= {poly4[2:0], p4_next};
            poly5  <= {poly5[3:0], p5_next};
            poly17 <= {poly17[15:0], p17_next};
            poly9  <= {poly9[7:0], p9_next};
        end
    end

    // Channel stepping with AUDCTL-controlled base clock selection.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chan_out    <= 4'b0000;
            counter[0]  <= 16'h0000;
            counter[1]  <= 16'h0000;
            counter[2]  <= 16'h0000;
            counter[3]  <= 16'h0000;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                channel_tick = use_15khz ? tick_15khz : tick_64khz;
                if ((i == 0) && audctl[6]) channel_tick = phi2_rise;
                if ((i == 2) && audctl[5]) channel_tick = phi2_rise;

                if (channel_tick) begin
                    if (!((i == 1 && link_12) || (i == 3 && link_34))) begin
                        if (counter[i] == 16'h0000) begin
                            if (i == 0 && link_12)
                                counter[i] <= {audf[1], audf[0]};
                            else if (i == 2 && link_34)
                                counter[i] <= {audf[3], audf[2]};
                            else
                                counter[i] <= {8'h00, audf[i]};

                            case (audc[i][7:5])
                                3'b000: chan_out[i] <= poly17[16] && poly5[4];
                                3'b001: chan_out[i] <= poly5[4];
                                3'b010: chan_out[i] <= poly17[16] && poly5[4];
                                3'b011: chan_out[i] <= poly5[4];
                                3'b100: chan_out[i] <= poly17[16];
                                3'b101: chan_out[i] <= ~chan_out[i];
                                3'b110: chan_out[i] <= poly17[16];
                                3'b111: chan_out[i] <= ~chan_out[i];
                                default: chan_out[i] <= chan_out[i];
                            endcase
                        end else begin
                            counter[i] <= counter[i] - 1'b1;
                        end
                    end
                end
            end
        end
    end

    // Read registers ($x00E = RANDOM).
    always @(*) begin
        if (cs && rw) begin
            case (addr)
                4'hE: dout = audctl[7] ? {poly9[7:0]} : {poly17[15:8]};
                default: dout = 8'hFF;
            endcase
        end else begin
            dout = 8'hFF;
        end
    end

    // 4-channel volume mix into 8-bit PWM level.
    always @(*) begin
        mixed_audio = 6'd0;
        for (k = 0; k < 4; k = k + 1) begin
            if (chan_out[k])
                mixed_audio = mixed_audio + {2'b00, audc[k][3:0]};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            audio_out <= 8'h00;
        else
            audio_out <= {mixed_audio, 2'b00};
    end

endmodule
`default_nettype wire
