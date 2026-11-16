#!/usr/bin/env bash
# Constrained-random lockstep check: vc_rv32i retirement trace vs the Python ISS.
#   ./run_rand.sh <vc_rv32i tb_core binary> [n_programs] [items_per_program]
set -u
SIM=$(realpath "$1"); N=${2:-100}; ITEMS=${3:-400}
cd "$(dirname "$0")"; mkdir -p build
pass=0; fail=0
for seed in $(seq 1 "$N"); do
    wait=$(( (seed % 3) * 25 ))      # 0 / 25 / 50 % data-bus wait states
    b=build/r$seed
    python3 gen.py "$seed" "$ITEMS" > $b.S
    riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -T ../isa/link.ld $b.S -o $b.elf || { fail=$((fail+1)); continue; }
    riscv64-unknown-elf-objcopy -O binary $b.elf $b.bin
    python3 ../../fw/bin2hex.py $b.bin $b.hex 16384
    python3 iss.py $b.bin $b.iss.trace
    "$SIM" +HEX=$b.hex +WAIT=$wait +TRACE=$b.rtl.trace +MAXCYC=500000 > $b.log 2>&1
    if cmp -s $b.iss.trace $b.rtl.trace; then
        pass=$((pass+1)); rm -f $b.*
    else
        fail=$((fail+1))
        echo "MISMATCH seed=$seed wait=$wait  (first difference: line $(cmp $b.iss.trace $b.rtl.trace 2>&1 | grep -o 'line [0-9]*'))"
        diff $b.iss.trace $b.rtl.trace | head -6
    fi
done
echo "Random tests: $pass passed, $fail failed  ($N programs x $ITEMS items)"
[ $fail -eq 0 ]
