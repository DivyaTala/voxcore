// Top level of the UVM testbench for aes_apb.
`timescale 1ns/1ps
module tb_top;
    import uvm_pkg::*;
    import aes_uvm_pkg::*;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    aes_apb_if apb (clk, rst_n);

    aes_apb dut (
        .clk, .rst_n,
        .psel(apb.psel), .penable(apb.penable), .pwrite(apb.pwrite), .paddr(apb.paddr),
        .pwdata(apb.pwdata), .prdata(apb.prdata), .pready(apb.pready));

    // assertions live in their own module and are attached to the DUT here
    bind aes_apb aes_sva u_sva (
        .clk, .rst_n, .psel, .penable, .pwrite, .paddr, .prdata, .pready,
        .start, .clear, .busy, .done, .done_vis, .key_q, .pt_q,
        .core_rk(u_core.rk), .core_state(u_core.state));

    initial begin
        repeat (4) @(posedge clk);
        #1 rst_n = 1;
    end

    initial begin
        uvm_config_db #(virtual aes_apb_if)::set(null, "*", "vif", apb);
        run_test("aes_full_test");
    end
endmodule
