#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Snapshot MAME frames FIRST..LAST from power-on, for scripts/compare_reset_frames.py.

    python scripts/mame_frames.py cischeat --first 1 --last 60

Writes debug/<set>-frames/frame<n>.png (MAME's frame number, at its frame notifier).
-snapview native: the screen alone, without the layout's gear-shift artwork (cischeat.lh).
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--last", type=int, default=60)
    a = ap.parse_args()
    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.set}-frames"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    cmd = mame_cmd(exe, a.set, "frames.lua", mame_dir, ["-seconds_to_run", str(a.last // 60 + 10), "-snapview", "native"])
    env = dict(os.environ, **lua_runner_env("frames.lua"), CORE_OUT=out.as_posix(),
               CORE_FIRST=str(a.first), CORE_LAST=str(a.last))
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    check_lua_error(out)
    if "CORE_FRAMES_OK" not in p.stdout + p.stderr:
        sys.exit("capture did not complete:\n" + "\n".join((p.stdout + p.stderr).strip().splitlines()[-15:]))
    print(f"{a.set} frames {a.first}..{a.last} -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
