// Self-checking testbench for aes_apb (AES-128 peripheral).
//
// An APB driver writes the key and plaintext, starts a block and reads the
// ciphertext back; every result is compared with a vector from the Python
// model (model/aes_model.py), whose first seven entries are the FIPS-197 and
// NIST SP 800-38A known answers. On top of the data check, directed tests
// cover the security rules of the register map: the key never reads back, the
// ciphertext is hidden while busy, writes are locked out during a block, and
// CLEAR and reset wipe everything. Coverage counters fail the run if a
// scenario was never exercised.
//
// Runs on Verilator (make aes) and on Icarus Verilog (-g2012).
`timescale 1ns/1ps
module tb_aes;
    localparam int N_VEC = 1000;
    localparam logic [11:0] CTRL = 12'h000, STATUS = 12'h004, KEY0 = 12'h010, PT0 = 12'h020, CT0 = 12'h030;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        psel = 0, penable = 0, pwrite = 0;
    logic [11:0] paddr = '0;
    logic [31:0] pwdata = '0, prdata;
    logic        pready;
    aes_apb dut (.*);

    logic [383:0] vec [0:N_VEC-1];     // {key, plaintext, ciphertext}
    string vecfile;

    int errors = 0;
    int cov_vec = 0, cov_kat = 0, cov_poll = 0, cov_fixed = 0, cov_ct_busy = 0, cov_key_read = 0;
    int cov_lock_key = 0, cov_lock_pt = 0, cov_start_busy = 0, cov_clear_idle = 0, cov_clear_busy = 0;
    int cov_reset_busy = 0, cov_key_reuse = 0, cov_b2b = 0;

    task automatic fail(input string msg);
        if (errors < 20) $display("ERROR @%0t: %s", $time, msg);
        errors++;
    endtask

    // ---- APB driver: signals change on the falling edge, the DUT samples on the rising edge
    task automatic apb_write(input logic [11:0] a, input logic [31:0] d);
        psel = 1; penable = 0; pwrite = 1; paddr = a; pwdata = d;
        @(negedge clk); penable = 1;
        @(negedge clk); psel = 0; penable = 0; pwrite = 0;
    endtask

    task automatic apb_read(input logic [11:0] a, output logic [31:0] d);
        psel = 1; penable = 0; pwrite = 0; paddr = a;
        @(negedge clk); penable = 1;
        #1 d = prdata;
        if (pready !== 1'b1) fail("pready low in the access phase");
        @(negedge clk); psel = 0; penable = 0;
    endtask

    task automatic expect_reg(input logic [11:0] a, input logic [31:0] exp, input string what);
        logic [31:0] d;
        apb_read(a, d);
        if (d !== exp) fail($sformatf("%s: addr %h read %h, expected %h", what, a, d, exp));
    endtask

    task automatic write128(input logic [11:0] base, input logic [127:0] v);
        int first;
        first = $urandom_range(0, 3);            // word order must not matter
        for (int i = 0; i < 4; i++) begin
            int w;
            w = (first + i) % 4;
            apb_write(base + 12'(4 * w), v[127 - 32*w -: 32]);
        end
    endtask

    task automatic read128(input logic [11:0] base, output logic [127:0] v);
        logic [31:0] d;
        for (int w = 0; w < 4; w++) begin
            apb_read(base + 12'(4 * w), d);
            v[127 - 32*w -: 32] = d;
        end
    endtask

    task automatic idle(input int n);
        repeat (n) @(negedge clk);
    endtask

    task automatic wait_done(input int limit);
        logic [31:0] s;
        int n;
        n = 0;
        do begin apb_read(STATUS, s); n++; end while (!s[1] && n < limit);
        if (!s[1]) fail("DONE never set");
        if (s[0])  fail("BUSY still set with DONE");
    endtask

    task automatic check_ct(input logic [127:0] exp, input string what);
        logic [127:0] got;
        read128(CT0, got);
        if (got !== exp) fail($sformatf("%s: ciphertext %h, expected %h", what, got, exp));
    endtask

    // One block from the vector file, with a randomly chosen way of waiting for the result.
    task automatic run_vector(input int n, input logic write_key);
        logic [127:0] key, pt, ct, rb;
        logic [31:0] d;
        int mode;
        {key, pt, ct} = vec[n];
        if (write_key) write128(KEY0, key); else cov_key_reuse++;
        write128(PT0, pt);
        if ($urandom_range(0, 7) == 0) begin
            read128(PT0, rb);
            if (rb !== pt) fail("plaintext did not read back");
            read128(KEY0, rb); cov_key_read++;
            if (rb !== 128'd0) fail($sformatf("key readable over the bus: %h", rb));
        end
        apb_write(CTRL, 32'h1);
        mode = $urandom_range(0, 5);
        case (mode)
            0, 1: begin wait_done(20); cov_poll++; end
            2: begin                                  // fixed wait: done exactly 10 clocks after the start write
                idle(9);
                if (dut.busy !== 1'b1) fail("core finished early");
                idle(1);
                if (dut.busy !== 1'b0 || dut.done_vis !== 1'b1) fail("core not done 11 clocks after start");
                cov_fixed++;
            end
            3: begin                                  // look at CT and KEY while the block is running
                read128(CT0, rb); cov_ct_busy++;
                if (rb !== 128'd0) fail($sformatf("round state visible while busy: %h", rb));
                wait_done(20);
            end
            4: begin                                  // try to change key and plaintext under the block
                apb_write(KEY0 + 12'(4 * $urandom_range(0, 3)), $urandom()); cov_lock_key++;
                apb_write(PT0  + 12'(4 * $urandom_range(0, 3)), $urandom()); cov_lock_pt++;
                apb_read(STATUS, d);
                if (!d[2]) fail("WERR not set after a write during busy");
                wait_done(20);
                read128(PT0, rb);
                if (rb !== pt) fail("plaintext changed by a write during busy");
                apb_write(STATUS, 32'h4);
                expect_reg(STATUS, 32'h2, "WERR write-1-to-clear");
            end
            default: begin                            // second START while busy must be ignored
                apb_write(CTRL, 32'h1); cov_start_busy++;
                apb_read(STATUS, d);
                if (!d[2]) fail("WERR not set after START during busy");
                idle(5);
                if (dut.busy !== 1'b1) fail("core finished early");
                idle(1);                          // 10 clocks after the first START
                if (dut.busy !== 1'b0) fail("START during busy restarted the block");
                wait_done(20);
                apb_write(STATUS, 32'h4);
            end
        endcase
        check_ct(ct, $sformatf("vector %0d", n));
        if (dut.u_core.rk !== 128'd0) fail("round key left in the core after the block");
        cov_vec++;
        if (n < 7) cov_kat++;
    endtask

    initial begin
        logic [127:0] key, pt, ct, rb;
        logic [31:0] d;
        if (!$value$plusargs("VEC=%s", vecfile)) vecfile = "../data/aes_vectors.hex";
        $readmemh(vecfile, vec);
        if (vec[0] === 384'bx) begin $display("ERROR: cannot read %s", vecfile); $finish; end

        idle(3); rst_n = 1; idle(1);

        // ---- reset values
        for (int a = 0; a < 16; a++) expect_reg(12'(4 * a), 32'd0, "reset value");

        // ---- known answers first, then corner and random vectors
        for (int n = 0; n < N_VEC; n++) begin
            if ($urandom_range(0, 2) == 0) idle($urandom_range(1, 4)); else cov_b2b++;
            // some vectors share the key with the one before (corner block): skip the key write
            run_vector(n, !(n > 0 && vec[n][383:256] === vec[n-1][383:256] && $urandom_range(0, 1)));
        end

        // ---- writes that must do nothing: unmapped offsets, setup phase only, psel low
        {key, pt, ct} = vec[1];
        write128(KEY0, key); write128(PT0, pt);
        for (int a = 16; a < 1024; a++) apb_write(12'(4 * a), 32'hFFFF_FFFF);   // includes the aliases of every register
        apb_write(12'h008, 32'hFFFF_FFFF); apb_write(12'h00c, 32'hFFFF_FFFF);
        psel = 1; penable = 0; pwrite = 1; paddr = PT0; pwdata = 32'hBAD0_BAD0;     // setup, never enabled
        @(negedge clk); psel = 0; pwrite = 0;
        psel = 0; penable = 1; pwrite = 1; paddr = PT0; pwdata = 32'hBAD1_BAD1;     // no select
        @(negedge clk); penable = 0; pwrite = 0;
        for (int a = 16; a < 1024; a++) expect_reg(12'(4 * a), 32'd0, "unmapped offset");
        apb_write(CTRL, 32'h1); wait_done(20); check_ct(ct, "after ignored writes");

        // ---- CLEAR when idle: data gone, and the key is really zero afterwards
        apb_write(CTRL, 32'h2); cov_clear_idle++;
        expect_reg(STATUS, 32'd0, "STATUS after CLEAR");
        read128(PT0, rb); if (rb !== 128'd0) fail("plaintext survived CLEAR");
        read128(CT0, rb); if (rb !== 128'd0) fail("ciphertext survived CLEAR");
        if (dut.key_q !== 128'd0 || dut.u_core.state !== 128'd0) fail("key or state survived CLEAR");
        apb_write(CTRL, 32'h1); wait_done(20);
        check_ct(128'h66e94bd4ef8a2c3b884cfa59ca342b2e, "all-zero block after CLEAR");

        // ---- CLEAR in the middle of a block aborts it; START+CLEAR together is a CLEAR
        for (int k = 1; k <= 10; k++) begin
            {key, pt, ct} = vec[10 + k];
            write128(KEY0, key); write128(PT0, pt);
            apb_write(CTRL, 32'h1); idle(k - 1);
            apb_write(CTRL, (k % 2) ? 32'h2 : 32'h3); cov_clear_busy++;
            if (dut.busy !== 1'b0) fail("CLEAR did not abort the block");
            idle(15);
            expect_reg(STATUS, 32'd0, "STATUS after aborted block");
            read128(CT0, rb); if (rb !== 128'd0) fail("ciphertext visible after aborted block");
            if (dut.key_q !== 128'd0 || dut.u_core.rk !== 128'd0 || dut.u_core.state !== 128'd0)
                fail("key material survived CLEAR during a block");
        end

        // ---- reset in the middle of a block
        for (int k = 1; k <= 10; k++) begin
            {key, pt, ct} = vec[30 + k];
            write128(KEY0, key); write128(PT0, pt);
            apb_write(CTRL, 32'h1); idle(k - 1);
            #2 rst_n = 0; cov_reset_busy++;
            #3 if (dut.busy !== 1'b0 || dut.u_core.rk !== 128'd0 || dut.key_q !== 128'd0) fail("reset did not wipe the core");
            idle(2); rst_n = 1; idle(1);
            for (int a = 0; a < 16; a++) expect_reg(12'(4 * a), 32'd0, "value after reset in a block");
            run_vector(30 + k, 1'b1);
        end

        // ---- coverage
        $display("coverage: vectors=%0d known-answer=%0d poll=%0d fixed-wait=%0d ct-while-busy=%0d key-read=%0d",
                 cov_vec, cov_kat, cov_poll, cov_fixed, cov_ct_busy, cov_key_read);
        $display("coverage: locked-key=%0d locked-pt=%0d start-while-busy=%0d key-reuse=%0d back-to-back=%0d clear-idle=%0d clear-busy=%0d reset-busy=%0d",
                 cov_lock_key, cov_lock_pt, cov_start_busy, cov_key_reuse, cov_b2b, cov_clear_idle, cov_clear_busy, cov_reset_busy);
        if (cov_kat < 7 || cov_vec < N_VEC) fail("COVERAGE HOLE: vectors");
        if (cov_poll < 50 || cov_fixed < 50 || cov_ct_busy < 50 || cov_key_read < 50) fail("COVERAGE HOLE: wait modes");
        if (cov_lock_key < 50 || cov_lock_pt < 50 || cov_start_busy < 50) fail("COVERAGE HOLE: locked writes");
        if (cov_key_reuse < 3 || cov_b2b < 100) fail("COVERAGE HOLE: key reuse / back-to-back");
        if (cov_clear_idle < 1 || cov_clear_busy < 10 || cov_reset_busy < 10) fail("COVERAGE HOLE: clear / reset");
        $display("==== tb_aes %s (%0d blocks, %0d errors) ====", errors ? "FAILED" : "PASSED", cov_vec, errors);
        $finish;
    end

    initial begin #50_000_000; $display("==== tb_aes FAILED (timeout) ===="); $finish; end
endmodule
