# VoxCore timing constraints (ASAP7 libraries use ps as the time unit).
# Audio only needs a few MHz, so the clock target is about showing good timing
# closure, not about throughput. Tighten CLK_PERIOD to find Fmax.
if {![info exists CLK_PERIOD]} { set CLK_PERIOD 2000 }   ;# 2000 ps = 500 MHz

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty  [expr 0.05 * $CLK_PERIOD] [get_clocks clk]
set_clock_transition   20 [get_clocks clk]

# Asynchronous inputs: each goes through a 2-flop synchroniser in RTL (i2s_rx,
# gpio_apb, reset synchroniser), so there is no timing relationship to clk.
set_false_path -from [get_ports {i2s_sck i2s_ws i2s_sd}]
set_false_path -from [get_ports gpio_in*]
set_false_path -from [get_ports rst_n]

# Slow, registered outputs
set_output_delay [expr 0.2 * $CLK_PERIOD] -clock clk [get_ports {uart_tx gpio_out*}]

set_load 1.0 [all_outputs]
set_max_fanout 32 [current_design]
