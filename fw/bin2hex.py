"""Convert a flat little-endian binary into a $readmemh word file, padded to N words."""
import sys

src, dst, nwords = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(src, "rb").read()
data += b"\0" * (-len(data) % 4)
words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
if len(words) > nwords:
    sys.exit(f"firmware too big: {len(words)} words > {nwords}")
words += [0] * (nwords - len(words))
open(dst, "w").write("".join(f"{w:08x}\n" for w in words))
