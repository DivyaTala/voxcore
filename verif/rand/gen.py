"""
Constrained-random RV32I (+VC.MAC) program generator.

Biases chosen to hit pipeline corner cases:
  * operands drawn from recently written registers (forwarding EX/MEM, MEM/WB, WB->ID)
  * load immediately followed by a use of its result (load-use bubble)
  * store then load of the same address (memory RAW)
  * forward branches / JAL / JALR skipping over instructions (flush of wrong path)
  * short counted loops (backward taken branches)
  * back-to-back custom-0 instructions (PCPI handshake)
  * function calls / returns via x1 or x5, including nested calls and calls
    from inside loops (return-address stack, BTB aliasing, re-training)
  * indirect jumps whose target changes between visits, and recursion deeper
    than the return-address stack -> "predicted taken, wrong target" cases
    (added after a mutation test showed this path was never exercised)
Reserved registers: x28 = recursion depth, x29 = software stack pointer,
x30 = loop counter, x31 = data base pointer (0x8000).
usage: python3 gen.py <seed> <n_items> > prog.S
"""
import random
import sys

seed, n_items = int(sys.argv[1]), int(sys.argv[2])
R = random.Random(seed)
GP = list(range(1, 28))  # general-purpose pool
recent = []
lines = []
label_id = 0
stored_offsets = []


def emit(s):
    lines.append("    " + s)


def pick_src():
    if recent and R.random() < 0.6:
        return R.choice(recent[-4:])
    return R.choice([0] + GP) if R.random() < 0.1 else R.choice(GP)


def pick_dst():
    r = 0 if R.random() < 0.03 else R.choice(GP)  # occasionally write x0
    recent.append(r)
    del recent[:-6]
    return r


def new_label():
    global label_id
    label_id += 1
    return f"L{label_id}"


ALU_R = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
ALU_I = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_I = ["slli", "srli", "srai"]
BR = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]


def simple_op(no_write=()):
    k = R.random()
    if k < 0.45:
        rd = pick_dst()
        while rd in no_write:
            rd = pick_dst()
        emit(f"{R.choice(ALU_R)} x{rd}, x{pick_src()}, x{pick_src()}")
    elif k < 0.75:
        rd = pick_dst()
        while rd in no_write:
            rd = pick_dst()
        emit(f"{R.choice(ALU_I)} x{rd}, x{pick_src()}, {R.randint(-2048, 2047)}")
    elif k < 0.88:
        rd = pick_dst()
        while rd in no_write:
            rd = pick_dst()
        emit(f"{R.choice(SH_I)} x{rd}, x{pick_src()}, {R.randint(0, 31)}")
    else:
        rd = pick_dst()
        while rd in no_write:
            rd = pick_dst()
        emit(f"{R.choice(['lui', 'auipc'])} x{rd}, {R.randint(0, 0xFFFFF)}")


def mem_op():
    size = R.choice([("w", 4), ("h", 2), ("b", 1)])
    if stored_offsets and R.random() < 0.5:
        off = R.choice(stored_offsets[-8:])
    else:
        off = R.randrange(0, 1024, 4)
    off += R.randrange(0, 4, size[1])
    if R.random() < 0.5:
        emit(f"s{size[0]} x{pick_src()}, {off}(x31)")
        stored_offsets.append(off & ~3)
    else:
        u = "u" if size[1] < 4 and R.random() < 0.5 else ""
        rd = pick_dst()
        emit(f"l{size[0]}{u} x{rd}, {off}(x31)")
        if R.random() < 0.5:  # immediate use -> load-use hazard
            emit(f"{R.choice(ALU_R)} x{pick_dst()}, x{rd}, x{pick_src()}")


def custom_op():
    for _ in range(R.randint(1, 3)):  # often back-to-back
        f3 = R.randint(0, 5)
        emit(f".insn r 0x0b, {f3}, 0, x{pick_dst()}, x{pick_src()}, x{pick_src()}")


def branch():
    l = new_label()
    emit(f"{R.choice(BR)} x{pick_src()}, x{pick_src()}, {l}")
    for _ in range(R.randint(1, 3)):
        simple_op()
    lines.append(f"{l}:")


def jump():
    l = new_label()
    if R.random() < 0.5:
        emit(f"jal x{pick_dst()}, {l}")
        for _ in range(R.randint(1, 3)):
            simple_op()
    else:
        base = R.choice(GP)
        emit(f"auipc x{base}, 0")
        emit(f"jalr x{pick_dst()}, 16(x{base})")
        simple_op(); simple_op()
    lines.append(f"{l}:")


def call():
    """jal link, F ; ... ; F: body [nested call] ; ret  (link = x1 or x5)"""
    link = R.choice([1, 5])
    f, after = new_label(), new_label()
    emit(f"jal x{link}, {f}")
    emit(f"j {after}")
    lines.append(f"{f}:")
    for _ in range(R.randint(1, 4)):
        simple_op(no_write=(1, 5))
    if R.random() < 0.3:                      # nested call through the other link reg
        inner, g = 5 if link == 1 else 1, new_label()
        emit(f"jal x{inner}, {g}")
        emit(f"jalr x0, 0(x{link})")
        lines.append(f"{g}:")
        simple_op(no_write=(1, 5))
        emit(f"jalr x0, 0(x{inner})")
    else:
        emit(f"jalr x0, 0(x{link})")          # ret
    lines.append(f"{after}:")


def indirect():
    """jalr at one PC alternating between two targets (BTB target goes stale)"""
    l, la_, lb, lj, sk = new_label(), new_label(), new_label(), new_label(), new_label()
    t, c = R.sample(GP, 2)
    emit(f"li x30, {R.randint(3, 8)}")
    lines.append(f"{l}:")
    emit(f"andi x{c}, x30, 1")
    emit(f"la x{t}, {la_}")
    emit(f"beqz x{c}, {sk}")
    emit(f"la x{t}, {lb}")
    lines.append(f"{sk}:")
    emit(f"jalr x0, 0(x{t})")
    lines.append(f"{la_}:"); simple_op(no_write=(t, c)); emit(f"j {lj}")
    lines.append(f"{lb}:"); simple_op(no_write=(t, c)); emit(f"j {lj}")
    lines.append(f"{lj}:")
    emit("addi x30, x30, -1")
    emit(f"bnez x30, {l}")


def recursion():
    """recursive function deeper than the 4-entry RAS (return mispredicts)"""
    r, base, after = new_label(), new_label(), new_label()
    emit(f"li x28, {R.randint(3, 9)}")
    emit("addi x29, x31, 1600")
    emit(f"jal x1, {r}")
    emit(f"j {after}")
    lines.append(f"{r}:")
    emit("sw x1, 0(x29)")
    emit("addi x29, x29, 4")
    simple_op(no_write=(1, 5))
    emit("addi x28, x28, -1")
    emit(f"beqz x28, {base}")
    emit(f"jal x1, {r}")
    lines.append(f"{base}:")
    emit("addi x29, x29, -4")
    emit("lw x1, 0(x29)")
    emit("jalr x0, 0(x1)")
    lines.append(f"{after}:")


def loop():
    l = new_label()
    emit(f"li x30, {R.randint(1, 8)}")
    lines.append(f"{l}:")
    for _ in range(R.randint(2, 5)):
        simple_op()
    if R.random() < 0.4:
        call()                                # call inside a loop: RAS + BTB reuse
    emit("addi x30, x30, -1")
    emit(f"bnez x30, {l}")


print("    .section .text.start\n    .global _start\n_start:")
emit("li x31, 0x8000")
for r in GP + [28, 29, 30]:
    emit(f"li x{r}, {R.randint(-2**31, 2**31 - 1)}")
for _ in range(n_items):
    k = R.random()
    if k < 0.50:
        simple_op()
    elif k < 0.70:
        mem_op()
    elif k < 0.80:
        branch()
    elif k < 0.87:
        jump()
    elif k < 0.91:
        custom_op()
    elif k < 0.94:
        call()
    elif k < 0.96:
        indirect()
    elif k < 0.97:
        recursion()
    else:
        loop()
emit("ebreak")
print("\n".join(lines))
