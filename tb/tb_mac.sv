// Constrained-random testbench for vc_mac_pcpi.
// A driver issues random custom-0 instructions with PicoRV32-style handshakes
// (valid held until ready, random idle gaps, and back-to-back issue). A
// reference model predicts the accumulator; every response is checked.
// Coverage counters make sure every opcode, both sign corners and
// back-to-back issue were actually exercised.
`timescale 1ns/1ps
module tb_mac;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic pcpi_valid = 0; logic [31:0] pcpi_insn = '0, pcpi_rs1 = '0, pcpi_rs2 = '0;
    logic pcpi_wr, pcpi_wait, pcpi_ready; logic [31:0] pcpi_rd;
    vc_mac_pcpi dut (.*);

    localparam int N_OPS = 20000;
    int errors = 0;
    int cov_op [8];
    int cov_b2b = 0, cov_neg = 0, cov_illegal = 0;
    logic signed [31:0] model_acc = 0;
    logic prev_legal = 0;

    function automatic logic [31:0] enc(input logic [2:0] f3, input logic [6:0] f7 = 0, input logic [6:0] op = 7'b0001011);
        return {f7, 5'd2, 5'd1, f3, 5'd3, op};   // vc.* x3, x1, x2
    endfunction

    function automatic logic signed [31:0] dot4(input logic [31:0] a, input logic [31:0] b);
        logic signed [31:0] s = 0;
        for (int i = 0; i < 4; i++) s += $signed(a[8*i +: 8]) * $signed(b[8*i +: 8]);
        return s;
    endfunction

    function automatic logic [31:0] rand_operand();
        // bias towards corner values: 0, -1, min/max int, min/max int8 lanes
        case ($urandom_range(0, 9))
            0: return 32'h0000_0000;
            1: return 32'hFFFF_FFFF;
            2: return 32'h8000_0000;
            3: return 32'h7FFF_FFFF;
            4: return 32'h8080_8080;
            5: return 32'h7F7F_7F7F;
            default: return $urandom();
        endcase
    endfunction

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (int n = 0; n < N_OPS; n++) begin
            logic [2:0] f3; logic illegal; logic signed [31:0] exp; int gap; int waited; logic b2b;
            illegal = ($urandom_range(0, 49) == 0);
            f3 = 3'($urandom_range(0, illegal ? 7 : 5));
            gap = ($urandom_range(0, 2) == 0) ? 0 : $urandom_range(1, 3);
            // drive on the falling edge (race-free), DUT samples on the next rising edge
            b2b = (gap == 0 && pcpi_valid && prev_legal);   // previous op left ready high
            if (b2b) cov_b2b++;                              // valid stays high: back-to-back
            if (gap > 0) begin pcpi_valid = 0; repeat (gap) @(negedge clk); end
            pcpi_rs1 = rand_operand(); pcpi_rs2 = rand_operand();
            pcpi_insn = illegal ? (($urandom_range(0,1)) ? enc(f3, 7'h01) : enc(f3, 7'h00, 7'b0101011)) : enc(f3);
            pcpi_valid = 1;
            // latency: 1 cycle; 2 cycles when issued back-to-back (ready of the
            // previous op is still high on the first edge, exactly as in PicoRV32/vc_rv32i)
            waited = 0;
            do begin
                @(negedge clk); waited++;
                if (illegal && pcpi_wait) begin $display("ERROR: claimed illegal insn %h", pcpi_insn); errors++; end
            end while (!pcpi_ready && waited < 20);
            if (illegal) begin
                if (pcpi_ready) begin $display("ERROR: responded to illegal insn %h", pcpi_insn); errors++; end
                cov_illegal++;
            end else begin
                case (f3)
                    3'd0: model_acc = model_acc + $signed(pcpi_rs1) * $signed(pcpi_rs2);
                    3'd1: model_acc = $signed(pcpi_rs1) * $signed(pcpi_rs2);
                    3'd2: model_acc = model_acc + dot4(pcpi_rs1, pcpi_rs2);
                    3'd3: model_acc = dot4(pcpi_rs1, pcpi_rs2);
                    3'd4: model_acc = pcpi_rs1;
                    default: ;
                endcase
                exp = model_acc;
                if (!pcpi_ready || !pcpi_wr || pcpi_rd !== exp) begin
                    if (errors < 10) $display("ERROR op%0d rs1=%h rs2=%h: got %h exp %h (ready=%b)", f3, pcpi_rs1, pcpi_rs2, pcpi_rd, exp, pcpi_ready);
                    errors++;
                end
                if (waited != (b2b ? 2 : 1)) begin $display("ERROR: latency %0d cycles (expected %0d)", waited, b2b ? 2 : 1); errors++; end
                cov_op[f3]++;
                if (exp < 0) cov_neg++;
            end
            prev_legal = !illegal;
        end
        $display("coverage: mac=%0d mul=%0d dot4=%0d dot4z=%0d setacc=%0d rdacc=%0d illegal=%0d b2b=%0d neg=%0d",
                 cov_op[0], cov_op[1], cov_op[2], cov_op[3], cov_op[4], cov_op[5], cov_illegal, cov_b2b, cov_neg);
        for (int i = 0; i < 6; i++) if (cov_op[i] < 100) begin $display("COVERAGE HOLE: op %0d", i); errors++; end
        if (cov_b2b < 100 || cov_illegal < 50) begin $display("COVERAGE HOLE: b2b/illegal"); errors++; end
        $display("==== tb_mac %s (%0d ops) ====", errors ? "FAILED" : "PASSED", N_OPS);
        $finish;
    end
endmodule
