#!/usr/bin/env python3
"""Inspect / convert OV5647 BG10 frames captured from the Tegra VI.

The VI stores each 10-bit sample in a 16-bit little-endian word. On R35 the
value is scaled to 16 bits (upstream README); the placement is detected from
the data, not assumed:
  lsb    value in bits [9:0]
  msb    value in bits [15:6], low 6 bits zero
  msbrep value in bits [15:6], low 6 bits = copy of the top 6 bits

usage:
  bayer_tool.py info   FILE --w 1920 --h 1080 [--stride N]   # per-frame stats
  bayer_tool.py png    FILE OUT.png [--w..] [--frame -1] [--wb]
      half-resolution BGGR debayer (no interpolation), optional gray-world WB
Needs numpy. PNG via cv2 if present, else a .ppm next to OUT.
"""
import argparse, os, sys
import numpy as np


def load(path, w, h, stride):
    stride = stride or w * 2
    fsz = stride * h
    data = np.fromfile(path, dtype=np.uint8)
    n = data.size // fsz
    if n == 0:
        sys.exit(f"{path}: {data.size} bytes < one frame ({fsz}); check --w/--h/--stride")
    if data.size % fsz:
        print(f"warning: {data.size % fsz} trailing bytes ignored (check --stride)", file=sys.stderr)
    fr = data[: n * fsz].reshape(n, h, stride)[:, :, : w * 2]
    return np.ascontiguousarray(fr).view("<u2").reshape(n, h, w)


def to10(raw):
    v = raw.astype(np.uint32)
    if v.max() <= 1023:
        return "lsb", raw & 0x3FF
    lo = v & 0x3F
    if np.all(lo == 0):
        return "msb", raw >> 6
    if np.mean(lo == (v >> 10)) > 0.999:
        return "msbrep", raw >> 6
    return "unknown(assumed msb)", raw >> 6


def planes(img):  # BGGR
    return {"B": img[0::2, 0::2], "Gb": img[0::2, 1::2],
            "Gr": img[1::2, 0::2], "R": img[1::2, 1::2]}


def save_rgb(rgb8, out):
    try:
        import cv2
        cv2.imwrite(out, rgb8[:, :, ::-1])
        return out
    except ImportError:
        out = os.path.splitext(out)[0] + ".ppm"
        h, w, _ = rgb8.shape
        with open(out, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (w, h))
            f.write(rgb8.tobytes())
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["info", "png"])
    ap.add_argument("file")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--w", type=int, default=1920)
    ap.add_argument("--h", type=int, default=1080)
    ap.add_argument("--stride", type=int, default=0)
    ap.add_argument("--frame", type=int, default=-1)
    ap.add_argument("--wb", action="store_true")
    a = ap.parse_args()
    raw = load(a.file, a.w, a.h, a.stride)
    pack, img = to10(raw)

    if a.cmd == "info":
        print(f"frames={img.shape[0]} size={a.w}x{a.h} packing={pack}")
        prev = None
        for i, f in enumerate(img):
            p = planes(f)
            ch = " ".join(f"{k}={v.mean():.1f}" for k, v in p.items())
            dup = " DUPLICATE" if prev is not None and np.array_equal(prev, f) else ""
            sat = (f >= 1020).mean() * 100
            print(f"  frame {i}: mean={f.mean():.1f} std={f.std():.1f} min={f.min()} max={f.max()} "
                  f"sat={sat:.2f}% {ch}{dup}")
            prev = f
        last = img[-1]
        verdict = "BLACK" if last.max() < 40 else ("FLAT" if last.std() < 2 else "CONTENT")
        print(f"last frame: {verdict}")
        return

    if not a.out:
        sys.exit("png needs OUT")
    p = planes(img[a.frame].astype(np.float32))
    g = (p["Gb"] + p["Gr"]) / 2
    rgb = np.dstack([p["R"], g, p["B"]])
    rgb = np.clip(rgb - 16, 0, None)            # rough black level (10-bit)
    if a.wb:
        m = rgb.reshape(-1, 3).mean(0)
        rgb = rgb * (m[1] / np.maximum(m, 1e-3))
    hi = max(np.percentile(rgb, 99.5), 1)
    rgb8 = (np.clip(rgb / hi, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)
    print(f"packing={pack} wrote {save_rgb(rgb8, a.out)} ({rgb8.shape[1]}x{rgb8.shape[0]})")


if __name__ == "__main__":
    main()
