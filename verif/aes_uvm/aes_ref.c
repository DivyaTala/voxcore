/* AES-128 encryption reference model for the UVM scoreboard (DPI-C).
 *
 * Written from FIPS-197. The S-box is computed at first use from the GF(2^8)
 * inverse and the affine transform, so no table is shared with the RTL.
 *
 * SystemVerilog side:
 *   import "DPI-C" function void aes128_ref(input bit [127:0] key,
 *                                           input bit [127:0] pt,
 *                                           output bit [127:0] ct);
 * Bit 127 of each vector is the first FIPS byte, as in the RTL.
 */
#include <stdint.h>
#include "svdpi.h"

static uint8_t sbox[256];
static int sbox_ready = 0;

static uint8_t xtime(uint8_t a) {
    return (uint8_t)((a << 1) ^ ((a & 0x80) ? 0x1b : 0x00));
}

static uint8_t gmul(uint8_t a, uint8_t b) {
    uint8_t r = 0;
    while (b) {
        if (b & 1) r ^= a;
        a = xtime(a);
        b >>= 1;
    }
    return r;
}

static void make_sbox(void) {
    int x, y, sh;
    for (x = 0; x < 256; x++) {
        uint8_t inv = 0, s;
        if (x != 0) {
            for (y = 1; y < 256; y++) {
                if (gmul((uint8_t)x, (uint8_t)y) == 1) { inv = (uint8_t)y; break; }
            }
        }
        s = inv;
        for (sh = 1; sh <= 4; sh++) s ^= (uint8_t)((inv << sh) | (inv >> (8 - sh)));
        sbox[x] = (uint8_t)(s ^ 0x63);
    }
    sbox_ready = 1;
}

/* byte i (0 = first FIPS byte) of a 128-bit SystemVerilog vector, bit 127 first */
static uint8_t get_byte(const svBitVecVal *v, int i) {
    int bit = 120 - 8 * i;
    return (uint8_t)((v[bit / 32] >> (bit % 32)) & 0xff);
}

static void put_byte(svBitVecVal *v, int i, uint8_t b) {
    int bit = 120 - 8 * i;
    v[bit / 32] = (v[bit / 32] & ~((svBitVecVal)0xff << (bit % 32))) | ((svBitVecVal)b << (bit % 32));
}

void aes128_ref(const svBitVecVal *key, const svBitVecVal *pt, svBitVecVal *ct) {
    static const uint8_t rcon[10] = {0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36};
    uint8_t rk[16], s[16], t[16];
    int i, c, r;

    if (!sbox_ready) make_sbox();

    for (i = 0; i < 16; i++) {
        rk[i] = get_byte(key, i);
        s[i]  = (uint8_t)(get_byte(pt, i) ^ rk[i]);
    }

    for (r = 1; r <= 10; r++) {
        /* next round key, in place (FIPS-197 section 5.2, Nk = 4) */
        uint8_t t0 = (uint8_t)(sbox[rk[13]] ^ rcon[r - 1]);
        uint8_t t1 = sbox[rk[14]];
        uint8_t t2 = sbox[rk[15]];
        uint8_t t3 = sbox[rk[12]];
        rk[0] ^= t0; rk[1] ^= t1; rk[2] ^= t2; rk[3] ^= t3;
        for (i = 4; i < 16; i++) rk[i] ^= rk[i - 4];

        /* SubBytes + ShiftRows: byte i is row i%4, column i/4 */
        for (i = 0; i < 16; i++) t[i] = sbox[s[(i % 4) + 4 * (((i / 4) + (i % 4)) % 4)]];

        /* MixColumns, skipped in the last round */
        if (r < 10) {
            for (c = 0; c < 4; c++) {
                uint8_t a0 = t[4 * c], a1 = t[4 * c + 1], a2 = t[4 * c + 2], a3 = t[4 * c + 3];
                s[4 * c]     = (uint8_t)(xtime(a0) ^ xtime(a1) ^ a1 ^ a2 ^ a3);
                s[4 * c + 1] = (uint8_t)(a0 ^ xtime(a1) ^ xtime(a2) ^ a2 ^ a3);
                s[4 * c + 2] = (uint8_t)(a0 ^ a1 ^ xtime(a2) ^ xtime(a3) ^ a3);
                s[4 * c + 3] = (uint8_t)(xtime(a0) ^ a0 ^ a1 ^ a2 ^ xtime(a3));
            }
        } else {
            for (i = 0; i < 16; i++) s[i] = t[i];
        }
        for (i = 0; i < 16; i++) s[i] ^= rk[i];
    }

    for (i = 0; i < 4; i++) ct[i] = 0;
    for (i = 0; i < 16; i++) put_byte(ct, i, s[i]);
}
