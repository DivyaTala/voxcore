// ============================================================================
// PDM microphone interface + decimation filter (digital half of a ΣΔ ADC)
//
//   pdm_dat (1 bit @ f_clk/DIV) ─► 2-FF sync ─► CIC4 ÷32 ─► >>>4 ─► FIR95 ÷2 ─► int16
//
//   * Clock: pdm_clk is generated here (f_clk / DIV, DIV >= 8). The microphone
//     (or the on-chip modulator macro) changes pdm_dat on the falling edge;
//     this block samples the synchronised data just before the next rising edge.
//   * CIC: 4 integrators at the bit rate, 4 combs at bit/32, 24-bit modular
//     arithmetic (the CIC needs only 1 + 4*log2(32) = 21 bits; wrap-around in the
//     integrators is harmless because the combs undo it).
//   * FIR: 95-tap least-squares low-pass with CIC droop compensation, Q1.15
//     coefficients (data/pdm_fir.hex), one output per 2 inputs, 1 MAC/2 cycles.
//   * Output: 16 kHz PCM for a 1.024 MHz PDM clock (f_clk = 1.024 MHz * DIV).
// Bit-exact with model/pdm_model.py decimate().
// ============================================================================
module pdm_rx #(
    parameter string DATA_DIR = "../data/"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        run,            // 1 = clock running (PDM source selected)
    input  logic        restart,        // pulse: clear filter state, restart clock phase
    input  logic [7:0]  div,            // f_clk / f_pdm, >= 8
    output logic        pdm_clk,
    input  logic        pdm_dat,        // asynchronous
    output logic        sample_valid,   // 1-cycle pulse, 16 kHz at nominal rates
    output logic [15:0] sample_data
);
    localparam int CW = 24;              // CIC register width
    localparam int TAPS = 95;
    localparam int XW = 18;              // FIR input width (CIC >>> 4)

    // ------------------------------------------------------------ clock + sampling
    logic [7:0] cnt;
    logic [1:0] dat_s;
    wire [7:0]  half = {1'b0, div[7:1]};
    wire        last = (cnt == div - 8'd1);
    wire        tick = run && last;          // one PDM bit available
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cnt <= '0; pdm_clk <= 1'b0; dat_s <= '0; end
        else begin
            dat_s <= {dat_s[0], pdm_dat};
            if (!run || restart) begin
                cnt <= '0; pdm_clk <= 1'b0;
            end else begin
                cnt     <= last ? 8'd0 : cnt + 8'd1;
                pdm_clk <= ((last ? 8'd0 : cnt + 8'd1) < half);   // high first half, low second
            end
        end
    end
    wire bit_in = dat_s[1];

    // ------------------------------------------------------------ CIC
    logic signed [CW-1:0] i1, i2, i3, i4, c1, c2, c3;   // integrators, comb delays
    logic signed [CW-1:0] d0;                           // previous decimated sample (comb 1 delay)
    logic [4:0]           bitcnt;
    wire signed [CW-1:0]  x  = bit_in ? CW'(1) : -CW'(1);
    wire signed [CW-1:0]  n1 = i1 + x;
    wire signed [CW-1:0]  n2 = i2 + n1;
    wire signed [CW-1:0]  n3 = i3 + n2;
    wire signed [CW-1:0]  n4 = i4 + n3;
    wire signed [CW-1:0]  k1 = n4 - d0;
    wire signed [CW-1:0]  k2 = k1 - c1;
    wire signed [CW-1:0]  k3 = k2 - c2;
    wire signed [CW-1:0]  k4 = k3 - c3;
    wire                  cic_valid_n = tick && (bitcnt == 5'd31);

    logic                 cic_valid;
    logic signed [XW-1:0] cic_x;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i1 <= '0; i2 <= '0; i3 <= '0; i4 <= '0; d0 <= '0; c1 <= '0; c2 <= '0; c3 <= '0;
            bitcnt <= '0; cic_valid <= 1'b0; cic_x <= '0;
        end else if (restart) begin
            i1 <= '0; i2 <= '0; i3 <= '0; i4 <= '0; d0 <= '0; c1 <= '0; c2 <= '0; c3 <= '0;
            bitcnt <= '0; cic_valid <= 1'b0;
        end else begin
            cic_valid <= cic_valid_n;
            if (tick) begin
                i1 <= n1; i2 <= n2; i3 <= n3; i4 <= n4;
                bitcnt <= bitcnt + 5'd1;
            end
            if (cic_valid_n) begin
                d0 <= n4; c1 <= k1; c2 <= k2; c3 <= k3;
                cic_x <= XW'(k4 >>> 4);
            end
        end
    end

    // ------------------------------------------------------------ FIR (circular buffer)
    // Every 2nd CIC sample starts an output: acc = sum_k h[k] * x[n-k], k = 0..94,
    // with x[m] = 0 before the first input (tracked by `avail`, not by clearing RAM).
    // Pipelined: tap k is read while tap k-1 is accumulated -> 1 MAC per cycle.
    logic [6:0]  wptr;            // where the next input goes
    logic [7:0]  n_in;            // inputs received (saturates at 128)
    logic        phase;           // 1 = the next input completes a pair
    logic        busy;
    logic [6:0]  newest;          // RAM address of x[n] for the running output
    logic [7:0]  avail;           // number of real inputs behind x[n] (incl. x[n])
    logic [7:0]  k;               // tap being read
    logic        v_d;             // data for tap k_d is on xq / hq
    logic [7:0]  k_d;
    logic signed [39:0] acc;

    wire issue = busy && (k < 8'(TAPS));
    logic signed [XW-1:0] xq; logic [15:0] hq;
    vc_sram_2p #(.DEPTH(128), .WIDTH(XW)) u_hist (
        .clk, .we_a(cic_valid), .addr_a(wptr), .wdata_a(cic_x),
        .re_b(issue), .addr_b(newest - k[6:0]), .rdata_b(xq));
    vc_rom #(.DEPTH(128), .WIDTH(16), .INIT_FILE({DATA_DIR, "pdm_fir.hex"})) u_coef (
        .clk, .en(issue), .addr(k[6:0]), .rdata(hq));

    wire signed [39:0] acc_sh = acc >>> 16;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= '0; n_in <= '0; phase <= 1'b0; busy <= 1'b0; newest <= '0; avail <= '0;
            k <= '0; k_d <= '0; v_d <= 1'b0; acc <= '0; sample_valid <= 1'b0; sample_data <= '0;
        end else if (restart) begin
            wptr <= '0; n_in <= '0; phase <= 1'b0; busy <= 1'b0; v_d <= 1'b0; sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (cic_valid) begin
                wptr  <= wptr + 7'd1;
                if (n_in != 8'd128) n_in <= n_in + 8'd1;
                phase <= ~phase;
                if (phase) begin
                    busy <= 1'b1; newest <= wptr; k <= '0; acc <= '0; v_d <= 1'b0;
                    avail <= (n_in == 8'd128) ? 8'd128 : n_in + 8'd1;
                end
            end
            if (busy) begin
                if (issue) k <= k + 8'd1;
                v_d <= issue;
                k_d <= k;
                if (v_d && k_d < avail) acc <= acc + 40'($signed(xq) * $signed(hq));
                if (!issue && !v_d) begin                  // all 95 taps accumulated
                    busy         <= 1'b0;
                    sample_valid <= 1'b1;
                    sample_data  <= (acc_sh > 40'sd32767)  ? 16'h7FFF :
                                    (acc_sh < -40'sd32768) ? 16'h8000 : acc_sh[15:0];
                end
            end
        end
    end
endmodule
