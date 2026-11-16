// ============================================================================
// Voice subsystem: I2S RX -> MFCC engine -> feature RAM -> NN engine,
// with an APB register interface for the CPU.
//
//   0x000 CTRL    W : bit0 MFCC_START (pulse), bit1 NN_START (pulse)
//                 RW: bit2 AUTO_NN (start the NN automatically when MFCC finishes)
//                 RW: bit3 SRC_PDM (audio source: 0 = I2S, 1 = PDM microphone)
//   0x004 STATUS  R : bit0 mfcc_busy, bit1 mfcc_done, bit2 nn_busy, bit3 nn_done,
//                     bit4 overflow, [13:8] frames_done
//   0x008 RESULT  R : [3:0] detected class
//   0x00C PDM_DIV RW: [7:0] f_clk / f_pdm, >= 8 (reset 49: 50 MHz / 49 = 1.02 MHz)
//   0x040-0x07C   R : LOGIT[0..15] (int32)
//   0x800-0xFA4   R : FEATURE[0..489] (int8, sign-extended) -- 1 APB wait state
// ============================================================================
module voice_apb #(
    parameter string DATA_DIR = "../data/"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    input  logic        i2s_sck,
    input  logic        i2s_ws,
    input  logic        i2s_sd,
    output logic        pdm_clk,
    input  logic        pdm_dat
);
    logic src_pdm; logic [7:0] pdm_div;
    logic mfcc_start;

    logic i2s_valid; logic [15:0] i2s_data;
    i2s_rx u_i2s (.clk, .rst_n, .i2s_sck, .i2s_ws, .i2s_sd, .sample_valid(i2s_valid), .sample_data(i2s_data));

    // PDM path: clock generator + CIC/FIR decimator. The clock starts and the
    // filters are cleared together with MFCC_START, so the first decimated sample
    // is the first sample of the utterance.
    logic pdm_valid; logic [15:0] pdm_data;
    pdm_rx #(.DATA_DIR(DATA_DIR)) u_pdm (.clk, .rst_n, .run(src_pdm), .restart(mfcc_start && src_pdm),
        .div(pdm_div), .pdm_clk, .pdm_dat, .sample_valid(pdm_valid), .sample_data(pdm_data));

    wire        sample_valid = src_pdm ? pdm_valid : i2s_valid;
    wire [15:0] sample_data  = src_pdm ? pdm_data  : i2s_data;

    logic mfcc_busy, mfcc_done, overflow; logic [5:0] frames_done;
    logic feat_we; logic [8:0] feat_waddr; logic [7:0] feat_wdata;
    mfcc_engine #(.DATA_DIR(DATA_DIR)) u_mfcc (
        .clk, .rst_n, .start(mfcc_start), .busy(mfcc_busy), .done(mfcc_done), .overflow,
        .frames_done, .sample_valid, .sample_data,
        .feat_we, .feat_addr(feat_waddr), .feat_wdata);

    logic nn_start, nn_busy, nn_done; logic [3:0] result_class;
    logic nn_feat_re; logic [8:0] nn_feat_raddr; logic [31:0] logit_value;
    logic [7:0] feat_q;
    nn_engine #(.DATA_DIR(DATA_DIR)) u_nn (
        .clk, .rst_n, .start(nn_start), .busy(nn_busy), .done(nn_done), .result_class,
        .feat_re(nn_feat_re), .feat_raddr(nn_feat_raddr), .feat_rdata(feat_q),
        .logit_sel(paddr[5:2]), .logit_value);

    // feature RAM: written by MFCC, read by the NN (when busy) or the CPU
    wire        cpu_feat_sel = psel && !pwrite && paddr[11];
    wire        feat_re      = nn_busy ? nn_feat_re : cpu_feat_sel;
    wire [8:0]  feat_raddr   = nn_busy ? nn_feat_raddr : 9'(paddr[10:2]);
    vc_sram_2p #(.DEPTH(512), .WIDTH(8)) u_feat (
        .clk, .we_a(feat_we), .addr_a(feat_waddr), .wdata_a(feat_wdata),
        .re_b(feat_re), .addr_b(feat_raddr), .rdata_b(feat_q));

    // ---- registers
    logic auto_nn, mfcc_done_d;
    wire wr = psel && penable && pwrite;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            auto_nn <= 1'b0; mfcc_start <= 1'b0; nn_start <= 1'b0; mfcc_done_d <= 1'b0;
            src_pdm <= 1'b0; pdm_div <= 8'd49;
        end else begin
            mfcc_start  <= wr && paddr == 12'h000 && pwdata[0];
            mfcc_done_d <= mfcc_done;
            nn_start    <= (wr && paddr == 12'h000 && pwdata[1]) ||
                           (auto_nn && mfcc_done && !mfcc_done_d);
            if (wr && paddr == 12'h000) begin auto_nn <= pwdata[2]; src_pdm <= pwdata[3]; end
            if (wr && paddr == 12'h00C) pdm_div <= pwdata[7:0];
        end
    end

    // feature reads need one wait state (synchronous RAM); everything else is zero-wait
    logic feat_wait;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) feat_wait <= 1'b0;
        else        feat_wait <= cpu_feat_sel && penable && !feat_wait && !nn_busy;
    assign pready = !(cpu_feat_sel && penable) || feat_wait;

    always_comb begin
        prdata = '0;
        if (paddr[11])                prdata = {{24{feat_q[7]}}, feat_q};
        else if (paddr[11:6] == 6'h1) prdata = logit_value;
        else case (paddr[7:0])
            8'h00: prdata = {28'd0, src_pdm, auto_nn, 2'b00};
            8'h04: prdata = {18'd0, frames_done, 3'd0, overflow, nn_done, nn_busy, mfcc_done, mfcc_busy};
            8'h08: prdata = {28'd0, result_class};
            8'h0C: prdata = {24'd0, pdm_div};
            default: ;
        endcase
    end
endmodule
