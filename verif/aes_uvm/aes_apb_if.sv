// APB interface for the AES peripheral testbench.
// The driver and the monitor each use a clocking block, so there are no races
// with the DUT. cycle counts clock edges; the monitor stamps every transfer
// with it and the scoreboard uses the stamp to model the 10-clock busy window.
interface aes_apb_if (input logic clk, input logic rst_n);
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [11:0] paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;

    int unsigned cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output psel, penable, pwrite, paddr, pwdata;
        input  prdata, pready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input psel, penable, pwrite, paddr, pwdata, prdata, pready, cycle;
    endclocking
endinterface
