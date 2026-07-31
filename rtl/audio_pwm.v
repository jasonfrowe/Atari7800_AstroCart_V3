// ============================================================================
// Module: audio_pwm
// Description: 8-Bit PWM Audio Modulator for Tang Nano 9K Audio Pin 76 (T_EAUD)
// ============================================================================

`default_nettype none

module audio_pwm (
    input  wire       clk,        // 27 MHz system clock
    input  wire       rst_n,      // Active low reset
    input  wire [7:0] level,      // 8-bit audio level input (0..255)
    output reg        pwm_out     // 1-bit PWM audio pulse output
);

    reg [7:0] pwm_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwm_cnt <= 8'h00;
            pwm_out <= 1'b0;
        end else begin
            pwm_cnt <= pwm_cnt + 1'b1;
            pwm_out <= (pwm_cnt < level);
        end
    end

endmodule
`default_nettype wire
