"""
Export golden vectors for the PDM path and measure recognition accuracy through it.

For every test clip: PCM -> analog sigma-delta model -> 1-bit PDM -> bit-exact
decimator -> 16 kHz PCM -> MFCC -> NN. The RTL testbenches regenerate the same
bitstream with the SystemVerilog RNM model, so only the decimator output and the
downstream features / logits need to be stored.

usage: python3 pdm_export.py <fsdd recordings dir>
"""
import json
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import voxcore_model as vm
import pdm_model as pm
from train import load_clip, list_fsdd, to_hex

DATA = os.path.join(os.path.dirname(__file__), "..", "data")
VEC = os.path.join(DATA, "vectors")


def load_hex(name, bits):
    v = np.array([int(l, 16) for l in open(os.path.join(DATA, name)) if l.strip()], dtype=np.int64)
    return np.where(v >= 1 << (bits - 1), v - (1 << bits), v)


def load_model():
    cfg = json.load(open(os.path.join(DATA, "model_cfg.json")))
    t = vm.build_tables()
    t["norm_off"] = np.array(cfg["norm_off"]); t["norm_sh"] = np.array(cfg["norm_sh"])
    words = [int(l, 16) for l in open(os.path.join(DATA, "weights.hex")) if l.strip()]
    bias = load_hex("bias.hex", 32)
    q = {"W": [], "b": [], "sh": cfg["shifts"]}
    bo = 0
    for base, (n_in, n_out) in zip(cfg["bases"], vm.NN_LAYERS):
        W = np.zeros((n_out, n_in), dtype=np.int64)
        for g in range(n_out // vm.LANES):
            for i in range(n_in):
                w = words[base + g * n_in + i]
                for l in range(vm.LANES):
                    b = (w >> (8 * l)) & 0xFF
                    W[g * vm.LANES + l, i] = b - 256 if b > 127 else b
        q["W"].append(W); q["b"].append(bias[bo:bo + n_out]); bo += n_out
    return t, q


def main():
    t, q = load_model()
    items = list_fsdd(sys.argv[1])
    manifest = json.load(open(os.path.join(VEC, "manifest.json")))
    # FIR coefficients for the RTL ROM
    open(os.path.join(DATA, "pdm_fir.hex"), "w").write(to_hex(pm.FIR_COEF, 16))

    # 1) golden vectors for the 10 RTL test clips
    exp = []
    for m in manifest:
        pcm = load_clip(os.path.join(sys.argv[1], m["file"]))
        assert np.array_equal(pcm, load_hex(f"vectors/clip{m['clip']}_pcm.hex", 16)), "clip mismatch"
        pdm_pcm, _ = pm.pdm_chain(pcm)
        feat = vm.mfcc_fixed(pdm_pcm, t)
        logits, cls = vm.nn_forward(feat, q)
        k = m["clip"]
        open(os.path.join(VEC, f"clip{k}_pdm_pcm.hex"), "w").write(to_hex(pdm_pcm, 16))
        open(os.path.join(VEC, f"clip{k}_pdm_feat.hex"), "w").write(to_hex(feat, 8))
        open(os.path.join(VEC, f"clip{k}_pdm_logits.hex"), "w").write(to_hex(logits, 32))
        exp.append(cls)
        print(f"clip{k}: label {m['label']}  I2S class {m['golden_class']}  PDM class {cls}")
    open(os.path.join(VEC, "expected_pdm.hex"), "w").write(to_hex(exp, 8))

    # 2) block-level sine vector: 1 kHz, -6 dBFS, 4096 PCM samples
    n = np.arange(4096 + 8)
    sine = np.round(16384 * np.sin(2 * np.pi * 1000 * n / 16000)).astype(np.int64)
    out, _ = pm.pdm_chain(sine, n_out_samples=4096)
    open(os.path.join(VEC, "sine_pcm.hex"), "w").write(to_hex(sine, 16))
    open(os.path.join(VEC, "sine_pdm_out.hex"), "w").write(to_hex(out, 16))
    snr = pm.snr_enob(out[256:4096], f0=1000.0, band=(20, 6400))[0]
    print(f"sine via PCM interpolation: SNR {snr:.1f} dB")

    # 3) recognition accuracy through the PDM path, whole test set
    test = [(p, c) for p, c, te in items if te]
    hit_pdm = hit_i2s = 0
    for p, c in test:
        pcm = load_clip(p)
        pdm_pcm, _ = pm.pdm_chain(pcm)
        hit_pdm += vm.nn_forward(vm.mfcc_fixed(pdm_pcm, t), q)[1] == c
        hit_i2s += vm.nn_forward(vm.mfcc_fixed(pcm, t), q)[1] == c
    res = {"test_clips": len(test), "acc_i2s": hit_i2s / len(test), "acc_pdm": hit_pdm / len(test),
           "sine_snr_db": round(snr, 1)}
    json.dump(res, open(os.path.join(DATA, "pdm_cfg.json"), "w"), indent=2)
    print(json.dumps(res))


if __name__ == "__main__":
    main()
