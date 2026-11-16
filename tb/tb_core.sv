// ============================================================================
// Core-level harness: runs a bare-metal program on either CPU.
//   +HEX=<file>      program image ($readmemh, 32-bit words, loaded at 0x0)
//   +WAIT=<0..100>   % chance of a wait state on every data-bus cycle (stall stress)
//   +TRACE=<file>    vc_rv32i only: dump the retirement trace (pc insn rd wdata)
//   +MAXCYC=<n>      cycle limit (default 2M)
//   +MAXMISS=<n>     vc_rv32i only: fail if branch mispredictions exceed n (perf check)
// Memory map: 0x0000_0000 64 KB RAM, 0x1000_0000 console (byte writes print).
// The run ends when the core halts (EBREAK/ECALL/illegal -> trap).
// Prints "HALT <console text>" so scripts can grep for OK / ERROR.
// Compile-time: -GCPU_SEL=0 (vc_rv32i, default) or -GCPU_SEL=1 (picorv32)
// ============================================================================
`timescale 1ns/1ps
module tb_core #(parameter int CPU_SEL = 0, parameter bit BP_EN = 1);
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [31:0] mem [16384];
    string hexfile, tracefile, console = "";
    int wait_pct = 0, maxcyc = 2_000_000, tf = 0, cyc = 0, maxmiss = -1;
    int bp_ctrl = 0, bp_miss = 0;

    // ---- data bus (both CPUs), PicoRV32-style valid/ready
    logic        d_valid, d_ready; logic [31:0] d_addr, d_wdata, d_rdata; logic [3:0] d_wstrb;
    logic        trap;
    // ---- PCPI + MAC unit (both CPUs)
    logic pcpi_valid, pcpi_wr, pcpi_wait, pcpi_ready; logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2, pcpi_rd;
    vc_mac_pcpi u_mac (.clk, .rst_n, .pcpi_valid, .pcpi_insn, .pcpi_rs1, .pcpi_rs2,
                       .pcpi_wr, .pcpi_rd, .pcpi_wait, .pcpi_ready);

    generate if (CPU_SEL == 0) begin : g_vc
        logic i_en; logic [31:0] i_addr, i_rdata;
        logic rv_valid; logic [31:0] rv_pc, rv_insn, rv_wdata; logic [4:0] rv_rd;
        vc_rv32i #(.BP_EN(BP_EN)) u_cpu (.clk, .rst_n, .imem_en(i_en), .imem_addr(i_addr), .imem_rdata(i_rdata),
            .dmem_valid(d_valid), .dmem_addr(d_addr), .dmem_wdata(d_wdata), .dmem_wstrb(d_wstrb),
            .dmem_ready(d_ready), .dmem_rdata(d_rdata),
            .pcpi_valid, .pcpi_insn, .pcpi_rs1, .pcpi_rs2, .pcpi_wr, .pcpi_rd, .pcpi_wait, .pcpi_ready,
            .trap, .rvfi_valid(rv_valid), .rvfi_pc(rv_pc), .rvfi_insn(rv_insn),
            .rvfi_rd(rv_rd), .rvfi_rd_wdata(rv_wdata));
        always_ff @(posedge clk) if (i_en) i_rdata <= mem[i_addr[15:2]];
        always @(posedge clk) begin bp_ctrl = u_cpu.bp_ctrl_cnt; bp_miss = u_cpu.bp_miss_cnt; end
        always @(posedge clk) if (rst_n && rv_valid && tf != 0)
            $fdisplay(tf, "%08x %08x %0d %08x", rv_pc, rv_insn, rv_rd, rv_wdata);
    end else begin : g_pico
        picorv32 #(.ENABLE_COUNTERS(1), .ENABLE_REGS_DUALPORT(1), .BARREL_SHIFTER(1),
                   .COMPRESSED_ISA(0), .ENABLE_PCPI(1), .PROGADDR_RESET(0), .STACKADDR(32'h10000))
        u_cpu (.clk, .resetn(rst_n), .trap,
            .mem_valid(d_valid), .mem_instr(), .mem_ready(d_ready), .mem_addr(d_addr),
            .mem_wdata(d_wdata), .mem_wstrb(d_wstrb), .mem_rdata(d_rdata),
            .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
            .pcpi_valid, .pcpi_insn, .pcpi_rs1, .pcpi_rs2, .pcpi_wr, .pcpi_rd, .pcpi_wait, .pcpi_ready,
            .irq(32'd0), .eoi(), .trace_valid(), .trace_data());
    end endgenerate

    // ---- data bus slave: RAM + console, random wait states
    always_ff @(posedge clk) begin
        d_ready <= 1'b0;
        if (rst_n && d_valid && !d_ready && ($urandom_range(0, 99) >= wait_pct)) begin
            d_ready <= 1'b1;
            if (d_addr[31:28] == 4'h1) begin
                if (|d_wstrb) begin console = {console, string'(d_wdata[7:0])}; $write("%c", d_wdata[7:0]); end
                d_rdata <= '0;
            end else begin
                for (int i = 0; i < 4; i++) if (d_wstrb[i]) mem[d_addr[15:2]][8*i +: 8] <= d_wdata[8*i +: 8];
                d_rdata <= mem[d_addr[15:2]];
            end
        end
    end

    initial begin
        if (!$value$plusargs("HEX=%s", hexfile)) begin $display("need +HEX="); $finish; end
        void'($value$plusargs("WAIT=%d", wait_pct));
        void'($value$plusargs("MAXCYC=%d", maxcyc));
        void'($value$plusargs("MAXMISS=%d", maxmiss));
        if ($value$plusargs("TRACE=%s", tracefile)) tf = $fopen(tracefile, "w");
        $readmemh(hexfile, mem);
        repeat (3) @(posedge clk);
        rst_n = 1;
        while (!trap && cyc < maxcyc) begin @(posedge clk); cyc++; end
        repeat (5) @(posedge clk);
        if (tf != 0) $fclose(tf);
        if (CPU_SEL == 0)
            $display("\nBPRED control_flow=%0d mispredicts=%0d (%0d.%0d%%)", bp_ctrl, bp_miss,
                     bp_ctrl ? bp_miss * 100 / bp_ctrl : 0, bp_ctrl ? (bp_miss * 1000 / bp_ctrl) % 10 : 0);
        if (maxmiss >= 0 && bp_miss > maxmiss) console = {console, " PERF-FAIL"};
        $display("\nHALT cycles=%0d %s %s", cyc, (cyc >= maxcyc) ? "TIMEOUT" : "", console);
        $finish;
    end
endmodule
