// ============================================================================
// sdm_rnm - behavioural real-number model (RNM) of a 2nd-order switched-capacitor
//           sigma-delta modulator: the ANALOG half of the PDM microphone ADC.
//
//            u ──►(+)──► ∫ 0.5 ──►(+)──► ∫ 0.5 ──► comparator ──► dout (1 bit)
//                  ▲ −              ▲ −                │
//                  └──── 1-bit DAC (±1 FS) ◄───────────┘
//
//   Discrete-time, Boser-Wooley topology, two delaying integrators (gain 1/2).
//   One update per falling edge of pdm_clk (the PDM convention: the microphone
//   drives data after the falling edge, the host samples on the rising edge).
//
//   Analog non-idealities (parameters; all ideal by default):
//     OPAMP_GAIN  finite op-amp DC gain A  -> integrator leakage (1 - 1/A); 0 = ideal
//     NOISE_RMS   input-referred thermal (kT/C) noise, in units of full scale
//     VOS         comparator offset, in units of full scale
//
//   With the defaults this model performs exactly the same IEEE-754 double
//   operations, in the same order, as SDM2.run() in model/pdm_model.py, so the
//   bitstreams are identical. That is what lets the digital decimator be
//   checked bit-exact against Python even with an "analog" block in the loop.
//
//   In a real chip this module would be replaced by a transistor-level
//   macro (or a Verilog-AMS / Spectre model in AMS co-simulation) with the same
//   ports: real ain, pdm_clk, dout.
// ============================================================================
`timescale 1ns/1ps
module sdm_rnm #(
    parameter real OPAMP_GAIN = 0.0,
    parameter real NOISE_RMS  = 0.0,
    parameter real VOS        = 0.0,
    parameter int  SEED       = 1,
    parameter real T_DELAY_NS = 2.0      // clock-to-data delay of the modulator
) (
    input  real  ain,          // analog input, full scale = ±1.0
    input  logic rst,          // discharge the integrators (power-up state)
    input  logic pdm_clk,
    output logic dout
);
    real x1 = 0.0, x2 = 0.0;   // integrator states (capacitor voltages)
    real leak;
    longint unsigned n_bits = 0;
    longint unsigned rs = 64'(SEED) * 64'h9E3779B97F4A7C15 + 64'd1;   // PRNG state
    initial begin
        dout = 1'b0;
        leak = (OPAMP_GAIN == 0.0) ? 1.0 : 1.0 - 1.0 / OPAMP_GAIN;
    end

    // uniform (0,1) from a 64-bit LCG (Knuth MMIX constants), 53-bit mantissa
    function automatic real uni();
        rs = rs * 64'd6364136223846793005 + 64'd1442695040888963407;
        return (real'(rs >> 11) + 0.5) / 9007199254740992.0;
    endfunction
    // Box-Muller gaussian (only used when NOISE_RMS > 0)
    function automatic real gauss();
        real u1, u2;
        u1 = uni(); u2 = uni();
        return $sqrt(-2.0 * $ln(u1)) * $cos(6.283185307179586 * u2);
    endfunction

    always @(posedge rst) begin x1 = 0.0; x2 = 0.0; n_bits = 0; end

    always @(negedge pdm_clk) begin
        real yn, x1_old;
        yn     = (x2 >= VOS) ? 1.0 : -1.0;        // comparator
        x1_old = x1;
        x1     = leak * x1 + 0.5 * (ain - yn);    // integrator 1 (input - DAC)
        if (NOISE_RMS > 0.0) x1 = x1 + NOISE_RMS * gauss();
        x2     = leak * x2 + 0.5 * (x1_old - yn); // integrator 2
        n_bits++;
        dout <= #(T_DELAY_NS) (yn > 0.0);
    end
endmodule
