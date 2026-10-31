#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Cisco Heat savestate files (docs/SAVESTATES.md).

A state is 16-bit little-endian words: an 8-word header ('CH' 'ST' version
nsec frame_hi frame_lo 0 0), then the sections below, in this order. The
manifest here and SEC_LEN in rtl/cischeat_board.sv must agree; the version
changes when they do.

    python scripts/state.py info  <state>
    python scripts/state.py diff  <a> <b>
    python scripts/state.py to-sim <state> <dir>     # one .hex per section, for $readmemh
    python scripts/state.py from-mame <capture dir> <out.hex>   # scripts/mame_state.py's capture

A state ending in .hex is read as one hex word per line, which is what the benches write.
"""
import argparse
import struct
import sys
from pathlib import Path

VERSION = 2
CPU_REGS = [f"D{i}" for i in range(8)] + [f"A{i}" for i in range(7)] + ["A7", "USP", "PC", "SR"]
BOARD_REGS = ([f"scroll{l}_{k}" for l in range(3) for k in "xyc"] +
              ["sl_to_sound", "sl_to_main", "ip_select", "comms", "oki_bank"] +
              [f"ga_ram{i}" for i in range(5)] + ["ga_hs", "odd_frame"] +
              [f"pend_{c}" for c in ("main", "road1", "road2", "sound")] +
              ["pend_io", "io_value", "io_ready", "wp_out", "dma_reg"])

SECTIONS = [
    ("cpu_main", 38), ("cpu_road1", 38), ("cpu_road2", 38), ("cpu_sound", 38),
    ("board_regs", len(BOARD_REGS)),
    ("work_ram", 32768), ("shared_road1", 16384), ("shared_road2", 16384),
    ("scroll0", 16384), ("scroll1", 16384), ("scroll2", 16384), ("palette", 16384),
    ("link", 1024), ("road_list0", 1024), ("road_list1", 1024),
    ("road1_local", 8192), ("road2_local", 8192), ("sound_ram", 32768),
    ("cpu_io", 38), ("io_shared", 2048), ("io_local", 8192), ("dma_buffer", 2048),
]
HEADER = 8
TOTAL = HEADER + sum(n for _, n in SECTIONS)


def load(path):
    """A binary state, or the same words as hex text, one per line (what the benches write)."""
    if str(path).endswith(".hex"):
        words = [int(t, 16) for t in Path(path).read_text().split()]
    else:
        data = Path(path).read_bytes()
        words = list(struct.unpack(f"<{len(data) // 2}H", data))
    if words[:2] != [0x4348, 0x5354]:
        sys.exit(f"{path}: not a Cisco Heat state (magic {words[0]:04x} {words[1]:04x})")
    if words[2] != VERSION or words[3] != len(SECTIONS) or len(words) != TOTAL:
        sys.exit(f"{path}: version {words[2]}, {words[3]} sections, {len(words)} words; "
                 f"this script reads version {VERSION}, {len(SECTIONS)} sections, {TOTAL} words")
    out, pos = {}, HEADER
    for name, n in SECTIONS:
        out[name] = words[pos:pos + n]
        pos += n
    return words[:HEADER], out


def cpu_regs(sec):
    return {r: (sec[2 * i] << 16) | sec[2 * i + 1] for i, r in enumerate(CPU_REGS)}


def cmd_info(a):
    hdr, secs = load(a.state)
    print(f"version {hdr[2]}, frame {(hdr[4] << 16) | hdr[5]}")
    for c in ("main", "road1", "road2", "sound"):
        r = cpu_regs(secs[f"cpu_{c}"])
        print(f"  {c:6} PC {r['PC']:06x} SR {r['SR'] & 0xffff:04x} SSP {(r['A7'] + 6) & 0xffffff:06x} "
              f"USP {r['USP']:06x} D0 {r['D0']:08x}")
    print("  " + " ".join(f"{n}={v:04x}" for n, v in zip(BOARD_REGS, secs["board_regs"])))
    return 0


def cmd_diff(a):
    ha, sa = load(a.a)
    hb, sb = load(a.b)
    rc = 0
    for name, n in SECTIONS:
        d = [i for i in range(n) if sa[name][i] != sb[name][i]]
        if d:
            rc = 1
            print(f"DIFF {name:13} {len(d):6} of {n:6} words, first at {d[0]}: "
                  f"{sa[name][d[0]]:04x} vs {sb[name][d[0]]:04x}")
        else:
            print(f"SAME {name:13} {n:6} words")
    return rc


def cmd_from_mame(a):
    """Pack scripts/mame_state.py's capture into a state.

    MAME gives the active stack pointer (SP) and USP. The stub's A7 is the
    supervisor stack pointer less the 6-byte exception frame, so a CPU caught
    in user mode, whose SSP MAME does not expose, is refused. MAME's pending
    HOLD_LINE interrupts are not visible from Lua and are saved as none.
    odd_frame is MAME's frame number's parity: both toggle at vblank start and
    MAME's frame notifier runs after it. The PC is MAME's CURPC, the start of
    the instruction in progress: MAME's 68000 can stop mid-instruction, and its
    PC is then the prefetch address, inside or past that instruction. The
    instruction runs again from its start, repeating any part already done.
    """
    src = Path(a.dir)
    kv = {}
    for ln in (src / "state.txt").read_text().splitlines():
        k, v = ln.split()
        kv[k] = int(v, 16)
    words = [0x4348, 0x5354, VERSION, len(SECTIONS), kv["frame"] >> 16, kv["frame"] & 0xffff, 0, 0]
    for c in ("maincpu", "road1cpu", "road2cpu", "soundcpu"):
        sr = kv[f"{c}.SR"]
        if not sr & 0x2000:
            sys.exit(f"{c} is in user mode; its SSP is not in MAME's state")
        regs = [kv[f"{c}.D{i}"] for i in range(8)] + [kv[f"{c}.A{i}"] for i in range(7)]
        regs += [(kv[f"{c}.SP"] - 6) & 0xffffffff, kv[f"{c}.USP"], kv[f"{c}.CURPC"], sr]
        for r in regs:
            words += [r >> 16, r & 0xffff]
    board = {n: kv.get(n, 0) for n in BOARD_REGS}
    board["oki_bank"] = (kv["oki_bank1"] << 1) | kv["oki_bank0"]
    board["odd_frame"] = kv["frame"] & 1
    words += [board[n] & 0xffff for n in BOARD_REGS]
    for name, n in SECTIONS[5:]:
        f = src / f"{name}.hex"
        if name.startswith(("cpu_io", "io_", "dma_")) and not f.exists():
            words += [0] * n            # a set without the io CPU or the sprite DMA
            continue
        sec = [int(t, 16) for t in f.read_text().split()]
        if len(sec) != n:
            sys.exit(f"{name}: {len(sec)} words, expected {n}")
        words += sec
    assert len(words) == TOTAL
    Path(a.out).write_text("".join(f"{w:04x}\n" for w in words))
    print(f"{TOTAL} words, frame {kv['frame']} -> {a.out}")
    return 0


def cmd_to_sim(a):
    _, secs = load(a.state)
    out = Path(a.dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, words in secs.items():
        (out / f"{name}.hex").write_text("".join(f"{w:04x}\n" for w in words))
    print(f"{len(secs)} sections -> {out}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info"); p.add_argument("state"); p.set_defaults(fn=cmd_info)
    p = sub.add_parser("diff"); p.add_argument("a"); p.add_argument("b"); p.set_defaults(fn=cmd_diff)
    p = sub.add_parser("from-mame"); p.add_argument("dir"); p.add_argument("out")
    p.set_defaults(fn=cmd_from_mame)
    p = sub.add_parser("to-sim"); p.add_argument("state"); p.add_argument("dir"); p.set_defaults(fn=cmd_to_sim)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
