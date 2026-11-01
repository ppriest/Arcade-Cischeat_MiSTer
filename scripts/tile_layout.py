#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The tilemap graphics layout in SDRAM (rtl/memory/cischeat_rom_transform.sv).

MAME's region holds 8x8 tiles of 32 bytes, row py in bytes 4*py..4*py+3. The loader
moves offset bits 6:2 so one 64-bit granule holds row py of codes c and c+2, the
left and right halves of a 16x16 tile's row:
    new[2] = old[6] (code bit 1), new[5:3] = old[4:2] (py), new[6] = old[5] (code bit 0)
"""


def pair_offset(a):
    return (a & ~0x7c) | ((a >> 6) & 1) << 2 | ((a >> 2) & 7) << 3 | ((a >> 5) & 1) << 6


def pair_tiles(data):
    """A scroll region in MAME's layout -> the loader's."""
    out = bytearray(len(data))
    for a in range(len(data)):
        out[pair_offset(a)] = data[a]
    return bytes(out)
