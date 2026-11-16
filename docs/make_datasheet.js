// Generates VoxCore_VC1_Datasheet.docx   (node make_datasheet.js)
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, ImageRun, Header, Footer,
  AlignmentType, HeadingLevel, WidthType, ShadingType, BorderStyle, LevelFormat, PageNumber,
  PageBreak, TableOfContents, TabStopType,
} = require("docx");

const FONT = "Arial", MONO = "Consolas";
const DARK = "111827", GREY = "374151", LIGHT = "F3F4F6";
// Light theme, high contrast: one hue per block type (same scheme as the figures
// and the project-plan diagrams). c = heading / accent (>= 4.5:1 on white), f = table-header fill.
const TH = {
  gen: { c: "111827", f: "E5E7EB" },   // general           charcoal / grey
  cpu: { c: "1D4ED8", f: "DBEAFE" },   // processor         blue
  dsp: { c: "C2410C", f: "FFEDD5" },   // DSP / audio       orange
  nn:  { c: "0F766E", f: "CCFBF1" },   // neural network    teal
  mem: { c: "1E3A8A", f: "E0E7FF" },   // memory            navy
  per: { c: "BE185D", f: "FCE7F3" },   // peripherals/regs  pink
  ana: { c: "15803D", f: "DCFCE7" },   // analog / external green
  ver: { c: "7C3AED", f: "EDE9FE" },   // verification      violet
};
let CUR = TH.gen;                       // theme of the current section (set by h1/h2)
const BLUE = TH.cpu.c;
const W = 10800;                       // content width (US Letter, 0.85" margins) in DXA
const border = { style: BorderStyle.SINGLE, size: 4, color: "D0D7DE" };
const borders = { top: border, bottom: border, left: border, right: border };

// ---------------------------------------------------------------- helpers
const t = (text, o = {}) => new TextRun({ text, font: o.mono ? MONO : FONT, size: o.size || 19, bold: o.bold,
  italics: o.italics, color: o.color || DARK });
const p = (runs, o = {}) => new Paragraph({ children: Array.isArray(runs) ? runs : [t(runs, o)],
  spacing: { after: o.after ?? 100, before: o.before ?? 0, line: 264 }, alignment: o.align, keepNext: o.keepNext });
// headings: coloured text + a coloured rule (H1) so each section reads as its block type
const h1 = (text, th = TH.gen) => { CUR = th; return new Paragraph({ heading: HeadingLevel.HEADING_1,
  border: { bottom: { style: BorderStyle.SINGLE, size: 10, color: th.c, space: 2 } },
  children: [new TextRun({ text, color: th.c })] }); };
const h2 = (text, th) => { if (th) CUR = th; return new Paragraph({ heading: HeadingLevel.HEADING_2,
  children: [new TextRun({ text, color: (th || CUR).c })] }); };
const bullet = (runs) => new Paragraph({ numbering: { reference: "bullets", level: 0 },
  children: Array.isArray(runs) ? runs : [t(runs)], spacing: { after: 40, line: 252 } });
const code = (lines) => lines.map((l, i) => new Paragraph({
  children: [new TextRun({ text: l || " ", font: MONO, size: 16, color: DARK })],
  shading: { type: ShadingType.CLEAR, fill: LIGHT, color: "auto" },
  spacing: { after: i === lines.length - 1 ? 140 : 0, line: 240 }, indent: { left: 120, right: 120 } }));
const caption = (text) => p([t(text, { size: 16, italics: true, color: GREY })], { align: AlignmentType.CENTER, after: 200 });
const img = (file, wPx, hPx) => new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 60 },
  children: [new ImageRun({ type: "png", data: fs.readFileSync(file), transformation: { width: wPx, height: hPx } })] });

function table(headers, rows, widths, o = {}) {
  const theme = o.theme || CUR;
  const total = widths.reduce((a, b) => a + b, 0);
  const cell = (txt, i, isHead) => new TableCell({
    borders, width: { size: widths[i], type: WidthType.DXA },
    shading: isHead ? { type: ShadingType.CLEAR, fill: theme.f, color: "auto" } : undefined,
    margins: { top: 50, bottom: 50, left: 90, right: 90 },
    children: String(txt).split("\n").map((line) => new Paragraph({ spacing: { after: 0, line: 240 },
      children: [t(line, { size: 17, bold: isHead, mono: !isHead && o.monoCols && o.monoCols.includes(i) })] })),
  });
  return new Table({
    width: { size: total, type: WidthType.DXA }, columnWidths: widths,
    rows: [new TableRow({ tableHeader: true, children: headers.map((h, i) => cell(h, i, true)) }),
           ...rows.map((r) => new TableRow({ cantSplit: true, children: r.map((c, i) => cell(c, i, false)) }))],
  });
}
const gap = () => p("", { after: 120 });

// ---------------------------------------------------------------- content
const children = [];

// ---- title block
children.push(
  new Paragraph({ spacing: { after: 0 }, children: [new TextRun({ text: "VoxCore VC-1", font: FONT, size: 52, bold: true, color: DARK })] }),
  new Paragraph({ spacing: { after: 60 }, children: [new TextRun({ text: "Push-to-Talk Voice-Recognition SoC with RISC-V Core and Neural Accelerator", font: FONT, size: 26, color: BLUE })] }),
  new Paragraph({ spacing: { after: 60 }, border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: DARK, space: 4 } },
    children: [t("Datasheet  ·  Revision 0.3  ·  Preliminary (pre-silicon, RTL)  ·  October 2026", { size: 18, color: GREY })] }),
  // colour key: section headings, table headers and figures use one colour per block type
  new Paragraph({ spacing: { after: 160 }, children: [
    t("Colour key:  ", { size: 16, bold: true, color: DARK }),
    ...[["CPU", TH.cpu], ["DSP / audio", TH.dsp], ["NN", TH.nn], ["Memory / performance", TH.mem],
        ["Pins / registers", TH.per], ["Analog", TH.ana], ["Verification", TH.ver]].flatMap(([n, th]) => [
      new TextRun({ text: "■ ", font: FONT, size: 18, color: th.c }), t(n + "    ", { size: 16, color: DARK })]) ] }),
);

children.push(h1("1  Features", TH.gen));
[
  [t("RISC-V CPU (vc_rv32i): ", { bold: true }), t("5-stage pipelined RV32I, full forwarding, CPI 1.05 on compiled C")],
  [t("Dynamic branch prediction: ", { bold: true }), t("16-entry BTB, 2-bit counters, 4-entry return-address stack; 99.3 % accuracy on firmware")],
  [t("VC.MAC ISA extension: ", { bold: true }), t("6 custom-0 instructions (int8 dot-4, int32 MAC); 47× faster int8 dot products")],
  [t("Mixed-signal audio front-end: ", { bold: true }), t("PDM microphone interface with 2nd-order ΣΔ modulator model and on-chip CIC + FIR decimator; 74 dB SNR (≈ 12 ENOB), 80 dB dynamic range")],
  [t("Hardware MFCC front-end: ", { bold: true }), t("window, 512-point FFT, 32-band mel, log2, DCT; 10 coefficients × 49 frames")],
  [t("Neural-network accelerator: ", { bold: true }), t("8-lane int8 MAC array, 490→64→64→10 MLP, 4,903 cycles per inference")],
  [t("Recognition: ", { bold: true }), t("spoken digits 0–9, 96.3 % test accuracy (int8, speaker-dependent split)")],
  [t("Interfaces: ", { bold: true }), t("PDM microphone (1.024 MHz) or I2S audio input, UART TX, 8-in / 8-out GPIO")],
  [t("On-chip memory: ", { bold: true }), t("16 KB dual-port SRAM for code and data; dedicated DSP and NN buffers")],
  [t("AMBA APB3 peripheral bus ", { bold: true }), t("with wait-state support")],
  [t("Verification: ", { bold: true }), t("bit-exact vs Python golden models; 37/37 RISC-V ISA tests; 300 random programs in lockstep with an ISS")],
].forEach((r) => children.push(bullet(r)));

children.push(p("", { after: 60 }));
children.push(img("fig_block_diagram.png", 600, 379));
children.push(caption("Figure 1. VC-1 block diagram"));
children.push(h1("2  Applications", TH.gen));
["Push-to-talk voice commands for wearables, appliances and toys", "Offline keyword / digit entry (privacy: audio never leaves the chip)",
 "Voice front-end that wakes or feeds a larger AI processor", "Teaching and evaluation platform for RISC-V hardware/software co-design"]
  .forEach((x) => children.push(bullet(x)));

children.push(h1("3  General Description", TH.gen));
children.push(p("The VC-1 recognises a spoken digit after the user presses a talk button. Audio arrives from a PDM (sigma-delta) microphone, decimated on chip, or over I2S. The MFCC engine converts each 32 ms frame into 10 cepstral coefficients, and the NN accelerator classifies the 490-feature utterance into one of ten classes. The vc_rv32i CPU sequences the operation through memory-mapped registers and reports the result on the UART and GPIO pins."));
children.push(p("The CPU implements the RV32I base ISA plus the Zicntr counters and a custom VC.MAC extension, which it reaches through a PCPI co-processor port. A PicoRV32 core can be selected at build time as a reference (CPU_SEL = 1); both CPUs share the same bus, peripherals, VC.MAC unit and firmware binary."));
children.push(p([t("Status: ", { bold: true }), t("this is a pre-silicon RTL design. All performance figures are measured in cycle-accurate RTL simulation (Verilator 5). Area figures come from generic Yosys synthesis; a Synopsys Design Compiler script for the ASAP7 PDK is provided but its results are not included in this revision.", { italics: true })]));


// ---- configuration
children.push(h1("4  Build-Time Configuration", TH.gen));
children.push(table(["Parameter", "Values", "Default", "Description"], [
  ["CPU_SEL", "0, 1", "0", "0 = vc_rv32i (own 5-stage core), 1 = PicoRV32 (reference)"],
  ["BP_EN", "0, 1", "1", "vc_rv32i dynamic branch prediction; 0 = static not-taken"],
  ["BTB_ENTRIES", "power of 2", "16", "Branch target buffer entries (vc_rv32i)"],
  ["RAS_DEPTH", "≥ 2", "4", "Return-address stack depth (vc_rv32i)"],
  ["DATA_DIR", "path", "../data/", "Location of ROM images generated by model/train.py"],
  ["FW_FILE", "path", "../fw/firmware.hex", "Initial SRAM contents (firmware image)"],
], [1900, 1500, 1800, 5600], { monoCols: [0] }));
children.push(gap());

// ---- pins
children.push(h1("5  Pin Description", TH.per));
children.push(table(["Pin", "Dir", "Width", "Description"], [
  ["clk", "I", "1", "System clock. Rising-edge; all logic is single-clock except the I2S inputs."],
  ["rst_n", "I", "1", "Active-low reset, asynchronous assert, synchronised de-assert inside the chip."],
  ["i2s_sck", "I", "1", "I2S bit clock from the microphone / codec. Asynchronous; requires f_clk ≥ 4 × f_sck."],
  ["i2s_ws", "I", "1", "I2S word select (0 = left). Asynchronous, 2-flop synchronised."],
  ["i2s_sd", "I", "1", "I2S serial data, MSB first, one SCK after the WS edge."],
  ["pdm_clk", "O", "1", "PDM microphone clock, f_clk / PDM_DIV (1.024 MHz nominal); low when the PDM source is off."],
  ["pdm_dat", "I", "1", "PDM microphone data (1-bit ΣΔ stream). Driven by the mic after the falling edge; asynchronous, 2-flop synchronised."],
  ["uart_tx", "O", "1", "UART transmit, 8N1, idle high. Bit time set by UART DIV."],
  ["gpio_in[7:0]", "I", "8", "General-purpose inputs (2-flop synchronised). Firmware: bit 0 = talk button."],
  ["gpio_out[7:0]", "O", "8", "General-purpose outputs. Firmware: bit 1 = listening, bit 2 = done, [7:4] = digit."],
  ["trap", "O", "1", "CPU halted (EBREAK, ECALL or illegal instruction), raised after older instructions retire."],
], [1800, 700, 900, 7400], { monoCols: [0] }));
children.push(gap());

// ---- memory map
children.push(h1("6  Memory Map", TH.mem));
children.push(table(["Address range", "Size", "Region", "Notes"], [
  ["0x0000_0000 – 0x0000_3FFF", "16 KB", "SRAM", "Code, data and stack. Reset vector 0x0000_0000; stack top 0x0000_4000."],
  ["0x1000_0000 – 0x1000_0FFF", "4 KB", "UART", "APB slave 0, zero wait states"],
  ["0x1000_1000 – 0x1000_1FFF", "4 KB", "GPIO", "APB slave 1, zero wait states"],
  ["0x1000_2000 – 0x1000_2FFF", "4 KB", "VOICE", "APB slave 2; feature-window reads insert 1 wait state"],
  ["0x1000_3000 – 0x1000_3FFF", "4 KB", "(reserved)", "Reads return 0xDEAD_BEEF"],
], [2900, 900, 1200, 5800], { monoCols: [0] }));
children.push(gap());

// ---- CPU
children.push(h1("7  Processor: vc_rv32i", TH.cpu));
children.push(img("fig_cpu_pipeline.png", 640, 232));
children.push(caption("Figure 2. vc_rv32i pipeline"));
children.push(table(["Feature", "Implementation"], [
  ["ISA", "RV32I, Zicntr (cycle, instret), hpmcounter3/4, VC.MAC (custom-0)"],
  ["Pipeline", "IF · ID · EX · MEM · WB. The synchronous instruction SRAM's output register acts as the IF/ID register."],
  ["Buses", "Harvard: instruction port with fixed 1-cycle latency; data port with valid/ready handshake (PicoRV32-compatible)"],
  ["Data hazards", "Forwarding EX/MEM→EX and MEM/WB→EX, WB→ID write-through; 1-cycle load-use bubble; held operands re-latched during stalls"],
  ["Control hazards", "Prediction at fetch, resolution in EX; 0 cycles when correct, 1 squashed instruction when wrong"],
  ["Branch predictor", "16-entry direct-mapped BTB (tag, target, type, 2-bit counter), allocate on first taken; 4-entry RAS for returns"],
  ["Co-processor", "PCPI port: rs1/rs2 forwarded, EX stalls until ready; result latched if MEM is stalled"],
  ["Traps", "ECALL, EBREAK and illegal instructions halt the core (no exception vector in this revision)"],
  ["Trace", "RVFI-style retirement port (pc, insn, rd, wdata) used for lockstep verification"],
], [2200, 8600]));
children.push(gap());
children.push(h2("7.1  Performance counters (read-only CSRs)"));
children.push(table(["CSR", "Name", "Counts"], [
  ["0xC00 / 0xC80", "cycle / cycleh", "Clock cycles since reset (64-bit)"],
  ["0xC02 / 0xC82", "instret / instreth", "Retired instructions (64-bit)"],
  ["0xC03", "hpmcounter3", "Executed control-flow instructions (branches, JAL, JALR)"],
  ["0xC04", "hpmcounter4", "Branch mispredictions"],
], [2400, 2400, 6000], { monoCols: [0, 1] }));
children.push(gap());

// ---- VC.MAC
children.push(h1("8  VC.MAC Instruction-Set Extension", TH.cpu));
children.push(p("R-type encoding, opcode custom-0 (0001011), funct7 = 0000000. Each instruction updates a 32-bit accumulator inside the unit and returns its new value in rd. The unit attaches to the PCPI port and has a latency of one cycle (two when issued back-to-back)."));
children.push(table(["funct3", "Mnemonic", "Operation", "rd ←"], [
  ["000", "vc.mac rd, rs1, rs2", "acc ← acc + rs1 × rs2  (signed, low 32 bits)", "acc"],
  ["001", "vc.mul rd, rs1, rs2", "acc ← rs1 × rs2", "acc"],
  ["010", "vc.dot4 rd, rs1, rs2", "acc ← acc + Σ int8(rs1.b[i]) × int8(rs2.b[i]), i = 0..3", "acc"],
  ["011", "vc.dot4z rd, rs1, rs2", "acc ← Σ int8(rs1.b[i]) × int8(rs2.b[i])", "acc"],
  ["100", "vc.setacc rd, rs1", "acc ← rs1", "acc"],
  ["101", "vc.rdacc rd", "(no change)", "acc"],
  ["11x", "reserved", "Not claimed; the CPU raises an illegal-instruction halt", "—"],
], [900, 2400, 6200, 1300], { monoCols: [0, 1] }));
children.push(gap());
children.push(p("Programming example (fw/vc_mac.h):", { keepNext: true }));
children.push(...code([
  "#include \"vc_mac.h\"",
  "int32_t dot_hw(const int8_t *a, const int8_t *b, int n) {",
  "    const uint32_t *a4 = (const uint32_t *)a, *b4 = (const uint32_t *)b;",
  "    int32_t s = vc_setacc(0);",
  "    for (int i = 0; i < n / 4; i++) s = vc_dot4(a4[i], b4[i]);   // 4 MACs per instruction",
  "    return s;",
  "}",
  "// assembler form:  .insn r 0x0b, 2, 0, rd, rs1, rs2",
]));
children.push(p([t("Note: ", { bold: true }), t("the accumulator is architectural state outside the register file and must be saved by software across context switches.")]));

// ---- voice subsystem
children.push(h1("9  Voice Subsystem", TH.dsp));
children.push(h2("9.1  MFCC engine", TH.dsp));
children.push(img("fig_mfcc_chain.png", 640, 120));
children.push(caption("Figure 3. MFCC signal chain and number formats"));
children.push(table(["Stage", "Operation", "Format"], [
  ["Input", "16 kHz PCM, 1 s utterance (16,000 samples)", "int16"],
  ["Framing", "49 frames × 512 samples, hop 320 (32 ms / 20 ms); 1,024-entry ring buffer", "—"],
  ["Window", "Hamming, xw = (x·w) >>> 15", "w: unsigned Q1.15"],
  ["FFT", "512-point radix-2 DIT, in place, bit-reversed load, no per-stage scaling", "28-bit data, Q1.15 twiddles"],
  ["Power", "P = (Xr² + Xi²) >> 16, bins 0..256", "41-bit unsigned"],
  ["Mel", "32 triangular filters, 60–7,800 Hz; each bin feeds ≤ 2 filters", "9-bit weights, 50-bit acc."],
  ["Log", "log2 ≈ MSB position + 10 mantissa bits (piecewise linear)", "U6.10"],
  ["DCT", "10 coefficients, Σ L[m]·cos(πi(m+½)/32)", "Q2.14, 40-bit acc."],
  ["Normalise", "feat = sat8((c − off) >>> sh), per coefficient", "int8"],
], [1500, 6300, 3000]));
children.push(gap());
children.push(p("The engine processes one frame in about 14,000 clock cycles, against a frame period of 20 ms (about 1,000,000 cycles at 50 MHz). An overflow flag reports a processing backlog."));
children.push(h2("9.2  Neural-network accelerator", TH.nn));
children.push(table(["Item", "Value"], [
  ["Network", "Fully connected 490 → 64 → 64 → 16 (classes 0–9 used), ReLU"],
  ["Arithmetic", "int8 weights and activations, int32 accumulators, power-of-two requantisation (shifts 11, 9)"],
  ["Array", "8 lanes, output-stationary: one input broadcast to 8 lanes per cycle, 64-bit weight word per cycle"],
  ["Latency", "4,903 cycles per inference (4,560 weight words + bias loads)"],
  ["Model storage", "4,560 × 64-bit weight ROM (36.5 KB) + 144 × 32-bit bias ROM"],
  ["Output", "Argmax class in RESULT, 16 raw int32 logits in LOGIT[0..15]"],
], [2200, 8600]));
children.push(gap());
children.push(h2("9.3  PDM microphone interface and sigma-delta front-end", TH.ana));
children.push(p("A sigma-delta ADC is split between an analog modulator and a digital decimation filter. The modulator (two switched-capacitor integrators, a comparator and a 1-bit DAC) converts the microphone voltage into a 1-bit pulse-density stream at 1.024 MHz and shapes its quantisation noise to high frequencies. It sits inside a PDM MEMS microphone, or on chip as an analog macro. The VC-1 generates the PDM clock and performs the decimation in synthesizable logic. The modulator is delivered as a SystemVerilog real-number model (rtl/ams/sdm_rnm.sv) for verification and AMS co-simulation."));
children.push(img("fig_pdm_spectrum.png", 640, 217));
children.push(caption("Figure 4. Noise shaping in the 1-bit stream (left) and the decimated 16 kHz output (right)"));
children.push(table(["Parameter", "Value"], [
  ["Modulator (analog model)", "2nd-order discrete-time, Boser-Wooley, integrator gains ½, 1-bit quantiser, OSR 64"],
  ["PDM clock", "f_clk / PDM_DIV, 1.024 MHz nominal; PDM_DIV ≥ 8. Data sampled just before the rising edge."],
  ["CIC decimator", "4th order, ÷32, 24-bit modular arithmetic, integrators at the bit rate, no multipliers"],
  ["FIR decimator", "95 taps, ÷2, least-squares with CIC droop compensation, Q1.15 coefficients, 1 MAC / cycle"],
  ["Passband / stopband", "0–6.4 kHz, 0.015 dB ripple / ≥ 8 kHz, ≥ 79 dB"],
  ["SNR / ENOB", "74.3 dB / 12.1 bits at −6 dBFS (average of 4 tones, 0.7–1.7 kHz); 73–76 dB per tone because of idle tones; the RTL test tone measures 76.3 dB"],
  ["Dynamic range", "≈ 80 dB; overload above ≈ −3 dBFS"],
  ["Decimator implementation loss", "< 0.1 dB (vs ideal filtering of the same bitstream)"],
], [2800, 8000]));
children.push(gap());
children.push(img("fig_pdm_sweeps.png", 640, 169));
children.push(caption("Figure 5. SNR vs input level and analog non-idealities (behavioural model, average of 4 tones)"));
children.push(bullet([t("Op-amp DC gain: ", { bold: true }), t("no loss for A ≥ 100; 53 dB at A = 10 (integrator leakage). Rule of thumb: A > OSR.")]));
children.push(bullet([t("Thermal noise: ", { bold: true }), t("no loss up to 1e-4 FS rms input-referred; this sizes the sampling capacitors (kT/C).")]));
children.push(bullet([t("Comparator offset: ", { bold: true }), t("no measurable effect up to 0.4 FS; the in-loop quantiser's offset is noise-shaped.")]));
children.push(bullet([t("Clock jitter: ", { bold: true }), t("< 2 dB loss at 30 ns rms (6 kHz input); 8 dB at 100 ns.")]));
children.push(h2("9.4  I2S receiver", TH.per));
children.push(bullet("Philips I2S, slave mode, 16-bit slots (32 SCK per frame), MSB first, data one SCK after the WS edge"));
children.push(bullet("Left channel (WS = 0) captured; right channel ignored"));
children.push(bullet("SCK, WS and SD are 2-flop synchronised and sampled on detected SCK rising edges: requires f_clk ≥ 4 × f_sck"));
children.push(bullet("At 16 kHz: f_sck = 512 kHz, so any system clock ≥ 2.05 MHz is sufficient"));

// ---- registers
children.push(h1("10  Register Reference", TH.per));
children.push(h2("10.1  VOICE (base 0x1000_2000)"));
children.push(table(["Offset", "Name", "Access", "Reset", "Description"], [
  ["0x000", "CTRL", "W / RW", "0x0", "bit0 MFCC_START (write 1: start capture, self-clearing)\nbit1 NN_START (write 1: start inference, self-clearing)\nbit2 AUTO_NN (RW: start NN automatically when MFCC finishes)\nbit3 SRC_PDM (RW: audio source, 0 = I2S, 1 = PDM microphone)"],
  ["0x004", "STATUS", "R", "0x0", "bit0 MFCC_BUSY · bit1 MFCC_DONE · bit2 NN_BUSY · bit3 NN_DONE\nbit4 OVERFLOW · [13:8] FRAMES_DONE (0–49)"],
  ["0x008", "RESULT", "R", "0x0", "[3:0] detected class (valid when NN_DONE = 1)"],
  ["0x00C", "PDM_DIV", "RW", "49", "[7:0] f_clk / f_pdm, ≥ 8 (50 MHz / 49 ≈ 1.02 MHz)"],
  ["0x040–0x07C", "LOGIT[0..15]", "R", "0x0", "Raw int32 class scores"],
  ["0x800–0xFA4", "FEATURE[0..489]", "R", "—", "int8 MFCC features, sign-extended to 32 bits (index = frame × 10 + coef); 1 wait state"],
], [1250, 2050, 900, 700, 5900], { monoCols: [0, 1] }));
children.push(gap());
children.push(h2("10.2  UART (base 0x1000_0000)"));
children.push(table(["Offset", "Name", "Access", "Reset", "Description"], [
  ["0x0", "TXDATA", "W", "—", "[7:0] byte to transmit; ignored while BUSY = 1"],
  ["0x4", "STATUS", "R", "0x0", "bit0 BUSY (transmission in progress)"],
  ["0x8", "DIV", "RW", "434", "[15:0] clock cycles per bit (e.g. 50 MHz / 115,200 = 434)"],
], [1250, 2050, 900, 700, 5900], { monoCols: [0, 1] }));
children.push(gap());
children.push(h2("10.3  GPIO (base 0x1000_1000)"));
children.push(table(["Offset", "Name", "Access", "Reset", "Description"], [
  ["0x0", "IN", "R", "—", "[7:0] synchronised gpio_in pins"],
  ["0x4", "OUT", "RW", "0x00", "[7:0] drives gpio_out pins"],
], [1250, 2050, 900, 700, 5900], { monoCols: [0, 1] }));
children.push(gap());

// ---- programming
children.push(h1("11  Operating Sequence", TH.gen));
["Firmware boots from 0x0000_0000, sets UART DIV and prints a ready message.",
 "Wait for the talk button (GPIO IN bit 0).",
 "PDM microphone: write PDM_DIV. Then write CTRL = 0x5 (I2S) or 0xD (PDM: MFCC_START | AUTO_NN | SRC_PDM); the PDM clock starts and the filters clear in the same cycle. Set the listening LED (GPIO OUT bit 1).",
 "The MFCC engine captures the next 16,000 I2S samples and writes 490 features.",
 "AUTO_NN starts the NN accelerator; poll STATUS until NN_DONE = 1.",
 "Read RESULT (and LOGIT[RESULT] as a confidence score); report on UART and GPIO OUT [7:4]."]
  .forEach((x, i) => children.push(new Paragraph({ numbering: { reference: "steps", level: 0 }, children: [t(x)], spacing: { after: 40 } })));
children.push(gap());
children.push(...code([
  "VOICE_CTRL = CTRL_MFCC_START | CTRL_AUTO_NN;   // arm capture + automatic inference",
  "GPIO_OUT   = 0x02;                             // listening LED",
  "while (!(VOICE_STATUS & STAT_NN_DONE)) { }",
  "uint32_t digit = VOICE_RESULT & 0xF;",
]));

// ---- performance
children.push(h1("12  Performance Characteristics", TH.mem));
children.push(p("Measured in cycle-accurate RTL simulation with the shipped firmware (vc_rv32i, BP_EN = 1 unless noted).", { after: 120 }));
children.push(table(["Parameter", "vc_rv32i", "PicoRV32", "Unit"], [
  ["CPI, compiled C loop (63,269 instructions)", "1.05 (1.21 with BP_EN = 0)", "4.61", "cycles/instr"],
  ["Branch-prediction accuracy (full firmware run)", "99.3", "—", "%"],
  ["512-element int8 dot product, software", "66,605", "291,924", "cycles"],
  ["512-element int8 dot product, vc.dot4", "1,417", "4,886", "cycles"],
  ["64-element int32 MAC, software / vc.mac", "11,412 / 712", "49,994 / 2,450", "cycles"],
  ["MFCC computation per frame", "≈ 14,000", "≈ 14,000", "cycles"],
  ["NN inference", "4,903", "4,903", "cycles"],
  ["Spoken-digit accuracy (int8 model, test set)", "96.3", "96.3", "%"],
  ["Spoken-digit accuracy through the PDM path", "95.3", "95.3", "%"],
  ["PDM path SNR / ENOB (−6 dBFS, 4-tone average)", "74.3 / 12.1", "74.3 / 12.1", "dB / bits"],
], [4700, 2600, 1900, 1600]));
children.push(gap());
children.push(h2("12.1  Implementation (generic synthesis)", TH.mem));
children.push(table(["Block", "Cells (Yosys generic)", "Notes"], [
  ["MFCC engine", "58,875", "4 multipliers (28×16), 2 squarers, 32 × 50-bit mel accumulators"],
  ["NN accelerator", "19,696", "8 × (8×8) MAC lanes, 2 × 64-byte activation buffers"],
  ["vc_rv32i", "12,760", "8,493 without branch predictor"],
  ["VC.MAC", "6,019", "Dominated by the 32 × 32 multiplier"],
  ["PDM decimator", "4,787", "CIC (adders only), 18 × 16 FIR multiplier, clock generator"],
  ["Peripherals + bus", "≈ 650", "UART, GPIO, I2S RX, APB bridge, voice registers"],
  ["Total (memories excluded)", "102,785", "Memories are macros, listed below"],
], [2600, 2400, 5800]));
children.push(gap());
children.push(table(["Memory", "Organisation", "Type"], [
  ["CPU SRAM", "4,096 × 32 (16 KB)", "Dual-port, byte write"],
  ["NN weights", "4,560 × 64 (36.5 KB)", "ROM"],
  ["FFT working RAM", "512 × 56", "Single-port"],
  ["Audio ring buffer", "1,024 × 16", "Simple dual-port"],
  ["PDM FIR history / coefficients", "128 × 18 / 128 × 16 (95 used)", "Simple dual-port / ROM"],
  ["Feature RAM", "512 × 8 (490 used)", "Simple dual-port"],
  ["Window / twiddle / mel / DCT / norm / bias", "512×16 / 256×32 / 257×15 / 320×16 / 10×40 / 144×32", "ROM"],
], [3300, 4300, 3200]));
children.push(gap());
children.push(p([t("Timing target: ", { bold: true }), t("the provided SDC constrains a 2.0 ns clock (500 MHz) for ASAP7; the application needs only a few MHz. Electrical characteristics (voltage, power, temperature) are not specified for this pre-silicon revision.")]));

// ---- verification
children.push(h1("13  Verification Summary", TH.ver));
children.push(table(["Test", "Scope", "Result"], [
  ["tb_mfcc", "10 clips; all 490 features bit-exact vs Python golden model", "Pass"],
  ["tb_nn", "10 clips; all 16 logits and class bit-exact", "Pass"],
  ["tb_mac", "20,000 constrained-random VC.MAC ops, coverage goals per opcode, illegal encodings", "Pass"],
  ["ISA tests", "37 rv32ui tests on vc_rv32i (0 % and 50 % bus wait states) and PicoRV32", "111 / 111"],
  ["Random lockstep", "300 programs × 500 items, every retired instruction compared with the Python ISS", "300 / 300"],
  ["Predictor perf", "Misprediction budget on a directed branch / call / return loop", "Pass (204 ≤ 210)"],
  ["tb_pdm", "Analog ΣΔ RNM + PDM decimator: sine and 3 speech clips, every output sample bit-exact; SNR on RTL output", "Pass"],
  ["tb_soc", "Boot, self-test, button, audio (I2S on both CPUs, PDM via the analog model), MFCC, NN, UART + GPIO; 10 clips × 3", "30 / 30"],
  ["Mutation checks", "Eight injected RTL bugs; each one makes at least one test fail", "Pass"],
], [1900, 7100, 1800]));
children.push(gap());

// ---- limitations
children.push(h1("14  Known Limitations (Revision 0.3)", TH.gen));
["No interrupts or exception vector: ECALL, EBREAK and illegal instructions halt the CPU; the voice block is polled.",
 "No misaligned-access trap: loads and stores must be naturally aligned.",
 "2-bit counters cannot learn alternating branch patterns (e.g. T, N, T, N); a history-based predictor is planned.",
 "Accuracy is measured on a speaker-dependent split of the Free Spoken Digit Dataset; retraining on Google Speech Commands is supported.",
 "Memories are behavioural models / black boxes; SRAM and ROM macros must be generated for a target process.",
 "The sigma-delta modulator is a behavioural model; a transistor-level design is planned. A 2nd-order 1-bit loop limits SNR to about 75 dB.",
 "Testbenches are directed and constrained-random SystemVerilog plus Python models; a UVM environment is planned."]
  .forEach((x) => children.push(bullet(x)));

children.push(h1("15  Revision History", TH.gen));
children.push(table(["Revision", "Date", "Changes"], [
  ["0.1", "Oct 2026", "Initial release: PicoRV32, MFCC engine, NN accelerator, peripherals"],
  ["0.2", "Oct 2026", "vc_rv32i 5-stage core, branch predictor, VC.MAC extension, precise trap"],
  ["0.3", "Oct 2026", "PDM microphone interface, sigma-delta front-end (RNM model + CIC/FIR decimator)"],
], [1400, 1600, 7800]));

// ---------------------------------------------------------------- document
const doc = new Document({
  creator: "Div", title: "VoxCore VC-1 Datasheet", description: "Push-to-talk voice-recognition SoC datasheet",
  styles: {
    default: { document: { run: { font: FONT, size: 19 } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 26, bold: true, font: FONT, color: DARK },
        paragraph: { spacing: { before: 280, after: 120 }, outlineLevel: 0, keepNext: true } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 21, bold: true, font: FONT, color: DARK },
        paragraph: { spacing: { before: 200, after: 100 }, outlineLevel: 1, keepNext: true } },
    ],
  },
  numbering: { config: [
    { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 360, hanging: 240 } } } }] },
    { reference: "steps", levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 360, hanging: 300 } } } }] },
  ] },
  sections: [{
    properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1080, bottom: 1080, left: 720, right: 720 } } },
    headers: { default: new Header({ children: [new Paragraph({
      tabStops: [{ type: TabStopType.RIGHT, position: W }],
      border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: "D0D7DE", space: 2 } },
      children: [t("VoxCore VC-1", { size: 16, bold: true, color: BLUE }), t("\tDatasheet · Rev 0.3 · Preliminary", { size: 16, color: GREY })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
      children: [t("Page ", { size: 16, color: GREY }), new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 16, color: GREY }),
                 t(" of ", { size: 16, color: GREY }), new TextRun({ children: [PageNumber.TOTAL_PAGES], font: FONT, size: 16, color: GREY })] })] }) },
    children,
  }],
});
Packer.toBuffer(doc).then((b) => { fs.writeFileSync("VoxCore_VC1_Datasheet.docx", b); console.log("written"); });
