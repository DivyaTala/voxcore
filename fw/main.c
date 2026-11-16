// VoxCore firmware: push-to-talk digit recogniser.
//
//   1. wait for the talk button (GPIO in bit0)
//   2. start MFCC capture with AUTO_NN, light the "listening" LED (GPIO out bit1)
//   3. poll until the NN finishes, read the class
//   4. drive the result on GPIO out [7:4] + "done" bit2, print it on the UART
#include <stdint.h>
#include "vc_mac.h"

#define REG(a) (*(volatile uint32_t *)(a))

#define UART_TX      REG(0x10000000)
#define UART_STATUS  REG(0x10000004)
#define UART_DIV     REG(0x10000008)
#define GPIO_IN      REG(0x10001000)
#define GPIO_OUT     REG(0x10001004)
#define VOICE_CTRL   REG(0x10002000)
#define VOICE_STATUS REG(0x10002004)
#define VOICE_RESULT REG(0x10002008)
#define VOICE_PDMDIV REG(0x1000200C)
#define VOICE_LOGIT(k) REG(0x10002040 + 4 * (k))

#define CTRL_MFCC_START (1u << 0)
#define CTRL_AUTO_NN    (1u << 2)
#define CTRL_SRC_PDM    (1u << 3)
#define GPIO_TALK       (1u << 0)      /* talk button                          */
#define GPIO_STRAP_PDM  (1u << 1)      /* board strap: 1 = PDM mic, 0 = I2S    */

#ifndef PDM_CLK_DIV
#define PDM_CLK_DIV 8      /* fast for simulation; silicon: f_clk / 1.024 MHz (e.g. 49 at 50 MHz) */
#endif
#define STAT_NN_DONE    (1u << 3)
#define STAT_OVERFLOW   (1u << 4)

#ifndef UART_CLKS_PER_BIT
#define UART_CLKS_PER_BIT 16   /* fast for simulation; use clk/115200 on silicon */
#endif

static void putc_(char c) {
    while (UART_STATUS & 1) {}
    UART_TX = (uint8_t)c;
}

static void puts_(const char *s) { while (*s) putc_(*s++); }

static void puthex(uint32_t v) {
    for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

static void putdec(int32_t v) {
    char buf[12]; int n = 0; uint32_t u = (v < 0) ? -(uint32_t)v : (uint32_t)v;
    do { buf[n++] = '0' + (char)(u % 10); u /= 10; } while (u);
    if (v < 0) putc_('-');
    while (n) putc_(buf[--n]);
}

// ---------------------------------------------------------------------------
// VC.MAC self-test + benchmark: int8 dot product, plain RV32I vs vc.dot4,
// and int32 multiply-accumulate, plain RV32I (__mulsi3) vs vc.mac.
// ---------------------------------------------------------------------------
#define N_DOT 512
static int8_t  va[N_DOT] __attribute__((aligned(4)));
static int8_t  vb[N_DOT] __attribute__((aligned(4)));
static int32_t wa[64], wb[64];

static uint32_t rng = 0x1234567u;
static uint32_t xorshift(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

static int32_t dot_sw(const int8_t *a, const int8_t *b, int n) {
    int32_t s = 0;
    for (int i = 0; i < n; i++) s += a[i] * b[i];          // __mulsi3 on RV32I (no M extension)
    return s;
}

static int32_t dot_hw(const int8_t *a, const int8_t *b, int n) {
    const uint32_t *a4 = (const uint32_t *)a, *b4 = (const uint32_t *)b;
    int32_t s = vc_setacc(0);
    for (int i = 0; i < n / 4; i++) s = vc_dot4(a4[i], b4[i]);
    return s;
}

static int32_t mac_sw(const int32_t *a, const int32_t *b, int n) {
    int32_t s = 0;
    for (int i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

static int32_t mac_hw(const int32_t *a, const int32_t *b, int n) {
    int32_t s = vc_setacc(0);
    for (int i = 0; i < n; i++) s = vc_mac(a[i], b[i]);
    return s;
}

static int mac_selftest(void) {
    for (int i = 0; i < N_DOT; i++) { va[i] = (int8_t)xorshift(); vb[i] = (int8_t)xorshift(); }
    va[0] = -128; vb[0] = -128; va[1] = 127; vb[1] = -128;   // int8 corners
    for (int i = 0; i < 64; i++) { wa[i] = (int32_t)xorshift() >> 12; wb[i] = (int32_t)xorshift() >> 12; }

    uint32_t i0 = rdinstret();
    uint32_t t0 = rdcycle(); int32_t ds = dot_sw(va, vb, N_DOT);
    uint32_t t1 = rdcycle();
    uint32_t i1 = rdinstret(); int32_t dh = dot_hw(va, vb, N_DOT);
    uint32_t t2 = rdcycle(); int32_t ms = mac_sw(wa, wb, 64);
    uint32_t t3 = rdcycle(); int32_t mh = mac_hw(wa, wb, 64);
    uint32_t t4 = rdcycle();

    puts_("dot512 sw="); putdec(ds); puts_(" cyc="); putdec((int32_t)(t1 - t0));
    puts_(" | hw="); putdec(dh); puts_(" cyc="); putdec((int32_t)(t2 - t1));
    puts_(" | speedup x"); putdec((int32_t)((t1 - t0) / (t2 - t1))); putc_('\n');
    puts_("mac64  sw="); putdec(ms); puts_(" cyc="); putdec((int32_t)(t3 - t2));
    puts_(" | hw="); putdec(mh); puts_(" cyc="); putdec((int32_t)(t4 - t3));
    puts_(" | speedup x"); putdec((int32_t)((t3 - t2) / (t4 - t3))); putc_('\n');

    // CPI of the plain-software loop (x100, integer only)
    puts_("cpi x100="); putdec((int32_t)((t1 - t0) * 100u / (i1 - i0))); puts_(" (sw dot loop, ");
    putdec((int32_t)(i1 - i0)); puts_(" instr)\n");

    int ok = (ds == dh) && (ms == mh) && (vc_rdacc() == mh);
    puts_(ok ? "MACTEST PASS\n" : "MACTEST FAIL\n");
    return ok;
}

int main(void) {
    UART_DIV = UART_CLKS_PER_BIT;
    GPIO_OUT = 0;
    mac_selftest();
    puts_("VoxCore ready\n");

    for (;;) {
        while (!(GPIO_IN & GPIO_TALK)) {}            // wait for talk button
        uint32_t pdm = GPIO_IN & GPIO_STRAP_PDM;
        if (pdm) VOICE_PDMDIV = PDM_CLK_DIV;
        // arm capture first (the PDM clock starts with it), then tell the world we listen
        VOICE_CTRL = CTRL_MFCC_START | CTRL_AUTO_NN | (pdm ? CTRL_SRC_PDM : 0);
        GPIO_OUT = 0x02;
        puts_(pdm ? "listening (PDM mic)\n" : "listening (I2S)\n");

        while (!(VOICE_STATUS & STAT_NN_DONE)) {}
        uint32_t cls = VOICE_RESULT & 0xf;
        uint32_t st  = VOICE_STATUS;

        puts_("DIGIT=");
        putc_('0' + (char)cls);
        puts_(" score=0x");
        puthex(VOICE_LOGIT(cls));
        if (st & STAT_OVERFLOW) puts_(" (overflow!)");
        putc_('\n');
        GPIO_OUT = (cls << 4) | 0x04;

        while (GPIO_IN & GPIO_TALK) {}                // wait for button release
    }
    return 0;
}
