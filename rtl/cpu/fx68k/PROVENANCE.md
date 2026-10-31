# fx68k provenance

Cycle-accurate 68000, Copyright (c) 2018, 2021 Jorge Cwik. GPLv3 (`LICENSE`).
Upstream: https://github.com/ijor/fx68k.

Not yet instantiated in `Cischeat.sv`; vendored to measure it against TG68K.C
before the roadmap commits to a CPU (`docs/ROADMAP.md`, area budget).

Microcoded: the instruction decode is a microcode ROM (`microrom.mem`, 19 KB)
plus a nano-ROM (`nanorom.mem`, 23 KB), not a gate-level translation of the
68000. That is the area argument for it over TG68K.C on a four- or five-CPU
board.

## Chain of custody

| Stage | What |
|-|-|
| Upstream | ijor/fx68k |
| Then | `Arcade-SegaXBoard_MiSTer-1.0.0/rtl/cpu/fx68k/` |
| Then | `Arcade-Seta_MiSTer/rtl/cpu/fx68k/` |
| Then | `Arcade-KonamiGX_MiSTer/rtl/cpu/fx68k/` |
| Here | copied from that KonamiGX tree unchanged |

`microrom.mem` and `nanorom.mem` match the SHA-1s Seta records for the SegaXBoard
copy (62036424..., a1f291b6...).

## Local changes

None of this project's. The copy carries KonamiGX's, which carry Seta's:

- Seta: the two `$readmemb` paths in `fx68k.sv` are relative to the project
  root (`rtl/cpu/fx68k/microrom.mem`, `nanorom.mem`). Anything that synthesises
  or simulates this tree must therefore run with the repository root as its
  working directory — including `rtl/synth_check/fx68k`, which is why its
  compile is launched from the root through `fit.tcl` rather than from its own
  directory.
- KonamiGX, for Verilator: the three structs in `fx68k.sv` (`s_clks`,
  `s_irdecod`, `s_nanod`) are declared `packed`, marked `[GX]` on each line.
- KonamiGX, for savestates: `stop_out`, high while IRD holds STOP, marked
  `[GX]`. No logic change.

`stop_out` is wanted here for the same reason: the state dump is designed in
from the first RTL (`references/savestates.md`).
