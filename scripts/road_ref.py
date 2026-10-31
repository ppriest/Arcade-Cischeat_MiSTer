#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write jaleco_road_line bench cases from the software model.

    python scripts/road_ref.py               # every case into debug/road_tb/
    bash scripts/run_sim.sh road_tb          # reads debug/road_tb/cases.txt

debug/road_tb/gfx.hex is the road0 region, shared by every case. Each case
directory holds list.hex (1,024 words) and expect.hex: 256 lines x 256 pixels
of {priority[2:0], color[5:0], pen[3:0]}. Pixels come from render_model's
draw_road run over all 256 rows, priority window 0..7, opaque, colour base 0,
so a pixel is color * 16 + pen exactly as the model draws it.

Capture cases are both road layers of each MAME capture. Synthetic cases are
random line records: every fine scroll, wrap point and colour bit.
"""
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_model as rm  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "debug" / "road_tb"
CAPTURES = ("cischeat-phase1_play", "cischeat-phase1_attract",
            "cischeat-phase1_play_later", "cischeat-phase1_play_later2")


def expect(roadram, tile_get):
    bitmap = np.zeros((256, 256), dtype=np.uint16)
    top, rows = rm.VISIBLE_TOP, rm.VISIBLE_ROWS
    rm.VISIBLE_TOP, rm.VISIBLE_ROWS = 0, 256
    try:
        rm.draw_road(bitmap, roadram, tile_get, 0, 7, False, 0, "all", {})
    finally:
        rm.VISIBLE_TOP, rm.VISIBLE_ROWS = top, rows
    pri = (np.asarray(roadram[2:1024:4], dtype=np.uint16) >> 8) & 7
    return bitmap | (pri[:, None] << 10)


def write_case(name, roadram, tile_get):
    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    roadram = np.asarray(roadram[:1024], dtype=np.uint16)
    (folder / "list.hex").write_text("".join(f"{int(v):04x}\n" for v in roadram))
    out = expect(roadram, tile_get)
    (folder / "expect.hex").write_text("".join(f"{int(v):04x}\n" for v in out.ravel()))
    print(f"{name}: written")


def main():
    path = REPO / "debug" / "rom_regions" / "cischeat_road0.bin"
    if not path.is_file():
        sys.exit("run scripts/build_region.py cischeat road0")
    gfx = path.read_bytes()
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "gfx.hex").write_text("".join(f"{b:02x}\n" for b in gfx))
    (OUT / "mask.txt").write_text(f"{len(gfx) // 32 - 1:04x}\n")
    tile_get = rm.make_tile_getter(gfx, 64, 1, low_nibble_first=True)
    names = []
    for cap in CAPTURES:
        c = rm.Capture(cap)
        for n in range(2):
            name = f"{cap.split('-', 1)[1]}_r{n}"
            write_case(name, c.roads[n], tile_get)
            names.append(name)
    rnd = random.Random(2)
    for k in range(2):
        roadram = [rnd.randrange(0x10000) for _ in range(1024)]
        write_case(f"rand_{k}", roadram, tile_get)
        names.append(f"rand_{k}")
    (OUT / "cases.txt").write_text("".join(f"{n}\n" for n in names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
