#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the frames tb_board shows after +LOADSTATE with MAME's frames after the capture.

    python scripts/compare_state_frames.py debug/cischeat-state-900 [--frames 2]

The bench's frame k is rows 16..239 (256 x 224); MAME's snapshot is Cisco Heat's
visible area, rows 16..231 (256 x 216). The state is taken at MAME's frame
notifier for frame N, so the bench's first frame is MAME's N + 1 (frame1.png).
Writes debug/state/compare<k>.png: MAME, bench, differing pixels in red.
"""
import argparse
import sys
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", type=Path)
    ap.add_argument("--frames", type=int, default=2)
    a = ap.parse_args()
    out = REPO / "debug" / "state"
    rc = 0
    for k in range(a.frames):
        mame = Image.open(a.capture / f"frame{k + 1}.png").convert("RGB")
        w, h = mame.size
        px = [int(t, 16) for t in (out / f"frame{k}.hex").read_text().split()]
        if len(px) != 256 * 224:
            sys.exit(f"frame{k}.hex: {len(px)} pixels, expected {256 * 224}")
        rtl = Image.new("RGB", (w, h))
        rtl.putdata([((p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff) for p in px[:w * h]])
        diff = Image.new("RGB", (w, h))
        n = 0
        dp = []
        for m, r in zip(mame.getdata(), rtl.getdata()):
            if m != r:
                n += 1
                dp.append((255, 0, 0))
            else:
                dp.append(tuple(c // 3 for c in m))
        diff.putdata(dp)
        sheet = Image.new("RGB", (3 * w + 8, h))
        for i, im in enumerate((mame, rtl, diff)):
            sheet.paste(im, (i * (w + 4), 0))
        sheet.save(out / f"compare{k}.png")
        print(f"frame {k} (MAME frame{k + 1}.png): {n} of {w * h} pixels differ -> {out / f'compare{k}.png'}")
        rc |= n != 0
    return rc


if __name__ == "__main__":
    sys.exit(main())
