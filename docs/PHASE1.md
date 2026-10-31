# Phase 1 results: video model

The capture pipeline, the software model and the Cisco Heat video RTL, verified against the
model frame by frame. Phase 1's exit, as amended, is met for Cisco Heat (below).

## Capture pipeline

The MAME 0.289 setup in `mister.env` drives the write-timing sweep and captures RAM, palette,
scroll registers, road line lists, sprite RAM and a reference screenshot. Cisco Heat's road line
lists live in the road CPUs' address spaces, so the capture config names those CPU spaces
separately. `mame_capture.py --coin` can insert a coin, start a game and keep driving while the
target frame is captured.

The completed attract and play write-timing runs are recorded in
`docs/write_timing_mame.txt`. The play run was started with coin at frame 600, then captured at
frame 1200:

```powershell
python scripts/write_timing.py cischeat --skip 600 --frames 1800
python scripts/write_timing.py cischeat --coin 600 --skip 1500 --frames 1800 --tag _play
python scripts/mame_capture.py cischeat --frame 1200 --name phase1_play --coin 600
python scripts/build_region.py cischeat scroll0
python scripts/build_region.py cischeat scroll1
python scripts/build_region.py cischeat scroll2
python scripts/build_region.py cischeat sprites
python scripts/build_region.py cischeat road0
python scripts/render_model.py cischeat-phase1_play
```

ROM images and MAME captures are derived from the local ROM set and stay under the ignored
`debug/` tree. `build_region.py` assembles graphics according to `ROM_START`; Cisco Heat's sprite
region also receives MAME's `init_cischeat` untangle transform.

## Current model result

The software model implements Cisco Heat's tilemap page mapping, fixed-width roads, zoom sprites,
shadow pen, palette conversion and the driver's ordered draw passes. The MAME reference contains
a gear overlay at x=232..255, y=181..215 that is not part of the modeled video; the comparison
excludes that rectangle. On gameplay frame 1200, **103 of 54,456 compared pixels differ (0.19%)**;
on attract frame 1200, **309 differ (0.57%)**; and on gameplay frames 1800 and 3000, **178 differ
(0.33%)** in each. Frame 3000 reaches a different gameplay scene. These differences cluster around
the lower-screen zoomed sprites.

The sprite renderer is planned to share a single zoom accumulator. Small pixel-distribution
differences on zoomed sprites versus MAME are intentional for that design; keep them visible in
the diff and do not tune the accumulator to erase them. The MAME software renderer remains the
reference for non-sprite layers and draw order. Captures, models and diffs are retained under
`debug/`.

The first comparison exposed two model bugs: road graphics use least-significant packed nibble
first, and road color groups are selected by the low six attribute bits. After correcting these,
the gameplay mismatch fell from 16,306 pixels to 480 before excluding the gear overlay. Reference,
model, diff and per-pass images for this capture are in `debug/cischeat-phase1_play/`.

## Video RTL

### Tilemap layer: `rtl/video/ms1_tmap_line.sv`

Renders one `ms1_tmap` layer's scanline (33 tile rows, 256 pixels of `{color, pen}`) from a
registered scroll-RAM read port and 64-bit SDRAM granules, overlapping each tile's fetch with
the previous tile's pixel writes. `sim/ms1_tmap_tb` compares all 256 lines against cases written
by `scripts/tmap_ref.py`, which uses `render_model.py`'s own map and tile functions:

```powershell
python scripts/tmap_ref.py
bash scripts/run_sim.sh ms1_tmap_tb
```

Result: **14 cases, 0 mismatches** - the three layers of the play and attract captures (16x16
2x16-page mode on layers 0-1, 8x8 2x4-page mode on layer 2), and random scroll RAM and
scroll values in all eight page arrangements with 4- and 5-bit colour. A single corrupted
expected pixel is reported, so the comparison is live. With the bench's random 2-24 clock
fetch latency a line averages about 640 clocks of the 3,072 available (47.69 ms of simulated
time for 3,584 lines, bench overhead included). Flip screen and the line buffer itself are not
in it.

### Road layer, fixed-width format: `rtl/video/jaleco_road_line.sv`

Renders one road layer's scanline from its four-word line record (code, x scroll, attribute)
through a registered line-list port: 17 granules of 16 pixels cover 256 pixels at any fine
scroll, and the 1,024-pixel row wraps. Output is `{color, pen}` per pixel and the line's
priority; transparency and the priority window are left to the mixer. `sim/road_tb` compares all
256 lines against `scripts/road_ref.py`, which runs the model's own `draw_road` over every row with
the window 0..7, opaque:

```powershell
python scripts/road_ref.py
bash scripts/run_sim.sh road_tb
```

Result: **10 cases, 0 mismatches** - both road layers of all four captures and two pages of
random line records. A corrupted pixel and a corrupted line priority are both reported. With
2-24 clock fetch latency a line averages about 360 clocks (19.22 ms simulated for 2,560
lines). The zooming format (F1 GP Star) is not written; the model does
not have it either.

### Sprites, standard format: `rtl/video/jaleco_zoomspr_line.sv`

Per-scanline sprites from the latched 256-record list into three pass-group line buffers
(Cisco Heat's passes 7..3, 2, 1..0), with the shadow pen as a separate buffer bit. The zoom is
the planned single accumulator: one quotient/remainder step of 128 / zoom across the whole
sprite, horizontally and vertically, so the pixel path only adds. A per-frame precompute (serial
divider, serial shift-add) sets up each record; it takes 24,833 clocks, about 8 lines.

`scripts/sprite_acc.py` is the bit-exact model. It also composites its group buffers into the
software model's draw order and compares the frame with MAME:

| capture | accumulator vs MAME | MAME-exact model vs MAME |
|---|---|---|
| phase1_play | 5,789 / 54,456 | 103 |
| phase1_attract | 5,923 | 309 |
| phase1_play_later | 4,767 | 178 |
| phase1_play_later2 | 4,664 | 178 |

The differences are column and row sampling inside shrunk sprites and one-pixel edges, where
MAME rounds each tile's size up and overlaps tiles (`debug/cischeat-phase1_play/acc_vs_model.png`).
The single accumulator was kept by decision over a MAME-exact per-tile design; `docs/HACKS.md`
records it and what the exact form would take.

```powershell
python scripts/sprite_acc.py --cases
bash scripts/run_sim.sh sprite_tb             # +LAT=n for a fixed fetch latency
```

Result: **7 cases, 0 mismatches** over 256 lines x 3 groups - the four captures and three pages
of random records (flips, both screen edges, zoom 8..511, shadows). Line time, with the next
tile row's granule prefetched while the current one draws:

| | worst gameplay line | fetches on it |
|---|---|---|
| random 2-24 clk latency | 2,979 clk (play_later, y=163) | 126 |
| fixed 12 clk latency | 2,880 clk | 126 |
| dense random records (rand_2) | 4,844 clk | - |

**The line budget is the open risk.** 3,072 clocks per line leaves 3% on the worst captured
line under the bench's latency, and the real latency through the shared arbiter is not known
yet. The worst line needs 126 granules against the roadmap's estimate of 96. Not handled yet:
running out of time. The Seta lesson applies: walk records so that a cutoff drops the bottom-most
sprites, and cut off below the line period. Options if the arbiter's latency makes it worse:
fetch the next drawn record's first tile while the current one draws, or give the engine a
second outstanding request.

### Mixer and the whole video path: `rtl/video/cischeat_video.sv`

`cischeat_video` runs all six engines into eleven double-buffered line buffers
(`line_buffer.sv`), then reads the finished line back two clocks per pixel through
`cischeat_mixer.sv`, Cisco Heat's twelve draw passes as a per-pixel painter's chain, and the
palette with MAME's shadow half (a 32-entry table of MAME's float32 x 0.6). The sprite-group
buffers are cleared as they are read. The road lines' priorities are latched per bank.

`sim/video_tb` runs a whole frame from each capture - sprite precompute, lines 0..255, per-client
random fetch latency - and compares rows 16..239 with `scripts/video_ref.py`'s frame, which is
`sprite_acc.py`'s composite (the software model's draw order, the core's sprite accumulator):

```powershell
python scripts/video_ref.py
bash scripts/run_sim.sh video_tb
```

Result: **4 frames, 0 mismatches** in palette index and in RGB, 57,344 pixels each. With two of
the mixer's passes swapped the same bench reports 1,141 mismatches. Worst line, all engines in
parallel: 2,956 clocks (play_later, y=164), the sprite engine's.

### Synthesis

`rtl/synth_check/video` fits `cischeat_video` with its memories: **1,193 ALMs, 100 M10K,
120.2 MHz** against the 48 MHz target, no DSP. Details in its README.

## Phase 1 exit

The criterion was amended to the software model's frames (`docs/ROADMAP.md`, Phase 1): MAME's
draw order with the core's single sprite zoom accumulator. The RTL matches it on all four captured
frames, so Phase 1 is met for Cisco Heat. Against MAME's screenshots the accumulator leaves
4,664-5,923 pixels a frame different (`docs/HACKS.md`).

## Carried forward

- Sprite line-time cutoff, and the arbiter latency the margin depends on (Phase 2's SDRAM work).
- Flip screen, one path for every layer (Phase 2's feature list).
- More Cisco Heat scenes through `video_tb`: the four captures cover one tilemap mode per layer.
- The zooming road, Big Run's sprite format and overlapping sprite pass windows, and the F1 GP
  Star and Big Run draw sequences, with those sets in Phase 4; the model does not have them yet.
