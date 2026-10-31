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

The **SDRAM multiple is 2**: the arbiter, phy and controller run on `clk_mem`, the clients on
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
| `090000-097fff` | 32 KB | shared RAM with road2 CPU |
| `098000-09ffff` | 32 KB | shared RAM with road1 CPU |
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
the `.mra` generator reads them.

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
- **The reference MAME is `C:\Emulation\Emulators\MAME\mame.exe`**, 0.289 with the full driver
  set: it lists `cischeat`. The `mame.exe` builds on `E:` are driver-filtered (117 systems, Psikyo
  only) and do not know any of these sets, so every capture, `-listxml` dump and trace names that
  binary explicitly rather than relying on `PATH`.
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
ships as asked, reproducing MAME's behaviour, labelled in the README and the OSD. There is no
correct reference to follow; only a driver fix or a PCB would give one.

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
