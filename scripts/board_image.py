#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Assemble a set's SDRAM contents, as the loader leaves them, from MAME region dumps.

The layout is docs/ROADMAP.md's SDRAM map. Every region comes from MAME after machine
init, so the sound bitswap and the sprite untangle are already applied; the scroll
regions are put in the loader's tile-pair layout (scripts/tile_layout.py). Output is one
16-bit word per line for $readmemh, words 0 .. 0x0f00000/2.

CPU regions are dumped in host (little-endian) word order and stored as their 68000
word value. Graphics regions are byte-wide: the even byte goes in bits [7:0].

    python scripts/mame_region_dump.py cischeat :maincpu --out debug/rom_regions/cischeat_maincpu.bin
    (likewise :user1 :road1cpu :road2cpu :soundcpu; the gfx dumps are Phase 1's)
    python scripts/board_image.py
"""
import argparse
from pathlib import Path

from tile_layout import pair_tiles

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "debug" / "rom_regions"

TOP = 0x0F00000

# (SDRAM byte address, dump, slot size); a set uses as much of a slot as its dump holds
LAYOUT = [
    (0x0000000, "maincpu",  0x80000),
    (0x0080000, "user1",    0x80000),
    (0x0100000, "road1cpu", 0x80000),
    (0x0180000, "road2cpu", 0x80000),
    (0x0200000, "iocpu",    0x80000),
    (0x0280000, "soundcpu", 0x40000),
    (0x02C0000, "scroll0",  0x80000),
    (0x0340000, "scroll1",  0x80000),
    (0x03C0000, "scroll2",  0x20000),
    (0x0400000, "sprites",  0x600000),
    (0x0A00000, "road0",    0x200000),
    (0x0C00000, "road1",    0x200000),
    (0x0E00000, "oki1",     0x80000),
    (0x0E80000, "oki2",     0x80000),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--game", default="cischeat")
    ap.add_argument("--out", type=Path, default=REPO / "debug" / "board" / "sdram.hex")
    args = ap.parse_args()

    img = bytearray(TOP)          # little-endian words, as $readmemh will see them
    for addr, name, size in LAYOUT:
        src = SRC / f"{args.game}_{name}.bin"
        if name == "iocpu" and not src.exists():
            continue                  # only F-1 Grand Prix Star II and Wild Pilot have one
        data = src.read_bytes()[:size]
        if name == "road1" and data == (SRC / f"{args.game}_road0.bin").read_bytes()[:len(data)]:
            continue                      # Big Run and Cisco Heat: road1 reads road0's copy
        if name.startswith("scroll"):
            data = pair_tiles(data)
        if not data:
            raise SystemExit(f"{name}: empty dump")
        img[addr:addr + len(data)] = data

    args.out.parent.mkdir(parents=True, exist_ok=True)
    words = memoryview(img).cast("H")
    with open(args.out, "w") as f:
        f.write("\n".join(f"{w:04x}" for w in words))
        f.write("\n")
    print(f"{len(words)} words -> {args.out}")


if __name__ == "__main__":
    main()
