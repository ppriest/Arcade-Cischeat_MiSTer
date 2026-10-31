#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) OpenAI
"""Assemble a MAME ROM region from ROM_START, with Cischeat's init transform.

    python scripts/build_region.py cischeat scroll0
    python scripts/build_region.py cischeat sprites

The image is written under debug/rom_regions by default. Files there are
derived from a user's ROM set and are never committed.
"""
import argparse
import re
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from extract_romstart import SRC, blocks, region_records  # noqa: E402
from mame_capture import mame_paths, rompath  # noqa: E402


def declared_size(body, region):
    for raw in body.splitlines():
        line = raw.split("//", 1)[0].strip()
        match = re.match(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^\"]+)"', line)
        if match and match.group(2) == region:
            return int(match.group(1), 16)
    return None


def game_line(setname):
    """(parent, input ports) from the set's GAME() line, parent None for a parent set."""
    if not SRC or not Path(SRC).is_file():
        return None, setname
    m = re.search(rf"^GAMEL?\(\s*\d+,\s*{re.escape(setname)},\s*(\w+),\s*\w+,\s*(\w+),",
                  Path(SRC).read_text(encoding="utf-8", errors="replace"), re.M)
    if not m:
        return None, setname
    return (m.group(1) if m.group(1) != "0" else None), m.group(2)


def parent_of(setname):
    return game_line(setname)[0]


def find_zip(setname):
    """The set's zip, else its parent's: a merged set keeps the clone's ROMs there."""
    mame_dir, _ = mame_paths()
    for name in (setname, parent_of(setname)):
        for folder in rompath(mame_dir).split(";") if name else ():
            candidate = Path(folder) / f"{name}.zip"
            if candidate.is_file():
                return candidate
    raise FileNotFoundError(f"{setname}.zip not found in the configured MAME ROM paths")


def region_image(setname, region, stack=(), transform=True):
    if region in stack:
        raise ValueError(f"cyclic ROM_COPY while building {setname}/{region}: "
                         + " -> ".join((*stack, region)))
    if not SRC or not Path(SRC).is_file():
        raise FileNotFoundError(f"MAME source not found at {SRC!r}; set MAME_SRC")
    all_blocks = blocks(Path(SRC).read_text(encoding="utf-8", errors="replace"))
    if setname not in all_blocks:
        raise ValueError(f"MAME source has no ROM_START for {setname}")
    body = all_blocks[setname]
    size = declared_size(body, region)
    if size is None:
        raise ValueError(f"{setname} has no ROM region {region!r}")
    records, unknown = region_records(body, region)
    if unknown:
        raise ValueError(f"unparsed {setname}/{region} ROM records: {unknown}")

    zippath = find_zip(setname)
    output = bytearray(size)
    with zipfile.ZipFile(zippath) as archive:
        by_crc = {}
        for info in archive.infolist():
            by_crc.setdefault(info.CRC, []).append(info.filename)
        previous = None
        used = 0
        for kind, name, dest, length, crc, *rest in records:
            if kind == "continue":
                if previous is None:
                    raise ValueError("ROM_CONTINUE has no preceding ROM load")
                data, previous_kind = previous
                kind = previous_kind
            else:
                if kind == "copy":
                    source_region, source_offset = name, rest[0]
                    source, _ = region_image(setname, source_region, (*stack, region), transform)
                    if (source_offset + length > len(source)
                            or dest + length > size):
                        raise ValueError(f"ROM_COPY {source_region}:{source_offset:#x} -> "
                                         f"{region}:{dest:#x} ({length:#x}) exceeds a region")
                    output[dest:dest + length] = source[source_offset:source_offset + length]
                    continue
                hits = by_crc.get(crc, []) if crc is not None else []
                if hits:
                    data = archive.read(hits[0])
                else:
                    try:
                        data = archive.read(name)
                    except KeyError as error:
                        raise ValueError(f"{name!r} (CRC {crc}) not found in {zippath}") from error
                previous = (data, kind)
                used = 0

            chunk = data[used:used + length]
            if len(chunk) != length:
                raise ValueError(f"{name or 'continued ROM'}: expected {length:#x} bytes, got {len(chunk):#x}")
            used += length
            if kind == "load16_byte":
                end = dest + 2 * length
                if dest + 2 * (length - 1) >= size:
                    raise ValueError(f"{name}: load exceeds declared region")
                output[dest:end:2] = chunk
            elif kind == "load":
                if dest + length > size:
                    raise ValueError(f"{name}: load exceeds declared region")
                output[dest:dest + length] = chunk
            elif kind == "load16_wswap":
                if length & 1 or dest + length > size:
                    raise ValueError(f"{name}: invalid word-swapped load")
                swapped = bytearray(length)
                swapped[0::2] = chunk[1::2]
                swapped[1::2] = chunk[0::2]
                output[dest:dest + length] = swapped
            else:
                raise ValueError(f"unsupported load kind {kind!r} in {setname}/{region}")

    if transform and setname == "cischeat" and region == "sprites":
        if size % 128:
            raise ValueError("Cischeat sprite untangle requires a multiple of 128 bytes")
        transformed = bytearray(size)
        for base in range(0, size, 128):
            for row in range(16):
                src = base + row * 4
                dst = base + row * 8
                transformed[dst:dst + 4] = output[src:src + 4]
                transformed[dst + 4:dst + 8] = output[src + 64:src + 68]
        output = transformed
    return bytes(output), zippath


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("set")
    parser.add_argument("region")
    parser.add_argument("-o", "--out", type=Path)
    args = parser.parse_args()
    try:
        image, zippath = region_image(args.set, args.region)
    except (FileNotFoundError, ValueError, zipfile.BadZipFile) as error:
        sys.exit(str(error))
    out = args.out or (REPO / "debug" / "rom_regions" / f"{args.set}_{args.region}.bin")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(image)
    print(f"{args.set}/{args.region}: {len(image):#x} bytes from {zippath}")
    if args.set == "cischeat" and args.region == "sprites":
        print("  applied MAME init_cischeat sprite untangle")
    print(f"  wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
