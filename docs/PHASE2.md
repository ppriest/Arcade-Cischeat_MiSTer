# Phase 2: hardware bring-up of Cisco Heat

Started on the user's approval after Phase 1's exit. Exit criterion (`docs/ROADMAP.md`):
`cischeat` boots and plays on a DE10-nano, silent, at 60 Hz, with coin, start, wheel,
accelerator, gear and brake working and the DIPs matching the driver.

## Plan

Each step ends in a commit and a bench or a hardware reading.

1. **Timing and interrupts** (`rtl/cischeat_timing.sv`): 384 x 260 at 6.000 MHz from 48 MHz,
   blanking and sync, MAME's interrupt guess (IRQ4 at line 240 and IRQ2 at line 0 on even frames,
   IRQ1 at line 240 on odd frames; road CPUs IRQ4 at vblank start), and the video schedule:
   frame_go and the sprite-list and scroll-register latch at vblank end, line_go one line ahead
   of the line shown.
2. **Board logic** (`rtl/cischeat_board.sv`): main, two road and the sound 68000 on
   `fx68k_bus`; the four memory maps; on-chip RAMs; scroll registers, the comms/reset register at
   `0x82308`, the sound latches, watchdog and screen-control writes accepted; `cischeat_video`
   attached. The sound CPU runs, with the YM2151 and M6295 stubbed to what MAME returns, so the
   latch handshake is real before Phase 3. One program-fetch port per CPU and one per video
   client, for the arbiter.
3. **Board bench against MAME**: a behavioural SDRAM holding the loader image; the main CPU's
   bus trace against MAME's well past the Phase 0 window, then frames against MAME's screenshots,
   from reset in Verilator for the first frames and from a MAME snapshot after that
   (WORKFLOW section 10). The snapshot is a savestate, S1 of `docs/SAVESTATES.md`.
4. **SDRAM stack**: `sdram.sv` behind `sdram_arbiter.sv` with every client, cache fills as
   bursts, sound work RAM in SDRAM; the step 3 bench re-run through it with the chip model.
   Measure the sprite engine's worst line through the real arbiter and add its time cutoff
   (`docs/PHASE1.md`, carried forward).
5. **ROM loading**: DDR3 -> `rom_loader` -> `cischeat_rom_transform` -> SDRAM, read back equal to
   the image `build_mra.py` verifies.
6. **Top level** (`Cischeat.sv`): `hps_io` and CONF_STR, wheel, pedals, gear, horn, coin, start,
   Pause, DIPs from the `.mra`, the video output chain (CRT Adjust, scaling, crop, rotation),
   flip screen, the ISSP probe and the hidden OSD debug page. Build, deploy, first boot.
   Proposed: savestate slots and pull/push over SSH, S2 of `docs/SAVESTATES.md`.
7. **Exit**: play on the board; DIPs checked against `-listxml`; evidence recorded here.

## Results

**Step 1** (`94e84aa`): `sim/timing_tb` passes over four frames: line and frame periods, sync
widths, the interrupt pattern by frame parity, latch then frame_go then line_go for rows 16..240.

**Step 2**: `rtl/cischeat_board.sv` with `rtl/cpu/board_cpu.sv` (bus slave and HOLD_LINE latches;
`fx68k_bus` gained an `iack` output) and `rtl/memory/dpram_be.sv`. The jt51 runs, so the sound
CPU's YM2151 IRQ is real; the M6295s are stubbed (`docs/HACKS.md`). `sim/board_tb` runs all four
CPUs and the video from reset on an ideal 8-clock memory holding `scripts/board_image.py`'s image:

- main CPU, 60,000 accesses: every write (6,002) and every I/O read (5,998) matches MAME's boot
  trace in order (`compare_boot_trace.py compare cischeat --rtl debug/cischeat-boot/cischeat_board.trace`);
- road CPUs 46,296 program reads each, sound CPU 47,942 accesses with 5,326 work-RAM writes, the
  video 51,471 granules over two frames with no overrun;
- the sprite precompute takes 24,834 clocks, which moved the latch to row 4.

ModelSim runs it at about five minutes a frame once the video draws, so MAME's 1.4M-access boot
window (about 41 frames, through the CPU release at `0x82308`) is step 3's, in Verilator. Not
synthesised yet.

**Step 3**: `sim/board_tb` builds in Verilator (`scripts/run_verilator.sh board_tb`, file list
`sim/board_tb/verilator.files`) at about 1.7 s a frame, against ModelSim's five minutes. Both
simulators give byte-identical frames from the MAME frame-900 state.

- main CPU, MAME's whole 1.4M-access boot window (40 frames, through the release at `0x82308`):
  all 140,005 writes match in address, lanes, data and order, all 140,000 I/O reads in order;
- frames 1..319 from reset (`+DUMPFRAMES=320`, `scripts/mame_frames.py`,
  `scripts/compare_reset_frames.py`): 314 are pixel-identical to a MAME frame. The bench runs
  0 to 8 frames behind MAME through the boot screens; the other five differ at screen changes,
  where the lagging bench falls between two MAME frames;
- the lag is the ROM checksum's data reads (0x000000-0x13ffff), which bypass the instruction
  cache and wait `+LAT=8` each: about 37,500 held clocks a frame while it runs. With one cache
  line the loop at 0x2118 refilled two lines per iteration and the bench ran 41 frames behind;
  `fx68k_bus` now has four lines;
- savestate: `tb_board +STATE=1 +LOADSTATE=debug/state/mame900.hex` restores MAME's frame 900,
  saves a frame later, restores again and saves: identical in all 18 sections, main trace
  identical over 3,241 accesses. `+LOADSTATE` alone against MAME's next two frames: 10,598 and
  16,313 of 55,296 pixels differ (`debug/state/compare<k>.png`). In the first frame the
  differences are on the zoomed sprites (`docs/HACKS.md`); in the second they spread over rows
  16-218, cause not found;
- the sprite precompute takes 24,834 clocks on the frame-900 list as on the empty boot list.

MAME's snapshots carry the layout's gear-shift artwork (`cischeat.lh`, 377 pixels) unless taken
with `-snapview native`, which the capture scripts now pass.

**Step 4**: `rtl/memory/cischeat_sdram.sv` puts the four CPU ports and six gfx clients on
`sdram_arbiter` -> `sdram_phy` -> `sdram.sv` at 96 MHz (`clk_mem`), the clients at 48. Each CPU
port keeps the last granule it read, so a cache line fill costs two SDRAM reads; the arbiter takes
client writes for the sound work RAM. `sim/board_tb` runs on it with the command-decoding chip
model (`+IDEAL=1` keeps the behavioural memory), checking every word handed to a CPU or gfx client
against the image:

- boot trace, 1.4M main CPU accesses: all 140,005 writes and 140,000 I/O reads match MAME, as on
  the behavioural memory;
- frames 1..319 from reset: 314 pixel-identical to a MAME frame, as before; the bench is 0 to 6
  frames behind (was 0 to 8), in step on 284. Comms writes at frames 19, 37, 55, 82, 156;
- from MAME frame 900, eight frames: no wrong word, no overrun; first frame 10,598 pixels
  different (unchanged), second 16,604 (16,313 on the behavioural memory). The main CPU runs
  105,000-120,000 of its 166,667 clocks a frame, against 104,000-106,700 on the behavioural
  memory: the ports' granules serve sequential ROM data reads;
- sprite engine through the arbiter: worst line 2,261 clocks of 3,072 in play (frames 901-908),
  1,857 over the 320 boot frames; no line cut. The cutoff (`docs/HACKS.md`) holds the dense
  random list in `sprite_tb -GLINE_CLK=3072` to 2,974.

The measurement that moved the SDRAM to 96 MHz, on the user's choice:

- capacity: `sim/sdram_tb` (arbiter -> `sdram_phy` -> `sdram.sv` -> the command-decoding chip
  model, ten clients always asking) serves **200 granules a line, 15.3 clocks each**, all data
  correct. `sdram.sv` spends 11 clocks a transaction with no bank overlap, the phy and arbiter
  handshakes the rest. The roadmap's 768 a line assumed one granule per 4 clocks;
- demand: `tb_board +LOADSTATE=debug/state/mame900.hex +FRAMES=8`, counting each gfx request,
  each cache line fill as two granules and every other external access as one: **at most 293 a
  line, video alone at most 202**, mean 175-234 per frame. Measured with the bench's ideal
  memory (`+LAT=8`), under which the main CPU already runs 104,000-106,700 of its 166,667 clocks
  a frame, the rest held on ROM;
- at 96 MHz the same bench serves 401 a line. `sdram.sv`'s refresh count of 670 is 6.98 us
  there, inside the chip's 7.8 us (at 48 MHz it would have been 14.0 us).

**Step 5**: `rtl/memory/cischeat_rom_load.sv` is the fast load: `ddram_phy` -> `rom_loader` ->
`cischeat_rom_transform` -> `cischeat_sdram`'s download port, all on `clk_mem`.
`sim/rom_load_tb` (Verilator) loads the image `build_mra.py --check --image` verifies from a DDR3
model that holds `DDRAM_BUSY` on a quarter of clocks, through the SDRAM stack into the chip model:
**all 7,864,320 words equal** MAME's regions after init (`debug/board/sdram.hex`, the board
bench's image) below `0x0e00000` and the raw image above it (OKI samples). 15 MB in 1.31 s of
simulated time.

- the first run had every CPU word byte swapped: the .mra holds the programs in 68000 order and
  the loader takes words little-endian, as the byte-wide gfx need. `cischeat_rom_transform` now
  swaps every word below `0x02c0000`; `rom_transform_tb` checks all 1,310,720 of them, the
  131,072 sound words (bitswapped, then in 68000 order) and the 2,097,152 sprite words;
- `rom_loader` left `L_RD` when the phy was idle, not when it had taken the read: a read asked
  while `DDRAM_BUSY` was high was dropped and the loader waited forever. It now waits for the
  phy's busy;
- the byte path (`sdram_download.sv`, `ioctl_wr`) is not wired; the .mra loads through DDR3.

**Step 6**: `Cischeat.sv` has `hps_io`, the PLL, the fast load, the inputs (wheel: `docs/HACKS.md`),
the DIPs from the .mra, CRT Adjust (`rtl/video/crt_chain.sv`, V-Size included), scaling, crop,
HDMI rotation, the HDMI-only options hidden under direct video, the hidden Debug page with Pause
CPU, and ISSP instance F in `Cischeat_stp` (fields in `scripts/read_issp.tcl`). Audio is silent.

- 5895ada fitted but missed timing on `clk_mem` by 1.362 ns, every path from `sdram_arbiter`'s
  `rr_ptr` through the round-robin search and the client mux into the phy registers
  (`scripts/sta_failing_paths.tcl`). The pick is now registered a cycle ahead (9a92d81);
  `sdram_tb +MHZ=96` still serves 401 granules a line with 0 bad words, and the boot trace through
  the stack still matches MAME (14,002 writes, 13,998 I/O reads, `compare_boot_trace.py`);
- 9a92d81 (with CRT Adjust and the probe, 1866a45): timing met, worst setup slack +0.975 ns;
  57% ALMs, 467 of 553 RAM blocks. Deployed as `Cischeat_30000001.rbf` with `_dev/Cisco Heat.mra`.
  Not launched;
- no core flip screen, on the user's decision: the game has none, the sprite engine steps its zoom
  accumulators upward from `y0`, and flipping at the output would need a frame buffer. Flip 180
  is the HDMI rotator's only.

The steps below this line are earlier preparation for 4-6.

## Cisco Heat development MRA

`scripts/build_mra.py` generates `releases/_dev/Cisco Heat.mra` from MAME 0.289's
`ROM_START(cischeat)`, CRC-matched ROM files and the fixed SDRAM map. It emits the
Cisco Heat DIP settings and game control names, records the installed MAME version,
and omits the second road-ROM copy because the board aliases that region. The
generated 15 MiB loader image was compared byte-for-byte with an independently
assembled image of the MAME regions.

Reproduce the checks:

```powershell
python scripts/build_mra.py
python scripts/build_mra.py --check
python scripts/validate_mra.py "releases\_dev\Cisco Heat.mra"
python scripts/mra.py
```

The MRA contains raw ROM data. The sound-program bitswap and sprite untangle are
load-time transforms still needed in the download path.

## Transform reference checks

`scripts/mame_region_dump.py` dumps a memory region after MAME's machine
initialization has applied the game's transform. `scripts/verify_transforms.py`
compares those bytes with the independently assembled and transformed ROM regions.
For Cisco Heat, both checks match:

- GS88000 sound program: 256 KiB
- sprite untangle: 4 MiB

The Lua memory-region API returns the big-endian sound region in host byte order;
the verifier normalizes its 16-bit words before comparing. Sprite data is byte-wide
and compares directly.

```powershell
python scripts/verify_transforms.py
```

This verifies the transforms in software against MAME. Basic SDRAM and DDR3 loader
modules exist, but the MRA load path is not integrated with this transform stage;
the corresponding Big Run checks remain open.

## RTL transform stage

`rtl/memory/cischeat_rom_transform.sv` implements the `rom_loader` transform
interface for Cisco Heat: it bitswaps sound words in place and redirects each
sprite word to its untangled destination. The address mapping was checked for all
2,097,152 sprite words against the MAME untangled image. The exhaustive
`sim/rom_transform_tb/` bench covers all sound and sprite word addresses.

`scripts/run_sim.sh rom_transform_tb` passes: 131,072 sound words and 2,097,152 sprite
words. The bench's references are transcriptions of `init_cischeat`, so it proves the RTL
equals that transcription; the transcription itself was checked against MAME's initialized
regions by `verify_transforms.py`. The stage is not wired to the loader or top level yet.

## Open from the preparation

- Verify both transforms on Big Run (the Cisco Heat load is step 5).
- Integrate the SDRAM backend and arbitrate the CPU and video clients.
- Add the wheel, accelerator, brake, gear, horn, Pause, DIPs, ioctl and OSD wiring.
- Add the standard OSD/video features and the ISSP/debug plumbing listed in the
  Phase 2 roadmap criteria.
