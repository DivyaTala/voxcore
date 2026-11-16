// Dual-port 32-bit SRAM: port A = instruction read, port B = data read/write
// with byte enables. Sync read, 1-cycle latency on both ports.
// (A true dual-port macro; black-boxed for synthesis like the other memories.)
module vc_sram_dp_bw #(
    parameter int DEPTH = 4096,
    parameter string INIT_FILE = "",
    localparam int AW = $clog2(DEPTH)
) (
    input  logic          clk,
    input  logic          en_a,
    input  logic [AW-1:0] addr_a,
    output logic [31:0]   rdata_a,
    input  logic          en_b,
    input  logic [3:0]    wstrb_b,
    input  logic [AW-1:0] addr_b,
    input  logic [31:0]   wdata_b,
    output logic [31:0]   rdata_b
);
`ifndef VOXCORE_BLACKBOX_MEM
    logic [31:0] mem [DEPTH];
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    always_ff @(posedge clk) if (en_a) rdata_a <= mem[addr_a];
    always_ff @(posedge clk) begin
        if (en_b) begin
            for (int b = 0; b < 4; b++) if (wstrb_b[b]) mem[addr_b][8*b +: 8] <= wdata_b[8*b +: 8];
            rdata_b <= mem[addr_b];
        end
    end
`endif
endmodule
