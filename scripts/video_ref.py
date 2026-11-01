#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write cischeat_video full-frame bench cases from the software model.

    python scripts/video_ref.py               # every capture into debug/video_tb/
    bash scripts/run_sim.sh video_tb          # reads debug/video_tb/cases.txt

Shared: the five graphics regions as 64-bit little-endian granules, the scroll
regions in the loader's tile-pair layout. Per case:
the capture's scroll RAMs, road line lists, sprite list, palette and scroll
registers, and the expected frame for bitmap rows 16..239 as palette index
({shadow, index}) and RGB. The expected frame is scripts/sprite_acc.py's
composite: render_model's draw order with the core's sprite accumulator.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_model as rm  # noqa: E402
import sprite_acc as sa  # noqa: E402
from tile_layout import pair_tiles  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "debug" / "video_tb"


def words(path, data, count):
    data = np.resize(np.asarray(data, dtype=np.uint16), count)
    path.write_text("".join(f"{int(v):04x}\n" for v in data))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    names = []
    for cap in sa.CAPTURES:
        c = rm.Capture(cap)
        name = cap.split("-", 1)[1]
        folder = OUT / name
        folder.mkdir(exist_ok=True)
        for n in range(3):
            words(folder / f"vram{n}.hex", c.vram[n][:8192], 8192)
        for n in range(2):
            words(folder / f"road{n}.hex", c.roads[n][:1024], 1024)
        words(folder / "sprites.hex", c.sprites[:2048], 2048)
        words(folder / "palette.hex", c.palette[:16384], 16384)
        (folder / "regs.txt").write_text("".join(f"{sx:04x} {sy:04x} {fl:04x}\n" for sx, sy, fl in c.scroll))
        tile_get = rm.make_tile_getter(c.gfx["sprites"], 16, 16)
        bufs = sa.render_lines(sa.sprites(c.sprites), tile_get, len(c.gfx["sprites"]) // 128 - 1)
        bm = sa.composite_indexed(c, bufs)[16:240]
        rgb = rm.palette_rgb(c.palette)[bm]
        (folder / "expect_idx.hex").write_text("".join(f"{int(v):04x}\n" for v in bm.ravel()))
        (folder / "expect_rgb.hex").write_text(
            "".join(f"{int(p[0]):02x}{int(p[1]):02x}{int(p[2]):02x}\n" for p in rgb.reshape(-1, 3)))
        names.append(name)
        print(f"{name}: written")
        gfx = c.gfx
    for region in ("scroll0", "scroll1", "scroll2", "road0", "sprites"):
        data = pair_tiles(bytes(gfx[region])) if region.startswith("scroll") else gfx[region]
        g = np.frombuffer(data, dtype="<u8")
        (OUT / f"{region}.hex").write_text("".join(f"{int(v):016x}\n" for v in g))
    (OUT / "cases.txt").write_text("".join(f"{n}\n" for n in names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
