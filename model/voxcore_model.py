"""
VoxCore bit-accurate golden model.

Every function here mirrors one RTL block exactly (same bit widths, same
shifts, same rounding). If the RTL and this file disagree by even one LSB,
the RTL is wrong (or this file is) -- that is the whole point of a golden model.

Pipeline (per 1 s utterance @ 16 kHz = 16000 int16 samples):
  framing   : 49 frames, 512 samples long, hop 320
  window    : Hamming, Q1.15, xw = (x*w) >>> 15
  fft       : 512-pt radix-2 DIT, in-place, 28-bit data, Q1.15 twiddles, no scaling
  power     : P = (Xr^2 + Xi^2) >> 16              (bins 0..256)
  mel       : 32 triangular filters, 9-bit weights (0..256), 50-bit accumulators
  log2      : L = msb*1024 + next 10 bits           (16-bit unsigned)
  dct       : 10 coefficients, Q2.14 cosine table, c = acc >>> 14
  normalize : feat = sat8((c - OFF[i]) >>> SH[i])
  nn        : int8 MLP 490 -> 64 -> 64 -> 16 (10 used), ReLU + shift requant
"""
import numpy as np

# ---------------------------------------------------------------- constants
FS = 16000
N_SAMPLES = 16000
FRAME_LEN = 512
HOP = 320
N_FRAMES = 1 + (N_SAMPLES - FRAME_LEN) // HOP  # 49
N_FFT = 512
N_BINS = N_FFT // 2 + 1  # 257
N_MEL = 32
N_MFCC = 10
N_FEAT = N_FRAMES * N_MFCC  # 490
FFT_W = 28  # FFT datapath width (signed)
MEL_W = 50  # mel accumulator width (unsigned)
LOG_FRAC = 10
DCT_Q = 14
MEL_FMIN, MEL_FMAX = 60.0, 7800.0
MEL_INVALID = 63

NN_LAYERS = [(N_FEAT, 64), (64, 64), (64, 16)]
N_CLASSES = 10
LANES = 8


def _hz_to_mel(f):
    return 2595.0 * np.log10(1.0 + f / 700.0)


def _mel_to_hz(m):
    return 700.0 * (10 ** (m / 2595.0) - 1.0)


def build_tables():
    t = {}
    n = np.arange(FRAME_LEN)
    t["window"] = np.round((0.54 - 0.46 * np.cos(2 * np.pi * n / (FRAME_LEN - 1))) * 32767).astype(np.int64)
    k = np.arange(N_FFT // 2)
    t["tw_re"] = np.round(np.cos(2 * np.pi * k / N_FFT) * 32767).astype(np.int64)
    t["tw_im"] = np.round(-np.sin(2 * np.pi * k / N_FFT) * 32767).astype(np.int64)
    # mel table: for each bin, the 'rising' filter index j and its weight wr (0..256)
    pts = _mel_to_hz(np.linspace(_hz_to_mel(MEL_FMIN), _hz_to_mel(MEL_FMAX), N_MEL + 2))
    mel_j = np.full(N_BINS, MEL_INVALID, dtype=np.int64)
    mel_w = np.zeros(N_BINS, dtype=np.int64)
    for b in range(N_BINS):
        f = b * FS / N_FFT
        for j in range(N_MEL + 1):
            if pts[j] <= f < pts[j + 1]:
                mel_j[b] = j
                mel_w[b] = int(round(256 * (f - pts[j]) / (pts[j + 1] - pts[j])))
                break
    t["mel_j"], t["mel_w"] = mel_j, mel_w
    i = np.arange(N_MFCC)[:, None]
    m = np.arange(N_MEL)[None, :]
    t["dct"] = np.round(np.cos(np.pi * i * (m + 0.5) / N_MEL) * (1 << DCT_Q)).astype(np.int64)
    # feature normalisation (offset, shift) per coefficient -- set by calibrate()
    t["norm_off"] = np.zeros(N_MFCC, dtype=np.int64)
    t["norm_sh"] = np.zeros(N_MFCC, dtype=np.int64)
    return t


def bitrev(x, bits=9):
    return int(f"{x:0{bits}b}"[::-1], 2)


BITREV = np.array([bitrev(i) for i in range(N_FFT)])


# ---------------------------------------------------------------- MFCC blocks
def frames_of(x):
    x = np.asarray(x, dtype=np.int64)
    idx = np.arange(N_FRAMES)[:, None] * HOP + np.arange(FRAME_LEN)[None, :]
    return x[idx]  # (49, 512)


def window(fr, t):
    return (fr * t["window"][None, :]) >> 15


def fft_fixed(xw, t):
    """In-place radix-2 DIT, bit-reversed input -> natural order output."""
    re = np.zeros_like(xw)
    im = np.zeros_like(xw)
    re[:, BITREV] = xw  # mem[bitrev(i)] = xw[i]
    lim = 1 << (FFT_W - 1)
    for s in range(9):
        h = 1 << s
        bfly = np.arange(N_FFT // 2)
        j = bfly & (h - 1)
        k = (bfly >> s) << (s + 1)
        a = k + j
        b = a + h
        tw = j << (8 - s)
        wr, wi = t["tw_re"][tw], t["tw_im"][tw]
        br, bi = re[:, b], im[:, b]
        tr = (br * wr - bi * wi) >> 15
        ti = (br * wi + bi * wr) >> 15
        ar, ai = re[:, a], im[:, a]
        re[:, a], im[:, a] = ar + tr, ai + ti
        re[:, b], im[:, b] = ar - tr, ai - ti
        assert np.all(np.abs(re) < lim) and np.all(np.abs(im) < lim), "FFT overflow"
    return re, im


def power(re, im):
    return (re[:, :N_BINS] ** 2 + im[:, :N_BINS] ** 2) >> 16


def mel(p, t):
    out = np.zeros((p.shape[0], N_MEL), dtype=np.int64)
    for b in range(N_BINS):
        j, wr = t["mel_j"][b], t["mel_w"][b]
        if j == MEL_INVALID:
            continue
        if j < N_MEL:
            out[:, j] += p[:, b] * wr
        if j >= 1:
            out[:, j - 1] += p[:, b] * (256 - wr)
    assert np.all(out < (1 << MEL_W))
    return out


def log2_fixed(v):
    v = np.asarray(v, dtype=np.int64)
    out = np.zeros_like(v)
    nz = v > 0
    msb = np.zeros_like(v)
    msb[nz] = np.floor(np.log2(v[nz].astype(np.float64))).astype(np.int64)
    # guard float rounding at exact powers of two
    msb[nz] = np.where((1 << msb[nz]) > v[nz], msb[nz] - 1, msb[nz])
    msb[nz] = np.where((1 << (msb[nz] + 1)) <= v[nz], msb[nz] + 1, msb[nz])
    frac = np.zeros_like(v)
    # bits just below the MSB, aligned to 10 bits
    sh = msb - LOG_FRAC
    rem = v - (1 << msb)
    frac = np.where(sh >= 0, rem >> np.maximum(sh, 0), rem << np.maximum(-sh, 0))
    out[nz] = msb[nz] * 1024 + frac[nz]
    return out


def dct(L, t):
    return (L @ t["dct"].T) >> DCT_Q  # (frames, 10), arithmetic shift (floor)


def normalize(c, t):
    v = (c - t["norm_off"][None, :]) >> t["norm_sh"][None, :]
    return np.clip(v, -128, 127)


def mfcc_raw(x, t):
    """Everything up to (but excluding) normalisation. Returns (49,10) int."""
    fr = frames_of(x)
    re, im = fft_fixed(window(fr, t), t)
    return dct(log2_fixed(mel(power(re, im), t)), t)


def mfcc_fixed(x, t):
    """Returns 490 int8 features, frame-major (feat[f*10+i])."""
    return normalize(mfcc_raw(x, t), t).reshape(-1)


# ---------------------------------------------------------------- NN
def nn_forward(feat, q):
    """Integer MLP exactly as the accelerator computes it. q: quantised params."""
    x = np.asarray(feat, dtype=np.int64)
    for li, (W, b, sh) in enumerate(zip(q["W"], q["b"], q["sh"])):
        acc = W @ x + b  # int32 range
        assert np.all(np.abs(acc) < (1 << 31))
        if li < len(q["W"]) - 1:
            x = np.clip(acc >> sh, 0, 127)  # ReLU + requant
        else:
            logits = acc
    cls = int(np.argmax(logits[:N_CLASSES]))
    return logits, cls
