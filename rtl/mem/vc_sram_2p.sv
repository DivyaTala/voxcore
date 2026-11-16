// Simple dual-port synchronous SRAM: port A writes, port B reads (1-cycle latency).
// See vc_sram_1p.sv for the synthesis black-box convention.
module vc_sram_2p #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 16,
    localparam int AW = $clog2(DEPTH)
) (
    input  logic             clk,
    input  logic             we_a,
    input  logic [AW-1:0]    addr_a,
    input  logic [WIDTH-1:0] wdata_a,
    input  logic             re_b,
    input  logic [AW-1:0]    addr_b,
    output logic [WIDTH-1:0] rdata_b
);
`ifndef VOXCORE_BLACKBOX_MEM
    logic [WIDTH-1:0] mem [DEPTH];
    always_ff @(posedge clk) begin
        if (we_a) mem[addr_a] <= wdata_a;
        if (re_b) rdata_b <= mem[addr_b];
    end
`endif
endmodule
