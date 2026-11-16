// AES-128 encryption core (FIPS-197), one round per clock.
//
// start is sampled when the core is idle: the plaintext is XORed with the key
// (round 0) and the next ten clocks each do one round. The round keys are
// expanded on the fly from the previous one, so only one 128-bit round-key
// register is kept. done pulses for one clock when ct holds the ciphertext,
// 11 clocks after start. ct then holds until the next start or clear.
//
// Key hygiene: the round-key register is wiped when the last round finishes,
// and clear wipes every register (and aborts a block in progress).
//
// Byte order follows FIPS-197: key[127:120] and pt[127:120] are byte 0.
module aes128_enc (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic         clear,
    input  logic [127:0] key,
    input  logic [127:0] pt,
    output logic         busy,
    output logic         done,
    output logic [127:0] ct
);
    function automatic logic [7:0] aes_sbox(input logic [7:0] x);
        case (x)
`include "aes_sbox.svh"
            default: aes_sbox = 8'h00;
        endcase
    endfunction

    function automatic logic [7:0] xtime(input logic [7:0] a);   // multiply by x in GF(2^8)
        xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
    endfunction

    // SubBytes then ShiftRows. State byte i is row i%4, column i/4; row r rotates left by r.
    function automatic logic [127:0] sub_shift(input logic [127:0] s);
        logic [127:0] o;
        int src;
        for (int i = 0; i < 16; i++) begin
            src = (i % 4) + 4 * (((i / 4) + (i % 4)) % 4);
            o[127 - 8*i -: 8] = aes_sbox(s[127 - 8*src -: 8]);
        end
        sub_shift = o;
    endfunction

    function automatic logic [127:0] mix_columns(input logic [127:0] s);
        logic [127:0] o;
        logic [7:0] a0, a1, a2, a3;
        for (int c = 0; c < 4; c++) begin
            a0 = s[127 - 32*c      -: 8];
            a1 = s[127 - 32*c - 8  -: 8];
            a2 = s[127 - 32*c - 16 -: 8];
            a3 = s[127 - 32*c - 24 -: 8];
            o[127 - 32*c      -: 8] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
            o[127 - 32*c - 8  -: 8] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
            o[127 - 32*c - 16 -: 8] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
            o[127 - 32*c - 24 -: 8] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
        end
        mix_columns = o;
    endfunction

    function automatic logic [7:0] rcon(input logic [3:0] r);
        case (r)
            4'd1: rcon = 8'h01;  4'd2: rcon = 8'h02;  4'd3: rcon = 8'h04;  4'd4:  rcon = 8'h08;
            4'd5: rcon = 8'h10;  4'd6: rcon = 8'h20;  4'd7: rcon = 8'h40;  4'd8:  rcon = 8'h80;
`ifdef AES_BUG_RCON
            4'd9: rcon = 8'h1b;  4'd10: rcon = 8'h6c;   // injected bug for the mutation check
`else
            4'd9: rcon = 8'h1b;  4'd10: rcon = 8'h36;
`endif
            default: rcon = 8'h00;
        endcase
    endfunction

    // Round key r from round key r-1 (FIPS-197 section 5.2, Nk = 4).
    function automatic logic [127:0] next_key(input logic [127:0] k, input logic [3:0] r);
        logic [31:0] w0, w1, w2, w3, t;
        t  = {aes_sbox(k[23:16]), aes_sbox(k[15:8]), aes_sbox(k[7:0]), aes_sbox(k[31:24])};
        t[31:24] = t[31:24] ^ rcon(r);
        w0 = k[127:96] ^ t;
        w1 = k[95:64]  ^ w0;
        w2 = k[63:32]  ^ w1;
        w3 = k[31:0]   ^ w2;
        next_key = {w0, w1, w2, w3};
    endfunction

    logic [127:0] state, rk, rk_n, sb;
    logic [3:0]   rnd;                 // 0 = idle, 1..10 = round in progress

    assign busy = (rnd != 4'd0);
    assign ct   = state;
    assign rk_n = next_key(rk, rnd);
    assign sb   = sub_shift(state);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= '0; rk <= '0; rnd <= '0; done <= 1'b0;
        end else if (clear) begin
            state <= '0; rk <= '0; rnd <= '0; done <= 1'b0;
        end else if (!busy) begin
            done <= 1'b0;
            if (start) begin
                state <= pt ^ key;
                rk    <= key;
                rnd   <= 4'd1;
            end
        end else if (rnd == 4'd10) begin
`ifdef AES_BUG_LASTMIX
            state <= mix_columns(sb) ^ rk_n;   // injected bug: last round must skip MixColumns
`else
            state <= sb ^ rk_n;
`endif
            rk    <= '0;                       // do not leave key material behind
            rnd   <= '0;
            done  <= 1'b1;
        end else begin
            state <= mix_columns(sb) ^ rk_n;
            rk    <= rk_n;
            rnd   <= rnd + 4'd1;
        end
    end
endmodule
