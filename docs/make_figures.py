"""Generate the datasheet figures (PNG) for VoxCore. Run: python3 make_figures.py"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

INK, EDGE, TINT = "#111827", "#374151", "#F3F4F6"
# light theme, high contrast: one hue per block type (same scheme as the plan doc)
#            stroke     fill
CPU = ("#1D4ED8", "#DBEAFE")   # blue    - processor
DSP = ("#C2410C", "#FFEDD5")   # orange  - DSP / audio
NN  = ("#0F766E", "#CCFBF1")   # teal    - neural network
MEM = ("#1E3A8A", "#E0E7FF")   # navy    - memory
PER = ("#BE185D", "#FCE7F3")   # pink    - peripherals / bus slaves
EXT = ("#15803D", "#DCFCE7")   # green   - external / analog
BP  = ("#7C3AED", "#EDE9FE")   # violet  - branch predictor
ACC = CPU[0]
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9})


def box(ax, x, y, w, h, title, lines=(), kind=None, dashed=False, **_):
    ec, fc = kind if kind else (EDGE, "white")
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.12",
                                lw=1.8, ec=ec, fc=fc, ls="--" if dashed else "-"))
    ty = y + h - 0.32
    ax.text(x + w / 2, ty, title, ha="center", va="center", fontsize=9.5, weight="bold", color=INK)
    for i, l in enumerate(lines):
        ax.text(x + w / 2, ty - 0.33 * (i + 1), l, ha="center", va="center", fontsize=8, color=INK)


def arrow(ax, x0, y0, x1, y1, both=False, color=INK):
    ax.add_patch(FancyArrowPatch((x0, y0), (x1, y1), arrowstyle="<|-|>" if both else "-|>",
                                 mutation_scale=10, lw=1.1, color=color))


def save(fig, name):
    fig.savefig(name, dpi=200, bbox_inches="tight", facecolor="white")
    plt.close(fig)


# ---------------------------------------------------------------- system block diagram
fig, ax = plt.subplots(figsize=(10, 6.2))
ax.set_xlim(0, 15); ax.set_ylim(0, 9.2); ax.axis("off")
# voice subsystem container
ax.add_patch(FancyBboxPatch((3.45, 5.3), 11.25, 3.7, boxstyle="round,pad=0,rounding_size=0.15",
                            lw=1.3, ec=INK, fc="#FAFAFA", ls=(0, (5, 3))))
ax.text(3.65, 8.75, "Voice subsystem (voice_apb)  ·  APB slave 2  ·  0x1000_2000", fontsize=9, weight="bold", color=INK)
box(ax, 0.2, 7.25, 2.5, 1.3, "I2S codec", ["SCK · WS · SD"], kind=EXT, dashed=True)
box(ax, 0.2, 5.55, 2.5, 1.45, "PDM mic", ["analog ΣΔ modulator", "1-bit @ 1.024 MHz"], kind=EXT, dashed=True)
box(ax, 3.6, 7.25, 2.3, 1.3, "i2s_rx", ["2-FF CDC"], kind=PER)
box(ax, 3.6, 5.55, 2.3, 1.45, "pdm_rx", ["CIC4 ÷32 · FIR ÷2", "clock gen"], kind=DSP)
box(ax, 6.3, 6.1, 3.0, 2.1, "MFCC engine", ["window · 512-pt FFT", "32 mel · log2 · DCT", "10 coeff × 49 frames"], kind=DSP)
box(ax, 9.7, 6.1, 1.7, 2.1, "Feature", ["RAM", "490 × int8"], kind=MEM)
box(ax, 11.8, 6.1, 2.7, 2.1, "NN accelerator", ["8-lane int8 MAC", "490→64→64→10", "argmax"], kind=NN)
arrow(ax, 2.7, 7.9, 3.6, 7.9); arrow(ax, 2.7, 6.1, 3.6, 6.1)
arrow(ax, 3.6, 6.55, 2.7, 6.55, color=EXT[0])
ax.text(3.06, 6.72, "pdm_clk", ha="center", fontsize=6.5, color=EXT[0], weight="bold")
ax.text(3.06, 5.8, "pdm_dat", ha="center", fontsize=6.5, color=INK)
arrow(ax, 5.9, 7.9, 6.3, 7.4); arrow(ax, 5.9, 6.3, 6.3, 6.8)
arrow(ax, 9.3, 7.15, 9.7, 7.15); arrow(ax, 11.4, 7.15, 11.8, 7.15)
# bus
ax.add_patch(FancyBboxPatch((0.2, 3.9), 14.5, 0.55, boxstyle="round,pad=0,rounding_size=0.1",
                            lw=1.1, ec=EDGE, fc=TINT))
ax.text(7.45, 4.175, "APB3 interconnect  ·  memory-mapped registers  ·  0x1000_0000", ha="center",
        va="center", fontsize=9, weight="bold", color=INK)
arrow(ax, 9.0, 5.3, 9.0, 4.45, both=True)
# lower row
box(ax, 0.2, 1.2, 2.9, 2.1, "vc_rv32i CPU", ["5-stage RV32I", "BTB + 2-bit + RAS", "Zicntr counters"], kind=CPU)
box(ax, 3.8, 1.2, 2.2, 2.1, "VC.MAC", ["custom-0 ISA ext.", "PCPI co-processor", "dot4 · mac"], kind=CPU)
box(ax, 6.5, 1.2, 2.2, 2.1, "SRAM 16 KB", ["dual-port", "I-port + D-port", "0x0000_0000"], kind=MEM)
box(ax, 9.1, 1.2, 1.7, 2.1, "APB bridge", ["native bus", "→ APB3"], kind=PER)
box(ax, 11.1, 1.2, 1.6, 2.1, "UART", ["TX 8N1", "slave 0"], kind=PER)
box(ax, 13.0, 1.2, 1.7, 2.1, "GPIO", ["8 in / 8 out", "slave 1"], kind=PER)
arrow(ax, 3.1, 2.25, 3.8, 2.25, both=True)
ax.text(3.45, 2.5, "PCPI", ha="center", fontsize=7.5, color=INK)
# CPU buses run underneath: I-bus to SRAM port A, D-bus to SRAM port B and the APB bridge
ax.plot([1.2, 1.2, 7.0, 7.0], [1.2, 0.75, 0.75, 1.2], color=INK, lw=1.2)
ax.plot([2.1, 2.1, 9.95, 9.95], [1.2, 0.45, 0.45, 1.2], color=INK, lw=1.2)
ax.plot([8.2, 8.2], [0.45, 1.2], color=INK, lw=1.2)
ax.text(4.6, 0.82, "I-bus", ha="center", va="bottom", fontsize=7.5, color=INK)
ax.text(5.6, 0.2, "D-bus (valid/ready)", ha="center", va="center", fontsize=7.5, color=INK)
arrow(ax, 9.95, 3.3, 9.95, 3.9, both=True)
arrow(ax, 11.9, 3.3, 11.9, 3.9, both=True); arrow(ax, 13.85, 3.3, 13.85, 3.9, both=True)
ax.text(11.9, 0.85, "uart_tx", ha="center", fontsize=8, color=INK)
ax.text(13.85, 0.85, "button · LEDs", ha="center", fontsize=8, color=INK)
for i, (lbl, k) in enumerate([("CPU", CPU), ("DSP / audio", DSP), ("NN", NN), ("Memory", MEM),
                              ("Peripherals", PER), ("External / analog", EXT)]):
    x0 = 0.25 + i * 2.45
    ax.add_patch(FancyBboxPatch((x0, -0.55), 0.32, 0.32, boxstyle="round,pad=0,rounding_size=0.06",
                                lw=1.6, ec=k[0], fc=k[1]))
    ax.text(x0 + 0.45, -0.39, lbl, va="center", fontsize=8, color=INK)
ax.set_ylim(-0.8, 9.2)
save(fig, "fig_block_diagram.png")

# ---------------------------------------------------------------- CPU pipeline
fig, ax = plt.subplots(figsize=(10, 3.6))
ax.set_xlim(0, 15); ax.set_ylim(0, 5.4); ax.axis("off")
stages = [("IF", ["PC select", "I-SRAM access"]), ("ID", ["decode · RF read", "load-use detect"]),
          ("EX", ["ALU · branch", "forwarding · PCPI"]), ("MEM", ["D-bus valid/ready", "load align"]),
          ("WB", ["RF write", "retire trace"])]
xs = [0.4, 3.3, 6.2, 9.1, 12.0]
for (n, l), x in zip(stages, xs):
    box(ax, x, 1.9, 2.4, 1.6, n, l, kind=CPU if n != "MEM" else MEM)
for x in xs[:-1]:
    arrow(ax, x + 2.4, 2.7, x + 2.9, 2.7)
box(ax, 0.4, 4.0, 6.3, 1.1, "Branch predictor (indexed by PC in ID)", ["16-entry BTB · 2-bit counters · 4-entry RAS"], kind=BP)
arrow(ax, 1.6, 4.0, 1.6, 3.5, color=BP[0])
ax.annotate("", xy=(1.0, 1.9), xytext=(7.4, 1.9), arrowprops=dict(arrowstyle="-|>", color="#B91C1C", lw=1.2,
            connectionstyle="arc3,rad=-0.35"))
ax.text(4.2, 0.55, "redirect on mispredict (1 squashed instruction)", ha="center", fontsize=8, color="#B91C1C")
ax.annotate("", xy=(7.0, 3.5), xytext=(10.3, 3.5), arrowprops=dict(arrowstyle="-|>", color=NN[0], lw=1.4,
            connectionstyle="arc3,rad=0.45"))
ax.annotate("", xy=(7.6, 3.5), xytext=(13.2, 3.5), arrowprops=dict(arrowstyle="-|>", color=NN[0], lw=1.4,
            connectionstyle="arc3,rad=0.35"))
ax.text(10.9, 4.75, "forwarding EX/MEM → EX, MEM/WB → EX", ha="center", fontsize=8, color=NN[0], weight="bold")
save(fig, "fig_cpu_pipeline.png")

# ---------------------------------------------------------------- MFCC chain
fig, ax = plt.subplots(figsize=(10, 1.9))
ax.set_xlim(0, 15.4); ax.set_ylim(0, 2.4); ax.axis("off")
chain = [("PCM", ["int16", "16 kHz"]), ("Frame", ["512 smp", "hop 320"]), ("Window", ["Hamming", "Q1.15"]),
         ("FFT", ["512-pt", "28-bit"]), ("|X|²", ["power", ">> 16"]), ("Mel", ["32", "filters"]),
         ("log2", ["U6.10", ""]), ("DCT", ["10", "coeff"]), ("Norm", ["int8", "feature"])]
w, g = 1.45, 0.25
for i, (n, sub) in enumerate(chain):
    x = 0.1 + i * (w + g)
    kind = EXT if n in ("PCM", "Frame") else DSP if n in ("Window", "FFT", "|X|²") else NN if n in ("Mel", "log2", "DCT") else MEM
    box(ax, x, 0.3, w, 1.7, n, sub, kind=kind)
    if i < len(chain) - 1:
        arrow(ax, x + w, 1.15, x + w + g, 1.15)
save(fig, "fig_mfcc_chain.png")
print("figures written")
