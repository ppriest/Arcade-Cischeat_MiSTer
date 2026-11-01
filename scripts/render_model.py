#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) OpenAI
"""Render Cisco Heat from a MAME capture and compare against its screenshot.

    python scripts/render_model.py cischeat-phase1_play
    python scripts/render_model.py cischeat-phase1_play --stages

ROM graphics are assembled from MAME ROM_START with scripts/build_region.py;
RAM, palette, registers, road lists and the reference image come from
the mister MCP's mame_capture. This models MAME's screen_update_cischeat draw order.
"""
import argparse
import functools
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SCREEN_W = 256
SCREEN_H = 256
VISIBLE_TOP = 16
VISIBLE_ROWS = 224
MAME_ROWS = 216
PALETTE_COLORS = 0x4000
# MAME's Cisco Heat layout overlays the gear indicator on top of the emulated
# frame. The software renderer models the game video, not this cabinet UI.
IGNORE_UI = (232, 181, 256, 216)


def read_u16(path):
    raw = np.fromfile(path, dtype=">u2")
    if raw.size == 0:
        raise ValueError(f"empty word region: {path}")
    return raw.astype(np.uint16)


class Capture:
    def __init__(self, name):
        self.path = REPO / "debug" / name
        self.manifest = {}
        for line in (self.path / "manifest.txt").read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition(" ")
            self.manifest[key] = value
        if self.manifest.get("set") != "cischeat":
            raise ValueError(f"this model handles cischeat; capture is {self.manifest.get('set')}")
        self.vram = [read_u16(self.path / f"scroll{n}.bin") for n in range(3)]
        self.palette = read_u16(self.path / "palette.bin")
        self.sprites = read_u16(self.path / "sprites.bin")
        self.roads = [read_u16(self.path / f"road{n}.bin") for n in range(2)]
        self.regs = np.fromfile(self.path / "reg_scroll_regs.bin", dtype="u1")
        self.ref = np.asarray(Image.open(self.path / "reference.png").convert("RGB"))
        if self.ref.shape[:2] != (MAME_ROWS, SCREEN_W):
            raise ValueError(f"expected MAME's 256x216 capture, got {self.ref.shape[1]}x{self.ref.shape[0]}")
        self.scroll = []
        for base in (0, 8, 0x100):
            words = np.frombuffer(self.regs[base:base + 6], dtype=">u2")
            if len(words) != 3:
                raise ValueError(f"scroll register dump is short at offset {base:#x}")
            self.scroll.append(tuple(int(v) for v in words))
        if any(len(r) < 1024 for r in self.roads):
            raise ValueError("road CPU capture must contain 256 four-word line records")

        self.gfx = {}
        for name in ("scroll0", "scroll1", "scroll2", "sprites", "road0"):
            path = REPO / "debug" / "rom_regions" / f"cischeat_{name}.bin"
            if not path.is_file():
                raise FileNotFoundError(f"run scripts/build_region.py cischeat {name}")
            self.gfx[name] = path.read_bytes()


def palette_rgb(words):
    """MAME RRRRGGGGBBBBRGBx conversion, including its shadow color group."""
    raw = np.asarray(words, dtype=np.uint16)
    r5 = ((raw >> 11) & 0x1e) | ((raw >> 3) & 1)
    g5 = ((raw >> 7) & 0x1e) | ((raw >> 2) & 1)
    b5 = ((raw >> 3) & 0x1e) | ((raw >> 1) & 1)
    rgb = np.stack(((r5 << 3) | (r5 >> 2),
                    (g5 << 3) | (g5 >> 2),
                    (b5 << 3) | (b5 >> 2)), axis=1).astype(np.uint8)
    shadow = (rgb.astype(np.float32) * 0.6).astype(np.uint8)
    return np.concatenate((rgb, shadow), axis=0)


def make_tile_getter(data, width, height, low_nibble_first=False):
    bytes_per_tile = width * height // 2
    pixels_per_row = width // 2

    @functools.lru_cache(maxsize=4096)
    def get(code):
        count = len(data) // bytes_per_tile
        code %= count
        packed = np.frombuffer(data, dtype=np.uint8,
                               count=bytes_per_tile,
                               offset=code * bytes_per_tile).reshape(height, pixels_per_row)
        tile = np.empty((height, width), dtype=np.uint8)
        if low_nibble_first:
            tile[:, 0::2] = packed & 0x0f
            tile[:, 1::2] = packed >> 4
        else:
            tile[:, 0::2] = packed >> 4
            tile[:, 1::2] = packed & 0x0f
        return tile

    return get


def map_dimensions(flag):
    mode = flag & 0x0f
    if flag & 0x10:
        page_x, page_y = ((8, 1), (4, 2), (4, 2), (2, 4))[mode & 3]
        return page_x * 32, page_y * 32, False
    page_x, page_y = ((16, 2), (8, 4), (4, 8), (2, 16))[mode & 3]
    return page_x * 32, page_y * 32, True


def tilemap_entry(col, row, cols, large):
    pages_x = cols // 32
    if not large:
        return (col * 32) + (row // 32) * 1024 * pages_x + (row % 32), 0
    tile_index = ((((col // 2) * 16)
                   + ((row // 2) // 16) * 256 * pages_x
                   + ((row // 2) % 16)) * 4
                  + (row & 1) + (col & 1) * 2)
    return tile_index >> 2, tile_index & 3


def put_tilemap(bitmap, vram, regs, graphics, layer, rgbbase, name, stages):
    sx, sy, flag = regs
    cols, rows, large = map_dimensions(flag)
    tile_get = graphics
    for y in range(VISIBLE_TOP, VISIBLE_TOP + VISIBLE_ROWS):
        source_y = (y + sy) % (rows * 8)
        row = source_y >> 3
        py = source_y & 7
        for x in range(SCREEN_W):
            source_x = (x + sx) % (cols * 8)
            col = source_x >> 3
            ram_index, sub = tilemap_entry(col, row, cols, large)
            word = int(vram[ram_index])
            code = (word & 0x0fff) * (4 if large else 1) + sub
            pen = int(tile_get(code)[py, source_x & 7])
            if pen != 15:
                color = (word >> 11) & 0x1f
                bitmap[y, x] = rgbbase + color * 16 + pen
    stages[name] = bitmap.copy()


def draw_road(bitmap, roadram, tile_get, priority_lo, priority_hi,
              transparent, colorbase, name, stages):
    lower, upper = sorted((priority_lo & 7, priority_hi & 7))
    for y in range(VISIBLE_TOP, VISIBLE_TOP + VISIBLE_ROWS):
        rec = y * 4
        code = int(roadram[rec])
        scroll = int(roadram[rec + 1]) & 0x3ff
        attr = int(roadram[rec + 2])
        priority = (attr >> 8) & 7
        if priority < lower or priority > upper:
            continue
        first = (code << 4) + (scroll >> 6)
        subx = scroll & 0x3f
        x = -subx
        tile_code = first
        while x < SCREEN_W:
            tile = tile_get(tile_code)
            left = max(0, x)
            right = min(SCREEN_W, x + 64)
            if left < right:
                pens = tile[0, left - x:right - x]
                # The device's gfx element has 64 color groups; priority bits
                # share the attr word but only the low six bits select color.
                color = attr & 0x3f
                for px, pen in enumerate(pens, start=left):
                    if not transparent or pen != 15:
                        bitmap[y, px] = colorbase + color * 16 + int(pen)
            x += 64
            tile_code += 1
            if (tile_code & 0x0f) == 0:
                tile_code = (code << 4)
    stages[name] = bitmap.copy()


def draw_sprites(bitmap, ram, tile_get, p1, p2, colorbase, name, stages):
    high_sprites = p1 >= 16 or p2 >= 16
    lower, upper = sorted((p1 & 0x0f, p2 & 0x0f))
    for base in range(0, min(len(ram), 0x1000 // 2), 8):
        size = int(ram[base])
        if size & 0x1000:
            continue
        attr = int(ram[base + 7])
        priority = (attr >> 8) & 7
        if priority < lower or priority > upper:
            continue
        color = attr & 0x7f
        if high_sprites and not (color & 0x80):
            continue
        xzoom = int(ram[base + 1])
        yzoom = int(ram[base + 2])
        xdim = ((16 << 16) * (xzoom & 0x1ff)) >> 7
        ydim = ((16 << 16) * (yzoom & 0x1ff)) >> 7
        if xdim >> 16 == 0 or ydim >> 16 == 0:
            continue
        xnum = (size & 0x0f) + 1
        ynum = ((size >> 4) & 0x0f) + 1
        sx = int(ram[base + 3]) & 0x7ff
        sy = int(ram[base + 4]) & 0x7ff
        if sx & 0x400:
            sx -= 0x800
        if sy & 0x400:
            sy -= 0x800
        sx <<= 16
        sy = (sy << 16) - ydim * ynum
        xscale = xdim >> 4
        yscale = ydim >> 4
        if xscale & 0xffff:
            xscale += 0x1000
        if yscale & 0xffff:
            yscale += 0x1000
        flipx = bool(xzoom & 0x1000)
        flipy = bool(yzoom & 0x1000)
        xindices = range(xnum - 1, -1, -1) if flipx else range(xnum)
        yindices = range(ynum - 1, -1, -1) if flipy else range(ynum)
        shadow = bool(attr & 0x1000)
        code = int(ram[base + 6])
        for yt in yindices:
            for xt in xindices:
                dx = (xscale * 16 + 0x8000) >> 16
                dy = (yscale * 16 + 0x8000) >> 16
                left = (sx + xt * xdim) >> 16
                top = (sy + yt * ydim) >> 16
                if dx > 0 and dy > 0 and left < SCREEN_W and left + dx > 0 \
                        and top < VISIBLE_TOP + VISIBLE_ROWS and top + dy > VISIBLE_TOP:
                    xstep = (16 << 16) // dx
                    ystep = (16 << 16) // dy
                    xs = (np.arange(dx, dtype=np.int64) * xstep) >> 16
                    ys = (np.arange(dy, dtype=np.int64) * ystep) >> 16
                    if flipx:
                        xs = ((dx - 1 - np.arange(dx, dtype=np.int64)) * xstep) >> 16
                    if flipy:
                        ys = ((dy - 1 - np.arange(dy, dtype=np.int64)) * ystep) >> 16
                    tile = tile_get(code)
                    for out_y, src_y in zip(range(max(top, VISIBLE_TOP),
                                                  min(top + dy, VISIBLE_TOP + VISIBLE_ROWS)),
                                            ys[max(0, VISIBLE_TOP - top):
                                               min(dy, VISIBLE_TOP + VISIBLE_ROWS - top)]):
                        for out_x, src_x in zip(range(max(left, 0), min(left + dx, SCREEN_W)),
                                                xs[max(0, -left):min(dx, SCREEN_W - left)]):
                            pen = int(tile[src_y, src_x])
                            if pen == 15:
                                continue
                            if pen == 0 and shadow:
                                old = int(bitmap[out_y, out_x])
                                if old < PALETTE_COLORS:
                                    bitmap[out_y, out_x] = old + PALETTE_COLORS
                            else:
                                bitmap[out_y, out_x] = colorbase + color * 16 + pen
                code += 1
        # An entry contributes its tiles in ascending code order. Flipping changes
        # placement and source orientation, not the sequence of codes.
    stages[name] = bitmap.copy()


def render(capture, save_stages=False):
    tile_getters = [make_tile_getter(capture.gfx[f"scroll{n}"], 8, 8) for n in range(3)]
    sprite_get = make_tile_getter(capture.gfx["sprites"], 16, 16)
    road_get = make_tile_getter(capture.gfx["road0"], 64, 1, low_nibble_first=True)
    indexed = np.zeros((SCREEN_H, SCREEN_W), dtype=np.uint16)
    stages = {}
    draw_road(indexed, capture.roads[0], road_get, 7, 5, False, 0x1c00, "road0_7_5", stages)
    draw_road(indexed, capture.roads[1], road_get, 7, 5, True, 0x2400, "road1_7_5", stages)
    put_tilemap(indexed, capture.vram[0], capture.scroll[0], tile_getters[0], 0,
                0x0e00, "scroll0", stages)
    put_tilemap(indexed, capture.vram[1], capture.scroll[1], tile_getters[1], 1,
                0x1600, "scroll1", stages)
    draw_sprites(indexed, capture.sprites, sprite_get, 15, 3, 0x2800, "sprites_15_3", stages)
    draw_road(indexed, capture.roads[0], road_get, 4, 1, True, 0x1c00, "road0_4_1", stages)
    draw_road(indexed, capture.roads[1], road_get, 4, 1, True, 0x2400, "road1_4_1", stages)
    draw_sprites(indexed, capture.sprites, sprite_get, 2, 2, 0x2800, "sprites_2", stages)
    draw_road(indexed, capture.roads[0], road_get, 0, 0, True, 0x1c00, "road0_0", stages)
    draw_road(indexed, capture.roads[1], road_get, 0, 0, True, 0x2400, "road1_0", stages)
    draw_sprites(indexed, capture.sprites, sprite_get, 1, 0,
                 0x2800, "sprites_1_0", stages)
    put_tilemap(indexed, capture.vram[2], capture.scroll[2], tile_getters[2], 2,
                0x3600, "scroll2", stages)
    rgb = palette_rgb(capture.palette)[indexed]
    return rgb, stages


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture", help="debug capture directory name (without debug/)")
    parser.add_argument("--stages", action="store_true", help="write the image after every draw pass")
    args = parser.parse_args()
    try:
        capture = Capture(args.capture)
        rgb, stages = render(capture, args.stages)
    except (OSError, ValueError) as error:
        sys.exit(str(error))

    output = capture.path / "model.png"
    Image.fromarray(rgb[VISIBLE_TOP:VISIBLE_TOP + VISIBLE_ROWS]).save(output)
    predicted = rgb[VISIBLE_TOP:VISIBLE_TOP + MAME_ROWS]
    equal = np.all(predicted == capture.ref, axis=2)
    compared = np.ones(equal.shape, dtype=bool)
    x0, y0, x1, y1 = IGNORE_UI
    compared[y0:y1, x0:x1] = False
    count = int(np.count_nonzero(~equal & compared))
    compared_pixels = int(np.count_nonzero(compared))
    delta = np.abs(predicted.astype(np.int16) - capture.ref.astype(np.int16))
    compared_delta = delta[compared]
    print(f"{capture.manifest['set']} frame {capture.manifest['frame']}: "
          f"{count}/{compared_pixels} compared pixels differ from MAME "
          f"({count / compared_pixels:.2%}; gear overlay excluded)")
    print(f"  max channel delta {int(compared_delta.max())}; "
          f"mean channel delta {compared_delta.mean():.3f}")
    if count:
        ys, xs = np.nonzero(~equal & compared)
        print(f"  mismatch bounds x={xs.min()}..{xs.max()} y={ys.min()}..{ys.max()}")
        diff = np.clip(delta * 4, 0, 255).astype(np.uint8)
        diff[y0:y1, x0:x1] = 32
        Image.fromarray(diff).save(capture.path / "diff.png")
    else:
        diff = np.clip(delta * 4, 0, 255).astype(np.uint8)
        diff[y0:y1, x0:x1] = 32
        Image.fromarray(diff).save(capture.path / "diff.png")
    print(f"  model: {output}")
    if args.stages:
        folder = capture.path / "stages"
        folder.mkdir(exist_ok=True)
        for name, indexed in stages.items():
            Image.fromarray(palette_rgb(capture.palette)[indexed][VISIBLE_TOP:VISIBLE_TOP + VISIBLE_ROWS]).save(
                folder / f"{name}.png")
        print(f"  stages: {folder}")
    return 0 if count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
