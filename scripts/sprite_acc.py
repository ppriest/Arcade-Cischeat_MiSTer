#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bit-exact model of the core's sprite line engine, and its distance from MAME.

    python scripts/sprite_acc.py                      # compare every capture
    python scripts/sprite_acc.py --cases              # also write bench cases
    bash scripts/run_sim.sh sprite_tb                 # reads debug/sprite_tb/cases.txt

MAME (jaleco_zoomspr.cpp, render_model.draw_sprites) scales each 16x16 tile on
its own: a rounded tile width dx and a source step (16 << 16) // dx. The core
has no divider at pixel rate, so one accumulator spans the whole sprite:
destination pixel d from the sprite's left edge shows source column
floor(d * 128 / zoom), and line d from its top edge shows source row
floor(d * 128 / zoom), stepped as quotient and remainder. The sprite's top
edge is MAME's, y - ceil(ynum * zoom_y / 8); its left edge is x. A flipped
sprite mirrors the whole source image, which is what MAME's reversed tile
order plus per-tile mirror amounts to.

Output per line: three group buffers (Cisco Heat's sprite passes 7..3, 2,
1..0), each pixel {shadow, opaque, color[6:0], pen[3:0]}. An opaque pen writes
opaque/color/pen and clears shadow; pen 0 of a shadow sprite sets shadow only.
Records are drawn in ascending order, so a later record covers an earlier one.
"""
import argparse
import random
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_model as rm  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "debug" / "sprite_tb"
CAPTURES = ("cischeat-phase1_play", "cischeat-phase1_attract",
            "cischeat-phase1_play_later", "cischeat-phase1_play_later2")
# Cisco Heat: draw_sprites(15, 3), (2, 2), (1, 0); priority is attr bits 10-8
GROUP_OF_PRI = (2, 2, 1, 0, 0, 0, 0, 0)
SHADOW, OPAQUE = 1 << 12, 1 << 11


def s11(v):
    v &= 0x7ff
    return v - 0x800 if v & 0x400 else v


def sprites(ram):
    """Per-frame precompute: the records that can draw, with their geometry."""
    out = []
    for i in range(256):
        w = [int(v) for v in ram[i * 8:i * 8 + 8]]
        size, zx_w, zy_w, x_w, y_w, _, code, attr = w
        if size & 0x1000:
            continue
        zx, zy = zx_w & 0x1ff, zy_w & 0x1ff
        if zx < 8 or zy < 8:          # MAME: xdim >> 16 == 0
            continue
        xnum, ynum = (size & 0xf) + 1, ((size >> 4) & 0xf) + 1
        out.append(dict(
            zx=zx, zy=zy, xnum=xnum, ynum=ynum,
            x=s11(x_w), top=s11(y_w) - ((ynum * zy + 7) >> 3),
            flipx=bool(zx_w & 0x1000), flipy=bool(zy_w & 0x1000),
            code=code, color=attr & 0x7f, group=GROUP_OF_PRI[(attr >> 8) & 7],
            shadow=bool(attr & 0x1000)))
    return out


def render_lines(spr, tile_get, mask):
    """bufs[group][line][x] for bitmap lines 0..255."""
    bufs = np.zeros((3, 256, 256), dtype=np.uint16)
    for s in spr:
        wsrc, hsrc = 16 * s["xnum"], 16 * s["ynum"]
        for y in range(max(0, s["top"]), 256):
            sy = ((y - s["top"]) * 128) // s["zy"]
            if sy >= hsrc:
                break
            ty = hsrc - 1 - sy if s["flipy"] else sy
            row_code = s["code"] + (ty >> 4) * s["xnum"]
            buf = bufs[s["group"], y]
            for x in range(max(0, s["x"]), 256):
                sx = ((x - s["x"]) * 128) // s["zx"]
                if sx >= wsrc:
                    break
                tx = wsrc - 1 - sx if s["flipx"] else sx
                pen = int(tile_get((row_code + (tx >> 4)) & mask)[ty & 15, tx & 15])
                if pen == 15:
                    continue
                if pen == 0 and s["shadow"]:
                    buf[x] |= SHADOW
                else:
                    buf[x] = OPAQUE | (s["color"] << 4) | pen
    return bufs


def composite(capture, bufs):
    """render_model.render with each sprite pass replaced by a group buffer."""
    return rm.palette_rgb(capture.palette)[composite_indexed(capture, bufs)]


def composite_indexed(capture, bufs):
    """The palette-index bitmap behind composite(); shadow is index + 0x4000."""
    stages = {}
    tg = [rm.make_tile_getter(capture.gfx[f"scroll{n}"], 8, 8) for n in range(3)]
    road_get = rm.make_tile_getter(capture.gfx["road0"], 64, 1, low_nibble_first=True)
    bm = np.zeros((rm.SCREEN_H, rm.SCREEN_W), dtype=np.uint16)

    def sprite_pass(g):
        b = bufs[g]
        op = (b & OPAQUE) != 0
        sh = (b & SHADOW) != 0
        bm[op] = 0x2800 + ((b[op] >> 4) & 0x7f) * 16 + (b[op] & 0xf)
        dark = sh & (bm < rm.PALETTE_COLORS)
        bm[dark] += rm.PALETTE_COLORS

    rm.draw_road(bm, capture.roads[0], road_get, 7, 5, False, 0x1c00, "a", stages)
    rm.draw_road(bm, capture.roads[1], road_get, 7, 5, True, 0x2400, "b", stages)
    rm.put_tilemap(bm, capture.vram[0], capture.scroll[0], tg[0], 0, 0x0e00, "c", stages)
    rm.put_tilemap(bm, capture.vram[1], capture.scroll[1], tg[1], 1, 0x1600, "d", stages)
    sprite_pass(0)
    rm.draw_road(bm, capture.roads[0], road_get, 4, 1, True, 0x1c00, "e", stages)
    rm.draw_road(bm, capture.roads[1], road_get, 4, 1, True, 0x2400, "f", stages)
    sprite_pass(1)
    rm.draw_road(bm, capture.roads[0], road_get, 0, 0, True, 0x1c00, "g", stages)
    rm.draw_road(bm, capture.roads[1], road_get, 0, 0, True, 0x2400, "h", stages)
    sprite_pass(2)
    rm.put_tilemap(bm, capture.vram[2], capture.scroll[2], tg[2], 2, 0x3600, "i", stages)
    return bm


def differing(a, b):
    eq = np.all(a == b, axis=2)
    cmp = np.ones(eq.shape, dtype=bool)
    x0, y0, x1, y1 = rm.IGNORE_UI
    cmp[y0:y1, x0:x1] = False
    return int(np.count_nonzero(~eq & cmp)), int(np.count_nonzero(cmp))


def write_case(name, ram, bufs):
    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "list.hex").write_text("".join(f"{int(v):04x}\n" for v in ram[:2048]))
    (folder / "expect.hex").write_text("".join(f"{int(v):04x}\n" for v in bufs.ravel()))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cases", action="store_true", help="write sim/sprite_tb inputs")
    args = parser.parse_args()
    names = []
    gfx = None
    for cap in CAPTURES:
        c = rm.Capture(cap)
        gfx = c.gfx["sprites"]
        tile_get = rm.make_tile_getter(gfx, 16, 16)
        mask = len(gfx) // 128 - 1
        bufs = render_lines(sprites(c.sprites), tile_get, mask)
        acc = composite(c, bufs)[rm.VISIBLE_TOP:rm.VISIBLE_TOP + rm.MAME_ROWS]
        mame_model = rm.render(c)[0][rm.VISIBLE_TOP:rm.VISIBLE_TOP + rm.MAME_ROWS]
        n_ref, total = differing(acc, c.ref)
        n_mod, _ = differing(mame_model, c.ref)
        n_vs, _ = differing(acc, mame_model)
        print(f"{cap}: accumulator vs MAME {n_ref}/{total}; MAME-model vs MAME {n_mod}; "
              f"accumulator vs MAME-model {n_vs}")
        Image.fromarray(composite(c, bufs)[rm.VISIBLE_TOP:rm.VISIBLE_TOP + rm.VISIBLE_ROWS]).save(
            c.path / "model_acc.png")
        if args.cases:
            name = cap.split("-", 1)[1]
            write_case(name, c.sprites, bufs)
            names.append(name)
    if args.cases:
        rnd = random.Random(3)
        tile_get = rm.make_tile_getter(gfx, 16, 16)
        mask = len(gfx) // 128 - 1
        for k in range(3):
            ram = np.zeros(2048, dtype=np.uint16)
            for i in range(256):
                hidden = rnd.random() < 0.6
                ram[i * 8:i * 8 + 8] = [
                    (0x1000 if hidden else 0) | rnd.randrange(0x100),
                    rnd.randrange(0x10000), rnd.randrange(0x10000),
                    rnd.randrange(0x10000), rnd.randrange(0x10000),
                    rnd.randrange(0x10000), rnd.randrange(0x10000), rnd.randrange(0x10000)]
                if k == 2:   # mostly near-screen, the zooms the games use
                    ram[i * 8 + 1] = (ram[i * 8 + 1] & 0x1000) | rnd.randrange(8, 0x140)
                    ram[i * 8 + 2] = (ram[i * 8 + 2] & 0x1000) | rnd.randrange(8, 0x140)
                    ram[i * 8 + 3] = rnd.randrange(-64, 300) & 0x7ff
                    ram[i * 8 + 4] = rnd.randrange(-64, 330) & 0x7ff
            write_case(f"rand_{k}", ram, render_lines(sprites(ram), tile_get, mask))
            names.append(f"rand_{k}")
        words = np.frombuffer(gfx, dtype="<u8")
        (OUT / "gfx.hex").write_text("".join(f"{int(v):016x}\n" for v in words))
        (OUT / "mask.txt").write_text(f"{len(gfx) // 128 - 1:04x}\n")
        (OUT / "cases.txt").write_text("".join(f"{n}\n" for n in names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
