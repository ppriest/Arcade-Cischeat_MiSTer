# Savestates and state dumps: plan

Approved; S1 done in simulation (checks 1 and 3 below; check 2 not run). It brings forward part of the roadmap's Phase 6 so that a state
moves between MAME, the simulators and the board from Phase 2 onwards.

## Verdict

Feasible at Tier 1 (game state exact, sound chips approximate) with work on two pieces:
the 68000 register capture, which FX68K has no port for, and a DDR3 writer for the slot.
Everything else is already reachable: every RAM has a port the engine can borrow
(`docs/STATE.md`), and the board registers are named flops.

## What a state holds

From `docs/STATE.md` at `b9d754c`:

| Section | Bytes | Source |
|---|---|---|
| main work RAM | 65,536 | `u_work` |
| shared RAM road1, road2 | 65,536 | `u_sh1`, `u_sh2` |
| scroll RAM 0..2, full 32 KB windows | 98,304 | `scr[n].u` |
| palette | 32,768 | `u_pal` |
| road CPU local RAM x2 | 32,768 | `road[n].u_loc` |
| road line lists x2 | 4,096 | `u_rl0`, `u_rl1` |
| link RAM | 2,048 | `u_link` |
| sound work RAM | 65,536 | SDRAM `0x03e0000` |
| four 68000s: D0-D7, A0-A6, USP, SSP, PC, SR | 4 x 76 | capture stub |
| board registers, pending interrupts, gate array, latches, timing counters | < 256 | state port |
| YM2151 register file (Tier 1) | 256 | shadow of the sound CPU's writes |
| **total** | **about 357 KB** | |

Not saved: the latched sprite list and the video line buffers (re-derived each frame from the
restore point), ROM and graphics in SDRAM (from the `.mra`).

## Restore point

**Row 1**, after the row-0 interrupt and before the latch at row 4. No video engine runs between
row 241 and row 13, so no line buffer, prefetch or precompute is in flight, and the sprite list is
copied fresh at row 4 of the restored frame. The timing counters freeze while the engine runs, so
the frame keeps its phase; the screen shows one held frame.

## The 68000 registers

`board_cpu` gains a **stub mode**. To capture, the wrapper asserts IPL 7, which the board never
uses (Cisco Heat uses levels 1, 2 and 4, roads 4, sound 4). At the acknowledge it enters stub mode:
from then on **every bus access of that CPU is served by the wrapper and none reaches memory**.

1. The vector fetch returns the address of a stub held in a small wrapper ROM.
2. The stub `MOVEM.L D0-D7/A0-A6` to a fixed address, then `MOVE USP,A0` and stores it. The
   wrapper captures these writes into a 19-longword register file.
3. The exception frame the CPU pushes (SR, PC) is captured the same way, and the SSP before the
   exception is the address of those pushes plus 6. The one exception is the PC-low push, which
   the 68000 makes before its acknowledge: it reaches RAM at SSP-2, below the stack pointer
   (`docs/HACKS.md`).
4. The stub ends on a read the wrapper holds (DTACK held) until the engine releases the CPU.

Restore is the same entry with a second stub: `MOVEM.L` reads load D0-D7/A0-A6 and USP from the
wrapper's file, and `RTE` reads SR and PC from it. The prefetch queue refills from the restored PC,
as after any exception.

Interrupts the CPU already has pending are board state (`board_cpu.pend`) and are saved with it.
The exception and the stub cost each CPU a few hundred of its clocks per save (an estimate, from
the 68000's 44-clock exception plus a 15-register `MOVEM.L`); a resumed game is that much behind
an uninterrupted one, inside a frame that is frozen anyway.

A CPU in STOP takes IPL 7 and resumes after the restore's `RTE`, as it would after any interrupt.
A CPU halted by a double fault takes nothing; the engine times out on it and marks the section.

## The engine

`rtl/state/state_engine.sv`, one sequencer:

1. At row 1, freeze the timing counters and video, put all four CPUs in stub mode, wait for each
   to park.
2. Walk the sections: every on-chip RAM through the **CPU's own port** (the CPUs are parked, so no
   mux lands on the video ports), sound work RAM through a write-capable SDRAM client, board
   registers through a state port (one address per register, as `scroll`, `comms` and the rest
   are named today).
3. Stream to the sink: DDR3 on the board, a file in simulation.
4. Restore is the same walk with the direction reversed, then release the CPUs through their
   restore stubs on one clock.

A read on the CPU ports is registered beside each RAM, so the walk adds one register stage, not a
mux on a critical path.

## The file

One format for the DDR3 slot, the PC and both simulators. Little-endian:

- header: magic `CHST`, format version, set name, build commit, frame number, row;
- manifest: per section its name, kind (`ram`, `cpu`, `regs`), element width, depth;
- payload, sections in manifest order.

The framework's slot header (a 64-bit word: change counter, then size in 32-bit words) wraps it.
A state names its commit; a loader refuses one whose manifest does not match the RTL's.

## Moving a state around

| From | To | How |
|---|---|---|
| MAME | file | `scripts/mame_state.py` (`scripts/mame/state.lua`): the RAMs through each CPU's space, the CPUs' registers through MAME's state interface, the readable registers through the bus and the write-only ones from write taps, at scanline 1 after the chosen frame's notifier (`--line`); then `state.py from-mame` |
| file | ModelSim | `tb_board +LOADSTATE=<state.hex>`: restored through the engine at the first row 1, not through a back door |
| simulator | file | `tb_board +STATE=1` writes the engine's output stream as `.hex` |
| board | file | save to a slot from the OSD; the HPS persists it to the SD card; `scripts/state.py pull` copies it off over SSH |
| file | board | `scripts/state.py push` writes the slot file; load it from the OSD |

So a bug seen on the board becomes a bench at that frame, and a MAME frame becomes a starting
point for the bench without simulating the boot (WORKFLOW section 10).

What MAME's Lua does not give: the supervisor stack pointer of a CPU in user mode (MAME
exposes `SP` and `USP`; `from-mame` refuses such a capture), and the pending HOLD_LINE
interrupts (saved as none). The parity bit is MAME's frame number's. MAME's 68000 can stop
mid-instruction, so the PC saved is `CURPC`, the start of the instruction in progress; MAME's
`PC` is the prefetch address and restoring it runs an extension word as an opcode.

The capture is at scanline 1, the bench's restore row. Cisco Heat sets
`VIDEO_UPDATE_AFTER_VBLANK` (`cischeat.cpp:1777`), so MAME's frame notifier runs at vblank end,
scanline 14 in the driver's numbering; a capture there restores into a frame the game has
already spent 13 lines of. `tb_board +LOADSTATE=debug/state/mame900.hex` against
`debug/cischeat-state-900` (`scripts/compare_state_frames.py`): 10,598 of 55,296 pixels differ
in the first frame, 16,313 in the second, the game's speed readout matching MAME in both.

## Sound chips (Tier 1)

- **YM2151 (jt51)**: its operator state circulates in shift registers (`jt51_sh`, used by
  `jt51_eg`, `jt51_op`, `jt51_pg`), so it is not addressable without forking it. Tier 1: the board
  keeps a 256-byte shadow of the sound CPU's register writes and replays it after a restore. Held
  notes re-attack; the timers restart from their reload values.
- **M6295 x2 (Phase 3)**: Tier 1 saves the bank bits and drops voices in flight; a sample playing
  at the save point is cut.

The README will say both.

## Verification

1. **Simulation round trip**: save at frame N, restore, save again: every section identical.
2. **Continuity in simulation**: a run restored from its own save at frame N matches the
   uninterrupted run's frames N+1..N+3 pixel for pixel.
3. **MAME to bench**: a state taken from MAME at frame N gives MAME's frame N+1 from the bench
   (the comparison step 3 needs anyway).
4. **Board**: save mid-race, reset the core, load, carry on: position, time and score intact.
   Then pull that state into the bench and get the board's next frame.

## Phasing

| Step | Lands with | Delivers |
|---|---|---|
| S1 | Phase 2 step 3 | file format, `state.py`, MAME `state.lua`, `board_cpu` stub mode, engine with a simulation sink; checks 1-3 |
| S2 | Phase 2 step 6 | DDR3 sink and source, `SS` in CONF_STR, four OSD slots, pull and push over SSH; check 4 |
| S3 | Phase 3 | YM2151 shadow replay, M6295 bank bits |

S1 replaces "from a MAME snapshot" in step 3's plan: the bench starts at a MAME frame instead of
simulating the boot. Cheats stay in Phase 6.

## Cost and risk

- **M10K**: none new; the engine uses the RAMs' existing ports. The CPU register files and stub
  ROMs are flops.
- **DDR3**: a third master beside the ROM loader (load time only) and the HDMI rotator, so the
  rotator's port goes behind an arbiter. Recorded in the roadmap's memory plan when S2 lands.
- **Timing**: the engine's address mux sits on each CPU-side RAM port. Expect a timing pass at S2.
- **Unverified**: that FX68K takes IPL 7 at the next instruction boundary in every state the
  games reach, and that the wrapper can hold the parked read indefinitely. S1's bench checks both.
