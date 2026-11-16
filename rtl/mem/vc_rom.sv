// Synchronous ROM (1-cycle latency), contents loaded from a .hex file produced by
// model/train.py. In silicon this is either a ROM macro or synthesised logic.
module vc_rom #(
    parameter int DEPTH = 256,
    parameter int WIDTH = 16,
    parameter string INIT_FILE = "",
    localparam int AW = $clog2(DEPTH)
) (
    input  logic             clk,
    input  logic             en,
    input  logic [AW-1:0]    addr,
    output logic [WIDTH-1:0] rdata
);
`ifndef VOXCORE_BLACKBOX_MEM
    logic [WIDTH-1:0] mem [DEPTH];
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    always_ff @(posedge clk) if (en) rdata <= mem[addr];
`endif
endmodule
