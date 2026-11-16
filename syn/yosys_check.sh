#!/usr/bin/env bash
# Open-source synthesizability check (no PDK): sv2v + Yosys generic synthesis.
# Use this when you don't have DC handy; it catches non-synthesizable RTL early.
# Memories are tagged (* blackbox *) so they stay as macro-like cells.
set -e
cd "$(dirname "$0")"
sv2v -DVOXCORE_BLACKBOX_MEM -I../data ../rtl/mem/*.sv ../rtl/mfcc_engine.sv ../rtl/nn_engine.sv \
     ../rtl/cpu/vc_rv32i.sv ../rtl/cpu/vc_mac_pcpi.sv ../rtl/periph/*.sv ../rtl/soc/*.sv \
     ../rtl/voice_apb.sv ../rtl/voxcore_top.sv \
  | sed -E 's/^module (vc_rom|vc_sram)/(* blackbox *) module \1/' > voxcore_sv2v.v
yosys -q -l yosys.log yosys_check.ys
awk '/=== design hierarchy ===/,0' yosys.log | grep -E "Number of cells" | tail -1
