// Single-port 32-bit SRAM with byte write enables (CPU code/data memory).
// Sync read, 1-cycle latency. Black-boxed for synthesis like the other memories.
module vc_sram_bw #(
    parameter int DEPTH = 4096,
    parameter string INIT_FILE = "",
    localparam int AW = $clog2(DEPTH)
) (
    input  logic          clk,
    input  logic          en,
    input  logic [3:0]    wstrb,
    input  logic [AW-1:0] addr,
    input  logic [31:0]   wdata,
    output logic [31:0]   rdata
);
`ifndef VOXCORE_BLACKBOX_MEM
    logic [31:0] mem [DEPTH];
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    always_ff @(posedge clk) begin
        if (en) begin
            for (int b = 0; b < 4; b++) if (wstrb[b]) mem[addr][8*b +: 8] <= wdata[8*b +: 8];
            rdata <= mem[addr];
        end
    end
`endif
endmodule
