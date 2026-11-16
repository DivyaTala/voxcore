# Branch-predictor performance test (directed). A loop of 200 iterations that
# calls a leaf function (return via the RAS), contains an always-taken and a
# never-taken branch, and a data-dependent branch that alternates. With a
# working BTB + 2-bit counters + RAS the steady state mispredicts only the
# alternating branch (2-bit counters can't learn T,N,T,N).
# Expected: ~1 mispredict per iteration + warm-up. Prints OK and checks a sum.
    .section .text.start
    .global _start
_start:
    li   sp, 0x10000
    li   s0, 200            # loop counter
    li   s1, 0              # running sum
    li   s2, 0              # toggle
loop:
    jal  ra, leaf           # call  -> RAS push; ret -> RAS pop
    beq  zero, zero, 1f     # always taken
    addi s1, s1, 1000       # (never executed)
1:  bne  zero, zero, 2f     # never taken
    addi s1, s1, 1
2:  xori s2, s2, 1
    beqz s2, 3f             # alternates T/N
    addi s1, s1, 2
3:  addi s0, s0, -1
    bnez s0, loop           # loop back-edge
    li   t0, 200*1 + 100*2 + 200*3
    bne  s1, t0, fail
    lui  a0, 0x10000
    li   a1, 'O'
    sw   a1, 0(a0)
    li   a1, 'K'
    sw   a1, 0(a0)
fail:
    ebreak
leaf:
    addi s1, s1, 3
    ret
