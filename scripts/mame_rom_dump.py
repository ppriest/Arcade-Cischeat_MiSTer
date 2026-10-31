#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Dump the program ROM as the CPU sees it, for the boot testbench.

    python scripts/mame_rom_dump.py cischeat
    -> debug/<set>-rom/<set>_rom.hex   (one 16-bit word per line)

The ranges come from scripts/mame/regions.json "trace" "rom". MAME applies the
driver's ROM_LOAD16_BYTE interleave and any byte swap, so this is the image the
68000 actually fetches; reimplementing the load from the ROM files in a
testbench is how an interleave gets guessed wrong.

The output is a MAME dump and must never be committed: `debug/` is gitignored.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, check_lua_error, lua_env, lua_runner_env,  # noqa: E402
                          mame_cmd, mame_paths, regions)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--cpu", default=None, help="CPU device tag, e.g. :soundcpu")
    ap.add_argument("--space", default=None, help="address space (default: regions.json)")
    ap.add_argument("--range", dest="ranges", action="append", default=None,
                    help="inclusive byte range LO:HI in hex; repeat for more ranges")
    a = ap.parse_args()

    r = regions()
    rom = (a.ranges if a.ranges else
           [f"{lo}:{hi}" for lo, hi in r.get("trace", {}).get("rom", [])])
    if not rom:
        sys.exit("regions.json has no trace.rom ranges")
    parsed_ranges = []
    for item in rom:
        lo, sep, hi = item.partition(":")
        if not sep:
            sys.exit(f"bad --range {item!r}; expected LO:HI")
        parsed_ranges.append((int(lo, 16), int(hi, 16)))
    ranges = ",".join("%x:%x" % pair for pair in parsed_ranges)
    words = sum((hi - lo) // r["bus_bytes"] + 1 for lo, hi in parsed_ranges)

    out = a.out or (REPO / "debug" / f"{a.game}-rom")
    out.mkdir(parents=True, exist_ok=True)
    hexf = out / f"{a.game}_rom.hex"
    if hexf.exists():
        hexf.unlink()

    mame_dir, exe = mame_paths()
    env = dict(lua_env(r), **lua_runner_env("romdump.lua"),
               CORE_OUT=out.resolve().as_posix(), CORE_TAG=a.game,
               CORE_ROM_RANGES=ranges, CORE_CPU=a.cpu or r["cpu"],
               CORE_SPACE=a.space or r["space"])
    cmd = mame_cmd(exe, a.game, "romdump.lua", mame_dir,
                   ["-seconds_to_run", str(a.seconds)])
    print("  " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=mame_dir, env=dict(os.environ, **env),
                       capture_output=True, text=True, timeout=a.seconds + 60, **NO_WINDOW)
    check_lua_error(out)
    for line in (p.stdout or "").splitlines():
        if line.startswith("ROMDUMP") or "rror" in line:
            print("  " + line)

    if not hexf.exists():
        sys.exit("no dump written; see MAME output above")
    lines = [ln for ln in hexf.read_text().splitlines() if ln.strip()]
    if len(lines) != words:
        sys.exit(f"{hexf} has {len(lines)} words, expected {words}")
    print(f"-> {hexf} ({len(lines)} words)")

    # The reset vector is the cheapest proof of order: SP then PC, which the
    # boot trace's first four reads repeat. A byte-swapped dump fails here.
    sp = (int(lines[0], 16) << 16) | int(lines[1], 16)
    pc = (int(lines[2], 16) << 16) | int(lines[3], 16)
    print("  reset vector: SP=%08X PC=%08X" % (sp, pc))
    print("  last word  : %s" % lines[-1])


if __name__ == "__main__":
    main()
