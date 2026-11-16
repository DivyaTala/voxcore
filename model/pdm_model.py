"""
VoxCore PDM / sigma-delta audio path: reference models.

  analog (behavioural)            digital (bit-exact with rtl/periph/pdm_rx.sv)
  ─────────────────────           ─────────────────────────────────────────────
  u(t) ─► 2nd-order ΣΔ ─► 1-bit ─► CIC4 ÷32 ─► >>>4 ─► 95-tap FIR ÷2 ─► int16 PCM
          modulator        1.024 MHz          32 kHz                    16 kHz

The modulator here must match rtl/ams/sdm_rnm.sv operation-for-operation
(same IEEE-754 double arithmetic in the same order), so that with the
non-idealities switched off the SystemVerilog RNM and this model produce the
identical bitstream. The decimator is pure integer and bit-exact.
"""
import numpy as np
from scipy import signal

FS_OUT = 16000
OSR = 64
FS_PDM = FS_OUT * OSR          # 1.024 MHz
CIC_N, CIC_R = 4, 32           # 4th-order CIC, decimate by 32 -> 32 kHz
CIC_W = 24                     # register width (modular arithmetic, needs >= 22)
CIC_SHIFT = 4                  # CIC output (±2^20) >>> 4 -> FIR input (±2^16)
FIR_TAPS = 95
FIR_DECIM = 2
FIR_Q = 15                     # coefficient format Q1.15
PCM_SHIFT = 16                 # FIR accumulator >>> 16 -> int16
INTERP = OSR                   # PCM -> modulator input: linear interpolation x64


# ---------------------------------------------------------------- filter design
def cic_mag(f):
    w = np.pi * np.asarray(f, float) / FS_PDM
    out = np.ones_like(w)
    nz = w != 0
    out[nz] = np.abs(np.sin(w[nz] * CIC_R) / (CIC_R * np.sin(w[nz]))) ** CIC_N
    return out


def design_fir(fp=6400.0, fstop=8000.0):
    """Least-squares FIR with CIC droop compensation in the passband."""
    fs = FS_PDM / CIC_R
    edges = np.linspace(0, fp, 17)
    bands, des, wts = [], [], []
    for a, b in zip(edges[:-1], edges[1:]):
        bands += [a, b]; des += list(1 / cic_mag([a, b])); wts.append(1)
    bands += [fstop, fs / 2]; des += [0, 0]; wts.append(60)
    h = signal.firls(FIR_TAPS, bands, des, weight=wts, fs=fs)
    return np.round(h * (1 << FIR_Q)).astype(np.int64)


FIR_COEF = design_fir()


# ---------------------------------------------------------------- analog modulator
class SDM2:
    """
    2nd-order discrete-time sigma-delta (Boser-Wooley, gains 1/2, 1-bit).
      y[n]    = +1 if x2[n] >= vos else -1
      x1[n+1] = leak*x1[n] + 0.5*(u[n] - y[n]) + e1[n]
      x2[n+1] = leak*x2[n] + 0.5*(x1[n] - y[n])
    Non-idealities (all off by default = ideal, matches the SV RNM bit-exactly):
      opamp_gain  finite DC gain A -> integrator leak = 1 - 1/A
      noise_rms   input-referred thermal (kT/C) noise added to integrator 1
      vos         comparator offset
    """
    def __init__(self, opamp_gain=None, noise_rms=0.0, vos=0.0, seed=1):
        self.leak = 1.0 if opamp_gain is None else 1.0 - 1.0 / opamp_gain
        self.noise_rms, self.vos = noise_rms, vos
        self.rng = np.random.default_rng(seed)

    def run(self, u):
        x1 = x2 = 0.0
        leak, vos = self.leak, self.vos
        e = self.rng.standard_normal(len(u)) * self.noise_rms if self.noise_rms else None
        y = np.empty(len(u), dtype=np.int8)
        for n, un in enumerate(u):
            yn = 1.0 if x2 >= vos else -1.0
            x1_old = x1
            x1 = leak * x1 + 0.5 * (un - yn)
            if e is not None:
                x1 += e[n]
            x2 = leak * x2 + 0.5 * (x1_old - yn)
            y[n] = 1 if yn > 0 else 0
        return y


def interp_pcm(pcm, n_out):
    """PCM (int16, 16 kHz) -> modulator input in [-1, 1) at 1.024 MHz.
    Linear interpolation written exactly as in tb/tb_pdm.sv so the doubles match."""
    pcm = np.asarray(pcm, dtype=np.int64)
    u = np.zeros(n_out)
    for n in range(n_out):
        k, j = divmod(n, INTERP)
        a = int(pcm[k]) if k < len(pcm) else 0
        b = int(pcm[k + 1]) if k + 1 < len(pcm) else 0
        u[n] = float(a * (INTERP - j) + b * j) / 64.0 / 32768.0
    return u


# ---------------------------------------------------------------- digital decimator
def _wrap(v, w=CIC_W):
    m = 1 << w
    v = np.asarray(v, dtype=np.int64) & (m - 1)
    return np.where(v >= m // 2, v - m, v)


def cic_decimate(bits):
    """4 integrators at the PDM rate, 4 combs at fs/32; modular CIC_W-bit math.
    Input bit 1 -> +1, 0 -> -1. Returns int (±2^20) at 32 kHz."""
    x = np.where(np.asarray(bits) > 0, 1, -1).astype(np.int64)
    acc = x
    for _ in range(CIC_N):
        acc = _wrap(np.cumsum(acc))           # wrap after every add == cumsum then wrap
    d = acc[CIC_R - 1::CIC_R]                 # sample every 32nd integrator output
    for _ in range(CIC_N):
        prev = np.concatenate(([0], d[:-1]))
        d = _wrap(d - prev)
    return d


def fir_decimate(x):
    """95-tap FIR, one output per 2 inputs (after inputs 2, 4, 6, ...)."""
    x = np.asarray(x, dtype=np.int64) >> CIC_SHIFT
    h = FIR_COEF
    xp = np.concatenate((np.zeros(FIR_TAPS - 1, dtype=np.int64), x))
    outs = []
    for n in range(FIR_DECIM - 1, len(x), FIR_DECIM):
        win = xp[n:n + FIR_TAPS][::-1]          # x[n], x[n-1], ... x[n-94]
        acc = int(np.dot(win, h))
        outs.append(acc >> PCM_SHIFT)
    return np.clip(np.array(outs, dtype=np.int64), -32768, 32767)


def decimate(bits):
    return fir_decimate(cic_decimate(bits))


def pdm_chain(pcm, n_out_samples=16000, **sdm_kw):
    """Full path: PCM clip -> analog modulator -> bitstream -> decimator -> PCM."""
    n_bits = (n_out_samples + 4) * OSR
    bits = SDM2(**sdm_kw).run(interp_pcm(pcm, n_bits))
    return decimate(bits)[:n_out_samples], bits


# ---------------------------------------------------------------- metrics
def snr_enob(x, fs=FS_OUT, f0=None, band=(20, 7800)):
    """SNR (and SINAD-based ENOB) of a sine in x, Blackman-Harris window."""
    x = np.asarray(x, float)
    x = x - x.mean()
    w = signal.windows.blackmanharris(len(x))
    X = np.abs(np.fft.rfft(x * w)) ** 2
    f = np.fft.rfftfreq(len(x), 1 / fs)
    k0 = np.argmax(X[1:]) + 1 if f0 is None else int(round(f0 * len(x) / fs))
    sig_bins = slice(max(k0 - 4, 1), k0 + 5)
    p_sig = X[sig_bins].sum()
    inband = (f >= band[0]) & (f <= band[1])
    mask = inband.copy(); mask[sig_bins] = False
    p_noise = X[mask].sum()
    snr = 10 * np.log10(p_sig / p_noise)
    return snr, (snr - 1.76) / 6.02
