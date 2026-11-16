// Single-port synchronous SRAM (1 read OR 1 write per cycle, 1-cycle read latency).
// Behavioral model for simulation. For synthesis define VOXCORE_BLACKBOX_MEM so the
// module becomes a black box, then replace it with a memory-compiler macro
// (e.g. ASAP7 fakeram) of the same port list.
module vc_sram_1p #(
    parameter int DEPTH = 512,
    parameter int WIDTH = 32,
    parameter string INIT_FILE = "",
    localparam int AW = $clog2(DEPTH)
) (
    input  logic             clk,
    input  logic             en,
    input  logic             we,
    input  logic [AW-1:0]    addr,
    input  logic [WIDTH-1:0] wdata,
    output logic [WIDTH-1:0] rdata
);
`ifndef VOXCORE_BLACKBOX_MEM
    logic [WIDTH-1:0] mem [DEPTH];
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    always_ff @(posedge clk) begin
        if (en) begin
            if (we) mem[addr] <= wdata;
            else    rdata     <= mem[addr];
        end
    end
`endif
endmodule
