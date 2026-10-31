#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) OpenAI
"""Verify Cisco Heat's sound and sprite transforms against initialized MAME regions."""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from build_region import region_image  # noqa: E402

BITSWAP_0 = (0xD, 0xE, 0xF, 0x0, 0xA, 0x9, 0x8, 0x1,
             0x6, 0x5, 0xC, 0xB, 0x7, 0x2, 0x3, 0x4)
BITSWAP_1 = (0xF, 0xD, 0xB, 0x9, 0x7, 0x5, 0x3, 0x1,
             0x8, 0xA, 0xC, 0xE, 0x0, 0x2, 0x4, 0x6)
BITSWAP_2 = (0x4, 0x5, 0x6, 0x7, 0x0, 0x1, 0x2, 0x3,
             0xB, 0xA, 0x9, 0x8, 0xF, 0xE, 0xD, 0xC)


def bitswap(value, sources):
    result = 0
    for bit in sources:
        result = (result << 1) | ((value >> bit) & 1)
    return result


def decode_sound(raw):
    if len(raw) != 0x40000:
        raise ValueError(f"Cisco Heat soundcpu region is {len(raw):#x}, expected 0x40000")
    out = bytearray(raw)
    for i in range(len(raw) // 2):
        # The paired ROM lanes form the 68000's big-endian program word.
        value = (raw[2 * i] << 8) | raw[2 * i + 1]
        if i < 0x4000:
            pattern = BITSWAP_0 if (i | 0x124) != i else BITSWAP_1
        elif i < 0x8000:
            pattern = BITSWAP_2
        elif i < 0xC000:
            pattern = BITSWAP_0 if (i | 0x124) != i else BITSWAP_1
        elif i < 0x10000:
            pattern = BITSWAP_1
        else:
            pattern = BITSWAP_2
        value = bitswap(value, pattern)
        out[2 * i] = value >> 8
        out[2 * i + 1] = value & 0xff
    return bytes(out)


def main():
    raw, _ = region_image("cischeat", "soundcpu", transform=False)
    for region, expected in (
        ("soundcpu", decode_sound(raw)),
        ("sprites", region_image("cischeat", "sprites", transform=True)[0]),
    ):
        dump = REPO / "debug" / f"cischeat-{region}-mame.bin"
        command = [sys.executable, str(REPO / "scripts" / "mame_region_dump.py"),
                   "cischeat", f":{region}", "--out", str(dump)]
        result = subprocess.run(command, cwd=REPO, capture_output=True, text=True)
        if result.returncode:
            sys.exit((result.stdout + result.stderr).strip())
        actual = dump.read_bytes()
        # Lua region:read() returns bytes in host order; soundcpu is a big-endian
        # 16-bit MAME region, so normalize that representation to ROM byte order.
        if region == "soundcpu":
            actual = b"".join(actual[i:i + 2][::-1]
                              for i in range(0, len(actual), 2))
        if actual != expected:
            mismatch = next((i for i, (a, b) in enumerate(zip(actual, expected))
                             if a != b), min(len(actual), len(expected)))
            mame_byte = actual[mismatch] if mismatch < len(actual) else None
            model_byte = expected[mismatch] if mismatch < len(expected) else None
            sys.exit(f"{region} transform differs from MAME at {mismatch:#x}: "
                     f"MAME={mame_byte!r} model={model_byte!r}")
        print(f"cischeat {region} transform matches initialized MAME region: "
              f"{len(actual):#x} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
