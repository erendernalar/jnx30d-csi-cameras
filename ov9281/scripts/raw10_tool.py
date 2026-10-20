#!/usr/bin/env python3
"""Unpack / inspect OV9281 RAW10 frames captured from the Tegra VI (T_R16).

The VI writes each 10-bit sample into a 16-bit little-endian word. The bit
placement is detected from the data instead of assumed:
  lsb   : value in bits [9:0]                      (v <= 1023)
  msb   : value in bits [15:6], low 6 bits zero
  msbrep: value in bits [15:6], low 6 bits = copy of the top 6 bits
The data is monochrome even though V4L2 labels it BG10 (R35 has no Y10 path),
so NO demosaicing is applied.

usage:
  raw10_tool.py info   FILE --w 1280 --h 800 [--stride 2560]
  raw10_tool.py png    FILE OUT.png [--frame -1] [--w..] [--stretch]
  raw10_tool.py shear  FILE [--frame -1]       # use with test pattern on
  raw10_tool.py series FILE                     # per-frame mean, dup/blank check
Needs numpy; PNG via cv2 if present, else writes .pgm next to OUT.
"""
import argparse, os, sys
import numpy as np


def load(path, w, h, stride):
    stride = stride or w * 2
    fsz = stride * h
    data = np.fromfile(path, dtype=np.uint8)
    n = data.size // fsz
    if n == 0:
        sys.exit(f"{path}: {data.size} bytes < one frame ({fsz})")
    if data.size % fsz:
        print(f"warning: {data.size % fsz} trailing bytes ignored "
              f"(check --stride / sizeimage)", file=sys.stderr)
    fr = data[: n * fsz].reshape(n, h, stride)[:, :, : w * 2]
    return np.ascontiguousarray(fr).view("<u2").reshape(n, h, w)


def detect(raw):
    v = raw.astype(np.uint32)
    if v.max() <= 1023:
        return "lsb", raw & 0x3FF
    lo = v & 0x3F
    if np.all(lo == 0):
        return "msb", (raw >> 6)
    if np.mean(lo == (v >> 10)) > 0.999:
        return "msbrep", (raw >> 6)
    return "unknown", (raw >> 6)


def to8(img10, stretch):
    f = img10.astype(np.float32)
    if stretch:
        lo, hi = np.percentile(f, [0.5, 99.5])
        f = np.clip((f - lo) / max(hi - lo, 1), 0, 1)
    else:
        f = f / 1023.0
    return (np.clip(f, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)


def save(img8, out):
    try:
        import cv2
        cv2.imwrite(out, img8)
        return out
    except ImportError:
        out = os.path.splitext(out)[0] + ".pgm"
        h, w = img8.shape
        with open(out, "wb") as f:
            f.write(b"P5\n%d %d\n255\n" % (w, h))
            f.write(img8.tobytes())
        return out


def shear(img, maxs=24):
    """Horizontal offset of each row vs. a reference row (SAD search).
    For the vertical-bar test pattern every row must give 0."""
    g = np.abs(np.diff(img.astype(np.float32), axis=1))
    h = g.shape[0]
    ref = g[h // 2]
    shifts = []
    for r in range(4, h - 4, max(1, h // 50)):
        row = g[r]
        best = min(range(-maxs, maxs + 1),
                   key=lambda s: np.abs(np.roll(row, s)[maxs:-maxs] - ref[maxs:-maxs]).mean())
        shifts.append((r, best))
    return shifts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["info", "png", "shear", "series"])
    ap.add_argument("file")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--w", type=int, default=1280)
    ap.add_argument("--h", type=int, default=800)
    ap.add_argument("--stride", type=int, default=0)
    ap.add_argument("--frame", type=int, default=-1)
    ap.add_argument("--stretch", action="store_true")
    a = ap.parse_args()

    frames = load(a.file, a.w, a.h, a.stride)
    mode, img = detect(frames[a.frame])
    if a.cmd == "info":
        print(f"frames={len(frames)} size={a.w}x{a.h} packing={mode}")
        print(f"10-bit: min={img.min()} max={img.max()} mean={img.mean():.1f} "
              f"std={img.std():.1f} sat%={(img >= 1020).mean()*100:.2f}")
        rows, cols = img.mean(1), img.mean(0)
        print(f"row-mean range {rows.min():.1f}..{rows.max():.1f}  "
              f"col-mean range {cols.min():.1f}..{cols.max():.1f}")
        top = frames[a.frame][:4]
        print("first 4 rows mean (raw16):", [int(x) for x in top.mean(1)])
    elif a.cmd == "png":
        out = save(to8(img, a.stretch), a.out or "frame.png")
        print(f"wrote {out} (packing={mode}, mean10={img.mean():.1f})")
    elif a.cmd == "shear":
        s = shear(img)
        vals = [b for _, b in s]
        print(f"packing={mode} row-offset vs centre row: min={min(vals)} max={max(vals)}")
        print("rows:", " ".join(f"{r}:{b}" for r, b in s[:: max(1, len(s) // 12)]))
        print("SHEAR: NONE" if max(map(abs, vals)) == 0 else "SHEAR/OFFSET DETECTED")
    elif a.cmd == "series":
        means = [detect(f)[1].mean() for f in frames]
        dup = sum(np.array_equal(frames[i], frames[i - 1]) for i in range(1, len(frames)))
        blank = sum(m < 1.0 for m in means)
        print(f"frames={len(frames)} mean10 per frame: " +
              " ".join(f"{m:.0f}" for m in means))
        print(f"identical-consecutive={dup} blank={blank}")


if __name__ == "__main__":
    main()
