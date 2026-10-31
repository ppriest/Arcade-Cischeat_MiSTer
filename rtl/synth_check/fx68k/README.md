# FX68K standalone area and Fmax

A Quartus project holding `rtl/cpu/fx68k` and nothing else, one revision with one CPU, one
with four and one with five, on the DE10-nano's Cyclone V 5CSEBA6U23I7, speed grade 7, Quartus
17.0.2, `HIGH PERFORMANCE EFFORT`, seed 1. Same device, effort and seed as the TG68K.C
measurement in `Arcade-KonamiGX_MiSTer/rtl/synth_check/tg68k` (2,926 ALMs), so the two are
comparable.

It answers the area question the roadmap turns on: Cischeat needs three 68000s plus a sound
CPU, and five on f1gpstr2 and wildplt.

```
cd E:/Arcade-Cischeat_MiSTer                      # root-relative $readmemb paths
python scripts/hwlock.py --require-no-jtag        # a compile blocks JTAG
quartus_sh -t rtl/synth_check/fx68k/fit.tcl
```

Every port is registered at the boundary and the pins are virtual, so the report is the
kernel's own register-to-register limit. One instance gives the per-CPU cost, four the
projected bigrun/cischeat/f1gpstar count, and five the f1gpstr2/wildplt count.

## Result

| | 1 CPU | 4 CPUs | 5 CPUs | marginal per CPU |
|---|---|---|---|---|
| ALMs | 2,061 | 8,319 | **10,326** | 2,007 (4 to 5); 2,086 (1 to 4) |
| registers | 1,856 | 7,734 | 9,350 | 1,616 (4 to 5); 1,469 (1 to 4) |
| M10K | 6 | 24 | 30 | 6 |
| DSP | 0 | 0 | 0 | 0 |
| Fmax (slow 1100mV 100C) | **130.7 MHz** | **115.2 MHz** | **119.3 MHz** | — |

Fmax derived from the 20 ns constraint: setup slack 12.346 ns (1 CPU), 11.320 ns (4 CPUs) and
11.620 ns (5 CPUs). Five instances are 10,326 ALMs (25%) and 30 of 553 M10K (5%), against the
10,405 ALMs projected in `docs/ROADMAP.md`.

## Against TG68K.C

| | FX68K | TG68K.C | difference |
|---|---|---|---|
| ALMs per CPU | 2,086 | 2,926 | **-840 (-29%)** |
| registers | 1,856 | 1,590 | +266 |
| M10K per CPU | 6 | 2 | +4 |
| DSP per CPU | 0 | 6 | -6 |
| Fmax | 130.7 MHz | 48.97 MHz | +81.7 MHz |

Projected on 41,910 ALMs:

| CPUs | FX68K | TG68K.C |
|---|---|---|
| 4 (bigrun, cischeat, f1gpstar) | 8,319 (20%) | 11,704 (28%) |
| 5 (f1gpstr2, wildplt) | 10,326 measured (25%; 10,405 projected) | 14,630 (35%) |

Five FX68Ks leave ~31,500 ALMs for three tilemap engines, two road generators, a scaling
sprite pipeline, SDRAM/DDR3, sound and the framework. Five TG68K.Cs would leave ~27,300.

## What it decides

FX68K is **smaller, faster and cycle-accurate**; TG68K.C is a 68000 approximation. On a board
with four CPUs kept in step by hardware handshakes, accuracy is the reason to prefer FX68K
anyway, and it now costs less area too.

Two costs to carry:

- **6 M10K per CPU**, 30 for five (5% of 553). TG68K.C uses 2. Budget tilemap line buffers
  against the difference.
- **`$readmemb` is project-relative** (`rtl/cpu/fx68k/*.mem`). Quartus resolves it from the
  project directory, so any project that instantiates FX68K must have those files reachable
  from its own root — which is why this directory carries a `.gitignore`d junction named
  `rtl`. `build_staged.py` builds in a worktree whose root *is* the repository root, so it is
  already correct; this is recorded because it is the kind of thing that fails only in the
  staged build.

GHDL/Verilator: FX68K is SystemVerilog and needs Verilator for the frame benches, as KonamiGX
does; TG68K.C is VHDL and its Verilator route goes through a GHDL conversion.
