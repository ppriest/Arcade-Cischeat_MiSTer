#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write sim/zoomroad_tb cases: jaleco_zoomroad_line's expected lines for road line
lists dumped from MAME, with the core's one-accumulator mapping (docs/HACKS.md).

    python scripts/zoomroad_ref.py <dump.txt> <set>   # dump: R<n> <line> w0 w1 w2 w3
    bash scripts/run_verilator.sh zoomroad_tb

Pixel x >= xstart = 1024 - (w0 mod 2048) - z shows source floor((x - xstart) * 512 / z)
while that is below 1024, z = (w1 & 0x3ff) + 1; tile (w3 << 4) + source / 64, pen at
source mod 64, low nibble first. Output word per pixel: {pri, covered, color, pen}.
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "debug" / "zoomroad_tb"


def line(w, gfx, mask):
    xs, xz, attr, code = w
    z = (xz & 0x3ff) + 1
    xstart = 1024 - (xs & 0x7ff) - z
    pri, color = (xs >> 12) & 7, (attr >> 8) & 0x3f
    out = []
    for x in range(256):
        s = (x - xstart) * 512 // z if x >= xstart else 1024
        if s >= 1024:
            out.append(pri << 11)
            continue
        tile = (((code & 0xfff) << 4) + (s >> 6)) & mask
        b = gfx[tile * 32 + (s & 63) // 2]
        pen = b & 15 if s % 2 == 0 else b >> 4
        out.append(pri << 11 | 1 << 10 | color << 4 | pen)
    return out


def main():
    dump, game = Path(sys.argv[1]), sys.argv[2]
    lists = {0: {}, 1: {}}
    for ln in dump.read_text().splitlines():
        t = ln.split()
        if t and t[0] in ("R0", "R1"):
            lists[int(t[0][1])][int(t[1])] = [int(v, 16) for v in t[2:]]
    OUT.mkdir(parents=True, exist_ok=True)
    names = []
    for r in (0, 1):
        gfx = (REPO / "debug" / "rom_regions" / f"{game}_road{r}.bin").read_bytes()
        mask = len(gfx) // 32 - 1
        name = f"{game}_road{r}"
        d = OUT / name
        d.mkdir(exist_ok=True)
        (d / "list.hex").write_text("".join(f"{v:04x}\n" for y in range(256) for v in lists[r][y]))
        (d / "expect.hex").write_text("".join(f"{p:04x}\n" for y in range(256)
                                              for p in line(lists[r][y], gfx, mask)))
        (d / "mask.txt").write_text(f"{mask:04x}\n")
        (d / "gfx.hex").write_text("".join(f"{b:02x}\n" for b in gfx))
        names.append(name)
    (OUT / "cases.txt").write_text("".join(n + "\n" for n in names))
    print(f"{len(names)} cases -> {OUT}")


if __name__ == "__main__":
    main()
