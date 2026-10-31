#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Dump a MAME region after machine initialization, including fixed transforms."""
import argparse
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, check_lua_error, lua_env, lua_runner_env,
                          mame_cmd, mame_paths, regions)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("game")
    ap.add_argument("region", help="absolute MAME region tag, e.g. :sprites")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.unlink(missing_ok=True)
    mame_dir, exe = mame_paths()
    env = dict(lua_env(regions()), **lua_runner_env("regiondump.lua"),
               CORE_OUT=args.out.parent.resolve().as_posix(),
               CORE_TAG=args.out.stem, CORE_REGION=args.region)
    cmd = mame_cmd(exe, args.game, "regiondump.lua", mame_dir, ["-seconds_to_run", "1"])
    p = __import__("subprocess").run(cmd, cwd=mame_dir,
             env=dict(os.environ, **env), capture_output=True, text=True,
             timeout=120, **NO_WINDOW)
    check_lua_error(args.out.parent)
    if not args.out.is_file():
        sys.exit((p.stdout or "") + (p.stderr or "") + "\nno region dump written")
    print(f"{args.region}: {args.out.stat().st_size:#x} bytes -> {args.out}")


if __name__ == "__main__":
    main()
