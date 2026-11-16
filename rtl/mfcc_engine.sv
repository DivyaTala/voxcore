// ============================================================================
// VoxCore MFCC engine
//
// Captures one 1 s utterance (16 kHz PCM) after `start`, and for each of the
// 49 frames (512 samples, hop 320) computes 10 int8 MFCC features, written to
// the feature memory at address frame*10 + coef.
//
// Datapath is sequential (one operation per cycle) and time-multiplexed: audio
// is slow (one sample every ~3000 clocks at 50 MHz), so one multiplier-heavy
// butterfly unit is plenty. Bit-exact with model/voxcore_model.py.
//
//   LOAD  : ring -> window multiply -> FFT RAM in bit-reversed order (2 cyc/sample)
//   FFT   : 9 stages x 256 radix-2 butterflies                      (5 cyc/bfly)
//   MEL   : |X|^2 >> 16, each bin feeds <=2 triangular filters       (2 cyc/bin)
//   LOG   : piecewise-linear log2 of each mel energy                 (1 cyc/filter)
//   DCT   : 10 x 32 MAC, then offset/shift normalise + saturate      (~34 cyc/coef)
// ============================================================================
module mfcc_engine #(
    parameter string DATA_DIR = "../data/"
) (
    input  logic        clk,
    input  logic        rst_n,
    // control
    input  logic        start,          // pulse: begin capturing a new utterance
    output logic        busy,
    output logic        done,           // sticky until next start
    output logic        overflow,       // a frame trigger arrived while 2 already pending
    output logic [5:0]  frames_done,
    // audio in (system clock domain)
    input  logic        sample_valid,
    input  logic [15:0] sample_data,
    // feature memory write port
    output logic        feat_we,
    output logic [8:0]  feat_addr,
    output logic [7:0]  feat_wdata
);
    localparam int N_FRAMES  = 49;
    localparam int FRAME_LEN = 512;
    localparam int HOP       = 320;
    localparam int N_MEL     = 32;
    localparam int N_MFCC    = 10;
    localparam int DW        = 28;   // FFT data width
    localparam int MW        = 50;   // mel accumulator width

    // ------------------------------------------------------------ capture side
    logic        capturing;
    logic [9:0]  ring_waddr;
    logic [13:0] scnt;          // samples captured
    logic [13:0] next_trig;     // sample count that completes the next frame
    logic [5:0]  frames_trig;   // frames triggered so far
    logic [1:0]  pending;       // frames waiting to be processed
    logic        frame_taken;   // processing FSM accepted a pending frame

    wire take_sample = capturing && sample_valid;
    wire trig        = take_sample && (scnt + 14'd1 == next_trig);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capturing <= 1'b0; ring_waddr <= '0; scnt <= '0;
            next_trig <= 14'(FRAME_LEN); frames_trig <= '0; pending <= '0; overflow <= 1'b0;
        end else if (start) begin
            capturing <= 1'b1; ring_waddr <= '0; scnt <= '0;
            next_trig <= 14'(FRAME_LEN); frames_trig <= '0; pending <= '0; overflow <= 1'b0;
        end else begin
            if (take_sample) begin
                ring_waddr <= ring_waddr + 10'd1;
                scnt       <= scnt + 14'd1;
            end
            if (trig) begin
                next_trig   <= next_trig + 14'(HOP);
                frames_trig <= frames_trig + 6'd1;
                if (frames_trig == 6'(N_FRAMES - 1)) capturing <= 1'b0;
                if (pending == 2'd2) overflow <= 1'b1;
            end
            case ({trig, frame_taken})
                2'b10:   if (pending != 2'd3) pending <= pending + 2'd1;
                2'b01:   pending <= pending - 2'd1;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------ memories
    logic [9:0]  ring_raddr;  logic ring_re;  logic [15:0] ring_q;
    vc_sram_2p #(.DEPTH(1024), .WIDTH(16)) u_ring (
        .clk, .we_a(take_sample), .addr_a(ring_waddr), .wdata_a(sample_data),
        .re_b(ring_re), .addr_b(ring_raddr), .rdata_b(ring_q));

    logic        fft_en, fft_we; logic [8:0] fft_addr; logic [2*DW-1:0] fft_wdata, fft_q;
    vc_sram_1p #(.DEPTH(512), .WIDTH(2*DW)) u_fft_ram (
        .clk, .en(fft_en), .we(fft_we), .addr(fft_addr), .wdata(fft_wdata), .rdata(fft_q));

    logic [8:0] win_addr;  logic [15:0] win_q;
    vc_rom #(.DEPTH(512), .WIDTH(16), .INIT_FILE({DATA_DIR, "window.hex"})) u_win (
        .clk, .en(1'b1), .addr(win_addr), .rdata(win_q));

    logic [7:0] tw_addr;   logic [31:0] tw_q;
    vc_rom #(.DEPTH(256), .WIDTH(32), .INIT_FILE({DATA_DIR, "twiddle.hex"})) u_tw (
        .clk, .en(1'b1), .addr(tw_addr), .rdata(tw_q));

    logic [8:0] mel_addr;  logic [15:0] mel_q;
    vc_rom #(.DEPTH(512), .WIDTH(16), .INIT_FILE({DATA_DIR, "mel.hex"})) u_mel (
        .clk, .en(1'b1), .addr(mel_addr), .rdata(mel_q));

    logic [8:0] dct_addr;  logic [15:0] dct_q;
    vc_rom #(.DEPTH(512), .WIDTH(16), .INIT_FILE({DATA_DIR, "dct.hex"})) u_dct (
        .clk, .en(1'b1), .addr(dct_addr), .rdata(dct_q));

    logic [3:0] norm_addr; logic [39:0] norm_q;
    vc_rom #(.DEPTH(16), .WIDTH(40), .INIT_FILE({DATA_DIR, "norm.hex"})) u_norm (
        .clk, .en(1'b1), .addr(norm_addr), .rdata(norm_q));

    // ------------------------------------------------------------ processing FSM
    typedef enum logic [4:0] {
        S_IDLE, S_LD_RD, S_LD_WR,
        S_FFT_RA, S_FFT_RB, S_FFT_CALC, S_FFT_WA, S_FFT_WB,
        S_MEL_RD, S_MEL_ACC, S_LOG,
        S_DCT_RD, S_DCT_MAC, S_DCT_NORM, S_DCT_OUT
    } state_t;
    state_t st;

    logic [9:0]  idx;          // generic loop counter (sample / bin / filter / dct m)
    logic [3:0]  stage;        // FFT stage 0..8
    logic [7:0]  bf;           // butterfly 0..255
    logic [3:0]  coef;         // DCT coefficient 0..9
    logic [9:0]  frame_start;  // ring address of the current frame's first sample
    logic [8:0]  feat_base;    // frame*10

    logic signed [DW-1:0] ar, ai, nar, nai, nbr, nbi;
    logic [MW-1:0]        mel_acc [N_MEL];
    logic [15:0]          logmel  [N_MEL];
    logic signed [39:0]   dct_acc;

    // FFT butterfly addressing (combinational from stage/bf)
    logic [8:0] hmask, bf_j, bf_k, addr_a, addr_b;
    always_comb begin
        hmask  = (9'd1 << stage) - 9'd1;
        bf_j   = {1'b0, bf} & hmask;
        bf_k   = ({1'b0, bf} >> stage) << (stage + 4'd1);
        addr_a = bf_k + bf_j;
        addr_b = addr_a + (9'd1 << stage);
    end

    function automatic logic [8:0] bitrev9(input logic [8:0] x);
        for (int i = 0; i < 9; i++) bitrev9[i] = x[8-i];
    endfunction

    // piecewise-linear log2: integer part = MSB position, 10 fraction bits below it
    function automatic logic [15:0] log2_fx(input logic [MW-1:0] v);
        logic [5:0] msb;
        logic [MW-1:0] rem;
        logic [9:0] frac;
        msb = '0;
        for (int i = 0; i < MW; i++) if (v[i]) msb = 6'(i);
        rem = v & ~(MW'(1) << msb);
        if (msb >= 6'd10) frac = 10'(rem >> (msb - 6'd10));
        else              frac = 10'(rem << (6'd10 - msb));
        log2_fx = (v == '0) ? 16'd0 : {msb, frac};
    endfunction

    // ---- datapath (combinational parts)
    // window multiply: signed 16 x unsigned Q15
    logic signed [32:0] win_prod;
    logic signed [15:0] xw;
    assign win_prod = $signed(ring_q) * $signed({1'b0, win_q});
    assign xw       = 16'(win_prod >>> 15);

    // twiddle multiply  t = b * W
    logic signed [DW-1:0] br, bi;
    logic signed [15:0]   wr, wi;
    logic signed [DW+16:0] tr_full, ti_full;
    logic signed [DW-1:0] tr, ti;
    assign br = $signed(fft_q[2*DW-1:DW]);
    assign bi = $signed(fft_q[DW-1:0]);
    assign wr = $signed(tw_q[31:16]);
    assign wi = $signed(tw_q[15:0]);
    assign tr_full = (br * wr) - (bi * wi);
    assign ti_full = (br * wi) + (bi * wr);
    assign tr = DW'(tr_full >>> 15);
    assign ti = DW'(ti_full >>> 15);

    // power spectrum of the bin currently on fft_q (re = br, im = bi)
    logic [2*DW:0] pw_full;
    logic [40:0]   pw;
    assign pw_full = (2*DW+1)'(br * br) + (2*DW+1)'(bi * bi);
    assign pw      = 41'(pw_full >> 16);

    logic [5:0] mel_j;  logic [8:0] mel_wr;
    assign mel_j  = mel_q[14:9];
    assign mel_wr = mel_q[8:0];

    // DCT normalise
    logic signed [25:0] dct_c;
    logic signed [31:0] norm_off;
    logic [7:0]         norm_sh;
    logic signed [32:0] norm_diff, norm_shifted;
    logic [7:0]         feat_sat;
    assign dct_c        = 26'(dct_acc >>> 14);
    assign norm_off     = $signed(norm_q[39:8]);
    assign norm_sh      = norm_q[7:0];
    assign norm_diff    = 33'(dct_c) - 33'(norm_off);
    assign norm_shifted = norm_diff >>> norm_sh;
    assign feat_sat     = (norm_shifted > 33'sd127)  ? 8'sd127 :
                          (norm_shifted < -33'sd128) ? -8'sd128 : norm_shifted[7:0];

    // ---- memory address / control muxing
    always_comb begin
        ring_re = 1'b0; ring_raddr = frame_start + idx;
        fft_en = 1'b0; fft_we = 1'b0; fft_addr = '0; fft_wdata = '0;
        win_addr = idx[8:0];
        tw_addr  = 8'(bf_j << (4'd8 - stage));
        mel_addr = idx[8:0];
        dct_addr = 9'({coef, 5'd0}) + 9'(idx[4:0]);
        norm_addr = coef;
        feat_we = 1'b0; feat_addr = feat_base + 9'(coef); feat_wdata = feat_sat;
        case (st)
            S_LD_RD:    ring_re = 1'b1;
            S_LD_WR:    begin fft_en = 1'b1; fft_we = 1'b1; fft_addr = bitrev9(idx[8:0]);
                              fft_wdata = {DW'(xw), DW'(0)}; end
            S_FFT_RA:   begin fft_en = 1'b1; fft_addr = addr_a; end
            S_FFT_RB:   begin fft_en = 1'b1; fft_addr = addr_b; end
            S_FFT_WA:   begin fft_en = 1'b1; fft_we = 1'b1; fft_addr = addr_a; fft_wdata = {nar, nai}; end
            S_FFT_WB:   begin fft_en = 1'b1; fft_we = 1'b1; fft_addr = addr_b; fft_wdata = {nbr, nbi}; end
            S_MEL_RD:   begin fft_en = 1'b1; fft_addr = idx[8:0]; end
            S_DCT_OUT:  feat_we = 1'b1;
            default: ;
        endcase
    end

    assign frame_taken = (st == S_IDLE) && (pending != 2'd0) && !start;
    assign busy        = capturing || (pending != 2'd0) || (st != S_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; idx <= '0; stage <= '0; bf <= '0; coef <= '0;
            frame_start <= '0; feat_base <= '0; frames_done <= '0; done <= 1'b0;
            ar <= '0; ai <= '0; nar <= '0; nai <= '0; nbr <= '0; nbi <= '0; dct_acc <= '0;
            for (int m = 0; m < N_MEL; m++) begin mel_acc[m] <= '0; logmel[m] <= '0; end
        end else if (start) begin
            st <= S_IDLE; frame_start <= '0; feat_base <= '0; frames_done <= '0; done <= 1'b0;
        end else begin
            case (st)
                S_IDLE: if (frame_taken) begin
                    idx <= '0; st <= S_LD_RD;
                    for (int m = 0; m < N_MEL; m++) mel_acc[m] <= '0;
                end
                // ---------------- LOAD + WINDOW
                S_LD_RD: st <= S_LD_WR;
                S_LD_WR: begin
                    if (idx == 10'(FRAME_LEN - 1)) begin
                        idx <= '0; stage <= '0; bf <= '0; st <= S_FFT_RA;
                    end else begin
                        idx <= idx + 10'd1; st <= S_LD_RD;
                    end
                end
                // ---------------- FFT
                S_FFT_RA: st <= S_FFT_RB;
                S_FFT_RB: begin ar <= $signed(fft_q[2*DW-1:DW]); ai <= $signed(fft_q[DW-1:0]); st <= S_FFT_CALC; end
                S_FFT_CALC: begin
                    nar <= ar + tr; nai <= ai + ti;
                    nbr <= ar - tr; nbi <= ai - ti;
                    st  <= S_FFT_WA;
                end
                S_FFT_WA: st <= S_FFT_WB;
                S_FFT_WB: begin
                    bf <= bf + 8'd1;
                    if (bf == 8'd255) begin
                        if (stage == 4'd8) begin idx <= '0; st <= S_MEL_RD; end
                        else begin stage <= stage + 4'd1; st <= S_FFT_RA; end
                    end else st <= S_FFT_RA;
                end
                // ---------------- POWER + MEL
                S_MEL_RD: st <= S_MEL_ACC;
                S_MEL_ACC: begin
                    if (mel_j != 6'd63) begin
                        if (mel_j < 6'(N_MEL))  mel_acc[5'(mel_j)]      <= mel_acc[5'(mel_j)]      + MW'(pw * mel_wr);
                        if (mel_j >= 6'd1)      mel_acc[5'(mel_j - 1)]  <= mel_acc[5'(mel_j - 1)]  + MW'(pw * (9'd256 - mel_wr));
                    end
                    if (idx == 10'd256) begin idx <= '0; st <= S_LOG; end
                    else begin idx <= idx + 10'd1; st <= S_MEL_RD; end
                end
                // ---------------- LOG
                S_LOG: begin
                    logmel[5'(idx)] <= log2_fx(mel_acc[5'(idx)]);
                    if (idx == 10'(N_MEL - 1)) begin idx <= '0; coef <= '0; dct_acc <= '0; st <= S_DCT_RD; end
                    else idx <= idx + 10'd1;
                end
                // ---------------- DCT + NORMALISE
                S_DCT_RD: st <= S_DCT_MAC;
                S_DCT_MAC: begin
                    dct_acc <= dct_acc + 40'($signed({1'b0, logmel[5'(idx)]}) * $signed(dct_q));
                    if (idx == 10'(N_MEL - 1)) begin idx <= '0; st <= S_DCT_NORM; end
                    else begin idx <= idx + 10'd1; st <= S_DCT_RD; end
                end
                S_DCT_NORM: st <= S_DCT_OUT;     // norm ROM read latency
                S_DCT_OUT: begin
                    dct_acc <= '0;
                    if (coef == 4'(N_MFCC - 1)) begin
                        feat_base   <= feat_base + 9'(N_MFCC);
                        frame_start <= frame_start + 10'(HOP);
                        frames_done <= frames_done + 6'd1;
                        if (frames_done == 6'(N_FRAMES - 1)) done <= 1'b1;
                        st <= S_IDLE;
                    end else begin
                        coef <= coef + 4'd1; st <= S_DCT_RD;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
