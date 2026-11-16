// Block-level self-checking testbench for nn_engine.
// Loads golden int8 features into a feature-memory model, runs the accelerator,
// and checks all 16 logits + the argmax class against the Python golden model.
`timescale 1ns/1ps
module tb_nn;
    localparam string VEC = "../data/vectors/";
    localparam int N_CLIPS = 10;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic start = 0, busy, done;
    logic [3:0] result_class, logit_sel = '0;
    logic [31:0] logit_value;
    logic feat_re; logic [8:0] feat_raddr; logic [7:0] feat_rdata;

    nn_engine dut (.*);

    logic [7:0]  fmem [490];
    logic [31:0] gold_logits [16];
    logic [7:0]  expected [N_CLIPS];
    always @(posedge clk) if (feat_re) feat_rdata <= fmem[feat_raddr];

    int errors, total_errors = 0, t0, cycles;
    initial begin
        $readmemh({VEC, "expected.hex"}, expected);
        repeat (5) @(posedge clk);
        rst_n = 1;
        for (int c = 0; c < N_CLIPS; c++) begin
            $readmemh($sformatf("%sclip%0d_feat.hex", VEC, c), fmem);
            $readmemh($sformatf("%sclip%0d_logits.hex", VEC, c), gold_logits);
            @(posedge clk) start = 1; t0 = $time;
            @(posedge clk) start = 0;
            wait (done);
            cycles = ($time - t0) / 10;
            @(posedge clk);
            errors = 0;
            for (int k = 0; k < 16; k++) begin
                logit_sel = 4'(k); #1;
                if (logit_value !== gold_logits[k]) begin
                    $display("  clip%0d logit[%0d]: got %0d exp %0d", c, k, $signed(logit_value), $signed(gold_logits[k]));
                    errors++;
                end
            end
            if (result_class !== expected[c][3:0]) begin
                $display("  clip%0d class: got %0d exp %0d", c, result_class, expected[c]); errors++;
            end
            $display("clip%0d: %s  class=%0d  (%0d cycles)", c, errors ? "FAIL" : "PASS", result_class, cycles);
            total_errors += errors;
        end
        $display("==== tb_nn %s ====", total_errors ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #100_000_000; $display("TIMEOUT"); $finish; end
endmodule
