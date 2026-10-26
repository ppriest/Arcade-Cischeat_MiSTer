# Cischeat: hardware notes

Jaleco driving-board family, 1989-1993. Four CPUs, three tilemap gate arrays, a zoomable
sprite generator, two zoomable road generators.

Source: MAME `src/mame/jaleco/cischeat.cpp` at tag `mame0289`, commit `f34f02505e3`
("Bumped version to 0.289"), which matches the installed MAME 0.289 binary. Line numbers
below are that file unless stated. Device models read from the same tree:
`jaleco_zoomspr`, `jaleco_road`, `ms1_tmap`, `ms1_gatearray`.

## Sets

| Set | Game | Board variant | ROM bytes | MAME flags |
|---|---|---|---|---|
| bigrun | Big Run (11th Rallye, Europe?) | `bigrun_d65006` | 8,331,776 | `MACHINE_NODEVICE_LAN` |
| bigrunu | Big Run (11th Rallye, US?) | `bigrun_d65006` | 8,331,776 | clone of bigrun |
| cischeat | Cisco Heat | `cischeat` | 10,944,512 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |
| f1gpstar | Grand Prix Star (ver 4.0) | `f1gpstar` | 15,092,736 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |
| f1gpstar3 | Grand Prix Star (ver 3.0) | `f1gpstar` | 15,092,736 | clone of f1gpstar |
| f1gpstar2 | Grand Prix Star (ver 2.0) | `f1gpstar` | 15,092,736 | clone of f1gpstar |
| f1gpstr2 | F-1 Grand Prix Star II | `f1gpstr2` | 20,344,832 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |
| wildplt | Wild Pilot | `wildplt` | 16,424,448 | `IMPERFECT_GRAPHICS`, **`NOT_WORKING`** ("busted timings") |

Region CRCs compared across sets: not yet done. Duplicate ROMs are visible in the data —
`90015-0x` graphics ROMs appear twice each in `f1gpstr2`/`wildplt` (same CRC at two
offsets), and the 8 KB `ch9072_*` programs are shared between cischeat-era and wildplt sets.
Storing byte-identical copies once is worth doing before the memory plan is fixed.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| maincpu | 68000 | 10 MHz (12 MHz on f1gpstar/f1gpstr2/wildplt) | game logic, video registers | FX68K / TG68K |
| road1cpu | 68000 | 10 MHz (12 on f1gpstar) | road layer 0 | FX68K / TG68K |
| road2cpu | 68000 | 10 MHz (12 on f1gpstar) | road layer 1 | FX68K / TG68K |
| soundcpu | 68000 | 6 MHz | YM2151 + 2x M6295 | FX68K / TG68K |
| iocpu | 68000 | 10 MHz | I/O and network (f1gpstr2, wildplt only) | FX68K / TG68K |
| spritegen | Jaleco zoom sprite generator | — | sprites, scaled | none; from `jaleco_zoomspr.cpp` |
| scroll0/1/2 | Mega System 1 tilemap | — | 3 tilemap layers, 8x8/16x16 | none; from `ms1_tmap.cpp` |
| road0/1 | Jaleco zoomable road generator | — | road layers, scaled | none; from `jaleco_road.cpp` |
| ymsnd | YM2151 | 3.5 MHz | FM | jt51 |
| oki1/oki2 | MSM6295 | 4 MHz | ADPCM | jt6295 |

CPU clocks are set in `cischeat_state::bigrun` (lines 1756-1768) and raised in
`cischeat_state::f1gpstar` (lines 1869-1876). Both f1gpstr2 and wildplt derive from
`f1gpstar`, so they run at 12 MHz. The iocpu is added only for those two (line 1905).

## Clocks

Board XTALs, from the driver's comment at lines 2918 and 2974: **4.000 MHz, 7.000 MHz,
24.000 MHz**. YM2151 at 7/2 = 3.5 MHz. The 24 MHz source divides to the 12 MHz CPU clocks;
10 MHz sets divide it differently, which the driver does not document.

Pixel clock is **not declared** — the driver uses `set_refresh_hz(60)`, `set_size(256, 256)`,
`set_visarea(0, 255, 16, 239)` with no `set_raw()` (lines 1778-1781). MAME therefore assumes
256 total pixels per line, i.e. ~3.93 MHz, which is suspiciously low for a 1989 board and is
an open item. The line count (256 total, 224 visible, 16 lines top and bottom) is stated.

## Video

256x256 total, 256x224 visible, 60 Hz, ROT0, 4:3 display (non-square pixels).

Layers, back to front per `screen_update_cischeat` (line 430) and `screen_update_f1gpstar`
(line 460): road 0, road 1 (with priority splitting), three scroll tilemaps, then sprites.
`screen_update_bigrun` (line 399) is a separate path with only two tilemaps.

- **Tilemaps** (`ms1_tmap.cpp`): 8x8 and 16x16 tile modes, 4 tile banks selected by a
  register, per-layer scroll X/Y, separate colour base per layer. Tilemap RAM is 0x1000 words
  per layer; scroll registers live alongside it (`scroll_w`, line 50 of the header).
- **Sprites** (`jaleco_zoomspr.cpp`): list of sprite records in work RAM, **zoom/scale
  capable**, two priority classes. `jaleco_zoomspr_bigrun` is a separate variant with its own
  draw routine, so bigrun's sprite hardware differs from cischeat/f1gpstar.
- **Road** (`jaleco_road.cpp`): two independent zoomable road generators, 0x1000 and 0xC00
  words of RAM, colour base per layer.
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
| 000000-07ffff | main ROM (128 KB) |
| 100000-17ffff | second main ROM (128 KB) |
| 080000-087fff | hardware registers |
| 088000-08ffff | units linking RAM |
| 090000-097fff | shared RAM #2 |
| 098000-09ffff | shared RAM #1 |
| 0a0000-0affff | scroll RAM 0 / 1 |
| 0b0000-0b7fff | scroll RAM 2 |
| 0b8000-0bffff | palette RAM |
| 0f0000-0fffff | work RAM + sprites |

Sub CPUs (`road1cpu`, `road2cpu`): ROM at 000000, work RAM, 0x800-word road RAM, shared RAM
block, watchdog. Sound CPU: 256 KB ROM, work RAM, both M6295s, YM2151, bidirectional latch to
main. Exact guarded offsets differ per CPU and per set; the maps are `bigrun_map`,
`cischeat_map`, `f1gpstar_map2/3` in the driver.

## Feasibility

This is a **large** board: five 68000s on the later sets, four custom or semi-custom video
devices with no public RTL, and three independent zoom pipelines. Feasible on DE10-nano, but
the risk is area, not speed.

| Blocking unknown | Measurement that closes it |
|---|---|
| **LE budget** with 4 (f1gpstr2/wildplt: 5) 68000 instances plus three tilemap engines, two road generators and a scaling sprite pipeline | Instantiate FX68K/TG68K x4 and the frame infrastructure in the template, fit with Quartus 17.0, and compare the fit report against an existing core of similar CPU count. Do this before writing video RTL. |
| **Sprite zoom algorithm** — how the chip steps source pixels per destination line, and whether bigrun's variant differs in more than record format | Video write sweep plus per-line capture of the sprite list in MAME, then a frame-for-frame Verilator comparison of a scaled sprite set. |
| **Screen control register** — MAME does not know where layer enables and priorities live | Trace writes in the 0x80000-0x87fff range against visible layer changes in a MAME capture; the register will move when a layer appears. |
| **Pixel clock / real htotal** — MAME assumes 256 total, ~3.93 MHz | Measure H-sync on original hardware or a PCB capture; until then, derive from the crystal divides and check that a 48 MHz `clk_sys` still divides to an exact pixel clock. |
| **Road generator geometry** — Wild Pilot's is wrong in MAME, and the cischeat one is imperfect | Compare MAME's road against PCB footage, per `references/pcb_video_reference.md`; if MAME is wrong, the core follows MAME and logs it in `MACHINE_KLUDGES.md`. |
| **Unit linking (LAN)** — 2-4 cabinets, `MACHINE_NODEVICE_LAN` | Out of scope unless asked; a single-cabinet core is playable. Record the decision in the roadmap. |

Standing unknown: **wildplt is `NOT_WORKING` in MAME**. There is no correct reference to
follow. If it ships, it ships with MAME's timing error reproduced deliberately, or not at
all. User decision recorded in the roadmap.
