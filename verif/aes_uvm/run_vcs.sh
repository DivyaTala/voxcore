#!/usr/bin/env bash
# UVM regression for the AES-128 peripheral on Synopsys VCS. Run from this directory.
#   ./run_vcs.sh                 aes_full_test, seed 1, with coverage, then a URG report
#   ./run_vcs.sh aes_rand_test 7 one test with a chosen seed
#   ./run_vcs.sh mut             mutation check: the test must FAIL on each injected bug
set -e
cd "$(dirname "$0")"
TEST=${1:-aes_full_test}
SEED=${2:-1}
SRC="+incdir+../../data ../../rtl/periph/aes128_enc.sv ../../rtl/periph/aes_apb.sv \
     aes_apb_if.sv aes_uvm_pkg.sv aes_sva.sv tb_top.sv aes_ref.c"
VCS="vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -assert svaext -top tb_top"

if [ "$TEST" = "mut" ]; then
  for BUG in AES_BUG_RCON AES_BUG_LASTMIX; do
    $VCS +define+$BUG $SRC -o simv_$BUG -l compile_$BUG.log > /dev/null
    ./simv_$BUG +UVM_TESTNAME=aes_kat_test +ntb_random_seed=1 -l run_$BUG.log > /dev/null || true
    if grep -q "PASSED ====" run_$BUG.log; then echo "$BUG: NOT CAUGHT"; exit 1; else echo "$BUG: caught"; fi
  done
  echo "==== aes_uvm mutation check PASSED ===="
  exit 0
fi

$VCS -cm line+cond+tgl+fsm+branch+assert -cm_hier cm_hier.cfg $SRC -o simv -l compile.log
./simv +UVM_TESTNAME=$TEST +ntb_random_seed=$SEED -cm line+cond+tgl+fsm+branch+assert -l run_${TEST}_${SEED}.log
urg -dir simv.vdb -report urgReport > urg.log
grep -E "UVM_ERROR :|UVM_FATAL :|====|\[SB\]" run_${TEST}_${SEED}.log
echo "coverage report: urgReport/dashboard.html"
