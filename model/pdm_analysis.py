"""
Mixed-signal characterisation of the PDM path (writes PNGs + pdm_results.json to docs/).
  1. noise-shaping spectrum (bitstream and decimated output)
  2. SNR vs input amplitude (dynamic range, overload)
  3. SNR vs op-amp DC gain (integrator leakage)
  4. SNR vs input-referred thermal noise
  5. SNR vs comparator offset
  6. SNR vs sampling-clock jitter
usage: python3 pdm_analysis.py
"""
import json
import os
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(__file__))
import pdm_model as pm

OUT = os.path.join(os.path.dirname(__file__), "..", "docs")
N = 8192                                   # output samples analysed
SETTLE = 64
F0 = round(1000 * N / pm.FS_OUT) * pm.FS_OUT / N      # coherent ~1 kHz tone
plt.rcParams.update({"font.size": 9, "font.family": "DejaVu Sans"})
ACC, INK, GRID = "#1D4ED8", "#111827", "#D1D5DB"
ORANGE, TEAL, PINK, GREEN, RED = "#C2410C", "#0F766E", "#BE185D", "#15803D", "#B91C1C"


def tone(amp, f0=F0, jitter_s=0.0, seed=3):
    t = np.arange((N + SETTLE + 4) * pm.OSR) / pm.FS_PDM
    if jitter_s:
        t = t + np.random.default_rng(seed).standard_normal(len(t)) * jitter_s
    return amp * np.sin(2 * np.pi * f0 * t)


def measure(amp=0.5, f0=F0, jitter_s=0.0, **kw):
    bits = pm.SDM2(**kw).run(tone(amp, f0, jitter_s))
    pcm = pm.decimate(bits)[SETTLE:SETTLE + N]
    return pm.snr_enob(pcm, f0=f0, band=(20, 6400))[0], bits, pcm


# 1-bit 2nd-order modulators produce idle tones, so a single-tone SNR scatters
# by about ±2 dB. Sweeps therefore average (in power) over four coherent tones.
TONES = [round(f * N / pm.FS_OUT) * pm.FS_OUT / N for f in (700, 1000, 1300, 1700)]


def measure_avg(amp=0.5, tones=TONES, **kw):
    snrs = [measure(amp, f0=f, **kw)[0] for f in tones]
    return 10 * np.log10(np.mean(10 ** (np.array(snrs) / 10)))


def style(ax, xl, yl):
    ax.grid(True, color=GRID, lw=0.6); ax.set_xlabel(xl); ax.set_ylabel(yl)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)


res = {}
# ---------------------------------------------------------------- 1. spectrum
snr, bits, pcm = measure(0.5)
res["snr_-6dBFS_1kHz"] = round(snr, 1); res["enob_-6dBFS_1kHz"] = round((snr - 1.76) / 6.02, 2)
snr_avg = measure_avg(0.5)
res["snr_-6dBFS_avg"] = round(snr_avg, 1); res["enob_-6dBFS_avg"] = round((snr_avg - 1.76) / 6.02, 2)
y = np.where(bits > 0, 1.0, -1.0)[SETTLE * pm.OSR:(SETTLE + N) * pm.OSR]
w = np.blackman(len(y)); Y = np.abs(np.fft.rfft(y * w)) ** 2; fy = np.fft.rfftfreq(len(y), 1 / pm.FS_PDM)
Y = 10 * np.log10(Y / Y.max() + 1e-30)
xo = (pcm - pcm.mean()) * np.blackman(N); X = np.abs(np.fft.rfft(xo)) ** 2; fx = np.fft.rfftfreq(N, 1 / pm.FS_OUT)
X = 10 * np.log10(X / X.max() + 1e-30)
fig, (a1, a2) = plt.subplots(1, 2, figsize=(10, 3.4))
a1.semilogx(fy[1:], Y[1:], color=ACC, lw=0.5)
f_ref = np.logspace(4, 5.6, 10)
a1.semilogx(f_ref, -95 + 40 * np.log10(f_ref / 1e4), "--", color=RED, lw=1.6, label="40 dB/decade (2nd order)")
a1.axvspan(20, 6400, color="#DCFCE7", alpha=0.9, label="audio band")
a1.set_xlim(100, pm.FS_PDM / 2); a1.set_ylim(-160, 5); a1.legend(loc="lower right", fontsize=8, frameon=False)
a1.set_title("1-bit PDM stream at 1.024 MHz: noise pushed out of band", fontsize=9.5, loc="left")
style(a1, "Frequency (Hz)", "Power (dB, rel. tone)")
a2.plot(fx / 1000, X, color=ORANGE, lw=0.6)
a2.set_xlim(0, 8); a2.set_ylim(-150, 5)
a2.set_title(f"Decimated 16 kHz PCM: SNR {snr:.1f} dB (−6 dBFS, 1 kHz)", fontsize=9.5, loc="left")
style(a2, "Frequency (kHz)", "Power (dB, rel. tone)")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig_pdm_spectrum.png"), dpi=200, facecolor="white"); plt.close(fig)

# ---------------------------------------------------------------- 2-6. sweeps
amps_db = [-80, -70, -60, -50, -40, -30, -20, -12, -9, -6, -4, -3, -2, -1.5, -1]
snr_amp = [measure_avg(10 ** (a / 20)) for a in amps_db]
gains = [10, 20, 50, 100, 200, 500, 1000, 3000, 10000]
snr_gain = [measure_avg(0.5, opamp_gain=g) for g in gains]
noises = [1e-6, 3e-6, 1e-5, 3e-5, 1e-4, 3e-4, 1e-3]
snr_noise = [measure_avg(0.5, noise_rms=n) for n in noises]
offsets = [0.0, 0.01, 0.05, 0.1, 0.2, 0.4]
snr_vos = [measure_avg(0.5, vos=v) for v in offsets]
jitters = [1e-9, 1e-8, 3e-8, 1e-7, 3e-7, 1e-6]
J_TONES = [round(f * N / pm.FS_OUT) * pm.FS_OUT / N for f in (5500, 6000)]
snr_jit = [measure_avg(0.5, tones=J_TONES, jitter_s=j) for j in jitters]

peak = int(np.argmax(snr_amp))
dr_idx = next(i for i, s in enumerate(snr_amp) if s > 0)
res.update({
    "peak_snr_db": round(snr_amp[peak], 1), "peak_snr_at_dbfs": amps_db[peak],
    "dynamic_range_db": round(-np.interp(0, snr_amp[:peak + 1], amps_db[:peak + 1]), 1),
    "snr_vs_amp": dict(zip(map(str, amps_db), [round(s, 1) for s in snr_amp])),
    "snr_vs_opamp_gain": dict(zip(map(str, gains), [round(s, 1) for s in snr_gain])),
    "snr_vs_noise_rms": dict(zip(map(str, noises), [round(s, 1) for s in snr_noise])),
    "snr_vs_offset": dict(zip(map(str, offsets), [round(s, 1) for s in snr_vos])),
    "snr_vs_jitter_6kHz": dict(zip(map(str, jitters), [round(s, 1) for s in snr_jit])),
})

fig, axs = plt.subplots(1, 4, figsize=(11, 2.9))
axs[0].plot(amps_db, snr_amp, "o-", color=ACC, ms=3.5, lw=1.4)
axs[0].axhline(0, color=INK, lw=0.6)
axs[0].set_title(f"Dynamic range ≈ {res['dynamic_range_db']:.0f} dB", fontsize=9, loc="left")
style(axs[0], "Input (dBFS)", "SNR (dB)")
axs[1].semilogx(gains, snr_gain, "o-", color=ORANGE, ms=3.5, lw=1.4)
axs[1].set_title("Op-amp DC gain (leakage)", fontsize=9, loc="left"); style(axs[1], "A (V/V)", "SNR (dB)")
axs[2].semilogx(noises, snr_noise, "o-", color=TEAL, ms=3.5, lw=1.4)
axs[2].set_title("Thermal noise (kT/C)", fontsize=9, loc="left"); style(axs[2], "Input-referred rms (FS)", "SNR (dB)")
axs[3].semilogx(np.array(jitters) * 1e9, snr_jit, "o-", color=PINK, ms=3.5, lw=1.4)
axs[3].set_title("Sampling jitter, 6 kHz tone", fontsize=9, loc="left"); style(axs[3], "σ jitter (ns)", "SNR (dB)")
fig.tight_layout(); fig.savefig(os.path.join(OUT, "fig_pdm_sweeps.png"), dpi=200, facecolor="white"); plt.close(fig)

json.dump(res, open(os.path.join(OUT, "pdm_results.json"), "w"), indent=2)
print(json.dumps(res, indent=2))
