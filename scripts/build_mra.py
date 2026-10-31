#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) OpenAI
"""Generate a set's development MRA from MAME ROM_START and verify its image.

    python scripts/build_mra.py [--set bigrun]
    python scripts/build_mra.py --check
    python scripts/build_mra.py --check --image debug/board/rom_image.hex

--image also writes the verified image as the DDR3 window holds it, one 64-bit
word per line (byte 8n + k in bits 8k+7..8k), for sim/rom_load_tb.

The MRA stream follows the fixed SDRAM map in docs/ROADMAP.md. The raw sprite and
sound-program bytes are transformed by the core download path; this tool proves
the MRA byte layout, not those RTL transforms.
"""
import argparse
import itertools
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import extract_dips
import mra as mra_lib
from build_region import find_zip, game_line, parent_of, region_image
from coretools import mame_version
from extract_romstart import SRC, blocks as rom_blocks, region_records

SET = "cischeat"
# the index-1 board byte Cischeat.sv reads (docs/ROADMAP.md, Per-game configuration)
BOARD = {"bigrun": 0, "bigrunu": 0, "cischeat": 1,
         "f1gpstar": 2, "f1gpstar2": 2, "f1gpstar3": 2, "f1gpstr2": 3,
         "wildplt": 4}
# the DIP ports, in the order of Cischeat.sv's sw[] bytes: DSW 1 & 2, then DSW 3
DIP_PORTS = {0: ("IN4", "IN5"), 1: ("IN4", "IN5"), 2: ("IN1", "IN4"), 3: ("IN1", "IN4"),
             4: ("IN0",)}
# the first four button slots (Cischeat.sv's joystick bits 4-7)
BUTTONS = {0: "Brake,Gear Shift,Accelerator,Horn", 1: "Brake,Gear Shift,Accelerator,Horn",
           2: "Brake,Gear Shift,Accelerator,-", 4: "Shot,Missile,Bomb,-"}
# names and settings shortened to the OSD's 28 columns
SHORT = {"Extra Setting For Coin B": "Coin B Extra", "Automatic Game Start": "Auto Start",
         "After 15 Seconds": "After 15s"}
IMAGE_SIZE = 0x0F00000

# Base and allocated size are the Phase 0 SDRAM map. The main 68000 sees its
# two ROM halves contiguously; the other CPUs have independent 512 KiB slots.
ALL_SEGMENTS = (
    ("maincpu",  0x0000000, 0x080000),
    ("user1",    0x0080000, 0x080000),
    ("road1cpu", 0x0100000, 0x080000),
    ("road2cpu", 0x0180000, 0x080000),
    ("iocpu",    0x0200000, 0x080000),    # F-1 Grand Prix Star II
    ("soundcpu", 0x0280000, 0x040000),
    ("scroll0",  0x02C0000, 0x080000),
    ("scroll1",  0x0340000, 0x080000),
    ("scroll2",  0x03C0000, 0x020000),
    ("sprites",  0x0400000, 0x600000),
    ("road0",    0x0A00000, 0x200000),
    ("road1",    0x0C00000, 0x200000),    # F1 GP Star family; the others read road0 for both
    ("oki1",     0x0E00000, 0x080000),
    ("oki2",     0x0E80000, 0x080000),
)


def segments():
    return [g for g in ALL_SEGMENTS
            if (g[0] != "road1" or BOARD[SET] >= 2) and (g[0] != "iocpu" or BOARD[SET] >= 3)]


def crc_text(crc):
    return f"{crc:08x}" if crc is not None else None


def groups(records):
    """Group a MAME region's plain loads and byte-lane pairs by destination."""
    records = [r for r in records if r[0] != "copy"]
    # ROM_CONTINUE: the next bytes of the file before it, as a plain load at
    # that file offset
    resolved = []
    for r in records:
        if r[0] == "continue":
            prev = resolved[-1]
            if prev[0] != "load":
                raise ValueError(f"ROM_CONTINUE after {prev[0]} at {r[2]:#x}")
            name, crc = prev[1], prev[4]
            off = (prev[5] if len(prev) > 5 else 0) + prev[3]
            resolved.append(("load", name, r[2], r[3], crc, off))
        else:
            resolved.append(r)
    records = resolved
    records.sort(key=lambda r: (r[2], r[0]))
    out = []
    i = 0
    while i < len(records):
        kind, name, dest, length, crc, *rest = records[i]
        if kind == "load16_byte":
            if i + 1 >= len(records):
                raise ValueError(f"unpaired ROM_LOAD16_BYTE at {dest:#x}")
            other = records[i + 1]
            if (other[0] != kind or other[2] != dest + 1 or other[3] != length
                    or tuple(other[5:]) != tuple(rest)):
                raise ValueError(f"unpaired or mismatched byte lanes at {dest:#x}")
            out.append({"dest": dest, "size": length * 2,
                        "parts": [(name, crc, rest[0] if rest else None, length),
                                  (other[1], other[4], other[5] if len(other) > 5 else None,
                                   length)], "interleave": True})
            i += 2
            continue
        if kind != "load":
            raise ValueError(f"unsupported MAME ROM load kind {kind!r} at {dest:#x}")
        off = rest[0] if rest else None
        out.append({"dest": dest, "size": length,
                    "parts": [(name, crc, off, length)], "interleave": False})
        i += 1
    return out


def part_xml(name, crc, offset=None, length=None, map_value=None):
    attrs = {"name": name}
    if crc is not None:
        attrs["crc"] = crc_text(crc)
    if offset is not None:
        attrs["offset"] = hex(offset)
        attrs["length"] = hex(length)
    if map_value is not None:
        attrs["map"] = map_value
    values = " ".join(f'{key}="{escape(str(value), {chr(34): "&quot;"})}"'
                      for key, value in attrs.items())
    return f"<part {values}/>"


def group_xml(group, zipfile_obj, truth):
    start, size = group["dest"], group["size"]
    expected = truth[start:start + size]
    if len(expected) != size:
        raise ValueError(f"MAME truth region is short at {start:#x}")
    entries = group["parts"]
    if not group["interleave"]:
        name, crc, offset, length = entries[0]
        whole = mra_lib._zip_read([zipfile_obj], name, crc)
        if offset is None and len(whole) > length:
            offset = 0              # a file read in parts (ROM_CONTINUE)
        data = whole[offset:offset + length] if offset is not None else whole[:length]
        if data != expected:
            raise ValueError(f"plain MRA part {name} does not reproduce bytes at {start:#x}")
        return part_xml(name, crc, offset, length if offset is not None else None)

    maps = ("01", "10")
    candidates = []
    for permutation in itertools.permutations(maps):
        data_parts = []
        for (name, crc, offset, length), map_value in zip(entries, permutation):
            data = mra_lib._zip_read([zipfile_obj], name, crc)
            data = data[offset:offset + length] if offset is not None else data[:length]
            data_parts.append((data, map_value))
        if mra_lib.interleave(data_parts, 16) == expected:
            candidates.append(permutation)
    if len(candidates) != 1:
        raise ValueError(f"expected one MRA lane map for {entries}, found {len(candidates)}")
    lane_map = candidates[0]
    body = "".join(part_xml(*entry, map_value=map_value)
                   for entry, map_value in zip(entries, lane_map))
    return f'<interleave output="16">{body}</interleave>'


def dip_xml():
    extract_dips._load_ioport_strings()
    all_ports = extract_dips.blocks(Path(SRC).read_text(encoding="utf-8", errors="replace"))
    missing = set()
    ports = extract_dips.parse_ports(all_ports[game_line(SET)[1]], all_ports, missing)
    if missing:
        raise ValueError("unresolved MAME DEF_STR labels: " + ", ".join(sorted(missing)))

    selected = DIP_PORTS[BOARD[SET]]
    defaults = []
    elements = []
    for port_index, name in enumerate(selected):
        fields = ports.get(name)
        if fields is None:
            raise ValueError(f"MAME input table has no {name} DIP port")
        default = 0xffff
        for label, mask, value, settings in fields:
            default = (default & ~mask) | (value & mask)
            if settings is None:
                continue
            bit_positions = [bit for bit in range(16) if mask & (1 << bit)]
            names = []
            ids = [None] * (1 << len(bit_positions))
            for setting, text in settings.items():
                if isinstance(setting, tuple):
                    raise ValueError(f"unfolded conditional DIP {label!r}")
                index = sum(((setting >> bit) & 1) << pos
                            for pos, bit in enumerate(bit_positions))
                ids[index] = text
            label = SHORT.get(label, label)
            ids = [re.sub(r"(\d+) Coins?/(\d+) Credits?", r"\1C/\2C", SHORT.get(i, i)) for i in ids]
            if any(value is None for value in ids):
                raise ValueError(f"DIP {label!r} has a missing setting")
            bit_text = ",".join(str(port_index * 16 + bit) for bit in bit_positions)
            escaped_label = escape(label, {'"': '&quot;'})
            escaped_ids = escape(",".join(ids), {'"': '&quot;'})
            elements.append(f'<dip name="{escaped_label}" bits="{bit_text}" '
                            f'ids="{escaped_ids}"/>')
        defaults.extend((default & 0xff, (default >> 8) & 0xff))
    default_text = ",".join(f"{byte:02X}" for byte in defaults)
    return f'<switches default="{default_text}" base="0">' + "".join(elements) + "</switches>\n"


def game_metadata(source):
    match = re.search(
        r'^GAMEL?\(\s*(\d{4})\s*,\s*' + re.escape(SET)
        + r'\s*,\s*\w+\s*,\s*\w+\s*,\s*\w+\s*,\s*\w+\s*,\s*\w+'
        r'\s*,\s*(ROT\d+)\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*'
        r'"((?:[^"\\]|\\.)*)"', source, re.M)
    if not match:
        raise ValueError(f"cannot parse {SET}'s GAME line from MAME source")
    year, rotation, manufacturer, title = match.groups()
    rotations = {"ROT0": "horizontal", "ROT90": "vertical (cw)",
                 "ROT180": "horizontal", "ROT270": "vertical (ccw)"}
    if rotation not in rotations:
        raise ValueError(f"unsupported MAME rotation {rotation}")
    return year, manufacturer, title, rotations[rotation]


def build_xml():
    if not SRC or not Path(SRC).is_file():
        raise FileNotFoundError(f"MAME source missing at {SRC!r}")
    version = mame_version()
    if not version:
        raise RuntimeError("cannot get <mameversion> from the configured MAME executable")
    source = Path(SRC).read_text(encoding="utf-8", errors="replace")
    year, manufacturer, title, rotation = game_metadata(source)
    all_sets = rom_blocks(source)
    if SET not in all_sets:
        raise ValueError(f"{SET} is missing from MAME ROM_START blocks")
    body = all_sets[SET]
    zippath = find_zip(SET)
    groups_by_region = {}
    truth_by_region = {}
    for region in {name for name, _, _ in segments()}:
        truth, _ = region_image(SET, region, transform=False)
        records, unknown = region_records(body, region)
        if unknown:
            raise ValueError(f"unparsed {SET}/{region} ROM records: {unknown[:3]}")
        groups_by_region[region] = groups(records)
        truth_by_region[region] = truth

    content = []
    cursor = 0
    with zipfile.ZipFile(zippath) as archive:
        for region, base, allocated in segments():
            if base < cursor:
                raise ValueError(f"overlapping ROM map segment {region}")
            if base > cursor:
                content.append(f'<part repeat="{base - cursor}">00</part>')
            truth = truth_by_region[region]
            end = min(allocated, len(truth))
            seggroups = [g for g in groups_by_region[region]
                         if g["dest"] < end]
            local_cursor = 0
            for group in seggroups:
                if group["dest"] != local_cursor:
                    raise ValueError(f"{region} has an unexpected gap at {local_cursor:#x}")
                content.append(group_xml(group, archive, truth))
                local_cursor += group["size"]
            if local_cursor > end:
                raise ValueError(f"{region} ROM loads exceed its mapped window")
            if local_cursor < allocated:
                # A MAME region may declare padding or the core may reserve a
                # larger fixed window than this set uses.
                content.append(f'<part repeat="{allocated - local_cursor}">00</part>')
            cursor = base + allocated

    if cursor < IMAGE_SIZE:
        content.append(f'<part repeat="{IMAGE_SIZE - cursor}">00</part>')

    return f'''<?xml version="1.0"?>
<misterromdescription>
    <name>{escape(title)}</name>
    <setname>{SET}</setname>
    <rbf>Cischeat</rbf>
    <mameversion>{version}</mameversion>
    <year>{year}</year>
    <manufacturer>{escape(manufacturer)}</manufacturer>
    <category>Arcade</category>
    <rotation>{rotation}</rotation>
    <players>{2 if BOARD[SET] == 4 else 1}</players>
    <rom index="1"><part>{BOARD[SET]:02X}</part></rom>
    <rom index="0" zip="{SET}.zip{"|" + parent_of(SET) + ".zip" if parent_of(SET) else ""}" md5="none" address="0x30000000">
        <!-- Raw sound program is bitswapped at load; sprite graphics are untangled at load. -->
        {''.join(content)}
    </rom>
    {dip_xml()}
    <buttons names="{BUTTONS[min(BOARD[SET], 2) if BOARD[SET] < 4 else 4]},-,-,-,-,Start,Coin,Pause,Service"
             default="A,B,X,Y,Start,Select,L,R" count="4"/>
</misterromdescription>
'''


def expected_stream():
    """Independently assemble the same fixed memory image from MAME regions."""
    image = bytearray(IMAGE_SIZE)
    for region, base, allocated in segments():
        data, _ = region_image(SET, region, transform=False)
        length = min(allocated, len(data))
        image[base:base + length] = data[:length]
    return bytes(image)


def main():
    global SET
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify without writing")
    parser.add_argument("--set", default="cischeat", choices=sorted(BOARD))
    parser.add_argument("--out", type=Path)
    parser.add_argument("--image", type=Path, help="also write the image as 64-bit hex words")
    args = parser.parse_args()
    SET = args.set
    try:
        xml = build_xml()
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
        sys.exit(str(error))

    # build_image accepts an MRA path, so use a temporary sibling file for the
    # independent mra-tools-c image reconstruction.
    if args.out is None:
        title = re.search(r"<name>(.*?)</name>", xml).group(1)
        args.out = REPO / "releases" / "_dev" / (re.sub(r'[<>:"/\|?*]', "", title) + ".mra")
    temp = args.out.with_suffix(".tmp.mra")
    try:
        temp.parent.mkdir(parents=True, exist_ok=True)
        temp.write_text(xml, encoding="utf-8")
        zip_path = find_zip(SET)
        actual = mra_lib.build_image(temp, zip_path, IMAGE_SIZE)
        expected = expected_stream()
        if actual != expected:
            mismatch = next(i for i, (a, b) in enumerate(zip(actual, expected)) if a != b)
            sys.exit(f"MRA ROM image differs from MAME at {mismatch:#x}: "
                     f"{actual[mismatch]:02x} != {expected[mismatch]:02x}")
        if args.image:
            args.image.parent.mkdir(parents=True, exist_ok=True)
            words = memoryview(actual).cast("Q")
            args.image.write_text("\n".join(f"{w:016x}" for w in words) + "\n")
            print(f"wrote {args.image} ({len(words)} 64-bit words)")
        if args.check:
            print(f"{SET}: MRA image matches MAME byte-for-byte ({IMAGE_SIZE:#x} bytes)")
        else:
            args.out.write_text(xml, encoding="utf-8")
            print(f"wrote {args.out} ({IMAGE_SIZE:#x}-byte image verified against MAME)")
    finally:
        temp.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
