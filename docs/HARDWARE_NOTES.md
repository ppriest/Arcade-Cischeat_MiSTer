# Cischeat: hardware notes

Jaleco driving-board family, 1989-1993. Four CPUs on most sets, five on the later ones, three
tilemap layers, a zoomable sprite generator, two zoomable road generators.

Source: MAME `src/mame/jaleco/cischeat.cpp` at tag `mame0289`, commit `f34f02505e3`
("Bumped version to 0.289"), which matches the installed MAME 0.289 binary. Line numbers
below are that file unless stated. Device models read from the same tree:
`jaleco_zoomspr`, `jaleco_road`, `ms1_tmap`, `ms1_gatearray`.

## Sets

| Set | Game | Board variant | Loaded bytes | MAME flags |
|---|---|---|---|---|
| bigrun | Big Run (11th Rallye, Europe?) | `bigrun_d65006` | 7,217,664 | `MACHINE_NODEVICE_LAN` |
| bigrunu | Big Run (11th Rallye, US?) | `bigrun_d65006` | 7,217,664 | clone of bigrun |
| cischeat | Cisco Heat | `cischeat` | 10,289,152 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |
| f1gpstar | Grand Prix Star (ver 4.0) | `f1gpstar` | 12,451,840 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |
| f1gpstar3 | Grand Prix Star (ver 3.0) | `f1gpstar` | 12,451,840 | clone of f1gpstar |
| f1gpstar2 | Grand Prix Star (ver 2.0) | `f1gpstar` | 12,451,840 | clone of f1gpstar |
| f1gpstr2 | F-1 Grand Prix Star II | `f1gpstr2` | 15,073,280 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |
| wildplt | Wild Pilot | `wildplt` | 13,762,560 | `IMPERFECT_GRAPHICS`, **`NOT_WORKING`** ("busted timings") |

Loaded bytes are summed from each `ROM_START` with `user2` excluded, the small PROMs included and
road graphics counted twice where `ROM_START` loads them twice. `ROADMAP.md`, Game scope, has the
same numbers with the per-region breakdown.

Region CRCs compared across sets: done for the big duplicates. `road0` and `road1` are
byte-identical on bigrun and cischeat, so the memory plan stores them once. `90015-0x` graphics
ROMs appear twice each in `f1gpstr2`/`wildplt` (same CRC at two offsets), and the 8 KB `ch9072_*`
programs are shared between cischeat-era and wildplt sets.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| maincpu | 68000 | 10 MHz (12 MHz on f1gpstar/f1gpstr2/wildplt) | game logic, video registers | FX68K, measured (`rtl/synth_check/fx68k`) |
| road1cpu | 68000 | 10 MHz (12 on the F1 GP Star family and wildplt) | road layer 0 | FX68K, measured (`rtl/synth_check/fx68k`) |
| road2cpu | 68000 | 10 MHz (12 on the F1 GP Star family and wildplt) | road layer 1 | FX68K, measured (`rtl/synth_check/fx68k`) |
| soundcpu | 68000 | 6 MHz | YM2151 + 2x M6295 | FX68K, measured (`rtl/synth_check/fx68k`) |
| iocpu | 68000 | 10 MHz | I/O and network (f1gpstr2, wildplt only) | FX68K, measured (`rtl/synth_check/fx68k`) |
| spritegen | Jaleco zoom sprite generator | — | sprites, scaled | none; from `jaleco_zoomspr.cpp` |
| scroll0/1/2 | Mega System 1 tilemap | — | 3 tilemap layers, 8x8/16x16 | none; from `ms1_tmap.cpp` |
| road0/1 | Jaleco zoomable road generator | — | road layers, scaled | none; from `jaleco_road.cpp` |
| ymsnd | YM2151 | 3.5 MHz | FM | jt51 |
| oki1/oki2 | MSM6295 | 4 MHz | ADPCM | jt6295 |

CPU clocks are set in `cischeat_state::bigrun` (lines 1756-1768) and raised in
`cischeat_state::f1gpstar` (lines 1869-1876). Both f1gpstr2 and wildplt derive from
`f1gpstar`, so they run at 12 MHz. The iocpu is added only for those two (line 1905).

## Clocks

Board XTALs, from the PCB notes: **20 MHz** on Big Run's main board (1967); **12, 4, 20 and
7 MHz** on Cisco Heat's top board (2217); **4, 7 and 24 MHz** on Wild Pilot's top board and
**24 MHz** on the lower board it shares with the F1 GP Star family (2918, 2974). The F1 GP Star
boards list no crystals of their own (2373). YM2151 at 7/2 = 3.5 MHz. 10 MHz is 20/2, 12 MHz is
24/2, 6 MHz is 12/2, 3.5 MHz is 7/2 and 4 MHz is the 4 MHz crystal. The sound clocks are marked
unverified in MAME (1803).

Pixel clock is **not declared** — the driver uses `set_refresh_hz(60)`, `set_size(256, 256)`,
`set_visarea(0, 255, 16, 239)` with no `set_raw()` (lines 1778-1781). MAME therefore assumes
256 total pixels per line, i.e. ~3.93 MHz, which is suspiciously low for a 1989 board and is an
open item. The core rejects it and uses 384x260 total at 6.000 MHz; `ROADMAP.md`, Clocks, has the
reasoning and the divisor table.

## Video

**MAME's model**: 256x256 total, 256x224 visible, 60 Hz, ROT0, 4:3 display (non-square pixels).
The core renders 384x260 total and the same 256x224 visible window; see `ROADMAP.md`, Video.

Each `screen_update_*` composites in a fixed pass order, not by a priority compare; the order
differs per board. `screen_update_cischeat` (line 430) is 13 draws, `screen_update_f1gpstar`
(line 460) 12 and `screen_update_bigrun` (line 399) 27. `ROADMAP.md`, Video, lists them.

- **Tilemaps** (`ms1_tmap.cpp`): 8x8 and 16x16 tile modes selected by bit 4 of the layer's flag,
  four page arrangements for each, per-layer scroll X/Y, separate colour base per layer. Each
  layer has a 32 KB scroll-RAM window, of which the first 16 KB is read for drawing; scroll
  registers live alongside it (`scroll_w`, line 50 of the header). `m_tile_bank` is never set in
  this driver, so a code is the word's low 12 bits.
- **Sprites** (`jaleco_zoomspr.cpp`): 16 bytes per record in work RAM, zoom/scale capable,
  priority in attribute bits 8-10, colour in bits 0-6, shadow in bit 12.
  `jaleco_zoomspr_bigrun` is a separate variant with its own record format and draw routine, so
  bigrun's sprite hardware differs from cischeat/f1gpstar.
- **Road** (`jaleco_road.cpp`): two independent road generators, a 2 KB line list per layer
  (256 lines x 4 words), colour base per layer; fixed-width on Big Run and Cisco Heat, zooming on
  the F1 GP Star family and Wild Pilot.
- **Palette**: `RRRRGGGGBBBBRGBx`, 8192 entries on bigrun (line 1787), 16384 on cischeat and
  f1gpstar (lines 1849, 1882). Shadows enabled.

MAME's own open questions, from the driver header (lines 124-137): the **screen control
register is not identified** (layer priorities and enables), priorities are imperfect,
sprite lag frames are unverified, and Wild Pilot's road is wrong. These are the places where
MAME cannot be the reference, because MAME does not know either.

## Memory map

Main CPU, from the driver's table (lines 59-78), Cisco Heat / f1gpstar columns:

| Range | Use |
|---|---|
| 000000-07ffff | main program ROM (512 KB) |
| 080000-080019 | board registers (inputs, sound latch, io CPU write) |
| 081000-081fff | io shared RAM (f1gpstr2, wildplt) |
| 082000-082401 | scroll registers, DSW 3, watchdog, sound latch/IRQ, CPU resets, active-layers stub |
| 088000-0887ff | cabinet link RAM (2 KB on cischeat and f1gpstr2, 1 KB on f1gpstar; none on wildplt) |
| 090000-097fff | shared RAM with road2 CPU |
| 098000-09ffff | shared RAM with road1 CPU |
| 0a0000-0a7fff | scroll RAM 0 |
| 0a8000-0affff | scroll RAM 1 |
| 0b0000-0b7fff | scroll RAM 2 |
| 0b8000-0bffff | palette RAM |
| 0f0000-0fffff | work RAM; the sprite list is at +0x8000 |
| 100000-17ffff | second main program ROM (512 KB) |

Big Run's map differs: registers at 080000-080013 and 082000-082401, link RAM 084000-0847ff,
shared RAM 088000-08bfff and 08c000-08ffff, scroll RAM 090000-09bfff in 16 KB banks, palette
09c000-09ffff, second program half 100000-13ffff.

Sub CPUs (`road1cpu`, `road2cpu`): ROM at 000000, work RAM, a 2 KB road line list (256 lines x
4 words), a shared RAM block and a watchdog. Sound CPU: 256 KB ROM, work RAM, both M6295s, YM2151,
bidirectional latch to main. Exact guarded offsets differ per CPU and per set; the maps are
`bigrun_map`, `cischeat_map`, `f1gpstar_map2/3` in the driver.

## Feasibility

This is a **large** board: five 68000s on the later sets, four custom or semi-custom video
devices with no public RTL, and three independent zoom pipelines. Feasible on DE10-nano, but
the risk is area, not speed.

| Blocking unknown | Measurement that closes it |
|---|---|
| **LE budget** with 4 (f1gpstr2/wildplt: 5) 68000 instances plus three tilemap engines, two road generators and a scaling sprite pipeline | **Measured**: FX68K at 2,086 ALMs per CPU (`rtl/synth_check/fx68k`), so 8,319 on four CPUs (20% of 41,910) and 10,405 on five (25%), leaving ~31,500 for everything else. TG68K.C would cost 2,926 each, 14,630 on five (35%). Still to measure: the video pipeline, which now has a fixed budget to fit inside. |
| **Sprite zoom algorithm** — how the chip steps source pixels per destination line, and whether bigrun's variant differs in more than record format | Video write sweep plus per-line capture of the sprite list in MAME, then a frame-for-frame Verilator comparison of a scaled sprite set. |
| **Screen control register** — MAME does not know where layer enables and priorities live | Trace writes in the 0x80000-0x87fff range against visible layer changes in a MAME capture; the register will move when a layer appears. |
| **Pixel clock / real htotal** — MAME assumes 256 total, ~3.93 MHz | Measure H-sync on original hardware or a PCB capture; until then, derive from the crystal divides and check that a 48 MHz `clk_sys` still divides to an exact pixel clock. |
| **Road generator geometry** — Wild Pilot's is wrong in MAME, and the cischeat one is imperfect | Compare MAME's road against PCB footage, per `references/pcb_video_reference.md`; if MAME is wrong, the core follows MAME and logs it in `MACHINE_KLUDGES.md`. |
| **Unit linking (LAN)** — 2-4 cabinets, `MACHINE_NODEVICE_LAN` | Out of scope unless asked; a single-cabinet core is playable. Record the decision in the roadmap. |

Standing unknown: **wildplt is `NOT_WORKING` in MAME**. There is no correct reference to
follow. If it ships, it ships with MAME's timing error reproduced deliberately, or not at
all. User decision recorded in the roadmap.
