#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the frames tb_board shows from reset with MAME's frames from power-on.

    bash scripts/run_verilator.sh board_tb +DUMPFRAMES=320
    python scripts/mame_frames.py cischeat --first 1 --last 340
    python scripts/compare_reset_frames.py [--window 8] [--sheet 158,173,296]
    python scripts/compare_reset_frames.py --set bigrun --bench debug/board_bigrun

The bench's frame k is rows 16..239 (256 x 224) of its k-th displayed frame
after reset; MAME's frame<n>.png is its visible area from row 16 at frame n
(256 x 216 on Cisco Heat, 256 x 224 on Big Run); the bench frame is cropped to it. The two need not be numbered alike, so each bench frame is
matched to the MAME frame within +-window of k + offset that differs least,
and the offsets found are reported: one steady offset with few differing
pixels means the boot runs in step with MAME's. --sheet writes
debug/board/compare<k>.png (MAME, bench, differences in red) for those bench
frames.
"""
import argparse
import sys
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
BENCH = REPO / "debug" / "board"
MAME = REPO / "debug" / "cischeat-frames"
W, H = 256, 216     # H is set from the first MAME frame


def bench_frame(k):
    px = np.array([int(t, 16) for t in (BENCH / f"frame{k}.hex").read_text().split()], dtype=np.uint32)
    if len(px) != 256 * 224:
        return None
    px = px[:W * H].reshape(H, W)
    return np.stack(((px >> 16) & 0xff, (px >> 8) & 0xff, px & 0xff), axis=2).astype(np.uint8)


def mame_frame(n, cache={}):
    if n not in cache:
        p = MAME / f"frame{n}.png"
        cache[n] = np.asarray(Image.open(p).convert("RGB")) if p.exists() else None
    return cache[n]


def main():
    global BENCH, MAME, H
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--window", type=int, default=8)
    ap.add_argument("--sheet", default="")
    ap.add_argument("--set", default="cischeat")
    ap.add_argument("--bench", type=Path, default=REPO / "debug" / "board")
    a = ap.parse_args()
    BENCH, MAME = a.bench, REPO / "debug" / f"{a.set}-frames"
    first = next(iter(sorted(MAME.glob("frame*.png"))), None)
    if first is not None:
        H = Image.open(first).height
    ks = sorted(int(p.stem[5:]) for p in BENCH.glob("frame*.hex"))
    offsets, rows = Counter(), []
    for k in ks:
        b = bench_frame(k)
        if b is None:
            continue
        best = None
        for n in range(k - a.window, k + a.window + 1):
            m = mame_frame(n)
            if m is None:
                continue
            d = int((m != b).any(axis=2).sum())
            if best is None or d < best[1] or (d == best[1] and abs(n - k) < abs(best[0] - k)):
                best = (n, d)
        if best is None:
            continue
        rows.append((k, *best))
        offsets[best[0] - k] += 1
    for k, n, d in rows:
        if k % 10 == 0 or d:
            print(f"bench {k:4d}  MAME {n:4d}  offset {n - k:+d}  {d:6d} of {W * H} pixels differ")
    print("offsets:", ", ".join(f"{o:+d} x{c}" for o, c in sorted(offsets.items())))
    print(f"{sum(1 for r in rows if r[2] == 0)} of {len(rows)} bench frames match a MAME frame exactly")
    for k in (int(t) for t in a.sheet.split(",") if t):
        n = next((r[1] for r in rows if r[0] == k), None)
        b, m = bench_frame(k), mame_frame(n) if n is not None else None
        if b is None or m is None:
            print(f"no sheet for bench frame {k}")
            continue
        diff = np.where((m != b).any(axis=2)[..., None], np.array([255, 0, 0], np.uint8), m // 3)
        sheet = np.zeros((H, 3 * W + 8, 3), np.uint8)
        for i, im in enumerate((m, b, diff)):
            sheet[:, i * (W + 4):i * (W + 4) + W] = im
        Image.fromarray(sheet).save(BENCH / f"compare{k}.png")
        print(f"bench {k} vs MAME {n} -> {BENCH / f'compare{k}.png'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
