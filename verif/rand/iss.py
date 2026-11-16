"""
Minimal RV32I + VC.MAC instruction-set simulator (reference model).
Produces the same retirement trace format as the vc_rv32i RVFI port:
    <pc> <insn> <rd> <wdata>      (rd = 0 and wdata = 0 when nothing is written)
Stops at EBREAK/ECALL (not traced, matching the core which halts in EX).
"""
import sys

M32 = 0xFFFFFFFF


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class ISS:
    def __init__(self, image: bytes, mem_size=64 * 1024):
        self.mem = bytearray(mem_size)
        self.mem[:len(image)] = image
        self.x = [0] * 32
        self.pc = 0
        self.acc = 0
        self.trace = []

    def ld(self, a, n):
        return int.from_bytes(self.mem[a:a + n], "little")

    def st(self, a, v, n):
        if a >> 28 == 1:
            return  # console
        self.mem[a:a + n] = (v & ((1 << (8 * n)) - 1)).to_bytes(n, "little")

    def run(self, max_steps=1_000_000):
        for _ in range(max_steps):
            pc, ins = self.pc, self.ld(self.pc, 4)
            op, rd, f3 = ins & 0x7F, (ins >> 7) & 31, (ins >> 12) & 7
            rs1, rs2, f7 = (ins >> 15) & 31, (ins >> 20) & 31, ins >> 25
            a, b = self.x[rs1], self.x[rs2]
            immI = sx(ins >> 20, 12)
            immS = sx(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)
            immB = sx(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 63) << 5) | (((ins >> 8) & 15) << 1), 13)
            immU = ins & 0xFFFFF000
            immJ = sx(((ins >> 31) << 20) | (((ins >> 12) & 255) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 1023) << 1), 21)
            npc, wr, val = pc + 4, True, 0
            if op == 0x37:
                val = immU
            elif op == 0x17:
                val = pc + immU
            elif op == 0x6F:
                val, npc = pc + 4, pc + immJ
            elif op == 0x67:
                val, npc = pc + 4, (a + immI) & ~1
            elif op == 0x63:
                wr = False
                sa, sb = sx(a, 32), sx(b, 32)
                take = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb, 6: a < b, 7: a >= b}[f3]
                if take:
                    npc = pc + immB
            elif op == 0x03:
                ad = (a + immI) & M32
                val = {0: lambda: sx(self.ld(ad, 1), 8), 1: lambda: sx(self.ld(ad, 2), 16), 2: lambda: self.ld(ad, 4),
                       4: lambda: self.ld(ad, 1), 5: lambda: self.ld(ad, 2)}[f3]()
            elif op == 0x23:
                wr = False
                self.st((a + immS) & M32, b, {0: 1, 1: 2, 2: 4}[f3])
            elif op in (0x13, 0x33):
                y = immI & M32 if op == 0x13 else b
                sh = y & 31
                if f3 == 0:
                    val = a - y if (op == 0x33 and f7 == 0x20) else a + y
                elif f3 == 1:
                    val = a << sh
                elif f3 == 2:
                    val = int(sx(a, 32) < sx(y, 32))
                elif f3 == 3:
                    val = int(a < y)
                elif f3 == 4:
                    val = a ^ y
                elif f3 == 5:
                    val = (sx(a, 32) >> sh) if (ins >> 30) & 1 else (a >> sh)
                elif f3 == 6:
                    val = a | y
                else:
                    val = a & y
            elif op == 0x0F:
                wr = False
            elif op == 0x0B:  # VC.MAC
                s8 = lambda v, i: sx(v >> (8 * i), 8)
                dot = sum(s8(a, i) * s8(b, i) for i in range(4))
                prod = sx(a, 32) * sx(b, 32)
                self.acc = {0: self.acc + prod, 1: prod, 2: self.acc + dot, 3: dot, 4: a, 5: self.acc}[f3] & M32
                val = self.acc
            elif op == 0x73 and f3 == 0:
                return  # EBREAK / ECALL: halt, not retired
            else:
                raise RuntimeError(f"ISS: unsupported insn {ins:08x} at {pc:08x}")
            if wr and rd != 0:
                self.x[rd] = val & M32
                self.trace.append(f"{pc:08x} {ins:08x} {rd} {val & M32:08x}")
            else:
                self.trace.append(f"{pc:08x} {ins:08x} 0 00000000")
            self.pc = npc & M32
        raise RuntimeError("ISS: step limit")


if __name__ == "__main__":
    iss = ISS(open(sys.argv[1], "rb").read())
    iss.run()
    open(sys.argv[2], "w").write("\n".join(iss.trace) + "\n")
