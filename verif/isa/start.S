# ISA test entry: run the test, which jumps back to mytest_ret on success
# (after printing "OK") or executes EBREAK on failure (after printing "ERROR").
    .section .text.start
    .global _start
    .global mytest_ret
_start:
    li   sp, 0x10000
    j    mytest
mytest_ret:
    ebreak
