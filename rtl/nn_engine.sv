// ============================================================================
// VoxCore NN accelerator: int8 MLP  490 -> 64 -> 64 -> 16 (10 classes used)
//
// An 8-lane MAC array: each cycle one input activation is broadcast to 8
// lanes, each lane multiplies it by its own int8 weight (one 64-bit weight
// word = 8 lanes) and accumulates into a 32-bit accumulator. So 8 output
// neurons are computed in parallel ("output-stationary" dataflow).
// The read pipeline is fully overlapped: 1 MAC/lane/cycle steady state.
//
// Hidden layers: y = sat_0_127( acc >>> SHIFT )  (ReLU + power-of-two requant)
// Output layer : raw int32 logits, then argmax over classes 0..9.
// Bit-exact with nn_forward() in model/voxcore_model.py.
// ============================================================================
module nn_engine #(
    parameter string DATA_DIR = "../data/"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    output logic        busy,
    output logic        done,            // sticky until next start
    output logic [3:0]  result_class,
    // feature memory read port (1-cycle sync read)
    output logic        feat_re,
    output logic [8:0]  feat_raddr,
    input  logic [7:0]  feat_rdata,
    // logit readout for the CPU
    input  logic [3:0]  logit_sel,
    output logic [31:0] logit_value
);
    `include "nn_cfg.svh"
    localparam int LANES = 8;
    localparam int N_CLASSES = 10;

    // layer table
    function automatic int n_in_of (input logic [1:0] l); return (l == 0) ? 490 : 64; endfunction
    function automatic int n_out_of(input logic [1:0] l); return (l == 2) ? 16 : 64;  endfunction
    function automatic int wbase_of(input logic [1:0] l);
        return (l == 0) ? L0_WBASE : (l == 1) ? L1_WBASE : L2_WBASE;
    endfunction

    // ---- memories
    logic [12:0] w_addr; logic [63:0] w_q; logic w_en;
    vc_rom #(.DEPTH(8192), .WIDTH(64), .INIT_FILE({DATA_DIR, "weights.hex"})) u_wrom (
        .clk, .en(w_en), .addr(w_addr), .rdata(w_q));
    logic [7:0] b_addr; logic [31:0] b_q;
    vc_rom #(.DEPTH(256), .WIDTH(32), .INIT_FILE({DATA_DIR, "bias.hex"})) u_brom (
        .clk, .en(1'b1), .addr(b_addr), .rdata(b_q));

    logic [7:0]         act_a [64];     // layer-0 output / layer-1 input
    logic [7:0]         act_b [64];     // layer-1 output / layer-2 input
    logic signed [31:0] logits [16];
    logic signed [31:0] acc [LANES];

    typedef enum logic [2:0] { S_IDLE, S_BIAS_RD, S_BIAS_LD, S_MAC, S_WB, S_ARGMAX, S_DONE } state_t;
    state_t st;
    logic [1:0] layer;
    logic [3:0] group;          // output group of 8 neurons
    logic [3:0] lane_cnt;       // bias load counter
    logic [9:0] i_issue;        // next input index to fetch
    logic       vld;            // a fetched (input, weight) pair is on the read data now
    logic [7:0] act_q;          // registered read of act_a/act_b (models a sync RAM)

    wire [9:0]  n_in   = 10'(n_in_of(layer));
    wire        issue  = (st == S_MAC) && (i_issue < n_in);

    // ---- read address generation
    always_comb begin
        w_en       = issue;
        w_addr     = 13'(wbase_of(layer)) + 13'(group) * 13'(n_in) + 13'(i_issue);
        feat_re    = issue && (layer == 2'd0);
        feat_raddr = i_issue[8:0];
        b_addr     = 8'((layer == 0) ? 0 : (layer == 1) ? 64 : 128) + 8'({group, 3'b000}) + 8'(lane_cnt);
    end

    // input operand: from feature memory (layer 0) or the activation buffers
    wire signed [7:0] x_in = (layer == 2'd0) ? $signed(feat_rdata) : $signed(act_q);

    // requant for hidden layers
    function automatic logic [7:0] relu_q(input logic signed [31:0] a, input logic [1:0] l);
        logic signed [31:0] s;
        s = (l == 0) ? (a >>> L0_SHIFT) : (a >>> L1_SHIFT);
        return (s < 0) ? 8'd0 : (s > 127) ? 8'd127 : s[7:0];
    endfunction

    assign busy = (st != S_IDLE) && (st != S_DONE);
    assign logit_value = logits[logit_sel];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; layer <= '0; group <= '0; lane_cnt <= '0; i_issue <= '0; vld <= 1'b0;
            act_q <= '0; done <= 1'b0; result_class <= '0;
            for (int l = 0; l < LANES; l++) acc[l] <= '0;
            for (int k = 0; k < 16; k++) logits[k] <= '0;
        end else if (start) begin
            st <= S_BIAS_RD; layer <= '0; group <= '0; lane_cnt <= '0; done <= 1'b0;
        end else begin
            case (st)
                S_IDLE, S_DONE: ;
                // load 8 biases into the accumulators (bias ROM has 1-cycle latency)
                S_BIAS_RD: st <= S_BIAS_LD;
                S_BIAS_LD: begin
                    acc[3'(lane_cnt)] <= $signed(b_q);
                    if (lane_cnt == 4'(LANES - 1)) begin
                        lane_cnt <= '0; i_issue <= '0; vld <= 1'b0; st <= S_MAC;
                    end else begin
                        lane_cnt <= lane_cnt + 4'd1; st <= S_BIAS_RD;
                    end
                end
                // pipelined MAC: fetch input i while accumulating input i-1
                S_MAC: begin
                    if (issue) i_issue <= i_issue + 10'd1;
                    vld   <= issue;
                    act_q <= (layer == 2'd1) ? act_a[6'(i_issue)] : act_b[6'(i_issue)];
                    if (vld)
                        for (int l = 0; l < LANES; l++)
                            acc[l] <= acc[l] + 32'($signed(w_q[8*l +: 8]) * x_in);
                    if (!issue && !vld) st <= S_WB;
                end
                S_WB: begin
                    for (int l = 0; l < LANES; l++) begin
                        if (layer == 2'd0)      act_a[{group[2:0], 3'(l)}] <= relu_q(acc[l], 2'd0);
                        else if (layer == 2'd1) act_b[{group[2:0], 3'(l)}] <= relu_q(acc[l], 2'd1);
                        else                    logits[{group[0], 3'(l)}] <= acc[l];
                    end
                    if (group == 4'(n_out_of(layer) / LANES - 1)) begin
                        group <= '0;
                        if (layer == 2'd2) st <= S_ARGMAX;
                        else begin layer <= layer + 2'd1; st <= S_BIAS_RD; end
                    end else begin
                        group <= group + 4'd1; st <= S_BIAS_RD;
                    end
                end
                S_ARGMAX: begin
                    logic [3:0] best;
                    best = 4'd0;
                    for (int k = 1; k < N_CLASSES; k++) if (logits[k] > logits[best]) best = 4'(k);
                    result_class <= best;
                    done <= 1'b1;
                    st <= S_DONE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
