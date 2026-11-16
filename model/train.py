"""
Train the VoxCore keyword model on hardware-exact features, quantise to int8,
and export everything the RTL needs (ROM .hex files + test vectors).

usage: python3 train.py <dataset_dir> [--speech-commands]
  default dataset : Free Spoken Digit Dataset recordings/ (8 kHz wav, digits 0-9)
  --speech-commands : Google Speech Commands root (16 kHz), uses 10 command words
"""
import argparse
import os
import sys
import json
import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly
from sklearn.neural_network import MLPClassifier

sys.path.insert(0, os.path.dirname(__file__))
import voxcore_model as vm

SC_WORDS = ["yes", "no", "up", "down", "left", "right", "on", "off", "stop", "go"]


def load_clip(path):
    fs, x = wavfile.read(path)
    x = x.astype(np.float64)
    if x.ndim > 1:
        x = x[:, 0]
    if fs == 8000:
        x = resample_poly(x, 2, 1)
    elif fs != 16000:
        raise ValueError(f"{path}: unsupported rate {fs}")
    # centre in a 1 s window (crop or zero-pad)
    out = np.zeros(vm.N_SAMPLES)
    if len(x) >= vm.N_SAMPLES:
        s = (len(x) - vm.N_SAMPLES) // 2
        out[:] = x[s:s + vm.N_SAMPLES]
    else:
        s = (vm.N_SAMPLES - len(x)) // 2
        out[s:s + len(x)] = x
    # fixed-gain stage: peak-normalise to ~ -6 dBFS (models the mic/PGA gain)
    pk = np.max(np.abs(out)) or 1.0
    return np.round(out * (16000.0 / pk)).astype(np.int64)


def list_fsdd(root):
    items = []
    for f in sorted(os.listdir(root)):
        if f.endswith(".wav"):
            d, spk, idx = f[:-4].split("_")
            items.append((os.path.join(root, f), int(d), int(idx) < 5))  # idx 0-4 = test
    return items


def list_sc(root):
    test = set(open(os.path.join(root, "testing_list.txt")).read().split())
    items = []
    for c, w in enumerate(SC_WORDS):
        for f in sorted(os.listdir(os.path.join(root, w))):
            rel = f"{w}/{f}"
            items.append((os.path.join(root, rel), c, rel in test))
    return items


def to_hex(vals, width_bits):
    mask = (1 << width_bits) - 1
    nd = (width_bits + 3) // 4
    return "\n".join(f"{int(v) & mask:0{nd}x}" for v in vals) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--speech-commands", action="store_true")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data"))
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    items = list_sc(args.dataset) if args.speech_commands else list_fsdd(args.dataset)
    print(f"{len(items)} clips")
    t = vm.build_tables()

    pcm = np.stack([load_clip(p) for p, _, _ in items])
    y = np.array([c for _, c, _ in items])
    is_test = np.array([te for _, _, te in items])
    raw = np.stack([vm.mfcc_raw(x, t) for x in pcm])  # (N,49,10)
    print("features done")

    # ---- calibrate normalisation on the training set
    tr = raw[~is_test].reshape(-1, vm.N_MFCC)
    off = np.round(tr.mean(axis=0)).astype(np.int64)
    span = np.percentile(np.abs(tr - off), 99.5, axis=0)
    sh = np.maximum(0, np.ceil(np.log2(np.maximum(span, 1) / 127.0))).astype(np.int64)
    t["norm_off"], t["norm_sh"] = off, sh
    feat = np.clip((raw - off) >> sh, -128, 127).reshape(len(items), -1)

    # ---- train float MLP on (int8 feature / 64)
    SX = 1.0 / 64
    clf = MLPClassifier(hidden_layer_sizes=(64, 64), activation="relu", alpha=1e-3,
                        max_iter=400, random_state=1, early_stopping=False)
    clf.fit(feat[~is_test] * SX, y[~is_test])
    print(f"float  test acc: {clf.score(feat[is_test] * SX, y[is_test]):.3f}")

    # ---- quantise: weights int8 per layer, bias int32, power-of-two requant shifts
    q = {"W": [], "b": [], "sh": []}
    s_in = SX
    x_cal = feat[~is_test].T.astype(np.int64)  # (490, Ntrain)
    for li, (Wf, bf) in enumerate(zip(clf.coefs_, clf.intercepts_)):
        Wf = Wf.T  # (out, in)
        n_in, n_out = vm.NN_LAYERS[li]
        sW = np.max(np.abs(Wf)) / 127.0
        Wq = np.zeros((n_out, n_in), dtype=np.int64)
        Wq[:Wf.shape[0]] = np.clip(np.round(Wf / sW), -127, 127)
        bq = np.zeros(n_out, dtype=np.int64)
        bq[:Wf.shape[0]] = np.round(bf / (sW * s_in))
        if li == len(clf.coefs_) - 1:
            bq[Wf.shape[0]:] = -(1 << 30)  # padded classes never win argmax
        acc = Wq @ x_cal + bq[:, None]
        if li < len(clf.coefs_) - 1:
            p = np.percentile(np.maximum(acc, 0), 99.9)
            s = int(max(0, np.ceil(np.log2(max(p, 1) / 127.0))))
            x_cal = np.clip(acc >> s, 0, 127)
            s_in = sW * s_in * (1 << s)
        else:
            s = 0
        q["W"].append(Wq); q["b"].append(bq); q["sh"].append(s)

    pred = np.array([vm.nn_forward(f, q)[1] for f in feat])
    acc_q = np.mean(pred[is_test] == y[is_test])
    print(f"int8   test acc: {acc_q:.3f}   (shifts {q['sh']})")

    # ---------------------------------------------------------------- export
    w = lambda name, txt: open(os.path.join(out, name), "w").write(txt)
    w("window.hex", to_hex(t["window"], 16))
    w("twiddle.hex", "".join(f"{int(r) & 0xffff:04x}{int(i) & 0xffff:04x}\n" for r, i in zip(t["tw_re"], t["tw_im"])))
    w("mel.hex", "".join(f"{(int(j) << 9) | int(wr):04x}\n" for j, wr in zip(t["mel_j"], t["mel_w"])))
    w("dct.hex", to_hex(t["dct"].reshape(-1), 16))
    w("norm.hex", "".join(f"{int(o) & 0xffffffff:08x}{int(s):02x}\n" for o, s in zip(off, sh)))
    # weights: 64-bit words, lane l in bits [8l+7:8l]; addr = base + group*n_in + i
    words, bases, bias = [], [], []
    for (Wq, bq), (n_in, n_out) in zip(zip(q["W"], q["b"]), vm.NN_LAYERS):
        bases.append(len(words))
        for g in range(n_out // vm.LANES):
            for i in range(n_in):
                v = 0
                for l in range(vm.LANES):
                    v |= (int(Wq[g * vm.LANES + l, i]) & 0xff) << (8 * l)
                words.append(v)
        bias.extend(bq.tolist())
    w("weights.hex", "".join(f"{v:016x}\n" for v in words))
    w("bias.hex", to_hex(bias, 32))
    cfg = {"bases": bases, "shifts": q["sh"], "n_words": len(words), "n_bias": len(bias),
           "norm_off": off.tolist(), "norm_sh": sh.tolist(), "int8_test_acc": float(acc_q)}
    w("model_cfg.json", json.dumps(cfg, indent=2))
    # SystemVerilog include consumed by rtl/nn_engine.sv (regenerated on every retrain)
    w("nn_cfg.svh", "\n".join([
        "// AUTO-GENERATED by model/train.py -- do not edit",
        f"localparam int L0_WBASE = {bases[0]}, L1_WBASE = {bases[1]}, L2_WBASE = {bases[2]};",
        f"localparam int L0_SHIFT = {q['sh'][0]}, L1_SHIFT = {q['sh'][1]};",
        f"localparam int N_WEIGHT_WORDS = {len(words)}, N_BIAS = {len(bias)};", ""]))

    # test vectors: one clip per digit from the test set (+ the golden results)
    vec_dir = os.path.join(out, "vectors")
    os.makedirs(vec_dir, exist_ok=True)
    test_idx = np.where(is_test)[0]
    chosen = [test_idx[np.where(y[test_idx] == c)[0][0]] for c in range(vm.N_CLASSES)]
    manifest = []
    for k, i in enumerate(chosen):
        logits, cls = vm.nn_forward(feat[i], q)
        w(f"vectors/clip{k}_pcm.hex", to_hex(pcm[i], 16))
        w(f"vectors/clip{k}_feat.hex", to_hex(feat[i], 8))
        w(f"vectors/clip{k}_logits.hex", to_hex(logits, 32))
        manifest.append({"clip": k, "file": os.path.basename(items[i][0]), "label": int(y[i]), "golden_class": cls})
    w("vectors/manifest.json", json.dumps(manifest, indent=2))
    w("vectors/expected.hex", to_hex([m["golden_class"] for m in manifest], 8))
    print(json.dumps(manifest))
    print("NN layer bases", bases, "words", len(words))


if __name__ == "__main__":
    main()
