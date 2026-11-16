// ============================================================================
// End-to-end SoC testbench: "WAV in, digit out".
//
//   - boots the firmware on the selected CPU (vc_rv32i or PicoRV32), waits for "VoxCore ready" on the UART
//   - presses the talk button, waits for the listening LED
//   - plays one test clip over I2S (16 kHz, 16-bit slots, left channel), or with
//     +SRC=PDM through the analog sigma-delta model (sdm_rnm) into the PDM pins:
//     the PDM-strap GPIO is set, firmware selects the PDM source, the chip
//     generates pdm_clk and decimates the 1-bit stream on chip
//   - waits for the done bit, then checks:
//       * the 490 features in the feature RAM vs Python      (hierarchical peek)
//       * the 16 logits vs Python
//       * the class on GPIO and in the UART message vs Python
//
// usage: Vtb_soc +CLIP=<0..9> [+SRC=PDM]   (default clip 0, I2S)
// ============================================================================
`timescale 1ns/1ps
module tb_soc #(parameter int CPU_SEL = 0, parameter bit BP_EN = 1);
    localparam string VEC = "../data/vectors/";
    localparam int CLK_NS = 10;        // 100 MHz system clock
    localparam int SCK_HALF_NS = 40;   // 12.5 MHz I2S SCK in sim (fast-forwarded audio);
                                       // real 16 kHz x 32 = 512 kHz, the design is rate-agnostic

    logic clk = 0, rst_n = 0;
    always #(CLK_NS/2) clk = ~clk;

    logic i2s_sck = 0, i2s_ws = 1, i2s_sd = 0, uart_tx;
    logic [7:0] gpio_in = '0, gpio_out;
    logic trap;
    logic pdm_clk, pdm_dat;
    real  ain = 0.0;

    voxcore_top #(.CPU_SEL(CPU_SEL), .BP_EN(BP_EN)) dut (.*);

    // predictor statistics (hierarchy only exists when the own core is selected)
    int bp_ctrl = 0, bp_miss = 0;
    generate if (CPU_SEL == 0) begin : g_bp
        always @(posedge clk) begin
            bp_ctrl = dut.g_vc_rv32i.u_cpu.bp_ctrl_cnt;
            bp_miss = dut.g_vc_rv32i.u_cpu.bp_miss_cnt;
        end
    end endgenerate

    // ---------------------------------------------------------- UART monitor
    localparam int UART_BIT = 16;      // must match UART_CLKS_PER_BIT in fw
    string uart_line = "", uart_log = "";
    bit    boot_done = 0;
    initial forever begin
        @(negedge uart_tx);
        repeat (UART_BIT + UART_BIT/2) @(posedge clk);
        begin
            logic [7:0] ch;
            for (int b = 0; b < 8; b++) begin ch[b] = uart_tx; repeat (UART_BIT) @(posedge clk); end
            if (ch == 8'h0a) begin $display("[uart] %s", uart_line); if (uart_line == "VoxCore ready") boot_done = 1; uart_log = {uart_log, uart_line, "\n"}; uart_line = ""; end
            else uart_line = {uart_line, string'(ch)};
        end
    end

    // ---------------------------------------------------------- I2S master model
    logic [15:0] pcm [16000];
    task automatic i2s_word(input logic ws, input logic [15:0] w);
        // Philips I2S: WS changes on SCK falling edge, MSB one SCK later
        for (int b = 15; b >= 0; b--) begin
            #(SCK_HALF_NS) i2s_sck = 0;
            if (b == 15) i2s_ws = ws;
            i2s_sd = (b == 15) ? prev_lsb : w[b + 1];
            #(SCK_HALF_NS) i2s_sck = 1;
        end
        prev_lsb = w[0];
    endtask
    logic prev_lsb = 0;

    // ---------------------------------------------------------- PDM microphone (analog model)
    // Same stimulus as tb_pdm: PCM linearly interpolated x64 to one modulator input
    // per PDM bit. The modulator starts when the chip starts pdm_clk.
    bit use_pdm = 0;
    int nbit = 0;
    sdm_rnm u_mic (.ain, .rst(1'b0), .pdm_clk, .dout(pdm_dat));
    function automatic int s16(input logic [15:0] v); return $signed(v); endfunction
    always @(posedge pdm_clk) begin
        int kk, jj, a, b;
        kk = nbit / 64; jj = nbit % 64;
        a = (kk < 16000) ? s16(pcm[kk]) : 0;
        b = (kk + 1 < 16000) ? s16(pcm[kk + 1]) : 0;
        ain = use_pdm ? real'(a * (64 - jj) + b * jj) / 64.0 / 32768.0 : 0.0;
    end
    always @(negedge pdm_clk) nbit++;

    // ---------------------------------------------------------- checks
    logic [7:0]  gold_feat [490];
    logic [31:0] gold_logits [16];
    logic [7:0]  expected [10];
    int clip = 0, errors = 0;

    string src, tag = "", cpu_name;
    initial begin
        if (!$value$plusargs("CLIP=%d", clip)) clip = 0;
        if ($value$plusargs("SRC=%s", src)) use_pdm = (src == "PDM");
        if (use_pdm) tag = "pdm_";              // (a string ternary would pad "" with spaces)
        cpu_name = (CPU_SEL != 0) ? "picorv32" : "vc_rv32i";
        if (use_pdm) cpu_name = {cpu_name, ",pdm"};
        $readmemh($sformatf("%sclip%0d_pcm.hex", VEC, clip), pcm);
        $readmemh($sformatf("%sclip%0d_%sfeat.hex", VEC, clip, tag), gold_feat);
        $readmemh($sformatf("%sclip%0d_%slogits.hex", VEC, clip, tag), gold_logits);
        if (use_pdm) $readmemh({VEC, "expected_pdm.hex"}, expected);
        else         $readmemh({VEC, "expected.hex"}, expected);
        gpio_in[1] = use_pdm;                      // board strap: PDM microphone fitted

        repeat (10) @(posedge clk);
        rst_n = 1;
        wait (boot_done);                          // "VoxCore ready" (after the MAC self-test)
        gpio_in[0] = 1;                            // press talk button
        wait (gpio_out[1]);                        // listening LED
        if (use_pdm) begin
            $display("[tb] clip%0d -> analog sigma-delta model -> PDM pins", clip);
            wait (nbit >= 16000 * 64);             // the chip clocks the mic; just wait
        end else begin
            $display("[tb] streaming clip%0d over I2S", clip);
            i2s_word(1'b1, 16'h0000);              // leading right slot
            for (int n = 0; n < 16000; n++) begin
                i2s_word(1'b0, pcm[n]);
                i2s_word(1'b1, 16'h0000);
            end
        end
        gpio_in[0] = 0;                            // release button
        wait (gpio_out[2]);
        repeat (UART_BIT * 10 * 30) @(posedge clk); // let the UART line finish

        // feature RAM vs golden
        for (int i = 0; i < 490; i++)
            if (dut.u_voice.u_feat.mem[i] !== gold_feat[i]) begin
                if (errors < 5) $display("  feat[%0d] got %0d exp %0d", i,
                    $signed(dut.u_voice.u_feat.mem[i]), $signed(gold_feat[i]));
                errors++;
            end
        for (int k = 0; k < 16; k++)
            if (dut.u_voice.u_nn.logits[k] !== gold_logits[k]) begin
                $display("  logit[%0d] got %0d exp %0d", k, dut.u_voice.u_nn.logits[k], $signed(gold_logits[k]));
                errors++;
            end
        if (gpio_out[7:4] !== expected[clip][3:0]) begin
            $display("  GPIO class %0d, expected %0d", gpio_out[7:4], expected[clip]); errors++;
        end
        if (!has_sub(uart_log, $sformatf("DIGIT=%0d", expected[clip]))) begin
            $display("  UART did not report DIGIT=%0d", expected[clip]); errors++;
        end
        if (!has_sub(uart_log, "MACTEST PASS")) begin
            $display("  firmware VC.MAC self-test did not pass"); errors++;
        end
        if (trap) begin $display("  CPU trapped"); errors++; end
        if (CPU_SEL == 0)
            $display("  [vc_rv32i] branch predictor %s: %0d control-flow instrs, %0d mispredicted",
                     BP_EN ? "on" : "off", bp_ctrl, bp_miss);
        if (use_pdm) $display("  [pdm] %0d PDM bits from the analog model", nbit);
        $display("==== tb_soc[%s] clip%0d %s (digit %0d, %0.1f ms sim time) ====",
                 cpu_name, clip, errors ? "FAILED" : "PASSED", gpio_out[7:4], $realtime / 1e6);
        $finish;
    end

    function automatic bit has_sub(string s, string sub);
        for (int i = 0; i + sub.len() <= s.len(); i++) if (s.substr(i, i + sub.len() - 1) == sub) return 1;
        return 0;
    endfunction

    initial begin #500_000_000; $display("TIMEOUT"); $finish; end
endmodule
