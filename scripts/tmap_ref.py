#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write ms1_tmap_line bench cases from the software model.

    python scripts/tmap_ref.py                 # every case into debug/tmap_tb/
    python scripts/tmap_ref.py --list
    bash scripts/run_sim.sh ms1_tmap_tb      # reads debug/tmap_tb/cases.txt

Each case directory holds vram.hex (8,192 words), gfx.hex (region bytes),
regs.txt (scroll_x scroll_y ctrl color5 code_mask, hex) and expect.hex: 256
lines x 256 pixels of {color, pen}, from render_model's map_dimensions,
tilemap_entry and tile getter -- the code that is compared with MAME.

Capture cases use a MAME capture's scroll RAM and registers. Synthetic cases
fill the scroll RAM with random words and cover all eight page arrangements,
which the captures do not.
"""
import argparse
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_model as rm  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "debug" / "tmap_tb"
CAPTURES = ("cischeat-phase1_play", "cischeat-phase1_attract")


def region(name):
    path = REPO / "debug" / "rom_regions" / f"cischeat_{name}.bin"
    if not path.is_file():
        sys.exit(f"run scripts/build_region.py cischeat {name}")
    return path.read_bytes()


def expect(vram, regs, gfx, color5):
    sx, sy, flag = regs
    cols, rows, large = rm.map_dimensions(flag)
    tile_get = rm.make_tile_getter(gfx, 8, 8)
    out = np.zeros((256, 256), dtype=np.uint16)
    for y in range(256):
        source_y = (y + sy) % (rows * 8)
        row, py = source_y >> 3, source_y & 7
        for x in range(256):
            source_x = (x + sx) % (cols * 8)
            col = source_x >> 3
            ram_index, sub = rm.tilemap_entry(col, row, cols, large)
            word = int(vram[ram_index])
            code = (word & 0x0fff) * (4 if large else 1) + sub
            pen = int(tile_get(code)[py, source_x & 7])
            color = (word >> 11) & 0x1f if color5 else (word >> 12) & 0x0f
            out[y, x] = (color << 4) | pen
    return out


def write_case(name, vram, regs, gfx, color5):
    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    vram = np.resize(np.asarray(vram, dtype=np.uint16), 8192)
    (folder / "vram.hex").write_text("".join(f"{int(v):04x}\n" for v in vram))
    (folder / "gfx.hex").write_text("".join(f"{b:02x}\n" for b in gfx))
    code_mask = len(gfx) // 32 - 1
    sx, sy, flag = regs
    (folder / "regs.txt").write_text(f"{sx:04x} {sy:04x} {flag:04x} {int(color5)} {code_mask:04x}\n")
    out = expect(vram, regs, gfx, color5)
    (folder / "expect.hex").write_text("".join(f"{int(v):03x}\n" for v in out.ravel()))
    print(f"{name}: regs {sx:04x} {sy:04x} {flag:04x} color5={int(color5)} mask={code_mask:04x}")


def cases():
    for cap in CAPTURES:
        c = rm.Capture(cap)
        for n in range(3):
            yield f"{cap.split('-', 1)[1]}_l{n}", c.vram[n], c.scroll[n], region(f"scroll{n}"), True
    rnd = random.Random(1)
    gfx0, gfx2 = region("scroll0"), region("scroll2")
    for flag in (0x00, 0x01, 0x02, 0x03, 0x10, 0x11, 0x12, 0x13):
        vram = [rnd.randrange(0x10000) for _ in range(8192)]
        regs = (rnd.randrange(0x10000), rnd.randrange(0x10000), flag)
        gfx = gfx2 if flag & 1 else gfx0
        yield f"rand_{flag:02x}", vram, regs, gfx, bool(flag & 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="print case names only")
    args = parser.parse_args()
    names = []
    for name, vram, regs, gfx, color5 in cases():
        names.append(name)
        if args.list:
            print(name)
        else:
            write_case(name, vram, regs, gfx, color5)
    if not args.list:
        (OUT / "cases.txt").write_text("".join(f"{n}\n" for n in names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
