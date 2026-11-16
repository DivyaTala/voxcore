// ============================================================================
// Mixed-signal block test: analog sigma-delta RNM + digital PDM decimator.
//
//   PCM vector ─► linear interp x64 (real) ─► sdm_rnm (analog model) ─► pdm_dat
//              ─► pdm_rx (RTL: sync, CIC, FIR) ─► 16 kHz PCM ─► compare with Python
//
// Tests: a 1 kHz / -6 dBFS sine (output also dumped for an SNR measurement on
// the RTL output) and three speech clips. Every output sample must be bit-exact.
// ============================================================================
`timescale 1ns/1ps
module tb_pdm #(
    parameter real OPAMP_GAIN = 0.0,   // non-ideal analog run: -GOPAMP_GAIN=20 etc.
    parameter real NOISE_RMS  = 0.0
);
    localparam bit IDEAL = (OPAMP_GAIN == 0.0) && (NOISE_RMS == 0.0);
    localparam string VEC = "../data/vectors/";
    localparam int DIV = 8;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic run = 0, restart = 0, pdm_clk, pdm_dat, sample_valid, sdm_rst = 0;
    logic [15:0] sample_data;
    real  ain = 0.0;

    pdm_rx  u_dut (.clk, .rst_n, .run, .restart, .div(8'(DIV)), .pdm_clk, .pdm_dat, .sample_valid, .sample_data);
    sdm_rnm #(.OPAMP_GAIN(OPAMP_GAIN), .NOISE_RMS(NOISE_RMS)) u_sdm (.ain, .rst(sdm_rst), .pdm_clk, .dout(pdm_dat));

    // ---- stimulus: PCM -> modulator input, one value per PDM bit (set on the rising edge)
    logic [15:0] pcm [16008];
    int n_pcm, nbit = 0;
    function automatic int s16(input logic [15:0] v); return $signed(v); endfunction
    always @(posedge pdm_clk) begin
        int kk, jj, a, b;
        kk = nbit / 64; jj = nbit % 64;
        a = (kk < n_pcm) ? s16(pcm[kk]) : 0;
        b = (kk + 1 < n_pcm) ? s16(pcm[kk + 1]) : 0;
        ain = real'(a * (64 - jj) + b * jj) / 64.0 / 32768.0;
    end
    always @(negedge pdm_clk) nbit++;

    // ---- capture
    logic [15:0] got [16000], gold [16000];
    int n_got = 0;
    always @(posedge clk) if (sample_valid && n_got < 16000) begin got[n_got] <= sample_data; n_got <= n_got + 1; end

    int total_err = 0;
    task automatic run_test(input string name, input string pcm_file, input string gold_file, input int n_pcm_in,
                            input int n_out, input string dump);
        int err, fd;
        n_pcm = n_pcm_in;
        foreach (pcm[i]) pcm[i] = '0;
        $readmemh(pcm_file, pcm);
        $readmemh(gold_file, gold);
        // power-up: modulator discharged, decimator cleared, clock restarted
        run = 0; @(posedge clk);
        sdm_rst = 1; #1 sdm_rst = 0;
        nbit = 0; n_got = 0;
        @(posedge clk) begin run <= 1; restart <= 1; end
        @(posedge clk) restart <= 0;
        wait (n_got >= n_out);
        @(posedge clk);
        err = 0;
        if (IDEAL) for (int i = 0; i < n_out; i++) if (got[i] !== gold[i]) begin
            if (err < 5) $display("  %s sample %0d: got %0d exp %0d", name, i, $signed(got[i]), $signed(gold[i]));
            err++;
        end
        if (dump != "") begin
            fd = $fopen(dump, "w");
            for (int i = 0; i < n_out; i++) $fdisplay(fd, "%0d", $signed(got[i]));
            $fclose(fd);
        end
        $display("%s: %s  (%0d/%0d mismatches, %0d PDM bits)", name, err ? "FAIL" : "PASS", err, n_out, nbit);
        total_err += err;
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        if (!IDEAL) $display("non-ideal analog model (A=%0.1f, noise=%g): bit-exact checks off, sine dumped", OPAMP_GAIN, NOISE_RMS);
        run_test("sine 1kHz -6dBFS", {VEC, "sine_pcm.hex"}, {VEC, "sine_pdm_out.hex"}, 4104, 4096,
                 IDEAL ? "pdm_sine_rtl.txt" : "pdm_sine_rtl_nonideal.txt");
        if (IDEAL) for (int c = 0; c < 3; c++)
            run_test($sformatf("clip%0d", c), $sformatf("%sclip%0d_pcm.hex", VEC, c),
                     $sformatf("%sclip%0d_pdm_pcm.hex", VEC, c), 16000, 16000, "");
        $display("==== tb_pdm %s ====", total_err ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #2_000_000_000; $display("TIMEOUT"); $finish; end
endmodule
