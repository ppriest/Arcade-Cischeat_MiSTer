#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture a Cisco Heat state from MAME at a frame, with that frame and the next three.

    python scripts/mame_state.py cischeat --frame 900 [--coin 600]
    python scripts/state.py from-mame debug/cischeat-state-900 debug/state/mame900.hex

Writes debug/<set>-state-<frame>/: state.txt, one .hex per RAM, frame0..3.png.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frame", type=int, required=True)
    ap.add_argument("--coin", type=int, default=0, help="insert a coin and start at this frame")
    ap.add_argument("--line", type=int, default=1, help="scanline to capture at (the bench restores at 1)")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = a.out or REPO / "debug" / f"{a.set}-state-{a.frame}"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    cmd = mame_cmd(exe, a.set, "state.lua", mame_dir, ["-seconds_to_run", str(a.frame // 60 + 10), "-snapview", "native"])
    env = dict(os.environ, **lua_runner_env("state.lua"), CORE_OUT=out.as_posix(),
               CORE_FRAME=str(a.frame), CORE_COIN=str(a.coin), CORE_LINE=str(a.line))
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    check_lua_error(out)
    blob = p.stdout + p.stderr
    if (out / "ERROR.txt").exists():
        sys.exit("state.lua failed:\n" + (out / "ERROR.txt").read_text())
    if "CORE_STATE_OK" not in blob:
        sys.exit("capture did not complete:\n" + "\n".join(blob.strip().splitlines()[-15:]))
    print(f"{a.set} frame {a.frame} -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
