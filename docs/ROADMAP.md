# Cischeat — MiSTer Core Roadmap

**This roadmap is a proposal until the user approves it. No phase executes before that approval,
and a phase whose scope changes goes back for approval.**

## Context

Goal: a DE10-nano MiSTer core for Jaleco's `Cischeat` driving-board family, emulated by MAME's
`jaleco/cischeat.cpp` and the devices it instantiates — a Quartus 17.0.2 Verilog/SystemVerilog
project producing one `.rbf` and a `.mra` per supported set, reusing proven open components where
they exist.

What shapes this project:

- **Four 68000s on most sets, five on `f1gpstr2` and `wildplt`.** That is the area question, and
  it is already answered: FX68K is vendored here and measured at **2,086 ALMs and 6 M10K per CPU**,
  130.7 MHz standalone and 115.2 MHz with four (`rtl/synth_check/fx68k/README.md`), 29% smaller
  than TG68K.C and cycle-accurate.
- **None of the four custom video devices has public RTL.** `ms1_tmap`, `jaleco_road`,
  `jaleco_zoomspr` and the gate arrays have no FPGA implementation in any tree on this machine,
  and the skill's searches found none. The only certifiable implementation is the one written
  here from the software model, verified against MAME frame by frame.
- **Three zooming pipelines on one die**: two road layers and a sprite generator, in two
  record formats and two road variants. The per-line fetch budget, not logic, is the risk.
- **Two load-time ROM transforms** (sprite untangle, sound-ROM bitswap) that no `.mra` can
  express, so the loader has to do them.

So the work divides into new RTL, in this order of difficulty:

1. One 68000 bus wrapper shared by five FX68K instances, each with a small instruction line cache,
   arbitrated onto SDRAM alongside six video clients (three tilemaps, two roads, sprites).
2. A 48 MHz system with a 6.000 MHz pixel clock and exact fractional enables for 10, 12, 6, 4 and
   3.5 MHz.
3. Three tilemap layers from `ms1_tmap.cpp`: page-mapped 8x8 and 16x16 tiles, four page
   layouts, per-layer scroll, 4- or 5-bit colour codes.
4. Two road generators from `jaleco_road.cpp`: fixed-width and per-line zooming.
5. A zooming sprite generator from `jaleco_zoomspr.cpp`, standard and Big Run record formats.
6. A painter's-algorithm mixer that replays each board's draw sequence exactly: 13 draws on
   Cisco Heat, 12 on F1 GP Star, 27 on Big Run.
7. The two load-time transforms in the download path.
8. Everything else is a port with verification: jt51, jt6295, the SDRAM controller, the loader,
   CRT Adjust, hiscore, and the template framework.

Cross-cutting findings from the previous cores are in **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**.
Working practice built on them is in **[`WORKFLOW.md`](WORKFLOW.md)**. The entries that already
bind decisions here are collected under "Pitfalls that already bind decisions here".

## Progress

**Phase 0 is done: the CPU, the bus wrapper and the line cache are measured and traced against
MAME. No core RTL exists yet and 0 of 8 sets boot.** Evidence per criterion in `docs/PHASE0.md`.

Done:

- Hardware notes from MAME 0.289 (commit `f34f02505e3`), the same release as the installed
  binary: sets, chips, clocks, memory maps, video devices, DIPs, protection
  (`312af36`, `docs/HARDWARE_NOTES.md`).
- FX68K vendored with chain of custody and its local changes listed (`a06d320`).
- FX68K standalone harness built and fixed for Quartus 17.0.2 (`871e315`); one-, four- and
  five-CPU fits completed.
- FX68K measured: 2,061 ALMs for one, 8,319 for four, 10,326 for five, marginal
  **2,086 ALMs / 1,469 registers / 6 M10K / 0 DSP per CPU**, 130.7 MHz (1), 115.2 MHz (4) and
  119.3 MHz (5) slow 1100 mV 100 °C (`252bc26`, `rtl/synth_check/fx68k/README.md`).
- The shared bus wrapper written and proved: `rtl/cpu/fx68k_bus.sv` (exact fractional phase
  enables, held DTACK, a 16-byte instruction line cache with an `ICACHE=0` bypass).
- Cischeat's main 68000 booted through it against MAME's decoded program image and diffed access
  by access: **700,000 accesses, 70,003 writes, 69,998 replayed I/O reads, all matching**, covering
  the reset vector, the init code, a 65,536-iteration delay loop and the road/sound CPU release at
  `0x82308` (`sim/cischeat_boot_tb`, §2 of `docs/PHASE0.md`).
- CPI measured at 10 and 12 MHz, cache in and out, split execution against stall, with a latency
  sweep: the 10 MHz CPU sustains 9.44 MHz of its 10 at 8 clk of memory latency, the 12 MHz CPU
  11.15 of 12, and the cache removes four of every five bus cycles (§3 of `docs/PHASE0.md`).
- Set sizing from `ROM_START` with `user2` excluded: largest set `f1gpstr2` at 15,073,280 bytes
  loaded; Big Run and Cisco Heat each load the same 1 MB of road graphics into `road0` and
  `road1`.
- DIP extraction tested against the driver: `cischeat` and `wildplt` extract cleanly;
  `bigrun`, `bigrunu`, `f1gpstar`, `f1gpstar2`, `f1gpstar3` and `f1gpstr2` make
  `scripts/extract_dips.py` exit on a multi-bit `PORT_CONDITION`.

Open:

- Cisco Heat's development MRA is generated and verified against the 15 MiB MAME ROM image;
  its sound and sprite transforms match MAME's initialized regions. Big Run and RTL download
  path verification remain open (`docs/PHASE2.md`).
- Which video pipeline fits in the remaining ~30,000 ALMs and ~170 M10K.

**Phase 1 is done for Cisco Heat, against the amended criterion.** All six line engines, the line
buffers, the pass-ordered mixer and the palette (`rtl/video/cischeat_video.sv`) reproduce the
model's frame on all four captures, 0 mismatches, and fit in 1,193 ALMs and 100 M10K at
120.2 MHz. The sprites' single zoom accumulator puts 4,664-5,923 pixels a frame off MAME
(`docs/HACKS.md`). Carried forward: the worst captured line takes 2,956 of 3,072 clocks and
needs 126 sprite granules against the 96 estimated below, with no time cutoff yet. See [`PHASE1.md`](PHASE1.md).

**Phase 2:** Cisco Heat boots and races on hardware (`PHASE2.md`, step 6). Open: hiscore and the
exit-criteria play check.

**Phase 3 has started:** YM2151 and two jt6295 on SDRAM sample clients, MAME's mix
(5b66744, timing met at +0.448 ns). Open: a from-reset bench run against MAME's audio, and a
listen on hardware.

**Phase 4 has started, on the user's request to add the other titles:** Big Run's main, road and
sound maps, D65006 gate array and bitswap, sprite record format, seven sprite pass groups and its
draw order, selected by the `.mra` board byte; `.mra` generation per set with multi-bit
`PORT_CONDITION` handling. Open: Big Run against MAME frames from reset, then hardware; `bigrunu`
needs its zip; the F1 GP Star family, `f1gpstr2` and `wildplt`.

## Game scope

Loaded bytes per set from each `ROM_START` (`cischeat.cpp:2022-3100`), `user2` excluded. Where
`ROM_START` loads the same files into two regions the bytes are counted twice here and once in the
memory plan, as noted. `-listxml` reports declared region sizes, which are not these numbers.

| Set | Game | Board config | Program ROMs (KB) | Graphics (KB) | Samples (KB) | Loaded bytes | MAME flags |
|---|---|---|---|---|---|---|---|
| bigrun | Big Run (11th Rallye, Europe?) | `bigrun_d65006` | 1,536 | 5,248 † | 256 | 7,217,664 | `NODEVICE_LAN` |
| bigrunu | Big Run (11th Rallye, US?) | `bigrun_d65006` | 1,536 | 5,248 † | 256 | 7,217,664 | clone of bigrun |
| cischeat | Cisco Heat | `cischeat` | 2,304 | 6,720 † | 1,024 | 10,289,152 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |
| f1gpstar | Grand Prix Star (ver 4.0) | `f1gpstar` | 1,792 | 9,344 | 1,024 | 12,451,840 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |
| f1gpstar3 | Grand Prix Star (ver 3.0) | `f1gpstar` | 1,792 | 9,344 | 1,024 | 12,451,840 | clone of f1gpstar |
| f1gpstar2 | Grand Prix Star (ver 2.0) | `f1gpstar` | 1,792 | 9,344 | 1,024 | 12,451,840 | clone of f1gpstar |
| wildplt | Wild Pilot | `wildplt` | 2,048 | 10,368 | 1,024 | 13,762,560 | `IMPERFECT_GRAPHICS`, **`NOT_WORKING`** |
| f1gpstr2 | F-1 Grand Prix Star II | `f1gpstr2` | 2,304 | 11,392 | 1,024 | 15,073,280 | `IMPERFECT_GRAPHICS`, `NODEVICE_LAN` |

† Big Run and Cisco Heat declare `road0` and `road1` from byte-identical files (1,024 KB); the
core stores them once. `Program ROMs` = main + second-half + two road CPUs + sound (+ io CPU).
`Graphics` = three scroll ROMs + sprites + road gfx. Small PROMs (8.5 KB on bigrun) are in no
column and are not needed by the core.

### Scope decision

- **In scope: all eight sets**, including `wildplt`. The user asked for every set; one `.rbf`
  serves all of them, and the extra cost of `wildplt` is one board-config table entry, one DMA
  register, analog-stick inputs and one more 68000.
- **Out of the first scope:** 2–4 cabinet linking (`MACHINE_NODEVICE_LAN`) and the cockpit motion
  outputs. Linking needs a network transport MiSTer does not have in the framework; the link RAM
  is backed on-chip but never exchanged, so the link test sees the no-partner path it already
  handles. Motion outputs drive a seat and a wheel that a core cannot feed. The registers are
  accepted and ignored, exactly as MAME accepts them without a partner.
- **Deliberately dropped:** the `user2` ROM region — 18 loads totalling 5,278,720 bytes on
  `f1gpstr2` alone, with overlapping offsets. No map in the driver references it, on any set; it
  is declared but unreadable. Sizing memory from it would be wrong by 5.3 MB.
- **First-target set: `cischeat`.** It is the standard path — standard zoom sprites, fixed-width
  roads, 16,384-entry palette, four CPUs, no io CPU — so every engine built for it is reused by
  `f1gpstar` and `f1gpstr2`. Its DIP block extracts cleanly today, unlike six other sets.
- **Second target: `bigrun`.** Smallest set (7.2 MB) and the two variants that nothing else uses:
  the Big Run sprite record format and the 8,192-entry palette, plus the second main-CPU map.

## Hardware reality (from the driver, not assumption)

Every value below is read out of the MAME driver or a device file and cites file and line. A
value from a datasheet or a PCB note says so. Line numbers are `jaleco/cischeat.cpp` unless
another file is named.

### Chips

| Tag | Part | Clock | Role | Source |
|---|---|---|---|---|
| maincpu | 68000 | 10 MHz (12 MHz on f1gpstar family and wildplt) | game logic, video registers, sound latch | 1756, 1769-1876 |
| road1cpu | 68000 | 10 / 12 MHz | road layer 0: builds the line list | 1760, 1872 |
| road2cpu | 68000 | 10 / 12 MHz | road layer 1 | 1764, 1875 |
| soundcpu | 68000 | 6 MHz | YM2151 + two M6295 | 1768 |
| iocpu | 68000 | 10 MHz | I/O board and link, f1gpstr2 and wildplt only | 1905 |
| spritegen | Jaleco zoom sprite generator | — | up to 256x256 px sprites, per-tile zoom | `jaleco_zoomspr.cpp` |
| scroll0/1/2 | Mega System 1 tilemap pair (GS-9000406/GS90015-02 class) | — | 8x8 or 16x16 tiles, page-mapped, four page layouts | `ms1_tmap.cpp` |
| road0/1 | Jaleco road generator (CS90015-04 / GS90015-05) | — | 1024-px line layers, zoom on later boards | `jaleco_road.cpp` |
| gate array | D65006C (bigrun, F1 GP Star family) / GS88000 (cischeat) | — | sound-ROM bitswap at power-on | `ms1_gatearray.cpp` |
| ymsnd | YM2151 | 3.5 MHz (7 MHz / 2) | FM | 1804 |
| oki1/oki2 | M6295 | 4 MHz, pin 7 high | ADPCM, one bank bit each | 1809-1813 |

Board crystals, from the PCB notes: **20 MHz** on the Big Run main board (1967); **12, 4, 20 and
7 MHz** on the Cisco Heat top board CH-9071 (2217); **4, 7 and 24 MHz** on Wild Pilot's top board
and **24 MHz** on the lower board it shares with the F1 GP Star family (2918, 2974). The F1 GP
Star boards list no crystals of their own (2373); their CPUs are TMP68000P-12 parts (2916) at
MAME's 12 MHz (1869-1875). 10 MHz is 20/2; 12 MHz is 24/2; 6 MHz is 12/2; 3.5 MHz is 7/2; 4 MHz
is the 4 MHz crystal.

### Clocks

**Plan: `clk_sys` = 48 MHz, SDRAM on `clk_mem` = 96 MHz (2 x `clk_sys`, same PLL), pixel clock
6.000 MHz = 48/8.**

Every board clock divides 48 MHz exactly, so `clk_sys` stays at 48. The SDRAM moved to 96 MHz on a
measured shortfall, agreed with the user (`docs/PHASE2.md`, step 4): the vendored `sdram.sv` takes
11 of its clocks per granule and the arbiter and phy about 4 more, 200 granules a line at 48 MHz
against up to 293 the board asked for in play; 401 at 96 MHz (`sim/sdram_tb`).

| Clock | Ratio to 48 MHz | Exact? | Notes |
|---|---|---|---|
| Pixel clock | /8 = 6.000 MHz | yes | core-generated; no board pixel-clock source is documented |
| main, road1, road2, iocpu (10 MHz sets) | 5/24 | yes | 5 evenly-spread enables per 24 clocks |
| main, road1, road2 (12 MHz sets) | /4 | yes | 12.000 MHz |
| iocpu (always 10 MHz) | 5/24 | yes | independent of the board's 12 MHz |
| soundcpu | /8 = 6.000 MHz | yes | same enable as the pixel clock, separate domain |
| YM2151 | 7/96 = 3.500 MHz | yes | 7 evenly-spread enables per 96; `cen_p1` every second |
| M6295 | /12 = 4.000 MHz | yes | one enable per 12 clocks |

**Video timing: 384 x 260 total, 256 x 224 visible.** 6.000 MHz / (384 x 260) = 60.096 Hz and
15.625 kHz. Visible lines are 16..239 on Big Run, F1 GP Star, F1 GP Star II and Wild Pilot;
Cisco Heat's MAME visarea is 16..231 (216 lines), so the core still renders the 224-line window
and comparisons crop its last 8 lines. The driver's scanline numbers (IRQ at 240 and at 0) keep
their meaning, and the 36 blank lines are 16 above and 20 below. MAME declares no pixel
clock at all — it calls `set_refresh_hz(60)`, `set_size(256, 256)` and nothing else (1778-1781),
which implies 3.93 MHz and 256 total pixels per line, a line rate of 15.36 kHz. 6.000 MHz with a
384-pixel line gives 15.625 kHz, the standard monitor line rate. It is the only 48 MHz multiple
that yields a whole number of clocks per pixel, per line and per frame. The 24 MHz crystal on the
lower board the F1 GP Star family shares with Wild Pilot divides to it, but no board documents a
pixel-clock source, so this stays a hypothesis. The hypothesis and what would settle it are in
Open items and go in `docs/HACKS.md` when the RTL lands.

The **SDRAM multiple is 2**: the controller (`sdram_sched.sv`) runs on `clk_mem`, the clients on
`clk_sys`, and `rtl/memory/cischeat_sdram.sv` crosses between them (a request is a held level, a
valid is stretched to two `clk_mem` cycles so one `clk_sys` edge sees it). 401 granules a 64 µs
line, 15.3 `clk_mem` cycles each, with every client asking.

**No run-ahead.** Each 68000 is the reference for its own bus and takes a stall as a wait state;
there is no single fast CPU to catch up, unlike a V70. `DTACK` is a held level, never a pulse
(`LESSONS_LEARNED.md`, "DTACK/ready must be a held level").

### Interrupts

All of them are `HOLD_LINE`: the line stays asserted until the CPU acknowledges, and the 68000
autovectors at `0x64` (level 1), `0x68` (level 2) and `0x70` (level 4). Vectors are to be read out
of the program ROM in Phase 0 rather than assumed.

| CPU | Level | When | Source |
|---|---|---|---|
| main | 4 | scanline 240, **even frames only**, "vblank out" | 1731-1740 |
| main | 1 | scanline 240, **odd frames only** | 1731-1734 |
| main | 2 | scanline 0, **even frames only** | 1731-1743 |
| road1, road2 | 4 | vblank start (`set_vblank_int`) | 1762, 1766 |
| sound | 4 | YM2151 IRQ (timer expiry) | 1746-1750, 1805 |
| sound | 4 | every main-CPU write to the board's sound-int register | 586, 634, 823 |
| iocpu | 4 | falling edge of bit 2 of the main's io write | 651-654 |
| iocpu | 2 | falling edge of bit 1 of the main's io write | 653-654 |

The scanline callback returns early on odd frames, after raising IRQ1 at line 240; IRQ4 (line 240)
and IRQ2 (line 0) therefore fire on even frames only. Each level fires at 30 Hz, and the 68000
sees one interrupt at line 240 every frame plus IRQ2 at line 0 on even frames. The driver's own
comment says "irq generation is unknown" (1719), records that IRQ1 on odd frames is a guess, and
notes that calling IRQ2 every frame desyncs Big Run's attract mode (1724); there is no
vblank-count register. The core reproduces the guess and logs it.

The main CPU also resets the other three or four CPUs through register writes at `0x82308`
(`cischeat_comms_w` 590-596, `f1gpstar_comms_w` 638-644), so those CPUs must be resettable and
must come out of reset in the same frame MAME's do.

### Memory map

Main CPU, `cischeat` / `f1gpstar` / `f1gpstr2` / `wildplt` (749, 812, 894, 938). Big Run's map
differs and is called out below.

| Range | Size | Use |
|---|---|---|
| `000000-07ffff` | 512 KB | program ROM, first half |
| `080000-080019` | — | board registers: inputs, sound latch, wheel/pedal, io CPU write and ready (f1gpstr2, wildplt) |
| `081000-081fff` | 4 KB | io shared RAM (f1gpstr2, wildplt) |
| `082000-082109` | — | per-layer scroll X/Y/flag registers, three layers |
| `082200` | — | DSW 3 (bigrun, cischeat) |
| `082208` | — | watchdog, written and ignored (712, 765) |
| `082300` | — | sound latch both ways plus sound IRQ (cischeat only) |
| `082308` | — | road and sound CPU resets (`cischeat_comms_w`, `f1gpstar_comms_w`) |
| `082400` | — | "active layers", written and **ignored by MAME** (560-563) |
| `084000`/`088000` | 1–2 KB | cabinet link RAM — backed on-chip, never exchanged (none on wildplt) |
| `090000-097fff` | 32 KB | shared RAM with road2 CPU (road1 on wildplt) |
| `098000-09ffff` | 32 KB | shared RAM with road1 CPU (road2 on wildplt) |
| `0a0000-0a7fff` | 32 KB | scroll RAM 0 |
| `0a8000-0affff` | 32 KB | scroll RAM 1 |
| `0b0000-0b7fff` | 32 KB | scroll RAM 2 |
| `0b8000-0bffff` | 32 KB | palette RAM |
| `0f0000-0fffff` | 64 KB | work RAM; the **sprite list is at +0x8000** (357) |
| `100000-17ffff` | 512 KB | program ROM, second half ("user1") |

Big Run instead: registers at `080000-080013` and `082000-082401`; link RAM `084000-0847ff`;
shared RAM `088000-08bfff` and `08c000-08ffff` (16 KB each, order reversed); scroll RAM
`090000-093fff`, `094000-097fff`, `098000-09bfff` (16 KB each); palette `09c000-09ffff`
(16 KB, 8,192 entries); second program half `100000-13ffff` (256 KB).

Road CPU (991-1054):

| Range | Size | Use |
|---|---|---|
| `000000-03ffff` | 256 KB | program ROM, first half |
| `040000-043fff` (Big Run) / `047fff` (Cisco Heat) / `080000-087fff` (f1gpstar family) | 16 or 32 KB | shared RAM with main |
| `080000-0807ff` (Big Run, Cisco Heat) / `100000-1007ff` (f1gpstar family) | 2 KB | road line list, 256 lines x 4 words |
| `0c0000-0c3fff` (Big Run, Cisco Heat) / `180000-183fff` (f1gpstar family) | 16 KB | local work RAM |
| `200000-23ffff` | 256 KB | program ROM, second half (Cisco Heat only) |
| `100000` (Cisco Heat) / `200000` (F1 GP Star family) | — | watchdog, written and ignored |

The road CPUs share RAM with the main CPU at a different address per board, which is why the
shared-RAM region and its address are both board constants.

Sound CPU (1081-1151):

| Range | Use |
|---|---|
| `000000-03ffff` | 256 KB program ROM, **bitswapped at load** |
| `040000` (Big Run), `040002`/`040004` (Cisco Heat), `040004`/`040008` (f1gpstar family) | M6295 bank bits; on Big Run the same word is the latch from main |
| `060000-060005` | the two 16-bit latches to and from main (f1gpstar both at `060000`, Cisco Heat and f1gpstr2 at `060002`/`060004`, Big Run's output at `060000`) |
| `080000-080003` | YM2151, byte-wide on the high lane |
| `0a0000`, `0c0000` | M6295 #1 and #2, byte-wide |
| `0f0000-0fffff` (Big Run, Cisco Heat) | 64 KB work RAM |
| `0e0000-0fffff` (f1gpstar family) | 128 KB work RAM |

Io CPU (`f1gpstr2_io_map`, 1161): program `000000-07ffff` (512 KB loaded on `f1gpstr2`, 256 KB on
`wildplt`, inside a 512 KB window), shared RAM `080000-080fff` (4 KB), io-ready write `100000`,
local RAM `180000-183fff` (16 KB).

### Video

256x224 visible, ROT0, 4:3 with non-square pixels (256x216 on Cisco Heat, whose visarea is
16..231). Three tilemap layers, two road layers, one sprite layer, a 16-bit palette with
shadows.

**Draw order is the model, not a priority compare.** Each `screen_update_*` composites in a fixed
sequence, and each draw is restricted to a priority window; a tilemap beats a priority-7 road
simply by being drawn later. The sequences are board constants (`screen_update_cischeat` 430-453,
`screen_update_f1gpstar` 460-488, `screen_update_bigrun` 399-423), listed in draw order:

- **Cisco Heat — 13 draws**, backdrop pen 0: road0 7..5 opaque; road1 7..5; tmap0; tmap1;
  sprites 15..3; road0 4..1; road1 4..1; sprites 2; road0 0; road1 0; sprites 1..0; tmap2;
  sprites 16..16.
- **F1 GP Star — 12 draws**, backdrop pen 0: road1 6..7 opaque; road0 6..7; tmap0; tmap1;
  road1 1..5; road0 1..5; sprites 15..2; road1 0; road0 0; sprites 1; tmap2; sprites 0.
- **Big Run — 27 draws**, backdrop pen `0x1000`: for priority `i` = 7 down to 4, road0 `i`
  (opaque only at `i` = 7), road1 `i`, sprites `i+1..i` — twelve draws; then tmap0 and tmap1;
  then the same three draws for `i` = 3 down to 0 — twelve more; then tmap2.

Road order is a board constant too: F1 GP Star draws road1 before road0 (`/* road 1!! 0!! */`),
the other two draw road0 first.

- **Cisco Heat's last sprite pass is a no-op in MAME.** It calls `draw_sprites(..., 16, 16, ...)`:
  the priority values become 0 after `& 0xf`, and the pass then requires bit 7 of a colour field
  MAME has already masked to 7 bits (`attr & 0x7f`, 131-133), so no sprite can match. The core
  reproduces the no-op and logs it.
- **Tilemaps** (`ms1_tmap.cpp`): a layer is 32 pages of 256x256 px with 16x16 tiles, or 8 pages
  with 8x8 tiles; the control register's low two bits pick the page arrangement (16x2, 8x4, 4x8,
  2x16 pages for 16x16 tiles; 8x1, 4x2, 4x2, 2x4 for 8x8), and bit 4 set selects the 8x8 tilemap
  set (clear selects 16x16). **There is no tile-bank select in this driver**: `m_tile_bank` is
  never set, so a code is `(code & 0xfff)`, multiplied by 4 for the four 8x8 quadrants of a
  16x16 tile (225-239). Colour is the top 4 bits of the word, or 5 on `cischeat` (1849-1858). The
  three scroll words per layer are at `0x82000 + 8*n` (n = 0, 1) and `0x82100`.
- **Sprites** (`jaleco_zoomspr.cpp`): 16 bytes per record, 256 records in 4 KB of work RAM. Size
  word on both formats: bit 12 hides, low nibble = x tiles - 1, high nibble = y tiles - 1;
  attribute bit 12 enables shadow. Standard format: zoom X at `+2`, zoom Y at `+4`, X at `+6`,
  Y at `+8`, code at `+0xc`, attribute at `+0xe` (bits 8-10 priority, bits 0-6 colour), zooms
  9-bit with bit 12 of each zoom word for flip. Big Run packs 8-bit zooms into `+2` (Y in the
  high byte, X in the low), positions at `+4`/`+6` with flip at bit 12 of each position word, and
  a 64-colour sprite table (1695). Zoom is
  `((16 << 16) * (zoom & 0x1ff)) >> 7`, so 0x80 is 1:1, 0x40 is half size and 0x100 is double.
  Both formats pass Y as the sprite's **last** line: the standard generator subtracts
  `ydim * ynum` (166-168); on Big Run that subtraction is commented out (294), so its Y is used
  as given. Standard positions are sign-extended from 11 bits (159-160), Big Run's from 9
  (287-288).
- **Roads** (`jaleco_road.cpp`): four words per line. Fixed-width format: code, x scroll,
  attribute (bits 8-10 priority, bits 4-0 colour), unused. Zoom format: scroll+priority,
  zoom, attribute, code; the source line is 1024 px wide, shrunk or widened about its centre
  and then scrolled (212-218). 256 lines, 2 KB per layer.
- **Palette** (`RRRRGGGGBBBBRGBx`): shadows enabled on every set. 8,192 entries on Big Run,
  16,384 on the rest. The layer colour bases are palette byte offsets as the driver configures
  them (72-78, 1790-1795, 1851-1861, 1884-1889): on Big Run scroll0 `0x0e00`, scroll1 `0x1600`,
  scroll2 `0x3600`, road0 `0x2000`, road1 `0x1800`, sprites `0x2800`; on Cisco Heat scroll0
  `0x1c00`, scroll1 `0x2c00`, scroll2 `0x6c00`, roads `0x3800`/`0x4800`, sprites `0x5000`; on
  the F1 GP Star family the scroll bases are `0x1e00`/`0x2e00`/`0x6e00`, and roads and sprites
  are as Cisco Heat. Sprite colour codes are the attribute's low 7 bits; the sprite table holds 64
  colours on Big Run and 128 elsewhere (1695, 1703).
- **MAME does not emulate**: the screen control register that would enable layers and set their
  priorities (127, and `active_layers_w` is a stub), sprite lag frames (137), and Wild Pilot's
  road (133). Priorities are admittedly imperfect (132).

### Sound

YM2151 at 3.5 MHz with `jt51` (stereo) and two M6295 at 4 MHz with `jt6295`, both driven by the
sound 68000 at 6 MHz. MAME's mix: YM 0.50 to each channel, each OKI 0.25 to each (1806-1815).
Both OKIs take a one-bit bank select from different registers per board, with `PIN7_HIGH` giving a
512 KB address space per chip. The main and sound CPUs talk through two 16-bit latches; the main
CPU raises IRQ4 on the sound CPU from its sound-int register, and the sound CPU's music timing
comes from polling the YM's status register, so the YM's timers must be accurate to the enable,
not approximated.

**All sound clocks are "unverified" in MAME** (1803): 3.5 MHz, 4 MHz and pin 7 are copied from
Mega System 1 assumptions. The core copies them and logs it.

### Protection

There is no MCU and no handshake. The only protection is a **16-bit lane permutation of the sound
CPU's program ROM**, applied once at power-on by the gate array (`ms1_gatearray.cpp` 44-92):

- `D65006` on Big Run and the whole F1 GP Star family (including `f1gpstr2` and `wildplt`),
  `GS88000` on Cisco Heat, with different permutation tables. The F1 GP Star configs call
  `bigrun()` and never replace the device (1866, 1897, 1914); only `cischeat()` installs the
  `GS88000` (1821, 1839).
- Three permutations selected by word index `i`, in 16,384-word (32 KB) steps, over the whole
  256 KB region (`size > 0x40000` is clamped):
  - 0–32 KB and 64–96 KB: permutation 0, except at indices with bits 2, 5 and 8 all set
    (`i | 0x124 == i`), which use permutation 1;
  - 32–64 KB: permutation 2;
  - 96–128 KB: permutation 1;
  - 128–256 KB: permutation 2.

The game cannot run without it, and no `.mra` can express it, so the loader performs it. The
gate array's ROM overlay/`hs_seq` machinery in the same file belongs to Mega System 1 and is not
instantiated here.

### Per-game configuration

One `.mra`-style mod block: a **board byte** plus flags. Everything else is a constant table
keyed by the board byte, because a board byte already implies the map, the mixing order, the
palette size and the colour bases.

| Field | Values | What it selects |
|---|---|---|
| board | 0 bigrun, 1 cischeat, 2 f1gpstar, 3 f1gpstr2, 4 wildplt | map, mixing pass table, sprite format, road format, palette size, colour bases, sound map, sound bank addresses |
| flags bit 0 | io CPU present | f1gpstr2, wildplt |
| flags bit 1 | sprite DMA | wildplt only (`0x8000c` bit 13, 374-384) |
| flags bit 2 | road1 gfx aliases road0 | bigrun, cischeat |
| clock | 0 = 10 MHz, 1 = 12 MHz | main and both road CPUs |

Derived from the board byte, not sent: work RAM 64 KB everywhere; shared road RAM 16 KB (bigrun)
or 32 KB; scroll RAM 16 KB (bigrun) or 32 KB; palette 8,192 or 16,384 entries; sound RAM 64 KB or
128 KB; link RAM 1 or 2 KB; scroll colour bits 4 or 5; road fixed or zooming; sprite record
standard or Big Run; the per-board draw sequence; the layer colour bases; the three
sound-bank/latch address variants.

Inputs differ more than the config suggests: Big Run and Cisco Heat read a wheel through selector
`0x80010`, and their selectors 1 and 2 (cockpit position) return all-ones because MAME wires no
input to them (510-520); only Big Run's selector 3 returns the analog pedal — on Cisco Heat the
accelerator is the digital button at `0x80002` bit 4 (1338). F1 GP Star reads an analog pedal in
the low byte and a paddle in the high byte of `0x80010` directly (604-607, 1565-1569), with the
gear shift as a toggle (1521). Wild Pilot muxes two 8-bit AD sticks and a set of buttons through
`0x80004` and `0x80010` (862-890). The core therefore needs paddle, pedal, analog stick and the
shift-as-toggle behaviour.

DIPs are 8-position switch blocks read as 16-bit ports: `IN4` plus the 4-bit `IN5` on bigrun and
cischeat, `IN1` plus `IN4` on the F1 GP Star family, and `IN0` on wildplt. `-listxml` reports 17
named switch entries on cischeat, 16 on bigrun, 21 on each F1 GP Star set, 20 on f1gpstr2 and 13
on wildplt, several of them conditional. Six of the eight sets have a `PORT_CONDITION` on a
multi-bit switch (`IN4 0x3`, `IN1 0x300`), which `scripts/extract_dips.py` refuses today — see
Phase 4.

## Component reuse map

Every row's "source" is a file that was located and whose header was read.

| block | plan | source |
|---|---|---|
| 68000 | Port, already vendored | `rtl/cpu/fx68k/` here, from `Arcade-KonamiGX_MiSTer/rtl/cpu/fx68k` (ijor/fx68k), GPL-3.0; measured in `rtl/synth_check/fx68k` |
| YM2151 | Port | `E:\jtcores\modules\jt51\hdl` (jotego, GPL-3.0); the 48 MHz enable pattern from `Arcade-Silkroad_MiSTer/rtl/sound/silkroad_sound.sv` (opcode-compatible YM2151 board) |
| M6295 | Port | `Arcade-Fuuki_MiSTer/rtl/sound/jt6295` (jotego, GPL-3.0; provenance written in `Arcade-Pandora_MiSTer/rtl/sound/jt6295/PROVENANCE.md`) |
| SDRAM controller | Port | `Arcade-Seta_MiSTer/rtl/memory/sdram/sdram.sv` with its `PROVENANCE.md`; re-derive its refresh and init timing for 48 MHz |
| ROM download | Port, then extend | `Arcade-Seta_MiSTer/rtl/memory/sdram_download.sv` + `sdram_phy.sv` + `sdram_arbiter.sv` |
| DDR3 fast load | Port | `Arcade-Seta_MiSTer/rtl/memory/rom_loader.sv` + `ddram_phy.sv` |
| HDMI rotation / flip | Port | `Arcade-Seta_MiSTer/rtl/video/screen_rotate_two.sv` (DDR3 client) |
| CRT Adjust | Port | `Arcade-Seta_MiSTer/rtl/video/crt_adjust.sv` |
| hiscore | Port | `Arcade-KonamiGX_MiSTer/rtl/hiscore/hiscore.v` |
| framework, HPS, OSD, scaler | Template, unedited | `sys/` (Template_MiSTer) |
| tilemap engine | From scratch | `ms1_tmap.cpp`/`.h`: page mapper, 8x8/16x16, four page layouts, scroll |
| road generators | From scratch | `jaleco_road.cpp`: fixed and zoom line draw |
| sprite engine | From scratch, jtframe structure | `jaleco_zoomspr.cpp`; line-sorted list and double buffer modelled on `Arcade-KonamiGX_MiSTer/rtl/jtframe/jtframe_objdraw*.v` |
| palette, shadow, mixer | From scratch | `palette_device` format and the driver's draw sequences (399-488) |
| dual-port RAM wrappers | Sibling core's | `Arcade-KonamiGX_MiSTer/rtl/jtframe/jtframe_dual_ram16.v` |
| line buffer | Sibling core's | `Arcade-KonamiGX_MiSTer/rtl/video/gx_obj_linebuf.v` as the pattern for a double-buffered line store |

Licence: **GPL-3.0-or-later** for this repository. FX68K, jt51, jt6295, the Seta SDRAM controller
and the framework are all GPLv3-compatible. `THIRD-PARTY.md` does not exist yet and is a Phase 0
deliverable.

## On-chip RAM budget

The DE10-nano's `5CSEBA6U23I7` has **553 M10K blocks** (5,662,720 bits), and the block count, not
the bits, is the limit. An M10K is 10,240 bits, configurable as 1,024x10, 512x20 or 256x40, so
the count follows depth and port width as much as total bits: a 1,024-deep 16-bit RAM costs two
blocks, while a 256-deep 16-bit line buffer fits in one at one pixel per clock (the mixer's
four-pixel read takes two). All figures are the block count at the width and depth the core
uses.

| RAM | bytes | bits | M10K |
|---|---|---|---|
| Main work RAM (64 KB, sprites live at +0x8000) | 65,536 | 524,288 | 64 |
| Shared RAM with road1 CPU (32 KB) | 32,768 | 262,144 | 32 |
| Shared RAM with road2 CPU (32 KB) | 32,768 | 262,144 | 32 |
| Road1 local RAM (16 KB) | 16,384 | 131,072 | 16 |
| Road2 local RAM (16 KB) | 16,384 | 131,072 | 16 |
| Io CPU local RAM (16 KB) | 16,384 | 131,072 | 16 |
| Io shared RAM (4 KB) | 4,096 | 32,768 | 4 |
| Scroll RAM, three layers at the full 32 KB window | 98,304 | 786,432 | 96 |
| Palette (16,384 x 16) | 32,768 | 262,144 | 32 |
| Road line lists, two at 2 KB | 4,096 | 32,768 | 4 |
| Sprite list + latched copy, two at 4 KB | 8,192 | 65,536 | 8 |
| Link RAM, 2 KB, backed and never exchanged | 2,048 | 16,384 | 2 |
| Five FX68K micro/nano ROMs (1,024 x 17 + 336 x 68 bits each, 6 M10K each measured) | 25,160 | 201,280 | 30 |
| **subtotal** | **354,888** | 2,839,104 | **352** |
| Line buffers, six layers, double-buffered, 2 x 256 px x 16 bits, read 4 px/clock | — | 49,152 | 24 (two blocks per buffer) |
| Instruction line caches, five x 16 bytes | — | 640 | 10 |
| **subtotal with video front end** | | | **386** |
| Sound work RAM, 128 KB | 131,072 | 1,048,576 | **0 — SDRAM** |

**352 of 553 before any framework RAM, 386 after the line buffers and caches.** The framework's
own memories (`video_mixer`, `scanlines`, `hq2x`, `osd`) are not in the table because they have
not been fitted in this project; the sibling cores' first fits put them in the region of 30–45
blocks, leaving roughly **120–135 blocks** for the sprite line engine, the mixer datapath
pipeline, jt51 and jt6295.

**The one to watch: the scroll RAM window.** 96 blocks is the single largest item and it exists
only because a power-on RAM test may walk the whole 32 KB the map declares
(`LESSONS_LEARNED.md`, "Back the RAM a power-on test walks at the size the map declares"). Only
the first 16 KB is read for drawing. If the first fit is short, the upper halves go to SDRAM —
they are never on the video path. The palette (32) and the main work RAM (64) are the next
candidates, in that order, both only after a measurement.

## Memory plan

32 MB SDRAM module, flat map, on `clk_mem` = 96 MHz. The RTL localparams are the source of truth and
the `.mra` generator reads them. On the chip, `sdram_sched.sv` puts byte address bits 4:3 in the bank,
so consecutive granules alternate banks; row bit 11 is address bit 23.

| Base | Size | Region | Clients |
|---|---|---|---|
| `0x0000000` | 1 MiB | main program (512 KB first half + 512 KB second half) | main 68000, CPU 1 fetch |
| `0x0100000` | 512 KB | road1 CPU program (256 or 512 KB used) | road1 68000 |
| `0x0180000` | 512 KB | road2 CPU program | road2 68000 |
| `0x0200000` | 512 KB | io CPU program (512 KB used on f1gpstr2, 256 KB on wildplt) | iocpu |
| `0x0280000` | 256 KB | sound CPU program, bitswapped at load | sound 68000 |
| `0x02c0000` | 512 KB | scroll0 gfx | tilemap 0 |
| `0x0340000` | 512 KB | scroll1 gfx | tilemap 1 |
| `0x03c0000` | 128 KB | scroll2 gfx | tilemap 2 |
| `0x03e0000` | 128 KB | sound work RAM (runtime, 64 or 128 KB window) | sound 68000 |
| `0x0400000` | 6 MiB | sprite gfx, untangled at load | sprite engine |
| `0x0a00000` | 2 MiB | road0 gfx | road 0 |
| `0x0c00000` | 2 MiB | road1 gfx; aliased to road0 on bigrun and cischeat | road 1 |
| `0x0e00000` | 512 KB | OKI #1 samples | jt6295 #1 |
| `0x0e80000` | 512 KB | OKI #2 samples | jt6295 #2 |
| `0x0f00000` | 17 MiB | free | — |

**Used 15.0 MB of 32 MB.** Sizing rule: each region is the largest loaded size any set needs, so
`f1gpstr2` fits without a per-set map. The sprite region is 6 MiB because `f1gpstr2` loads 6,291,456
bytes; `bigrun` uses 2.5 MiB of it and `cischeat` 4 MiB.

**DDR3 is used for two clients, both standard**: the HPS writes the ROM image into the DDR3 window
at load time and the core copies it to SDRAM before reset is released, and the HDMI rotator
(`screen_rotate_two`) uses it while the core runs. The rotator is the framework's standard HDMI
rotation path and the only runtime DDR3 user; the game logic and the video front end never address
it. **No core client reads DDR3 during play** — 15 MB against a 32 MB module leaves no reason, and
`references/ddr_rom_loading.md` treats runtime DDR3 on a 16-bit-era board as a design smell.

**Load-time transforms in the download path**, before the bytes reach SDRAM:

1. **Sprite untangle**, every set (`cischeat_untangle_sprites`, 1938-1955). Every 128-byte block
   becomes 16 rows of 8 bytes: row `i` = source bytes `4i..4i+3` then `64+4i..64+4i+3`. A 128-byte
   staging buffer and a reordered write.
2. **Sound ROM bitswap**, every set (`ms1_gatearray.cpp` 44-92): a 16-bit lane permutation
   selected by word index range over the whole 256 KB sound region. One word in flight.

**Per-scanline fetch budget.** 3,072 `clk_sys` clocks per line, 8 per visible pixel; the SDRAM
serves 401 granules a line (above). The estimate below assumed 768 at 48 MHz, one granule per 4
clocks, which the controller does not do. Measured in play from MAME frame 900: up to 293 a
line, video alone up to 202, counting each cache line fill as two granules (`docs/PHASE2.md`).
Background clients, 256 visible pixels:

| Client | Granules per line | Derivation |
|---|---|---|
| three tilemaps, 16x16 mode | 60 | 16 tile words (4 granules) + 16 tile rows (16 granules) each |
| two roads, fixed width | 32 | 32 8-pixel tiles x 4 bytes each |
| sprites | ≤ 96 | cap: 768 bytes of gfx per line |
| **video total** | **188** | 24% of the line |
| five CPUs, worst case with line caches | ~ 190 | 3 M granules/s, see below |

The CPU row is the design constraint. Without a cache, a 68000 at 10 MHz can request one 16-bit
word per 2 clocks — 5 M words/s, and a granule serves one word — which is 5 M granules/s per CPU
and 25 M/s for five, three times the line. With a **16-byte instruction line cache per CPU** a
granule serves eight words, so the same fetch rate costs ~0.6 M granules/s per CPU, about 3 M/s
for five, or 190 granules per line. That is the reason the cache is planned from the start rather
than added later. Data accesses to on-chip RAM never leave the chip.

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no PCB
here. MAME is the accuracy target and its acknowledged guesses are inherited deliberately. Each
goes in `docs/MAME_KLUDGES.md` when it is implemented: the odd-frame IRQ1, the missing screen
control register, sprite lag, Wild Pilot's road, and the draw sequences in `screen_update_*`.

**Where a vendored module and MAME disagree, record it and keep the module.** A silicon-derived
disagreement is evidence about the chip; MAME's is evidence about MAME. It goes in
`docs/MAME_KLUDGES.md`, not into a "fix", until one side is shown to describe the chip.

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands, with
what would make it correct. The pixel clock hypothesis is the first entry.

**Transcribe the reference literally first, then look for the chip.** Build MAME's version, get
pixel-exact agreement with captured references, and only then experiment — with the experiment on
an OSD switch so it is an A/B, not a rebuild.

**One `.rbf` for all games.** Per-set differences are `.mra` mod-byte configuration.

**Two Quartus revisions, `Cischeat_stp` and `Cischeat`,** differing only by a `DEBUG_ISSP` macro.
See [`WORKFLOW.md`](WORKFLOW.md).

**Licence: GPL-3.0-or-later.** Every dependency, what it obliges and the release checklist are in
[`THIRD-PARTY.md`](../THIRD-PARTY.md), to be written in Phase 0. `sys/` is never edited.

**Per-scanline rendering from buffered sprite RAM.** The default shape, as the boards worked: the
sprite list is latched once a frame, a per-scanline engine builds one double-buffered line buffer
per layer, and a mixer composites the passes in the driver's order into the output line. No frame
buffer anywhere; no board here had one, and `LESSONS_LEARNED.md` (Fuuki) says not to add one.

**No multiplies, no divides, in 2D pipelines.** Shifts, masks, adds and accumulators; WORKFLOW §14.
Both zoomers use the driver's integer arithmetic (`(x << 16) * (z & 0x1ff) >> 7`), which is a
shift-add on a small constant.

**FX68K, five instances, and no second CPU option.** Cycle-accurate, 2,086 ALMs and 6 M10K each,
130.7 MHz; 25% of the logic for five. It costs 30 M10K, four blocks per CPU more than TG68K.C,
which is why the scroll RAM window is watched. It is microcoded, so the area is in the two ROMs
rather than in the datapath.

**A 16-byte instruction line cache in front of each CPU's SDRAM fetch.** Eight 16-bit words plus a
tag, no write-back (program ROM is read-only, so a cache is invisible to the program), 2 M10K per
CPU. The arithmetic above says the design does not meet its line budget without it, and it does
not change bus-visible behaviour, so it cannot affect MAME agreement.

**48 MHz `clk_sys`, SDRAM at 96 MHz, pixel clock 6.000 MHz.** Every board clock divides 48
exactly and the pixel clock gives 15.625 kHz. The SDRAM runs at twice that on a measured
shortfall (Clocks, above).

**Line-based video, six double-buffered layer line buffers, a pass-ordered mixer.** Each layer
fills its own line buffer during the line; the mixer then walks the driver's draw sequence,
reading only the layers a pass covers, at 4 pixels per clock. Each 256x16 buffer is split across
two M10K so that its ports can deliver four 16-bit pixels per clock, hence four blocks per
double-buffered layer: 6 x 2 x 256 x 16 bits = 49,152 bits, 24 M10K. Shadows blend against
whatever the earlier passes left, which is what the painter's algorithm gives for free.

**Sound work RAM in SDRAM, everything else on-chip.** It is the largest RAM (128 KB), the most
latency-tolerant client (a 68000 at 6 MHz has 32 clocks per bus cycle), and the only one whose
loss does not touch video. KonamiGX's `GX_T34` build is the precedent.

**ROM transforms at load time, not at fetch time.** Both are 128-byte or 2-byte permutations over
a region written once; fetching through them would put a permutation in the pixel and instruction
paths for ever.

**Road gfx stored once where `ROM_START` loads it twice.** Big Run and Cisco Heat build `road1`
from the same files as `road0`; the mod block's "aliases" flag points both layers at one 1 MB
region and the `.mra` omits the duplicate loads.

**Out of scope: cabinet linking and motion outputs.** The link RAM is backed and never exchanged;
motion registers are latched and ignored. The README and the OSD say so; there is no fake link.

## Pitfalls that already bind decisions here

Entries from [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) that are not general advice but already
constrain something written above. Read the entry, not the summary.

| Entry | What it binds here |
|---|---|
| [Seta] Sanity-check a reported clock against the board | MAME's implied 3.93 MHz / 256-pixel line is the reason for the 384x260 hypothesis, not an accepted fact |
| [Seta] An unbacked RAM region does not read as garbage, it reads as a failed power-on test | The scroll RAM window is 32 KB, the io and road local RAM 16 KB, and the io shared RAM 4 KB, at the sizes the maps declare |
| [Seta] Back the RAM a power-on test walks at the size the map declares, even the part nothing else uses | Same: the upper 16 KB of each scroll window is backed even though only the first 16 KB is drawn |
| [GX] An `initial` value on a register array is not a power-up value | MAME fills every scroll RAM word with `0xffff` at reset (`ms1_tmap.cpp` 130-137) and powers the rest of RAM up as zero; the core writes both at reset instead of relying on `initial` under Power-Up Don't Care. Without the scroll fill, Big Run shows an opaque pen after a bump |
| [HyperNG64] Check a large set's regions for byte-identical copies before sizing memory | `road0 == road1` on bigrun and cischeat, 1 MB each; the SDRAM map stores them once |
| [Seta] A snapshot is a race with whoever writes the thing being copied | The sprite list is 4 KB of work RAM that the CPU writes all frame; it is latched once, at the end of vblank, and never read live |
| [Seta] Latch the sprite list and the video registers at the same point unless evidence separates them | Scroll registers and the sprite list are latched together at vblank end; MAME's `VIDEO_UPDATE_AFTER_VBLANK` is the evidence for that point |
| [Fuuki] Buffer the sprite list and render per line; do not add a frame buffer | The video architecture: six line buffers and a pass-ordered mixer |
| Choose SDRAM over DDRAM for hard real-time fetch budgets | No runtime DDR3 client; DDR3 is the loader and the rotator only |
| Derive the clock-enable ratio exactly rather than rounding | 10 MHz is 5/24, YM2151 is 7/96, and the two are the reason 48 MHz works |
| [Seta] Read the interrupt vectors before trusting a board's interrupt config | Phase 0 reads the vector table out of the ROM; levels 1, 2 and 4 must resolve to `0x64`, `0x68`, `0x70` |
| DTACK/ready must be a held level, never a pulse, for any clock-enabled CPU | FX68K runs on a 10 or 12 MHz enable inside a 48 MHz domain; DTACK is held until the last SDRAM beat arrives |
| A design can be BRAM-bound while logic sits at 40% | 352 of 553 M10K before video; the scroll window and palette are named as the first things to move |
| [GX] A one-cycle handshake into a slower clock-enabled domain must land on that domain's edge | Interrupts and bus resets from the main CPU land in the road/sound/io CPUs' 10 or 6 MHz domains |
| Publish an `.mra` only with the core it needs, in the same push | Eight sets share one `.rbf`; the release gates the `.mra` set on the `.rbf` build id |
| A `<dip>`'s `bits` is a range, "first,last", not a list | `-listxml` reports 17/16/21/20/13 named switch entries per set; generator and checker both parse `bits` as the loader's `sscanf("%d,%d")` does, and the result is compared with `-listxml` per set |

## Phased roadmap

**Phase 0 — Vendoring spike and the measurements. The gate.**

Vendor jt51, jt6295, the SDRAM controller and download path, the DDR3 loader, CRT Adjust, hiscore
and the dual-port RAM wrappers into `rtl/`, each with a `PROVENANCE.md`. Run every upstream
testbench that exists, unchanged, before editing anything. Stand five FX68Ks, one bus wrapper,
the line cache and a behavioural SDRAM behind the cischeat program ROM in `rtl/synth_check/` and
fit it.
Exit criteria:

1. **Every vendored module's own tests pass unchanged, on arrival.** jt51 ships a conformance
   bench (`ver/jt51_con`, with its own test programs); jt6295 ships none in the tree vendored
   here and FX68K ships none (KonamiGX drives it through `sim/gx_boot_tb`). FX68K's regression
   is criterion 2; jt6295's is Phase 3's register-write trace against MAME.
2. **The CPU boots the first target's program ROM and matches MAME's bus trace**, diffed access by
   access, every peripheral stubbed to what MAME's returns.
3. **Measured CPI on real game code** at 10 and 12 MHz, split between execution and memory stall,
   with the line cache in and out.
4. **Standalone Fmax and area for five CPUs** at this project's settings, with the constraint that
   proves it committed in the same commit as the measurement. One and four are already measured;
   five is not.
5. **The two load-time transforms are proven against MAME**: an image built from the `.mra` and
   passed through the RTL download path equals MAME's decoded `soundcpu` region and `sprites`
   region byte for byte, on cischeat and bigrun.

**Phase 1 — Video, against a software model.**

Build the MAME capture pipeline first. Start with the video-write sweep (`write_timing.py`) over
`0x80000-0x87fff`, the scroll registers and the sprite list: it confirms the latch point and shows
what the screen-control stub ignores before any buffer is wired. Then `mame_capture.py` plus a
`render_model.py` that reproduces the driver's `screen_update_*` behaviour, including the draw
sequence; get the model pixel-exact on captured frames, then check RTL against the model layer by
layer: each tilemap mode, each road variant, both sprite formats, the shadow pen, and the
pass-ordered mixer on all three board sequences, on scenes that exercise every priority window.
Exit criteria: the first target renders frames pixel-identical to the software model's for a
captured set of scenes, silent, in simulation, comparing the 224-line window. The model is MAME's
draw order with the core's single sprite zoom accumulator in place of MAME's per-tile sprite
scaling (amended by the user's decision to keep the accumulator); every place the model differs
from MAME is in `docs/HACKS.md` with its pixel count against MAME's screenshots (216 lines on
Cisco Heat, where MAME cropped the last 8).

**Phase 2 — Hardware bring-up and the first game.**

SDRAM backend with all clients on one arbiter, the ROM download path with both transforms, `.mra`
generation for `cischeat`, inputs (wheel, digital accelerator, brake, gear, horn, and Pause, which
suspends the main CPU), DIPs, the ioctl and OSD plumbing, the ISSP probe and the OSD debug page.
The standard feature set: CRT Adjust (v-size included — the budget allows it), hiscore, fast DDR
ROM loading, HDMI scaling and crop, HDMI rotation, audio mix, HDMI-only options hidden under
direct video, and CRT Adjust parameters hidden until enabled. No core flip screen, on the user's
decision (the game has none); Flip 180 is the HDMI rotator's.
Exit criteria: `cischeat` boots and plays on a DE10-nano, silent, at 60 Hz, with coin, start,
wheel, accelerator, gear and brake working and the DIPs matching the driver.

**Phase 3 — Sound.**

Sound CPU with the bitswapped program and its work RAM in SDRAM (64 KB on cischeat and bigrun,
128 KB on the F1 GP Star family), its two latches, both M6295 bank registers per board, the YM2151
with `cen` = 3.5 MHz and `cen_p1` at half, mixed at MAME's levels into the framework's 48 kHz
audio. Exit criteria: register-write traces captured from MAME
reproduce correct audio, by ear and by a decoded capture against MAME's output.

**Phase 4 — The rest of the list, and accuracy.**

`bigrun` and `bigrunu` (Big Run sprite format, 8,192-entry palette, second main map), then
`f1gpstar`, `f1gpstar2`, `f1gpstar3` (zooming roads, 12 MHz CPUs), then `f1gpstr2` and `wildplt`
(the io CPU, sprite DMA, AD-stick inputs). Extend `scripts/extract_dips.py` to fold a multi-bit
`PORT_CONDITION` into its switch labels, which six of the eight sets need; verify each `.mra`'s
DIP block against MAME's `-listxml`. `docs/MAME_KLUDGES.md` and `docs/HACKS.md` are the deliverables
that say what is still not right and what would settle it.

**Phase 5 — Cabinet linking and motion feedback. A decision with evidence rather than a default.**

The board supports 2–4 linked cabinets and drives seat and wheel motors. Linking needs a transport
the framework does not provide; motion output needs hardware a MiSTer cannot feed. The default is
**not built**, and this phase records why, with the register traces that show the games run
single-cabinet (the link RAM is backed but never exchanged, so the link test takes its "no
partner" path). Re-opened only if the user asks.

**Phase 6 — Savestates, state dumps and cheats.** Optional but desirable. Not before Phase 4, but
the RTL is written for it from Phase 1 (`references/savestates.md`): reachable RAM ports, a
`docs/STATE.md` inventory, addressable chip state, and FX68K's `stop_out` already exposed for it.
The state dump and its simulator loader are worth building before the savestate itself, because
they make hardware bugs reproducible in a bench. **Proposed: savestates brought forward into
Phase 2** (`docs/SAVESTATES.md`, steps S1 with Phase 2 step 3 and S2 with step 6); cheats stay
here.

## Verification strategy

- **MAME is a reference generator, driven from scripts, not a thing to eyeball.** Boot traces, VRAM
  and register dumps at known frames, palette dumps, register-write logs. WORKFLOW §9 applies.
- **The reference MAME is `E:\MAME-Checkouts\mame-0289-wildplt\cischeat.exe`** at commit
  `781b31b376b` (Cischeat's `MAME_DIR`/`MAME_EXE`/`MAME_SRC` in `~/.mister-core.env`). Against
  stock 0.289 it swaps the main CPU's two road shared-RAM windows on every board and changes
  `screen_update_f1gpstar`'s backdrop and road 1 priority 6-7 transparency. The core follows the
  backdrop change, and the swap on Wild Pilot only (`docs/HACKS.md`).
  Captures, savestates and `debug/` images made with stock 0.289 predate the swap: 0.289
  savestates do not load in it.
- **The software model comes before the RTL.** The model is checked against MAME first; the RTL
  against the model.
- **Every vendored module is verified against MAME before it is wired to anything**, and its own
  testbench is the regression for every later change to it.
- **Layouts are verified before ROMs are involved**: every `gfx_layout` gets the "every bit of a
  tile exactly once" check, and the sprite untangle is checked as a permutation (each of the 128
  input bytes appears once in the output block).
- **`.mra` files are generated, not written**, re-read byte-for-byte against an image built from
  `ROM_START`, and gated on an XML well-formedness check before deploy.
- **Worst cases are measured in the RTL**, not modelled: the per-line sprite count and fetch
  overrun, the CPU stall counts, and the mixer's pass count, each paired with a total.

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer**: `Template.*` is renamed to `Cischeat.*`, split into
the `Cischeat_stp` and `Cischeat` revisions, and the Quartus 13 project is dropped. Both
revisions and `Cischeat.qpf` already exist in the repository. Quartus **17.0.2**. Conventions
are in [`WORKFLOW.md`](WORKFLOW.md).

## Open items

**The pixel clock is a hypothesis: 6.000 MHz, 384x260, 60.096 Hz.** MAME declares none and its
`set_size(256,256)` implies 3.93 MHz, which cannot be right for a 1989 board. 6.000 MHz is 24/4,
15.625 kHz and 60.096 Hz, and it is the only whole-clock divisor of 48 MHz that gives an integer
number of clocks per pixel and per frame. What closes it: an H-sync measurement on a board or a
capture with a known pixel clock. Until then it is in `HACKS.md` and nothing else depends on it —
the visible 256x224 window is what gets compared (216 lines on Cisco Heat).

**The screen control register is unidentified.** MAME has a write-only stub at `0x82400` and
always draws every layer. What closes it: a video-write sweep in MAME (or footage) correlating a
write to `0x80000-0x87fff` with a layer appearing or disappearing. Until then the core draws what
MAME draws, and logs the writes.

**Interrupt generation is MAME's guess.** The driver says so (`irq generation is unknown`), and
records that IRQ1 on odd frames is what makes Big Run's service mode work while calling IRQ2 every
frame desyncs its attract mode. What closes it: a logic-analyser capture of IPL0-2 on a board.
Until then the core reproduces the guess.

**Sprite lag frames are unverified.** MAME renders after vblank; the core latches the list at the
end of vblank. What closes it: a scene where a sprite moves across the vblank boundary, compared
frame by frame.

**Wild Pilot is `NOT_WORKING` in MAME** ("busted timings", empty road gaps, a floating ship). It
is parked: its `.mra` is in `releases/unsupported/`, outside the Downloader database, and work on
it stops until the other sets are done. There is no correct reference to follow; only a driver fix
or a PCB would give one. MAME's TODO places the
gaps and the floating ship in stage 6 (`cischeat.cpp:133`), which attract never shows: MAME's
attract frames 0-6000 (stages 1, 2, 3, 5) have no visible road gaps (`scripts/mame/roadsnap.lua`,
`debug/wildplt_mame_sheet.png`). The core's Wild Pilot bench has covered frames 0-330 only, before
the first road scene (MAME frame ~1460).

The sixth boss's stage (harbour and open sea, still labelled "STAGE 1") is reached by holding the
slot count (word) at `0xf0114` and `0xf021a` through the WANTED screen
(`scripts/mame/wildplt_stage.lua`; a MAME 0.289 state at frame 1900 is
`debug/wildplt-stage6/stage6.sta`). At frame 1950 the floating ships are sprites placed there by
the game, not a road fault: the sea (road 1) starts at line 171 and the city tilemap meets it, but
the warship sprites (code `0x4c1c`) have bottom y 62 (zoom `0x9a`), 85 (`0x5c`) and 101 (`0x33`),
and a far ship (`0x0aa8`, zoom `0x14`) 116. The nearest ship is the highest, the reverse of the
perspective the sea follows. Road 0's lines there (prio 0, zoom word top nibble `0xf`, codes
`0xf80-0xfff`) draw nothing because those ROM lines are blank, so they are not the gap either.
Open: where the main CPU computes the ship y, and whether it reads a value the road CPUs write
(a cross-CPU timing would fit the driver's "busted timings").

PCB reference: camera recordings of a cabinet at the Misaki Park game corner by どえんどえん,
https://www.youtube.com/watch?v=-O3bBgPV0gg (all bosses, eased settings, no seat motion) and
https://www.youtube.com/watch?v=zTCjQUqig2w (factory settings, seat motion). In the first, the sea
segment at 2:16-2:58 has the sea filling the screen from about mid-height down, and the warships
sitting on it at the horizon (2:30, 2:40; `debug/wildplt_pcb_sea_2m30_2m40.png`). In MAME, the city
tilemap fills that band and the ships float in it.

Where the sea is in RAM at MAME frame 1950 (`wildplt_stage.lua`, `CORE_RAMAT`, `CORE_TAP`): sea
records (code `0x300-0x3ff`, colour `0x28-0x2f`) exist only in road CPU 2, as a 54-record list in
its local RAM at `0x182b50` and lines 187-239 of its road RAM. Main RAM, both shared RAMs and road
CPU 1 hold none. Road CPU 1's lines 56-124 (prio 0, zoom word `0xf0e3-0xf1e6`) use codes
`0xf80-0xfff`, which are `0xff` fill at the end of the fourth ROM of both road sets, so they draw
nothing on the board too. The sprite list is not truncated: 37 of 256 entries are enabled, and the
game's working copy at `0xfb000` holds the same sprites. Tilemap 0 is the city, opaque over the
band; tilemap 1 the clouds; tilemap 2 the HUD. The game never writes `0x82400` (MAME's
`active_layers_w`), and the tilemap flags are only written at boot and at `0x82004 = 2` on stage
start. So, in MAME's run, the game itself puts the sea's horizon at line 187.

The horizon follows the main CPU's camera pitch. The main CPU copies `0xf0202-0xf0221` to both
road CPUs' parameter blocks (`0x90002`, `0x98002`) at PC `0xa4a2`, adding offsets from
`0xf4d00-0xf4d07`; the pitch word `0xf0216` lands at shared `0x80016`. Road CPU 2 copies it to
`0x1800b4` and uses it as the vertical offset `0x180074` in its projection (`0x59f6-0x5a2c`); road
CPU 1 uses a constant there (`0xbd`). Pitch over stage 6 (`debug/wildplt-pitch/pitchv.txt`): 0 up
to frame 1700, swinging to `0xfc0d` at 1790-1900 and back to 0 at 2030, then to `0xf5d8` (2250)
and `0xeee9` (3290). The sea's first visible line is 131 at pitch 0 and 189 at `0xfc0d`;
tilemap 0's (city) y scroll moves 28 lines over the same swing (`0x203` to `0x1e7`), tilemap 1's
66, and the nearest warship's sprite y stays at about `0x8d`. Forcing road CPU 2 to read pitch 0
at frame 1950 puts the sea at line ~105, under the ships (`debug/wildplt-pitch/p0.png` against
`pnone.png`). Frame 1950 is mid-tilt; at pitch 0 MAME has the sea from mid-height (`t2100.png`).
The main CPU writes the parameter block every second frame in MAME.

The PCB video's stage 2 (2:07-2:58) is not this stage. Its WANTED screen names Jack the Slasher,
which is boss index 4 ("ATLANTIC OCEAN"; `wildplt_stage.lua` with `CORE_STAGE=5`,
`debug/wildplt-stage5`). Indices 0-5 are Shotgun Jones, Giant Lee, Marie Vixen, Graham Remington,
Jack the Slasher, Harold Trickster. On index 4, MAME and the board match through takeoff, the tanks
along the runway and the hangars (PCB 2:11-2:13.5, MAME frames 1980-2040). Then the camera pitches
up to `0xf447` (MAME frame 2130). On the board the hangars and runway slide off the bottom and the
screen is sky and clouds (2:14.5-2:25). In MAME the tree tilemap slides down the same way, but
the runway stretches up the screen and sea bands sit at the top (frames 2070-2340,
`debug/wildplt_idx4_climb_mame.png`). These are road CPU 2's lines, not a drawing fault. At frame
2220 its list has sea (codes `0x353-0x3a0`, colour `0x2a-0x2b`) on lines 19-63 and runway (codes
`0x72c-0x7cb`, colour `0x08-0x0b`) on 64-239. This is the visible Wild Pilot road fault to match
against.

How road CPU 2 places those lines (index 4, frame 2100; `debug/wildplt-proj/proj2.txt`). Each track
point's screen line is `((h + pitch) * depth) >> 14` plus the horizon `0x18010e`
(`0x59f6-0x5a3c`, `0x6230`). Here `h` is the point's height minus the camera's (`0x180040`), and
depth is `($bc,A3)`. In this scene the camera height is taken from the track at the camera's own
distance (`0x4ae0-0x4af0`), so `h` is 0 (`0x14e - 0x14e`). The flag `0x18009a` is 1, which
skips the rotation term. That leaves `pitch * depth`. With the pitch negative (`0xf598`), the
nearer the point, the higher its line, so the runway comes out as a ceiling above the horizon,
which is MAME's picture. The list is rebuilt over two frames (lines 159-223, then 2-158; PCs
`0x615c`, `0x6208`) and fully rewritten each time, so these are not stale lines. The shared
mode word `0x80018` is 1 throughout. The main CPU writes it at line 244 of odd frames and road
CPU 2 reads it at line 47 of even frames (`flag.txt`), so it does not depend on timing. No MAME
timing effect has been found on this path. Open: whether the board's main CPU sends a different
pitch or mode here, or its road chip drops these lines; the road RAM words carry no bit that sets
them apart from the sea lines it does draw.

The main CPU's side (`debug/wildplt-proj/mainw.txt`). It writes the camera block every second
frame: `0xf0216 = -($c,A6)` of the camera object (PC `0x31278`), and `0xf0214 = ($c,A6) >> 5`
(`>> 4` when `0xf0114` is 0). `0xf0214` reaches road CPU 2 as `0x1800b2`, which builds the per-line
table at `0x1813be` (`0x87e4`). Road CPU 2 adds a track slope to the pitch and caps the sum at
`+0x2f` (`0x8894`). The camera object's script is picked by `0xf0114` from the table at `0x2fd00`
(`0x31244`). `0xf0114` is not a boss number. It is the count of leading non-zero words in the
10-slot list at `0xf0b82` (PC `0x2abc`), and `0xf021a` copies it at stage start (`0x31782`). Forcing
`0xf0114` from the Start press on therefore gives the game's own camera and track for that slot;
the only state left inconsistent is the `0xf0b82` list. Forcing `0xf021a` alone gives a mix (Giant
Lee's WANTED and airport with index 4's sea; `debug/wildplt-b4`). Nothing found on the main CPU
explains the board's view. The camera path is scripted, and the climb takes about 1.5 s from the
hangars to full sky on both (PCB 2:13.5-2:15, MAME frames 2040-2130).

Forcing both road CPUs to read `0x18009a` as 0 (`debug/wildplt-noflat4`, against stock
`wildplt-stage5`; `debug/wildplt_noflat4_vs_stock.png`) does not fix the climb. The runway still
stretches up the screen (frames 2070-2160) and the sea bands still sit at the top; the sea edge
moves a few lines. What `0x18009a` means is unverified: the name "flat mode" is a guess from this
one code path. Open: trace how the F1 GP Star and Big Run road programs set and use it.

What differs is the road priority, not the geometry. Forcing road CPU 2's pitch on index 4
from -500 to -4000 (`debug/wildplt-sweep4`) moves the runway down and off the bottom, then the
sea, then grows sky and blank lines from the top: the list follows the pitch in the board's
direction throughout. The parameter path is a fixed pipeline (main CPU writes at line 244, road
CPU 2 reads at line 47 of the next frame, `debug/wildplt-proj/order.txt`). The runway and sea
lines are priority 0 on the ground (frames 1950-2010) and in level flight (2940, where MAME's sea
from line 136 matches the PCB at 2:30), and priority 1 from frame 2040, the first frame of the
climb, through 2550. Tilemap 0 is an opaque sky over the whole screen from 2100
(`debug/wildplt-climb/tmaps.png`). MAME draws road 1-5 after the tilemaps, so the runway shows
through the sky; drawn before them it is hidden, which is the PCB's picture. Drawing priority 1 before
tilemaps 0 and 1 in the core's F1 GP Star mixer (dfea419) was reverted on the user's decision: the
core follows MAME. The Graham Remington stage draws a priority-2 cloud deck over an
opaque tilemap-0 sky (`debug/wildplt-stage4/tmaps.png`, frame 1950) and no footage of that
stage has been found. The PCB video's bosses are Jack the Slasher (2:07), Marie Vixen (6:10),
Giant Lee (9:26), Gava Hornet (12:56) and Diamond Gordon (14:41); the boss list has ten slots.
Verification on the board: pick Jack the Slasher on the WANTED screen and watch the climb after
the hangars. The same change in MAME 0.289 (`E:/MAME-Checkouts/mame-0289-wildplt`, branch
`wildplt-road-prio`, `cischeat.exe`) gives the PCB's climb: sky and clouds only from frame 2070
(`debug/wildplt_climb_stock_vs_fixed.png`); ground, takeoff and level flight are unchanged
(`debug/wildplt_other_stock_vs_fixed.png`). It also changes the harbour stage (index 5), which
no footage covers: the priority-1 sea strip at the bottom (frames 1740-1960) is hidden under the
city tilemap, and the warships sit on the city's lower rows (`debug/wildplt_harbour_stock_vs_fixed.png`).
Whether the board shows sea there is open.

At full size the PCB's climb has four phases (`debug/pcb_climb_134_139.jpg`, `pcb_climb_1376_1386.jpg`,
`pcb_climb_1395_145.jpg`): clouds only (134.5-137.4), a full-width sea strip across the bottom
with a straight top edge and the cloud deck above it (137.6-138.2), sea through ragged holes in
the deck's lower edge (138.4-138.8), clouds only (139-142.5), then sea from mid-screen (143.0).
MAME's own sequence has the same four pictures in the same order at a slower pace: runway and
sea band at the top (2070-2300, the visible fault), cloud deck over everything (2310-2505), sea
strip at the bottom (2510-2550), all sky (2580-2820), return (2850-2880). So drawing road
priority 1 under the tilemaps is wrong after all: it hides the strip phase too, and tilemap 0 is
an opaque flat blue there (`debug/compose_strip.png`); the core's commit was reverted (02a3aee).
What reproduces the PCB in MAME is the road CPU reading a pitch about 2.6 times the main CPU's
(`debug/wildplt-gain26`, `wildplt_gain_sheet.png`; forced-pitch table at the strip's track
position in `debug/wildplt-sweep4b`: the PCB's strip top, line ~184, needs -4200; MAME's pitch is
-1600), with road 0 drawn before road 1 inside the 1-5 pass so the strip lies over road 0's
priority-1 clouds. The source of that factor is not found. Ruled out: the stick (moves the
crosshair, not the pitch); IRQ 4/2 every frame (the sequence runs 1.75x faster, same pitch
values and lists; the PCB's pace is about 1.5x MAME's); road CPUs at 24 MHz (same lists);
writes to `0x80014` (a 0/1/2 mux pattern) and `0x82108`; the frame-parity word `0x80018` (always
1; road CPU 2 toggles its copy to 0 before use, `debug/wildplt-proj/b6.txt`); the list entries
outside lines 16-239 (constant). A MAME 0.289 worktree with runtime switches is at
`E:/MAME-Checkouts/mame-0289-wildplt` (`cischeat.exe`; env `WILDPLT_P1U`, `WILDPLT_ROADCLK`,
`WILDPLT_IRQ=every`).

The main CPU's pitch is a ROM script and nothing else. `($c,A6)` of the camera object is a 16.16
accumulator: `0x9752` ramps a velocity `($20,A6)` by `($24,A6)` per step, clamped at `($28,A6)`,
and `0x31172` adds it to the pitch each pass; `0xf0216 = -(high word)`, `0xf0214 = high word >> 5`.
The (accel, vmax, duration) records come from the per-stage table at `0x2fd00`; index 4's script
is at `0x142970` in the user1 region (the `rom_regions` dump is byte-swapped). Its climb records,
`+243500 x20, 0 x20, -243500 x20` steps, integrate to 3046 units, MAME's measured -3002, and the
231 steps before them place the climb 462 frames after stage start, as in MAME. Durations count
IRQ 4 steps, so the IRQ cadence sets the pace and not the values. No input, DIP, seat or timing
term enters it. The main CPU's `0x80014` writes are the analog mux select, mirrored from
`0x80010` in a three-phase read (channel 0 is the motion seat's position pot, OUTPUT CHECK's
"UP/DOWN VR."; MAME returns 0xffff and the game keeps the old value, used only by the test
screen). What remains is the road CPU's conversion of pitch to lines (`0x4e66` loop, `0x59f6`,
`0x5a3c`, `0x6230`) or the road hardware's vertical mapping. Scaling the script data itself (accel
and vmax of all 1491 records under `0x2fd00`, x2.5, patched into user1 at load) does not match:
the pitch peaks at -7500 and holds at -4000, tilemap 0 (fed by `0xf0214`) scrolls to dark navy,
the cloud deck and every sea phase are gone (`debug/wildplt-scale25`,
`debug/wildplt_scale25_sheet.png`). The factor belongs to road CPU 2's path only, as the
read-side gain had it.

Road CPU 2's line placement is a pure function of the 32-byte block. A read tap over its whole
map outside ROM and work RAM (`debug/wildplt-r2reads/r2reads.txt`, boot to frame 2600) finds
reads of `0x80000-0x80021` only (copied to `0x1800a0` at `0x486`), the boot RAM test, and the
handshake words `0x80072/74`: no unmapped or hardware reads. Per depth step k (93 steps, z from the
table at `0x8a28` plus camera z `0x1800ae`): `0x5876` gives the track height there; `0x59f6`
takes `v = height - 0x180040` (ground height under the camera, 334 rising to 936 through the
climb), rotated by `0x180050/52` unless `0x18009a`, then `v += P` (`0x180074`, from `0x1800b4` =
`-pitch`, plus a track term at `0x8894` clamped to <= 0x2f); `y = (v * S[k]) >> 14` with `S` the
table at `0x8ae4`. `0x5a3c` adds the running line and `T[n] = -n * Q / 128` (`0x87e4`, table
`0x1813be`), `Q = 0x1800b2` = main `0xf0214` = pitch >> 5. The gain that reproduces the PCB
scales P only. `0xf0218` (road `0x80018`) is not a parity word: per stage it selects the
altitude-delta path (`0x4bd0`); for index 4 it is 1 until track position `0xf0118` reaches 50000,
which the climb (positions 8400-24000, `debug/wildplt-pos/pos.txt`) never does. With these ROMs,
MAME's road CPU 2 output is what the board computes for the same block, and the block is
deterministic. The difference is therefore after road RAM (road chip rendering) or in ROM
contents: the set mixes `ver1-4` program ROMs with `ver1-0` road CPU and user1 ROMs, and a road
CPU program with a different `S` table or shift would scale P alone (untested; needs a dump of
another board's road CPU ROMs).

The road chip's rendering does not account for it either. `jaleco_zoom_road_device::draw` puts
entry y on screen line y and ignores w0 bit 15, w1 bits 10-15, w2 bits 14-15 and w2's low byte,
and uses w3 whole. Over 238 climb frames (`debug/wildplt-climb2`) w0 bit 15 and w3 bits 12-15
are never set. w2's low byte is a gradient (0x38-0x3d) on the priority-7 sky lines and 0xff on
every other line. w1 bits 12-15 are 0xf when bit 15 of a track segment's word `($18,A2)` is set
(`0x5bb6`, `0x5f74`); these are the cloud-deck lines, and hiding them removes the deck and shows
runway and sea (`debug/compose_hidef.png`), so the flag does not mean "skip". None of these fields
can move the horizon in proportion to pitch, and level flight (frame 2940) matches the PCB
unshifted. What is left is ROM contents.

Taking the ROMs as correct, further facts. The two road CPUs do not get the same block: `0xa4c8`
adds per-road offsets `0xf4d00-07` to the Q and P words (`0x90014/16` road CPU 2, `0x98014/16`
road CPU 1). They come from track-position tables (`0x43690`, four channels on `0xf0118 >> 9`).
Through the climb road CPU 2's Q gets -360 (frames 2060-2540, Q about -410 against road CPU 1's
-50) and road CPU 1's Q gets -168/-240 from 2300; the P offsets stay 0
(`debug/wildplt-offs/offs.txt`). On stage index 4, `0xa502` writes `0x9800c = 0`, switching road
CPU 1 off, for positions 0x4268-0x4844 (frames about 2470-2550, the sea-strip phase). Tilemap 0
is its own scripted object (`0x44a60`, `0x44b1c`) with a clamped vertical scroll; from 2345 it
is parked at (0,0), flat blue (`debug/tmap0_full_climb.png`). The pitch script and track
position both advance once per game step (`0xf0174` is 0 during the climb and only rises near
the stage end, `0x301b2`), so interrupt timing cannot shift the climb against the terrain.
Flipping the sign of P on road CPU 2 alone gives the PCB's first phase (trees at the bottom
edge, then clouds only), the cloud deck and the sea from mid-screen on the return, but no sea
strip (`debug/wildplt_signflip_fine.png`); flipping road CPU 1 as well, or swapping the two
shared RAMs, garbles the picture (`debug/wildplt_signflip_both.png`,
`debug/wildplt_swapshare_sheet.png`). Neither the gain nor the sign flip has a mechanism. No
wiring gives the flip: the block (`debug/wildplt-block/block.txt`) holds the pitch only as -P
(+0x16) and Q (+0x14, about P/32 plus the offset); no word carries +P for an address-line swap to
select, and inverting or byte-swapping the data bus would also change the `0x80000 == 1`
handshake word, which the road CPU waits on at `0x432`. A single inverted address line A1-A5
between the sides would make the road CPU read P from +0x14 (Q), +0x12 (camera z low word), +0x1e
or +0x06 (both 0), never +P, and would move the handshake word to +0x02/04/08/10/20, all 0, so the
road CPU would never start; a line above A5 does not touch the block. The MAME worktree has the flip as a switch, `WILDPLT_P2NEG=1` (a read tap negating road CPU 2's `0x80016`, branch `wildplt-road-prio`); takeoff, hangars and level flight are unchanged by it (`debug/wildplt_p2neg_sheet.png`). Played, it fixes one stage and breaks another. Every stage's script keeps P (`0xf0216`) in [-4375, 0] (integrated from the `0x2fd00` records; index 4 gives -3002, as measured), so no rule on P's sign separates stages. Stages differ in `0xf0218` (table at `0x31704`: 0 for indexes 1 and 2, which run the altitude-delta path `0x4bd0`), in the per-road offsets and in the track data. `WILDPLT_P2SM12=1` (bits 0-11 magnitude, bit 12 sign) brings back the runway in the sky and the sea band at the top on Jack's climb (`debug/wildplt_p2sm12_sheet.png`); a 13-bit two's-complement reading is the identity for |P| < 4096, every stage but index 5's deepest point.
Replays of the user's savestates (`wildplt_state.lua`, `CORE_STATE=1|2`): P2NEG breaks Graham Remington's stage (index 3, state 1) and Giant Lee's takeoff (index 1, state 2: the dome rises), where stock is right (`debug/wildplt_states_compare.png`). Negating Q (`0x80014`) for road CPU 2 instead gives the same Jack's-climb phases as the P flip, leaves Giant Lee unchanged (Q about -12, per-road offset 0), and changes Graham's arches (`debug/wildplt_states_qflip.png`). Negating only road 2's per-road part of Q (`0xf0230`; `wildplt_qtap.lua CORE_QMODE=off`, MAME switch `WILDPLT_Q2OFF=1`) gives the same Jack's climb as the full Q flip (`debug/wildplt_qoff_jack.png`) and the same Graham as the full Q flip (offset +40 there; `debug/wildplt_states_qoff.png`). Which Graham picture is right is unverified.
Savestates 4-7 (user's, `wildplt_state.lua`): 4 and 5 render identically with and without Q2OFF (per-road offset 0 in 4). The main CPU places ground sprites from each road CPU's line-y table (main `0x375c8`: road 1's at `0x985c0`, road 2's at `0x905c0`, bits 12-13 masked off), so sprites move with the road CPUs' output, not with the Q tap. In states 6 and 7 (index 5) road CPU 1's ground lines are priority 0 (drawn over sprites of priority 2 and up) with word 1 bits 12-15 = `0xf`, and hide the tanks (`wildplt_roadw.lua`, `debug/wildplt-sta6-roadw/roadw.txt`). MAME's `screen_update_f1gpstar` has no priority bitmap, only draw passes. MAME switch `WILDPLT_FPRI=1` draws a flagged priority-0 line in the priority-1 pass, under the sprites: states 6 and 7 then show the tanks on the road (`debug/wildplt_fpri_states.png`); states 4 and 5 barely change. State 8 (index 4, sea) is unchanged by it: road CPU 1's lines 108-235 use codes `0xfa1`-`0xfcf`, all pen 15 in both road ROMs, so road CPU 2's priority-7 gradient lines (codes 0-3) show through as stripes. `WILDPLT_PDRAW=1` replaces FPRI with a priority map: road lines and tilemaps write levels (road 6-7: 0, tilemaps 0/1: 1, road 1-5: 2, road 0: 3, tilemap 2: 4; a flagged line writes 2), sprites go in one pass front to back with `prio_zoom_transtable` (priority 2-7 under levels 3-4, priority 1 under 4, priority 0 over all). States 6 and 7 match FPRI (`debug/wildplt_pdraw_states.png`). User's rule, from savestates 6 and 9: sprite priority 3 and up behind a flagged road priority-0 line, priority 2 over it, 1 over 2, 0 over 1; MAME's draw ignores sprite priority between sprites (RAM order) and puts every sprite of priority 2 and up under road priority 0. `WILDPLT_PDRAW=1` now does this (`WILDPLT_FLAGPRI`, default 3, is the first priority behind the flagged line): state 9's troops and car and state 6's tanks show on the road, state 9's far trees stay behind it (`debug/wildplt_flagpri3.png`). Shadow sprites (attr bit 12) draw dark where MAME's pass order drew them light (state 9's road cracks). The game lowers an object's priority by one as it approaches (state 6, tanks 4 to 3 between frames 40 and 80). Object placement (main `0x37268`-`0x373d4`, `0x374a2`, `0x375c8`): each object's flag word (`d6`) bit 7 selects road CPU 1's tables (x `0x983c0`, y `0x985c0`) or road CPU 2's (`0x903c0`, `0x905c0`), indexed by distance through `0x1063c4`; bit 9 subtracts a height, bit 10 adds 1 to the sprite priority, and the sprite priority is `0x100 + (entry & 0x3000) >> 4`, so the road CPUs supply each distance's priority. `0x375c8` uses both tables (base from road 1, height from road 2 - road 1). The `0x8000c` low byte is a level from `0xf059e` (clamped to `0xff`, `0x7dee0`-`0x7df98`), not a priority table (`wildplt_dmareg.lua`). Swapping the tables the main CPU reads (`wildplt_ytabswap.lua`): state 4 with road 1's tables shows its enemies (car, helicopter, truck) on the runway; state 5 with road 2's puts the tank on the road (`debug/wildplt_ytab_swap.png`). So state 4's road CPU 2 table (P -833 there, altitude-delta path) and state 5's road CPU 1 table (rising 85 to 268 with distance) are the wrong ones. Both road CPUs copy a role flag from shared `0x80018` into `0x1800b6`; the main CPU writes the same value to both and road CPU 2 inverts its copy (`0x4678`), so exactly one road CPU has `b6` = 1. That CPU projects its own track (height `0x180040`) and adds its height minus the other CPU's (`0x180068`) to its camera height `P` (`0x4bd0`); the projection (`0x59f6`) is (point height - `0x180040` + `P`) times the distance scale. In both 4 and 5 the wrong table is the `b6` = 1 CPU's (`wildplt_pvars.lua`, `debug/wildplt-sta{4,5}-pvars/pvars.txt`: state 4 road 2 `P` -841 vs -58, state 5 road 1 `P` 269 vs -27). MAME switch `WILDPLT_SHARESWAP=1` maps road CPU 1's shared RAM at main `0x090000` and road CPU 2's at `0x098000` (MAME has the reverse for every board in the driver): state 4 shows its car, truck, helicopter and scenery, state 5 puts the tank on the road, states 2, 6, 7 and 9 keep their look (`debug/wildplt_shareswap.png`). With the swap, Q2OFF changes states 1 and 5 (arches as a row instead of a receding tunnel, `debug/wildplt_shareswap_q2off.png`); state 1 differs from stock either way (`debug/wildplt_sta15_variants.png`). Under the swap the objects read the `b6` = 0 CPU's tables, whose priority bits give sprite priorities one lower (state 6: 27 at 3 and 12 at 2 become 27 at 2 and 14 at 1, `debug/wildplt-sta6-sprpri-*/sprpri.txt`), so `WILDPLT_FLAGPRI=2` keeps states 6 and 7 as before; at 2 the flagged-line rule has no effect and the order is MAME's stock one with sprites sorted by priority (`debug/wildplt_swap_flagpri2.png`). The dashboard is tilemap 2 (`debug/wildplt_sta1_k280_layers.png`); with levels 0-5 OR-ed into the map, level 5 over road level 2 or 3 became 7 and state 1's near tank drew over it. PDRAW now uses one bit per covering layer, OR-ed as pdrawgfx expects (1 flagged road priority 0, 2 road priority 0, 4 tilemap 2), and each sprite's mask is the OR of the map values holding the bits that cover it (`debug/wildplt_orpri.png`). State 2, frame 1 after load: the bottom corners (lines ~212-224) are black because nothing draws there. Road CPU 2's lines 170-239 are priority 6, code 0, colour `0x70`, x scroll word `0x6fa6`; MAME takes it mod 2048 and draws one copy of the line, which lands off-screen to the left (`debug/wildplt-sta2-k1-rw/rw1.txt`). `WILDPLT_RWRAP=1` repeats each road line across the screen and fills them; `WILDPLT_P6UP=1` draws road priority 6 between tilemaps 0 and 1; `WILDPLT_OPAQUE` (pen 15 opaque on priority 1-5) changes nothing here (`debug/wildplt_rwrap.png`, `debug/wildplt_p6up.png`). Not checked against footage: video 1's takeoffs (0:16, 2:08, 6:13, 9:33, 13:03, 14:50) are other airports; video 2 not yet searched. The two road CPU programs differ (88098 bytes, `0x4ae`-`0x320f9`). `WILDPLT_LAYERS` (hex mask) isolates layers: on state 8 tilemap 1 is empty, tilemap 0 ends at line 105, and the stripes are road CPU 2's lines (`debug/wildplt_sta8_layers.png`). Unverified against the PCB.

The MAME worktree (branch `wildplt-road-prio`, commit `1b0e341c9c1`, pushed to `ppriest/mame`) changes `cischeat.cpp` only, with no per-set logic: Wild Pilot is `MACHINE_IMPERFECT_GRAPHICS` without `MACHINE_NOT_WORKING`; every board's main map has road CPU 1's shared RAM at the lower address, and `screen_update_f1gpstar` clears to road palette entry 0 (grey, 148,148,173) and draws road 1's priority 6-7 lines with transparency, in MAME's stock pass order. With the swap, Wild Pilot's sprites of priority 2 and up are behind road priority 0, which is the stock order; the priority-map drawing (`49503a2bb78`) gave the same states 1-9 apart from shadow and tile-seam pixels (`debug/wildplt_stockorder_vs_pmap.png`) and was removed. Regression against stock 0.289, 120 s of attract per set (`scripts/mame/avidiff.py`, `debug/regress/`): F1 GP Star (3 sets) identical; F1 GP Star II 21 frames differ (2592-2612, background one pixel off, from the swap); Big Run, Big Run US and Cisco Heat run a different attract sequence from frames 371 and 1326 (the swap; their drawing is unchanged). Whether that sequence is correct on those boards is unverified. Tried and dropped: not drawing tilemaps 0 and 1 on lines where both roads' word 2 low byte is `0xff` (fixes state 2's airport, draws lines across the title and cloud scenes, `debug/regress/wildplt_after_sheet.png`); the same on road priority 0 lines (either road: a grey block in attract frame 3300; both roads: state 2 unchanged, its runway lines are priority 1; `debug/wildplt_p0clip_a.png`). State 2's gradient beside the runway, state 8's stripes and the sea's wrap are open.

**The road geometry is imperfect even where it works** (MAME: "priorities!", "Wild Pilot road
needs some serious work"). The core transcribes the model; where MAME and footage disagree, MAME
wins and the difference is logged.

**Sound clocks are unverified in MAME** (3.5 MHz YM, 4 MHz OKI, pin 7). The core copies them.
What closes it: a PCB crystal check.

**Six of eight DIP blocks cannot be extracted by the current script.** `bigrun`, `bigrunu`,
`f1gpstar`, `f1gpstar2`, `f1gpstar3` and `f1gpstr2` exit on a multi-bit `PORT_CONDITION`
(`IN1 0x300` region, `IN4 0x3` coin B). `cischeat` and `wildplt` extract today. Phase 4 extends
the script; the alternative is hand-written DIP blocks, which is worse.

**The video pipeline has not been fitted.** 386 M10K is counted, 553 exist, and the sprite engine
plus mixer are not written. What closes it: the Phase 1 fit, and if it is short, the scroll RAM
upper halves moving to SDRAM. No video-engine estimate is offered here as a number.

**`THIRD-PARTY.md` does not exist.** Phase 0 writes it with FX68K, jt51, jt6295, the Seta
controller and the framework.

## Next steps

1. **Approve or amend this roadmap.** Nothing below starts before that.
2. Phase 0: vendor jt51, jt6295, the SDRAM controller and download path, the DDR3 loader, CRT
   Adjust, hiscore and the RAM wrappers, each with `PROVENANCE.md`; run their tests unchanged.
3. Phase 0: five-CPU bus wrapper, line cache, behavioural SDRAM, cischeat boot trace against
   MAME, access for access.
4. Phase 0: five-CPU fit with its constraint; CPI at 10 and 12 MHz with the cache in and out.
5. Phase 0: prove both load-time transforms against MAME's decoded regions.
6. Phase 0 exit review against criteria 1–5, then Phase 1's capture pipeline and software model.
