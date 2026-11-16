"""AES-128 encryption reference model for the VoxCore AES peripheral (aes_apb).

Written from FIPS-197 with nothing imported, so the model and the RTL share no code.
The S-box is computed from the GF(2^8) inverse and the affine transform, not typed in.

    python aes_model.py selftest          check the model against FIPS-197 / NIST known answers
    python aes_model.py sbox  <out.svh>   write the S-box case table included by the RTL
    python aes_model.py vectors <out.hex> [n] [seed]
                                          write test vectors: one line per test,
                                          96 hex digits = key(32) plaintext(32) ciphertext(32)
"""
import random
import sys


def _xtime(a):
    a <<= 1
    return (a ^ 0x11B) & 0xFF if a & 0x100 else a


def _gmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xtime(a)
        b >>= 1
    return r


def _make_sbox():
    box = []
    for x in range(256):
        inv = 0
        if x:
            for y in range(1, 256):
                if _gmul(x, y) == 1:
                    inv = y
                    break
        s = inv
        for sh in (1, 2, 3, 4):
            s ^= ((inv << sh) | (inv >> (8 - sh))) & 0xFF
        box.append(s ^ 0x63)
    return box


SBOX = _make_sbox()
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


def expand_key(key):
    """key: 16 bytes -> list of 11 round keys (16 bytes each)."""
    w = [list(key[4 * i:4 * i + 4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [SBOX[b] for b in t]
            t[0] ^= RCON[i // 4 - 1]
        w.append([a ^ b for a, b in zip(w[i - 4], t)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(11)]


def _sub_shift(s):
    # state byte i sits at row i % 4, column i // 4 (FIPS-197 section 3.4)
    return [SBOX[s[(i % 4) + 4 * (((i // 4) + (i % 4)) % 4)]] for i in range(16)]


def _mix(s):
    o = []
    for c in range(4):
        a = s[4 * c:4 * c + 4]
        o += [
            _gmul(a[0], 2) ^ _gmul(a[1], 3) ^ a[2] ^ a[3],
            a[0] ^ _gmul(a[1], 2) ^ _gmul(a[2], 3) ^ a[3],
            a[0] ^ a[1] ^ _gmul(a[2], 2) ^ _gmul(a[3], 3),
            _gmul(a[0], 3) ^ a[1] ^ a[2] ^ _gmul(a[3], 2),
        ]
    return o


def encrypt(key, pt, trace=None):
    """key, pt: 16 bytes each -> 16-byte ciphertext. trace (a list) collects the state after each round."""
    rk = expand_key(key)
    s = [a ^ b for a, b in zip(pt, rk[0])]
    if trace is not None:
        trace.append(bytes(s))
    for r in range(1, 11):
        s = _sub_shift(s)
        if r < 10:
            s = _mix(s)
        s = [a ^ b for a, b in zip(s, rk[r])]
        if trace is not None:
            trace.append(bytes(s))
    return bytes(s)


# (key, plaintext, ciphertext, source)
KAT = [
    ("2b7e151628aed2a6abf7158809cf4f3c", "3243f6a8885a308d313198a2e0370734",
     "3925841d02dc09fbdc118597196a0b32", "FIPS-197 Appendix B"),
    ("000102030405060708090a0b0c0d0e0f", "00112233445566778899aabbccddeeff",
     "69c4e0d86a7b0430d8cdb78070b4c55a", "FIPS-197 Appendix C.1"),
    ("00000000000000000000000000000000", "00000000000000000000000000000000",
     "66e94bd4ef8a2c3b884cfa59ca342b2e", "all-zero key and block"),
    ("2b7e151628aed2a6abf7158809cf4f3c", "6bc1bee22e409f96e93d7e117393172a",
     "3ad77bb40d7a3660a89ecaf32466ef97", "NIST SP 800-38A F.1.1 block 1"),
    ("2b7e151628aed2a6abf7158809cf4f3c", "ae2d8a571e03ac9c9eb76fac45af8e51",
     "f5d3d58503b9699de785895a96fdbaaf", "NIST SP 800-38A F.1.1 block 2"),
    ("2b7e151628aed2a6abf7158809cf4f3c", "30c81c46a35ce411e5fbc1191a0a52ef",
     "43b1cd7f598ece23881b00e3ed030688", "NIST SP 800-38A F.1.1 block 3"),
    ("2b7e151628aed2a6abf7158809cf4f3c", "f69f2445df4f9b17ad2b417be66c3710",
     "7b0c785e27e8ad3f8223207104725dd4", "NIST SP 800-38A F.1.1 block 4"),
]

# FIPS-197 Appendix B: state at the start of rounds 1, 2 and 10, and the output
KAT_B_ROUNDS = {
    0: "193de3bea0f4e22b9ac68d2ae9f84808",
    1: "a49c7ff2689f352b6b5bea43026a5049",
    9: "eb40f21e592e38848ba113e71bc342d2",
    10: "3925841d02dc09fbdc118597196a0b32",
}


def selftest():
    ok = True
    if SBOX[0x00] != 0x63 or SBOX[0x53] != 0xED or SBOX[0xFF] != 0x16 or sorted(SBOX) != list(range(256)):
        print("S-box FAILED")
        ok = False
    for k, p, c, src in KAT:
        got = encrypt(bytes.fromhex(k), bytes.fromhex(p)).hex()
        good = got == c
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} {src}: {got}")
    tr = []
    encrypt(bytes.fromhex(KAT[0][0]), bytes.fromhex(KAT[0][1]), tr)
    for r, exp in KAT_B_ROUNDS.items():
        good = tr[r].hex() == exp
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} Appendix B round state {r}")
    try:  # independent cross-check, only if the package happens to be installed
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        rng = random.Random(7)
        for _ in range(2000):
            k, p = rng.randbytes(16), rng.randbytes(16)
            enc = Cipher(algorithms.AES(k), modes.ECB()).encryptor()
            if enc.update(p) + enc.finalize() != encrypt(k, p):
                ok = False
                print("FAIL cross-check", k.hex(), p.hex())
                break
        else:
            print("ok   2000 random blocks match the 'cryptography' package")
    except ImportError:
        print("note 'cryptography' package not installed, cross-check skipped")
    print("==== aes_model selftest", "PASSED" if ok else "FAILED", "====")
    return ok


def write_sbox(path):
    with open(path, "w", newline="\n") as f:
        f.write("// AES S-box (FIPS-197 figure 7). Generated by model/aes_model.py sbox; do not edit.\n")
        for i, v in enumerate(SBOX):
            f.write(f"8'h{i:02x}: aes_sbox = 8'h{v:02x};\n")


def write_vectors(path, n=1000, seed=1):
    rng = random.Random(seed)
    corner = [bytes(16), bytes([0xFF] * 16), bytes([0x55] * 16), bytes([0xAA] * 16)]
    rows = [(bytes.fromhex(k), bytes.fromhex(p)) for k, p, _, _ in KAT]
    rows += [(k, p) for k in corner for p in corner]
    for i in range(128):  # walking one in the key, then in the plaintext
        one = (1 << (127 - i)).to_bytes(16, "big")
        rows.append((one, bytes(16)) if i % 2 == 0 else (bytes(16), one))
    while len(rows) < n:
        rows.append((rng.randbytes(16), rng.randbytes(16)))
    with open(path, "w", newline="\n") as f:
        for k, p in rows:
            f.write(k.hex() + p.hex() + encrypt(k, p).hex() + "\n")
    print(f"wrote {len(rows)} vectors to {path} ({len(KAT)} known answers first)")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "selftest"
    if cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    elif cmd == "sbox":
        write_sbox(sys.argv[2])
    elif cmd == "vectors":
        write_vectors(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 1000,
                      int(sys.argv[4]) if len(sys.argv) > 4 else 1)
    else:
        sys.exit(__doc__)
