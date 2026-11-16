// I2S receiver (slave), oversampled into the system clock domain.
// SCK/WS/SD come from an external master (mic / codec) and are asynchronous to
// clk, so each goes through a 2-flop synchronizer (CDC). Requires
// f_clk >= 4 x f_sck. 16-bit slots, MSB first, data 1 SCK after WS edge
// (Philips I2S). Only the left channel (WS = 0) is output.
module i2s_rx (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i2s_sck,
    input  logic        i2s_ws,
    input  logic        i2s_sd,
    output logic        sample_valid,   // 1-cycle pulse
    output logic [15:0] sample_data
);
    logic [2:0] sck_s; logic [1:0] ws_s, sd_s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sck_s <= '0; ws_s <= '1; sd_s <= '0; end
        else begin
            sck_s <= {sck_s[1:0], i2s_sck};
            ws_s  <= {ws_s[0], i2s_ws};
            sd_s  <= {sd_s[0], i2s_sd};
        end
    end
    wire sck_rise = sck_s[1] & ~sck_s[2];
    wire ws = ws_s[1], sd = sd_s[1];

    logic [15:0] shreg;
    logic        ws_last;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shreg <= '0; ws_last <= 1'b1; sample_valid <= 1'b0; sample_data <= '0;
        end else begin
            sample_valid <= 1'b0;
            if (sck_rise) begin
                shreg   <= {shreg[14:0], sd};
                ws_last <= ws;
                // WS changed: the bit sampled now is the LSB of the previous channel's word
                if (ws != ws_last && ws_last == 1'b0) begin
                    sample_data  <= {shreg[14:0], sd};
                    sample_valid <= 1'b1;
                end
            end
        end
    end
endmodule
