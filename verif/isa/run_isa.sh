#!/usr/bin/env bash
# Build every rv32ui test and run it on a core.
#   ./run_isa.sh <sim-binary> [WAIT%]
# e.g. ./run_isa.sh ../../sim/obj_core_vc/Vtb_core 30
set -u
SIM=$(realpath "$1"); WAIT=${2:-0}
cd "$(dirname "$0")"; mkdir -p build
pass=0; fail=0; failed=""
for t in tests/*.S; do
    n=$(basename "$t" .S)
    riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -Itests \
        -DTEST_FUNC_NAME=mytest -DTEST_FUNC_TXT="\"$n\"" -DTEST_FUNC_RET=mytest_ret \
        -T link.ld start.S "$t" -o build/$n.elf 2>build/$n.err || { echo "BUILD FAIL $n"; cat build/$n.err; fail=$((fail+1)); continue; }
    riscv64-unknown-elf-objcopy -O binary build/$n.elf build/$n.bin
    python3 ../../fw/bin2hex.py build/$n.bin build/$n.hex 16384
    out=$("$SIM" +HEX=build/$n.hex +WAIT=$WAIT +MAXCYC=200000 2>&1 | grep HALT)
    if echo "$out" | grep -q "OK"; then pass=$((pass+1)); else fail=$((fail+1)); failed="$failed $n"; echo "FAIL $n: $out"; fi
done
echo "ISA tests: $pass passed, $fail failed${failed:+ (}$failed${failed:+ )}"
[ $fail -eq 0 ]
