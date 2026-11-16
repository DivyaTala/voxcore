# ============================================================================
# VoxCore synthesis with Synopsys Design Compiler on ASAP7
#   cd syn/dc && dc_shell -f run_dc.tcl | tee dc.log
#
# EDIT THE TWO PATHS BELOW to match your EEE525 setup (same .db files you used
# for the GCN accelerator).
#
# Memories (vc_rom / vc_sram_*) are intentionally NOT read: DC leaves them as
# unresolved black boxes (LINK-5 warnings are expected), which is how SRAM
# macros are treated before you have memory-compiler .db/.lef views. To get
# real macros, generate them with bsg_fakeram for ASAP7 and add their .db to
# link_library.
# ============================================================================
set ASAP7_DB_DIR  "/path/to/asap7/lib/db"          ;# <-- edit
set CLK_PERIOD    2000                               ;# ps
set CPU_SEL       0                                  ;# 0 = vc_rv32i (own core), 1 = PicoRV32
set RTL           "../../rtl"
set DATA          "../../data"

set_app_var search_path   [concat . $RTL $DATA $search_path]
set_app_var target_library [glob $ASAP7_DB_DIR/*RVT*TT*.db]
set_app_var link_library   [concat "*" $target_library]
set_app_var hdlin_sverilog_std 2017

file mkdir reports out work
define_design_lib WORK -path ./work

# ---- read RTL (memories excluded on purpose, see header)
analyze -format sverilog -define VOXCORE_BLACKBOX_MEM [list \
    $RTL/cpu/vc_rv32i.sv   $RTL/cpu/vc_mac_pcpi.sv \
    $RTL/periph/i2s_rx.sv  $RTL/periph/pdm_rx.sv   $RTL/periph/uart_apb.sv $RTL/periph/gpio_apb.sv \
    $RTL/soc/apb_bridge.sv $RTL/mfcc_engine.sv     $RTL/nn_engine.sv \
    $RTL/voice_apb.sv      $RTL/voxcore_top.sv ]
analyze -format verilog $RTL/third_party/picorv32/picorv32.v
elaborate voxcore_top -parameters "CPU_SEL=$CPU_SEL"
current_design [get_designs voxcore_top*]
link
check_design > reports/check_design.rpt

# ---- constraints
source voxcore.sdc

# ---- compile: clock gating on enable flops (big power win: the MFCC/NN
#      registers only toggle while a frame is being processed)
set_clock_gating_style -sequential_cell latch -minimum_bitwidth 4 -max_fanout 32
compile_ultra -gate_clock -no_autoungroup

# ---- reports
report_qor                                  > reports/qor.rpt
report_timing -max_paths 10 -nets -input    > reports/timing_setup.rpt
report_timing -delay_type min -max_paths 5  > reports/timing_hold.rpt
report_area -hierarchy                      > reports/area.rpt
report_power -hierarchy                     > reports/power.rpt
report_clock_gating                         > reports/clock_gating.rpt
report_reference -hierarchy                 > reports/reference.rpt
report_constraint -all_violators            > reports/violators.rpt

write -format verilog -hierarchy -output out/voxcore_top.syn.v
write_sdc out/voxcore_top.syn.sdc
write -format ddc -hierarchy -output out/voxcore_top.ddc
exit
