// VC.MAC custom-instruction intrinsics (opcode custom-0 = 0x0B, funct7 = 0).
// Each returns the new accumulator value. `volatile` because the accumulator
// is hidden state inside the unit: the compiler must not reorder or drop these.
#ifndef VC_MAC_H
#define VC_MAC_H
#include <stdint.h>

#define VC_INSN(f3, a, b) ({ int32_t _r; \
    __asm__ volatile (".insn r 0x0b, " #f3 ", 0, %0, %1, %2" : "=r"(_r) : "r"(a), "r"(b)); _r; })

static inline int32_t vc_mac(int32_t a, int32_t b)     { return VC_INSN(0, a, b); } // acc += a*b
static inline int32_t vc_mul(int32_t a, int32_t b)     { return VC_INSN(1, a, b); } // acc  = a*b
static inline int32_t vc_dot4(uint32_t a, uint32_t b)  { return VC_INSN(2, a, b); } // acc += 4x int8 dot
static inline int32_t vc_dot4z(uint32_t a, uint32_t b) { return VC_INSN(3, a, b); } // acc  = 4x int8 dot
static inline int32_t vc_setacc(int32_t a)             { return VC_INSN(4, a, 0); } // acc  = a
static inline int32_t vc_rdacc(void)                   { return VC_INSN(5, 0, 0); } // read acc

static inline uint32_t rdcycle(void)   { uint32_t c; __asm__ volatile ("rdcycle %0"   : "=r"(c)); return c; }
static inline uint32_t rdinstret(void) { uint32_t c; __asm__ volatile ("rdinstret %0" : "=r"(c)); return c; }
#endif
