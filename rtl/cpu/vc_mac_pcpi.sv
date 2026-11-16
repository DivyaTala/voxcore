// ============================================================================
// VC.MAC - custom RISC-V ISA extension on the PicoRV32 co-processor port (PCPI)
//
// Encoding: R-type, opcode custom-0 (0001011), funct7 = 0000000
//
//   funct3  mnemonic        operation                                   rd <=
//   000     vc.mac          acc += rs1 * rs2      (signed, low 32 bits)  acc
//   001     vc.mul          acc  = rs1 * rs2                             acc
//   010     vc.dot4         acc += sum_i s8(rs1.b[i]) * s8(rs2.b[i])     acc
//   011     vc.dot4z        acc  = sum_i s8(rs1.b[i]) * s8(rs2.b[i])     acc
//   100     vc.setacc       acc  = rs1                                   acc
//   101     vc.rdacc        (no change)                                  acc
//   11x     reserved -> not claimed (CPU raises illegal instruction)
//
// Why a hidden accumulator? PCPI (like any 2-read-port core) only delivers
// rs1/rs2, never the old value of rd. Keeping the running sum inside the unit
// removes the extra `add` per loop iteration, so an int8 dot product costs one
// load pair + one vc.dot4 per 4 elements. Trade-off: acc is extra architectural
// state that an OS would have to save on a context switch (fine for bare metal).
//
// Handshake (PicoRV32 PCPI): pcpi_valid stays high until the core sees
// pcpi_ready, so an op is started only on (valid && match && !ready).
// Latency: 1 cycle (ready is registered). Back-to-back ops are supported, which
// the vc_rv32i pipeline relies on.
// ============================================================================
module vc_mac_pcpi (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        pcpi_valid,
    input  logic [31:0] pcpi_insn,
    input  logic [31:0] pcpi_rs1,
    input  logic [31:0] pcpi_rs2,
    output logic        pcpi_wr,
    output logic [31:0] pcpi_rd,
    output logic        pcpi_wait,
    output logic        pcpi_ready
);
    wire [6:0] opcode = pcpi_insn[6:0];
    wire [2:0] funct3 = pcpi_insn[14:12];
    wire [6:0] funct7 = pcpi_insn[31:25];
    wire claim = pcpi_valid && opcode == 7'b0001011 && funct7 == 7'd0 && (funct3 <= 3'b101);
    wire start = claim && !pcpi_ready;

    // datapath
    logic signed [31:0] acc;
    logic signed [63:0] prod32;
    logic signed [17:0] dot;
    assign prod32 = $signed(pcpi_rs1) * $signed(pcpi_rs2);
    always_comb begin
        dot = '0;
        for (int i = 0; i < 4; i++)
            dot += 18'($signed(pcpi_rs1[8*i +: 8]) * $signed(pcpi_rs2[8*i +: 8]));
    end

    logic signed [31:0] acc_next;
    always_comb begin
        case (funct3)
            3'b000:  acc_next = acc + prod32[31:0];
            3'b001:  acc_next = prod32[31:0];
            3'b010:  acc_next = acc + 32'(dot);
            3'b011:  acc_next = 32'(dot);
            3'b100:  acc_next = pcpi_rs1;
            default: acc_next = acc;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= '0; pcpi_ready <= 1'b0; pcpi_rd <= '0;
        end else begin
            pcpi_ready <= start;
            if (start) begin
                acc     <= acc_next;
                pcpi_rd <= acc_next;
            end
        end
    end
    assign pcpi_wr   = pcpi_ready;
    assign pcpi_wait = claim && !pcpi_ready;   // hold off PicoRV32's 16-cycle illegal-insn timeout
endmodule
