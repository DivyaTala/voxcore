// ============================================================================
// vc_rv32i - 5-stage pipelined RV32I core (IF ID EX MEM WB)
//
//   IF  : PC select + synchronous instruction SRAM access. The SRAM's output
//         register *is* the IF/ID pipeline register (stall = SRAM enable low).
//   ID  : decode, register file read (with WB->ID write-through bypass),
//         load-use hazard detection.
//   EX  : ALU, branch compare + target, CSR read, forwarding muxes
//         (EX/MEM and MEM/WB -> EX), custom-0 instructions via a PCPI port.
//   MEM : data bus access (valid/ready, stalls the pipe), load align/extend.
//   WB  : register file write, retirement trace.
//
// Hazards
//   data    : full forwarding; 1 bubble for load-use.
//   control : dynamic branch prediction at fetch (BP_EN=1):
//               - 16-entry direct-mapped BTB (tag, target, type, 2-bit counter)
//               - 2-bit saturating counters give the conditional direction
//               - 4-entry return-address stack for function returns
//             predictions are checked in EX; a mispredict squashes the one
//             instruction in ID (1-cycle penalty), a correct one costs 0.
//             BP_EN=0 -> static not-taken (every taken branch costs 1 cycle).
//   struct. : Harvard buses (separate instruction / data ports).
// Supported : all of RV32I except FENCE.I/ECALL semantics (ECALL/EBREAK halt
//             the core with `trap`), Zicntr reads (cycle/instret), and the
//             VC.MAC custom-0 extension through PCPI.
// Assumes naturally aligned loads/stores (no misaligned-access trap).
// ============================================================================
module vc_rv32i #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000,
    parameter bit          BP_EN    = 1'b1,      // dynamic branch prediction
    parameter int          BTB_ENTRIES = 16,     // power of two
    parameter int          RAS_DEPTH   = 4
) (
    input  logic        clk,
    input  logic        rst_n,
    // instruction port: synchronous SRAM, fixed 1-cycle latency
    output logic        imem_en,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    // data port: valid held until ready (PicoRV32 native-bus compatible)
    output logic        dmem_valid,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_wstrb,
    input  logic        dmem_ready,
    input  logic [31:0] dmem_rdata,
    // PCPI co-processor port (same protocol as PicoRV32)
    output logic        pcpi_valid,
    output logic [31:0] pcpi_insn,
    output logic [31:0] pcpi_rs1,
    output logic [31:0] pcpi_rs2,
    input  logic        pcpi_wr,
    input  logic [31:0] pcpi_rd,
    input  logic        pcpi_wait,
    input  logic        pcpi_ready,
    output logic        trap,
    // retirement trace (one entry per retired instruction, in WB)
    output logic        rvfi_valid,
    output logic [31:0] rvfi_pc,
    output logic [31:0] rvfi_insn,
    output logic [4:0]  rvfi_rd,
    output logic [31:0] rvfi_rd_wdata
);
    // ------------------------------------------------------------------ decode
    localparam logic [6:0] OP_LUI = 7'b0110111, OP_AUIPC = 7'b0010111, OP_JAL = 7'b1101111,
                           OP_JALR = 7'b1100111, OP_BRANCH = 7'b1100011, OP_LOAD = 7'b0000011,
                           OP_STORE = 7'b0100011, OP_IMM = 7'b0010011, OP_REG = 7'b0110011,
                           OP_FENCE = 7'b0001111, OP_SYSTEM = 7'b1110011, OP_CUSTOM0 = 7'b0001011;

    typedef struct packed {
        logic        uses_rs1, uses_rs2, writes_rd;
        logic        is_load, is_store, is_branch, is_jal, is_jalr, is_lui, is_auipc;
        logic        is_alu_imm, is_alu_reg, is_csr, is_pcpi, is_halt, illegal;
        logic [31:0] imm;
    } dec_t;

    function automatic dec_t decode(input logic [31:0] in);
        dec_t d;
        logic [6:0] op; logic [2:0] f3; logic [6:0] f7;
        op = in[6:0]; f3 = in[14:12]; f7 = in[31:25];
        d = '0;
        case (op)
            OP_LUI:    begin d.is_lui = 1; d.writes_rd = 1; d.imm = {in[31:12], 12'd0}; end
            OP_AUIPC:  begin d.is_auipc = 1; d.writes_rd = 1; d.imm = {in[31:12], 12'd0}; end
            OP_JAL:    begin d.is_jal = 1; d.writes_rd = 1;
                             d.imm = {{12{in[31]}}, in[19:12], in[20], in[30:21], 1'b0}; end
            OP_JALR:   begin d.is_jalr = 1; d.writes_rd = 1; d.uses_rs1 = 1;
                             d.imm = {{20{in[31]}}, in[31:20]}; d.illegal = (f3 != 3'd0); end
            OP_BRANCH: begin d.is_branch = 1; d.uses_rs1 = 1; d.uses_rs2 = 1;
                             d.imm = {{20{in[31]}}, in[7], in[30:25], in[11:8], 1'b0};
                             d.illegal = (f3 == 3'd2) || (f3 == 3'd3); end
            OP_LOAD:   begin d.is_load = 1; d.writes_rd = 1; d.uses_rs1 = 1;
                             d.imm = {{20{in[31]}}, in[31:20]};
                             d.illegal = (f3 == 3'd3) || (f3 == 3'd6) || (f3 == 3'd7); end
            OP_STORE:  begin d.is_store = 1; d.uses_rs1 = 1; d.uses_rs2 = 1;
                             d.imm = {{20{in[31]}}, in[31:25], in[11:7]}; d.illegal = (f3 > 3'd2); end
            OP_IMM:    begin d.is_alu_imm = 1; d.writes_rd = 1; d.uses_rs1 = 1;
                             d.imm = {{20{in[31]}}, in[31:20]};
                             if (f3 == 3'd1) d.illegal = (f7 != 7'd0);
                             if (f3 == 3'd5) d.illegal = (f7 != 7'd0) && (f7 != 7'b0100000); end
            OP_REG:    begin d.is_alu_reg = 1; d.writes_rd = 1; d.uses_rs1 = 1; d.uses_rs2 = 1;
                             d.illegal = !((f7 == 7'd0) || (f7 == 7'b0100000 && (f3 == 3'd0 || f3 == 3'd5))); end
            OP_FENCE:  ;                                         // no caches: FENCE is a NOP
            OP_SYSTEM: begin
                if (f3 == 3'd0) d.is_halt = 1;                   // ECALL / EBREAK / xRET -> halt
                else begin d.is_csr = 1; d.writes_rd = 1; d.uses_rs1 = !f3[2]; end
            end
            OP_CUSTOM0: begin d.is_pcpi = 1; d.writes_rd = 1; d.uses_rs1 = 1; d.uses_rs2 = 1; end
            default:   d.illegal = 1;
        endcase
        if (in[11:7] == 5'd0) d.writes_rd = 0;                   // x0 is never written
        return d;
    endfunction

    // ------------------------------------------------------------------ state
    logic        started, trap_r;
    // IF/ID
    logic        id_valid;  logic [31:0] id_pc;
    // ID/EX
    logic        ex_valid;  logic [31:0] ex_pc, ex_insn, ex_rs1_val, ex_rs2_val; dec_t ex_d;
    logic        ex_pcpi_done; logic [31:0] ex_pcpi_res;
    logic        ex_pred_taken; logic [31:0] ex_pred_target;
    // EX/MEM
    logic        mem_valid, mem_wen, mem_is_load, mem_is_store;
    logic [4:0]  mem_rd;  logic [2:0] mem_f3;  logic [1:0] mem_off;
    logic [31:0] mem_pc, mem_insn, mem_result, mem_addr_w, mem_wdata_w; logic [3:0] mem_wstrb_w;
    // MEM/WB
    logic        wb_valid, wb_wen;  logic [4:0] wb_rd;  logic [31:0] wb_data, wb_pc, wb_insn;
    // architectural
    logic [31:0] rf [32];
    logic [63:0] cycle_cnt, instret_cnt;

    // ------------------------------------------------------------------ ID
    wire [31:0] id_insn = imem_rdata;
    dec_t id_d;
    assign id_d = decode(id_insn);
    wire [4:0] id_rs1 = id_insn[19:15], id_rs2 = id_insn[24:20];
    // register read with WB write-through (WB writes and ID reads in the same cycle)
    wire [31:0] id_rs1_val = (id_rs1 == 5'd0) ? 32'd0 :
                             (wb_valid && wb_wen && wb_rd == id_rs1) ? wb_data : rf[id_rs1];
    wire [31:0] id_rs2_val = (id_rs2 == 5'd0) ? 32'd0 :
                             (wb_valid && wb_wen && wb_rd == id_rs2) ? wb_data : rf[id_rs2];

    wire [4:0] ex_rd  = ex_insn[11:7];
    wire [4:0] ex_rs1 = ex_insn[19:15], ex_rs2 = ex_insn[24:20];
    wire load_use = id_valid && ex_valid && ex_d.is_load && ex_d.writes_rd &&
                    ((id_d.uses_rs1 && id_rs1 == ex_rd) || (id_d.uses_rs2 && id_rs2 == ex_rd));

    // ------------------------------------------------------------------ EX
    // forwarding: EX/MEM first (younger), then MEM/WB, else the value read in ID
    function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] v);
        if (r == 5'd0)                                          return 32'd0;
        if (mem_valid && mem_wen && !mem_is_load && mem_rd == r) return mem_result;
        if (wb_valid && wb_wen && wb_rd == r)                    return wb_data;
        return v;
    endfunction
    wire [31:0] a = fwd(ex_rs1, ex_rs1_val);
    wire [31:0] b = fwd(ex_rs2, ex_rs2_val);
    wire [2:0]  ex_f3 = ex_insn[14:12];
    wire        ex_f7b5 = ex_insn[30];

    logic [31:0] alu_b, alu_out;
    always_comb begin
        alu_b = ex_d.is_alu_imm ? ex_d.imm : b;
        case (ex_f3)
            3'd0: alu_out = (ex_d.is_alu_reg && ex_f7b5) ? a - alu_b : a + alu_b;
            3'd1: alu_out = a << alu_b[4:0];
            3'd2: alu_out = {31'd0, $signed(a) < $signed(alu_b)};
            3'd3: alu_out = {31'd0, a < alu_b};
            3'd4: alu_out = a ^ alu_b;
            3'd5: alu_out = ex_f7b5 ? 32'($signed(a) >>> alu_b[4:0]) : a >> alu_b[4:0];
            3'd6: alu_out = a | alu_b;
            default: alu_out = a & alu_b;
        endcase
    end

    logic br_cond;
    always_comb begin
        case (ex_f3)
            3'd0: br_cond = (a == b);
            3'd1: br_cond = (a != b);
            3'd4: br_cond = ($signed(a) <  $signed(b));
            3'd5: br_cond = ($signed(a) >= $signed(b));
            3'd6: br_cond = (a <  b);
            default: br_cond = (a >= b);
        endcase
    end
    wire        ex_taken  = ex_valid && (ex_d.is_jal || ex_d.is_jalr || (ex_d.is_branch && br_cond));
    wire [31:0] ex_target = ex_d.is_jalr ? ((a + ex_d.imm) & ~32'd1) : (ex_pc + ex_d.imm);

    logic [31:0] csr_val;
    always_comb begin
        case (ex_insn[31:20])
            12'hC00, 12'hB00: csr_val = cycle_cnt[31:0];
            12'hC80, 12'hB80: csr_val = cycle_cnt[63:32];
            12'hC02, 12'hB02: csr_val = instret_cnt[31:0];
            12'hC82, 12'hB82: csr_val = instret_cnt[63:32];
            12'hC03, 12'hB03: csr_val = bp_ctrl_cnt;     // hpmcounter3: control-flow instrs
            12'hC04, 12'hB04: csr_val = bp_miss_cnt;     // hpmcounter4: mispredictions
            default:          csr_val = 32'd0;
        endcase
    end

    // custom-0 -> PCPI. Valid until the co-processor answers; the answer is
    // latched if the pipe cannot move on in that cycle (MEM stall).
    assign pcpi_valid = ex_valid && ex_d.is_pcpi && !ex_pcpi_done && !trap_r;
    assign pcpi_insn  = ex_insn;
    assign pcpi_rs1   = a;
    assign pcpi_rs2   = b;
    wire        pcpi_ok  = ex_pcpi_done || (pcpi_ready && pcpi_wr);
    wire [31:0] pcpi_res = ex_pcpi_done ? ex_pcpi_res : pcpi_rd;
    wire        pcpi_unclaimed = pcpi_valid && !pcpi_wait && !pcpi_ready;

    wire ex_halt = ex_valid && (ex_d.illegal || ex_d.is_halt || pcpi_unclaimed);

    logic [31:0] ex_result;
    always_comb begin
        if (ex_d.is_lui)                    ex_result = ex_d.imm;
        else if (ex_d.is_auipc)             ex_result = ex_pc + ex_d.imm;
        else if (ex_d.is_jal || ex_d.is_jalr) ex_result = ex_pc + 32'd4;
        else if (ex_d.is_csr)               ex_result = csr_val;
        else if (ex_d.is_pcpi)              ex_result = pcpi_res;
        else                                ex_result = alu_out;
    end

    // memory request formatting (store data replicated / strobed per byte lane)
    wire [31:0] ex_addr = a + ex_d.imm;
    logic [31:0] ex_wdata; logic [3:0] ex_wstrb;
    always_comb begin
        case (ex_f3[1:0])
            2'd0:    begin ex_wdata = {4{b[7:0]}};  ex_wstrb = 4'b0001 << ex_addr[1:0]; end
            2'd1:    begin ex_wdata = {2{b[15:0]}}; ex_wstrb = ex_addr[1] ? 4'b1100 : 4'b0011; end
            default: begin ex_wdata = b;            ex_wstrb = 4'b1111; end
        endcase
    end

    // ------------------------------------------------------------------ MEM
    assign dmem_valid = mem_valid && (mem_is_load || mem_is_store);
    assign dmem_addr  = {mem_addr_w[31:2], 2'b00};
    assign dmem_wdata = mem_wdata_w;
    assign dmem_wstrb = mem_is_store ? mem_wstrb_w : 4'b0000;

    logic [31:0] load_val, ld_sh;
    always_comb begin
        ld_sh = dmem_rdata >> {mem_off, 3'b000};
        case (mem_f3)
            3'd0: load_val = {{24{ld_sh[7]}},  ld_sh[7:0]};
            3'd1: load_val = {{16{ld_sh[15]}}, ld_sh[15:0]};
            3'd4: load_val = {24'd0, ld_sh[7:0]};
            3'd5: load_val = {16'd0, ld_sh[15:0]};
            default: load_val = dmem_rdata;
        endcase
    end

    // ------------------------------------------------------------------ branch prediction
    // Looked up with id_pc (a register), so the predictor is not on the
    // SRAM-data -> SRAM-address path: it predicts the successor of the
    // instruction now in ID, i.e. the address fetched this cycle.
    localparam int BI = $clog2(BTB_ENTRIES);
    localparam int TW = 16 - 2 - BI;                  // tag bits (16-bit address space)
    localparam logic [1:0] T_BR = 2'd0, T_JMP = 2'd1, T_RET = 2'd2;
    logic          btb_v   [BTB_ENTRIES];
    logic [TW-1:0] btb_tag [BTB_ENTRIES];
    logic [31:0]   btb_tgt [BTB_ENTRIES];
    logic [1:0]    btb_typ [BTB_ENTRIES];
    logic [1:0]    btb_ctr [BTB_ENTRIES];
    logic [31:0]   ras     [RAS_DEPTH];
    logic [$clog2(RAS_DEPTH)-1:0] ras_sp;         // points at the top entry
    logic [$clog2(RAS_DEPTH):0]   ras_cnt;

    function automatic logic [BI-1:0] bidx(input logic [31:0] pc); return pc[BI+1:2]; endfunction
    function automatic logic [TW-1:0] btag(input logic [31:0] pc); return pc[15:BI+2]; endfunction

    wire [BI-1:0] f_idx = bidx(id_pc);
    wire f_hit = BP_EN && id_valid && btb_v[f_idx] && btb_tag[f_idx] == btag(id_pc);
    wire f_ret = f_hit && btb_typ[f_idx] == T_RET && ras_cnt != 0;
    wire        pred_taken  = f_hit && (btb_typ[f_idx] != T_BR || btb_ctr[f_idx][1]);
    wire [31:0] pred_target = f_ret ? ras[ras_sp] : btb_tgt[f_idx];

    // resolution in EX
    wire        ex_ctrl    = ex_valid && (ex_d.is_branch || ex_d.is_jal || ex_d.is_jalr);
    wire [31:0] ex_next    = ex_taken ? ex_target : ex_pc + 32'd4;
    wire        mispredict = ex_valid && ((ex_pred_taken != ex_taken) ||
                                          (ex_taken && ex_pred_target != ex_target));
    wire        is_link_rs1 = (ex_rs1 == 5'd1 || ex_rs1 == 5'd5);
    wire [1:0]  ex_typ = ex_d.is_branch ? T_BR :
                         (ex_d.is_jalr && is_link_rs1 && ex_rd == 5'd0) ? T_RET : T_JMP;
    wire [BI-1:0] u_idx = bidx(ex_pc);
    wire u_hit = btb_v[u_idx] && btb_tag[u_idx] == btag(ex_pc);

    // call / return detection for the RAS (done when the instruction leaves ID,
    // which only happens on the correct path, so the stack needs no repair)
    wire [4:0] id_rd = id_insn[11:7];
    wire id_is_jump = id_d.is_jal || id_d.is_jalr;
    wire id_call = id_valid && id_is_jump && (id_rd == 5'd1 || id_rd == 5'd5);
    wire id_ret  = id_valid && id_d.is_jalr && (id_rs1 == 5'd1 || id_rs1 == 5'd5) && id_rd == 5'd0;

    // performance counters (read through hpmcounter3/4 CSRs and the TB)
    logic [31:0] bp_ctrl_cnt, bp_miss_cnt;

    // ------------------------------------------------------------------ pipeline control
    wire mem_stall = dmem_valid && !dmem_ready;
    wire ex_stall  = ex_valid && (ex_halt || (ex_d.is_pcpi && !pcpi_ok)) ;
    wire adv_mem   = !mem_stall;                    // MEM -> WB
    wire adv_ex    = adv_mem && !ex_stall;          // EX  -> MEM
    wire redirect  = mispredict && adv_ex;
    wire adv_id    = adv_ex && (!load_use || redirect);   // ID -> EX (or squash)
    wire adv_if    = adv_id || !started;            // fetch next

    assign imem_en   = adv_if;
    assign imem_addr = !started ? RESET_PC : redirect ? ex_next :
                       pred_taken ? pred_target : id_pc + 32'd4;
    assign trap      = trap_r && !mem_valid && !wb_valid;   // precise: older instructions have retired

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            started <= 1'b0; trap_r <= 1'b0;
            id_valid <= 1'b0; id_pc <= RESET_PC;
            ex_valid <= 1'b0; ex_pc <= '0; ex_insn <= 32'h0000_0013; ex_d <= '0;
            ex_rs1_val <= '0; ex_rs2_val <= '0; ex_pcpi_done <= 1'b0; ex_pcpi_res <= '0;
            ex_pred_taken <= 1'b0; ex_pred_target <= '0;
            mem_valid <= 1'b0; mem_wen <= 1'b0; mem_is_load <= 1'b0; mem_is_store <= 1'b0;
            mem_rd <= '0; mem_f3 <= '0; mem_off <= '0; mem_pc <= '0; mem_insn <= '0;
            mem_result <= '0; mem_addr_w <= '0; mem_wdata_w <= '0; mem_wstrb_w <= '0;
            wb_valid <= 1'b0; wb_wen <= 1'b0; wb_rd <= '0; wb_data <= '0; wb_pc <= '0; wb_insn <= '0;
            cycle_cnt <= '0; instret_cnt <= '0;
        end else begin
            cycle_cnt <= cycle_cnt + 64'd1;
            if (wb_valid) instret_cnt <= instret_cnt + 64'd1;
            if (ex_halt) trap_r <= 1'b1;

            // ---- IF -> ID
            if (adv_if) begin
                started  <= 1'b1;
                id_pc    <= imem_addr;
                id_valid <= 1'b1;
            end

            // ---- ID -> EX
            if (adv_ex) begin
                ex_pcpi_done <= 1'b0;
                if (adv_id && !redirect) begin
                    ex_valid   <= id_valid;
                    ex_pc      <= id_pc;
                    ex_insn    <= id_insn;
                    ex_d       <= id_d;
                    ex_rs1_val <= id_rs1_val;
                    ex_rs2_val <= id_rs2_val;
                    ex_pred_taken  <= pred_taken;
                    ex_pred_target <= pred_target;
                end else begin
                    ex_valid <= 1'b0;                  // load-use bubble or squashed (wrong path)
                    ex_d     <= '0;
                    ex_pred_taken <= 1'b0;
                end
            end else begin
                // EX is held: keep the operands it has forwarded so far (their
                // producers may retire out of the forwarding window meanwhile)
                ex_rs1_val <= a;
                ex_rs2_val <= b;
                if (pcpi_valid && pcpi_ready) begin ex_pcpi_done <= 1'b1; ex_pcpi_res <= pcpi_rd; end
            end

            // ---- EX -> MEM
            if (adv_mem) begin
                mem_valid    <= adv_ex && ex_valid;
                mem_wen      <= adv_ex && ex_valid && ex_d.writes_rd;
                mem_is_load  <= adv_ex && ex_valid && ex_d.is_load;
                mem_is_store <= adv_ex && ex_valid && ex_d.is_store;
                mem_rd       <= ex_rd;
                mem_f3       <= ex_f3;
                mem_off      <= ex_addr[1:0];
                mem_pc       <= ex_pc;
                mem_insn     <= ex_insn;
                mem_result   <= ex_result;
                mem_addr_w   <= ex_addr;
                mem_wdata_w  <= ex_wdata;
                mem_wstrb_w  <= ex_wstrb;
            end

            // ---- MEM -> WB
            wb_valid <= adv_mem && mem_valid;
            wb_wen   <= adv_mem && mem_valid && mem_wen;
            wb_rd    <= mem_rd;
            wb_data  <= mem_is_load ? load_val : mem_result;
            wb_pc    <= mem_pc;
            wb_insn  <= mem_insn;
        end
    end

    // ---- predictor training (EX) and RAS (ID)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < BTB_ENTRIES; i++) begin
                btb_v[i] <= 1'b0; btb_tag[i] <= '0; btb_tgt[i] <= '0; btb_typ[i] <= '0; btb_ctr[i] <= '0;
            end
            for (int i = 0; i < RAS_DEPTH; i++) ras[i] <= '0;
            ras_sp <= '0; ras_cnt <= '0; bp_ctrl_cnt <= '0; bp_miss_cnt <= '0;
        end else begin
            if (adv_ex && ex_ctrl) begin
                bp_ctrl_cnt <= bp_ctrl_cnt + 32'd1;
                if (mispredict) bp_miss_cnt <= bp_miss_cnt + 32'd1;
                if (u_hit) begin
                    if (ex_taken) btb_tgt[u_idx] <= ex_target;
                    btb_typ[u_idx] <= ex_typ;
                    if (ex_typ != T_BR)                       btb_ctr[u_idx] <= 2'd3;
                    else if (ex_taken && btb_ctr[u_idx] != 2'd3) btb_ctr[u_idx] <= btb_ctr[u_idx] + 2'd1;
                    else if (!ex_taken && btb_ctr[u_idx] != 2'd0) btb_ctr[u_idx] <= btb_ctr[u_idx] - 2'd1;
                end else if (ex_taken) begin                 // allocate on first taken
                    btb_v[u_idx]   <= 1'b1;
                    btb_tag[u_idx] <= btag(ex_pc);
                    btb_tgt[u_idx] <= ex_target;
                    btb_typ[u_idx] <= ex_typ;
                    btb_ctr[u_idx] <= (ex_typ == T_BR) ? 2'd2 : 2'd3;
                end
            end
            if (adv_ex && ex_valid && !ex_ctrl && ex_pred_taken && u_hit)
                btb_v[u_idx] <= 1'b0;                    // stale entry on a non-branch
            if (adv_id && !redirect) begin
                case ({id_call, id_ret})
                    2'b10: begin                             // call: push return address
                        ras[ras_sp + 1'b1] <= id_pc + 32'd4; ras_sp <= ras_sp + 1'b1;
                        if (ras_cnt != ($clog2(RAS_DEPTH)+1)'(RAS_DEPTH)) ras_cnt <= ras_cnt + 1'b1;
                    end
                    2'b01: if (ras_cnt != 0) begin           // return: pop
                        ras_sp <= ras_sp - 1'b1; ras_cnt <= ras_cnt - 1'b1;
                    end
                    2'b11: ras[ras_sp] <= id_pc + 32'd4;     // pop + push (co-routine jump)
                    default: ;
                endcase
            end
        end
    end

    // ---- WB: register file write
    always_ff @(posedge clk) if (wb_valid && wb_wen) rf[wb_rd] <= wb_data;

    assign rvfi_valid    = wb_valid;
    assign rvfi_pc       = wb_pc;
    assign rvfi_insn     = wb_insn;
    assign rvfi_rd       = wb_wen ? wb_rd : 5'd0;
    assign rvfi_rd_wdata = wb_wen ? wb_data : 32'd0;
endmodule
