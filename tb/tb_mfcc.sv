// Block-level self-checking testbench for mfcc_engine.
// For each test clip: stream 16000 PCM samples, capture the 490 features the
// engine writes, and compare every one against the Python golden vectors.
`timescale 1ns/1ps
module tb_mfcc;
    localparam string VEC = "../data/vectors/";
    localparam int N_CLIPS = 10;
    localparam int SAMPLE_GAP = 50;   // clocks between samples (engine needs ~13.8k clk/frame)

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic start = 0, busy, done, overflow;
    logic [5:0] frames_done;
    logic sample_valid = 0; logic [15:0] sample_data = '0;
    logic feat_we; logic [8:0] feat_addr; logic [7:0] feat_wdata;

    mfcc_engine dut (.*);

    logic [15:0] pcm  [16000];
    logic [7:0]  gold [490];
    logic [7:0]  got  [490];
    int errors = 0, total_errors = 0;

    always @(posedge clk) if (feat_we) got[feat_addr] <= feat_wdata;

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        for (int c = 0; c < N_CLIPS; c++) begin
            $readmemh($sformatf("%sclip%0d_pcm.hex", VEC, c), pcm);
            $readmemh($sformatf("%sclip%0d_feat.hex", VEC, c), gold);
            foreach (got[i]) got[i] = 'x;
            @(posedge clk) start <= 1; @(posedge clk) start <= 0;
            for (int n = 0; n < 16000; n++) begin
                repeat (SAMPLE_GAP - 1) @(posedge clk);
                sample_valid <= 1; sample_data <= pcm[n];
                @(posedge clk) sample_valid <= 0;
            end
            wait (done);
            @(posedge clk);
            errors = 0;
            for (int i = 0; i < 490; i++) if (got[i] !== gold[i]) begin
                if (errors < 5) $display("  clip%0d feat[%0d] (frame %0d coef %0d): got %0d exp %0d",
                    c, i, i / 10, i % 10, $signed(got[i]), $signed(gold[i]));
                errors++;
            end
            if (overflow) begin $display("  clip%0d: OVERFLOW flag set", c); errors++; end
            $display("clip%0d: %s  (%0d/490 mismatches, frames=%0d)", c, errors ? "FAIL" : "PASS", errors, frames_done);
            total_errors += errors;
        end
        $display("==== tb_mfcc %s ====", total_errors ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #2_000_000_000; $display("TIMEOUT"); $finish; end
endmodule
