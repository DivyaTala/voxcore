// Assertions for aes_apb, attached with bind (see tb_top.sv). They state the
// timing and the security rules of the block as properties, so a violation is
// reported at the clock it happens, not only when a ciphertext comes out wrong.
module aes_sva (
    input logic         clk,
    input logic         rst_n,
    input logic         psel,
    input logic         penable,
    input logic         pwrite,
    input logic [11:0]  paddr,
    input logic [31:0]  prdata,
    input logic         pready,
    input logic         start,
    input logic         clear,
    input logic         busy,
    input logic         done,
    input logic         done_vis,
    input logic [127:0] key_q,
    input logic [127:0] pt_q,
    input logic [127:0] core_rk,
    input logic [127:0] core_state
);
    default clocking cb @(posedge clk); endclocking
    // every property is switched off in reset (written out on each one: not every
    // simulator supports "default disable iff")

    // ---- timing
    // A block takes exactly 10 busy clocks, unless CLEAR cuts it short.
    a_latency:      assert property (disable iff (!rst_n) start |=> (busy && !done) [*10] ##1 (!busy && done)
                                              or (##[0:9] clear));
    a_start_idle:   assert property (disable iff (!rst_n) start |-> !busy);
    a_done_pulse:   assert property (disable iff (!rst_n) done |=> !done);
    a_done_idle:    assert property (disable iff (!rst_n) done |-> !busy);
    a_pready:       assert property (disable iff (!rst_n) psel |-> pready);

    // ---- security rules
    // The key never appears on the read bus.
    a_key_wo:       assert property (disable iff (!rst_n) (psel && !pwrite && paddr[7:4] == 4'h1) |-> prdata == 32'd0);
    // The ciphertext register shows nothing until the block is done.
    a_ct_hidden:    assert property (disable iff (!rst_n) (psel && !pwrite && paddr[7:4] == 4'h3 && !done_vis) |-> prdata == 32'd0);
    // Key and plaintext cannot change under a running block.
    a_key_locked:   assert property (disable iff (!rst_n) (busy && !clear) |=> $stable(key_q) && $stable(pt_q));
    // CLEAR wipes everything in one clock.
    a_clear:        assert property (disable iff (!rst_n) clear |=> key_q == '0 && pt_q == '0 && core_rk == '0 &&
                                               core_state == '0 && !busy && !done_vis);
    // No round key is left in the core once it is idle.
    a_rk_wiped:     assert property (disable iff (!rst_n) !busy |-> core_rk == '0);

    // ---- things the tests must reach
    c_b2b_start:    cover property (disable iff (!rst_n) done ##1 start);                 // start right after a result
    c_clear_busy:   cover property (disable iff (!rst_n) busy && clear);
    c_ct_read_busy: cover property (disable iff (!rst_n) psel && penable && !pwrite && paddr[7:4] == 4'h3 && busy);
    c_key_wr_busy:  cover property (disable iff (!rst_n) psel && penable && pwrite && paddr[7:4] == 4'h1 && busy);
endmodule
