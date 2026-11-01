"""Frame-by-frame diff of two MAME -aviwrite recordings of the same run.

    python scripts/mame/avidiff.py before.avi after.avi out_dir [--samples N]

Writes out_dir/summary.txt (frame counts, first differing frame, differing frames and pixels)
and out_dir/frames.csv (differing pixels per frame). For the first differing frame and the N
frames with the most differing pixels it saves before | after | mask as PNG.
"""
import argparse
import csv
import os

import av
import numpy as np
from PIL import Image


def frames(path):
    with av.open(path) as c:
        for f in c.decode(video=0):
            yield f.to_ndarray(format='rgb24')


def sheet(a, b):
    mask = (a != b).any(2)
    m = np.zeros_like(a)
    m[mask] = (255, 0, 255)
    gap = np.full((a.shape[0], 4, 3), 64, np.uint8)
    return Image.fromarray(np.hstack([a, gap, b, gap, m]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('before')
    ap.add_argument('after')
    ap.add_argument('out')
    ap.add_argument('--samples', type=int, default=4)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    counts = []
    first = None
    worst = []      # (pixels, frame, before, after), at most args.samples
    na = nb = 0
    fa, fb = frames(args.before), frames(args.after)
    while True:
        a = next(fa, None)
        b = next(fb, None)
        na += a is not None
        nb += b is not None
        if a is None or b is None:
            break
        n = 0 if a.shape != b.shape else int((a != b).any(2).sum())
        if a.shape != b.shape:
            n = a.shape[0] * a.shape[1]
        counts.append(n)
        if n and first is None:
            first = len(counts) - 1
            if a.shape == b.shape:
                sheet(a, b).save(os.path.join(args.out, f'first_{first:06d}.png'))
        if n and a.shape == b.shape and (len(worst) < args.samples or n > worst[-1][0]):
            worst.append((n, len(counts) - 1, a, b))
            worst.sort(key=lambda w: -w[0])
            del worst[args.samples:]
    for _ in fa:
        na += 1
    for _ in fb:
        nb += 1

    for n, i, a, b in worst:
        sheet(a, b).save(os.path.join(args.out, f'worst_{i:06d}.png'))
    with open(os.path.join(args.out, 'frames.csv'), 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['frame', 'pixels'])
        w.writerows((i, n) for i, n in enumerate(counts) if n)
    diff = [n for n in counts if n]
    lines = [
        f'before {args.before}: {na} frames',
        f'after  {args.after}: {nb} frames',
        f'compared {len(counts)} frames, {len(diff)} differ, {sum(diff)} pixels',
        f'first differing frame: {first}',
        'worst: ' + ', '.join(f'{i} ({n} px)' for n, i, _, _ in worst),
    ]
    open(os.path.join(args.out, 'summary.txt'), 'w').write('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
