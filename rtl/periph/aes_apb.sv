// AES-128 encryption peripheral with an APB slave interface.
//
//   0x00 CTRL    W   [0] START  start one block (ignored while busy)
//                    [1] CLEAR  zeroize key, plaintext, ciphertext and core state
//   0x04 STATUS  R   [0] BUSY   a block is being encrypted
//                    [1] DONE   ciphertext is valid (cleared by START or CLEAR)
//                    [2] WERR   a write to KEY, PT or START was dropped because
//                               the core was busy (write 1 to clear)
//   0x10 KEY0..3 W   key, KEY0 = key[127:96]. Write-only: reads return 0.
//   0x20 PT0..3  RW  plaintext, PT0 = pt[127:96]
//   0x30 CT0..3  R   ciphertext, CT0 = ct[127:96]. Reads 0 unless DONE is set.
//
// Security behaviour, each one checked by the testbench:
//   - the key can never be read back over the bus
//   - the round state is never visible: CT reads 0 while BUSY
//   - KEY and PT cannot change under a running block (writes dropped, WERR set)
//   - CLEAR wipes all key and data registers in one write
module aes_apb (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready
);
    logic [127:0] key_q, pt_q, ct;
    logic         start, clear, busy, done, done_q, werr_q;

    logic       wr;
    logic [5:0] widx;
    // The block owns a 4 KB slot but only decodes its first 256 bytes: the rest must
    // read 0 and ignore writes, or every register (the key included) would have
    // 15 aliases higher up in the slot.
    logic       hit;
    assign hit   = (paddr[11:8] == 4'h0);
    assign wr    = psel && penable && pwrite && hit;
    assign widx  = paddr[7:2];
    assign clear = wr && (widx == 6'h00) && pwdata[1];
    assign start = wr && (widx == 6'h00) && pwdata[0] && !pwdata[1] && !busy;

    logic locked_wr;   // a write that must not land while a block is running
    assign locked_wr = wr && busy &&
                       ((widx == 6'h00 && pwdata[0] && !pwdata[1]) || widx[5:2] == 4'h1 || widx[5:2] == 4'h2);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_q <= '0; pt_q <= '0; done_q <= 1'b0; werr_q <= 1'b0;
        end else if (clear) begin
            key_q <= '0; pt_q <= '0; done_q <= 1'b0; werr_q <= 1'b0;
        end else begin
            if (start)     done_q <= 1'b0;
            else if (done) done_q <= 1'b1;

            if (locked_wr)                              werr_q <= 1'b1;
            else if (wr && widx == 6'h01 && pwdata[2])  werr_q <= 1'b0;

            if (wr && !busy) begin
                case (widx)
                    6'h04: key_q[127:96] <= pwdata;
                    6'h05: key_q[95:64]  <= pwdata;
                    6'h06: key_q[63:32]  <= pwdata;
                    6'h07: key_q[31:0]   <= pwdata;
                    6'h08: pt_q[127:96]  <= pwdata;
                    6'h09: pt_q[95:64]   <= pwdata;
                    6'h0a: pt_q[63:32]   <= pwdata;
                    6'h0b: pt_q[31:0]    <= pwdata;
                    default: ;
                endcase
            end
        end
    end

    aes128_enc u_core (
        .clk, .rst_n, .start, .clear, .key(key_q), .pt(pt_q), .busy, .done, .ct);

    // DONE is visible in the same clock the core finishes, so software never
    // sees an idle core with no result.
    logic         done_vis;
    logic [127:0] ct_vis;
    assign done_vis = done_q || done;
    assign ct_vis   = done_vis ? ct : 128'd0;

    always_comb begin
        case ({!hit, paddr[7:2]})
            7'h01:   prdata = {29'd0, werr_q, done_vis, busy};
            7'h08:   prdata = pt_q[127:96];
            7'h09:   prdata = pt_q[95:64];
            7'h0a:   prdata = pt_q[63:32];
            7'h0b:   prdata = pt_q[31:0];
            7'h0c:   prdata = ct_vis[127:96];
            7'h0d:   prdata = ct_vis[95:64];
            7'h0e:   prdata = ct_vis[63:32];
            7'h0f:   prdata = ct_vis[31:0];
            default: prdata = 32'd0;      // CTRL, KEY0..3 and unmapped offsets
        endcase
    end
    assign pready = 1'b1;
endmodule
