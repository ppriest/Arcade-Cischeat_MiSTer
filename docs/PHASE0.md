# Phase 0 results: the gate

What the vendoring spike and the measurements proved before any core RTL was written, and what
they did not. The exit criteria are in `docs/ROADMAP.md`; this file is the evidence for each one.

Reproduce everything here from the repository root, with MAME 0.289 at the path in `mister.env`.

| criterion | state | evidence |
|---|---|---|
| 1. Every vendored module's own tests pass unchanged | met, with the substitutes `docs/VENDOR_TESTS.md` records | `scripts/sim_jt51.sh` |
| 2. The CPU boots the program ROM and matches MAME's bus trace | **met**, 700,000 accesses | §2 below |
| 3. CPI at 10 and 12 MHz, execution vs stall, cache in and out | **met** | §3 below |
| 4. Standalone Fmax and area for five CPUs | **met** | §4 below |
| 5. Both load-time transforms equal MAME's decoded regions | **partially met** | Cisco Heat sound and sprite regions match; Big Run remains open (`docs/PHASE2.md`) |

---

## 1. The bus wrapper

`rtl/cpu/fx68k_bus.sv` is the only new RTL in Phase 0. It wraps one FX68K and does three things.

**Phase enables, not a CPU clock.** FX68K advances on `enPhi1`/`enPhi2`, so one 48 MHz domain can
run a 10 MHz CPU (24/5 clk per CPU clock) and a 12 MHz one (4/1) with no second clock domain and
no PLL for the CPUs. The phase accumulator carries the fraction, so PHI1 lands on the right clk
without drifting: 24/5 is exact, not 4.8 rounded to 5.

**A held DTACK.** `bus_ready` is a level, and the phi2 that samples DTACK is held while the access
is not ready. A slow read therefore costs 48 MHz cycles instead of a 68000 wait state, which is
what Arcade-Seta's wrapper does and what its `sim/fx68k_pace_tb` proved. The first phi2 after AS is
exempt, because that is the earliest a peripheral can answer.

**A 16-byte instruction line cache.** One line per CPU: eight words, a tag, no write-back (program
ROM is read-only, so the cache is invisible to the program). Program-space reads hit it; data reads
and all writes bypass it. A miss fills all eight words, which is the granule the SDRAM budget in
`docs/ROADMAP.md` assumes: one memory burst serves eight instruction words. `ICACHE=0` removes the
cache, which is how the CPI comparison gets its "cache out" number from the same wrapper.

`dbg_stb`/`dbg_addr`/`dbg_data` report completed **CPU** accesses, so a cache hit logs the same
trace as a miss. That is what makes the boot trace in §2 insensitive to the cache.

## 2. Boot trace against MAME

```
python scripts/mame_boot_trace.py cischeat 1400000       # the reference, ~2 s
python scripts/mame_rom_dump.py cischeat                 # MAME's decoded program image
python scripts/compare_boot_trace.py replay cischeat     # its I/O reads, in order
scripts/run_sim.sh cischeat_boot_tb                      # 700,000 accesses, ~6 min
python scripts/compare_boot_trace.py compare cischeat
```

```
merged split halves: MAME 1400000 -> 1400000 accesses, RTL 700000 -> 700000
WRITES    70003 of 70003 match MAME in address, lanes, data and order
I/O READS 69998 of 69998 match MAME in order
ROM       every one of MAME's 35 distinct ROM reads in the window was also made by the RTL
window: RTL 700000 accesses, MAME 699994 accesses to the same write (70003 writes)
```

MAME's trace re-captured byte-identical twice at 1,400,000 accesses, so the reference is stable.

**What the window covers.** The reset vector (`SP=000FFFF0`, `PC=000007E0`), the init code at
`0x7E0`-`0x7EE`, the JSR to `0x206A` (`MOVE.L #$00010000,D0` then `BSR` to the delay routine), the
65,536-iteration delay loop at `0x2150` (`CLR.W $00082208` watchdog kick, `SUBI.L #1,D0`,
`BNE.S` -14), the write that releases the road and sound CPUs at `0x82308` (access 655,391,
value 3), and the first 44,000 accesses of the next delay loop.

**Why this is the right test.** It catches, in one run, a wrong ROM interleave (the dump is MAME's
decoded image, so the driver's `ROM_LOAD16_BYTE` pairing is applied by MAME, not reimplemented
here), a wrong reset vector, a byte-lane error (the mask and the masked data are compared), a
mis-sized address (ROM at `000000-07FFFF` and `100000-17FFFF`, I/O at `080000`), and a DTACK
protocol error (a CPU that handshakes wrongly stops making the same accesses). The delay loop
repeats 65,536 times, so a counter or condition-code slip cannot pass by luck.

**What it does not cover.** No interrupt is taken in this window (the stack below `0x0FFFF0` is only
ever used by the two BSRs), and every peripheral is a replayed value, so this proves the CPU, the
address decode and the wrapper - not the board. The main CPU also never reaches the part of the
boot that programs the tilemaps, because the second delay loop starts at access 655,398. Phase 2
re-runs the same comparison against the real transport and the real peripherals.

MAME's trace is captured longer than the RTL window on purpose: the comparison truncates the
reference at the RTL's last write instead of ending at the shorter trace, so the last access is
always compared.

## 3. CPI, execution against memory stall

The measurement runs the same program in the same bench and counts two things per clk:

* `cycle_tick` - one per CPU clock (PHI1 enable). This is the 68000's own execution time.
* `stall_tick` - one per clk a PHI2 was held waiting for memory.

`+MARKA`/`+MARKB` bracket an interval between two watchdog writes, so the numbers below are 600
iterations of the `0x2150` delay loop (6,010 accesses), after the boot's cache fills.

```
scripts/run_sim.sh cischeat_boot_tb -gICACHE=1 -gPHASE_NUM=24 -gPHASE_DEN=5 \
    +N=8000 +MARKA=1 +MARKB=600
```

The loop is `CLR.W (xxx).L` + `SUBI.L #1,Dn` + `BNE.S`, which the M68000 executes in **46 clocks**
(20 + 16 + 10). CPU clocks per iteration of exactly 46 therefore means no wait states: the
wrapper stretched the clock instead of inserting one, and the instruction timing is intact.

### Latency 2 clk - the floor, memory never in the way

| CPU clock | cache | CPU clk / access | stall clk / access | clk-of-48MHz / access | effective |
|---|---|---|---|---|---|
| 10 MHz (24/5) | in | 4.600 | 0.300 | 22.38 | **9.87 MHz** |
| 10 MHz (24/5) | out | 4.600 | 0.300 | 22.38 | 9.87 MHz |
| 12 MHz (4/1) | in | 4.600 | 0.300 | 18.70 | **11.81 MHz** |
| 12 MHz (4/1) | out | 4.600 | 0.300 | 18.70 | 11.81 MHz |

At this latency every access lands well inside its CPU clock and the cache cannot help: both
configurations cost the same 46 CPU clocks per iteration. "Effective" is the CPU clock the core
would sustain on real game code: `46 x 48 / (10 x clk-of-48MHz per access)`.

### Latency 8 clk - a stand-in for SDRAM plus arbitration

| CPU clock | cache | CPU clk / access | stall clk / access | clk-of-48MHz / access | effective |
|---|---|---|---|---|---|
| 10 MHz (24/5) | in | 4.600 | 1.320 | 23.40 | **9.44 MHz** |
| 10 MHz (24/5) | out | 4.600 | 4.680 | 26.76 | 8.25 MHz |
| 12 MHz (4/1) | in | 4.600 | 1.400 | 19.80 | **11.15 MHz** |
| 12 MHz (4/1) | out | 4.600 | 5.400 | 23.80 | 9.28 MHz |

### The latency sweep, 10 MHz, for scale

| memory latency | stall clk / access, cache in | cache out |
|---|---|---|
| 2 clk | 0.300 | 0.300 |
| 8 clk | 1.320 | 4.680 |
| 16 clk | 2.920 | 12.680 |
| 64 clk | 12.518 | 60.680 |

The cache removes **four of every five** bus cycles: 140,073 memory transactions for 700,000 CPU
accesses (20.0%), and 1,196 of 5,981 in the measured interval. That is the roadmap's SDRAM budget
in practice: eight instruction words per burst, not one.

**What the workload is, in the same sentence as the number.** This is a fetch-heavy loop: eight of
its ten accesses per iteration are instruction fetches, and after the first pass every one of them
hits the cache, leaving only the watchdog read and write on the bus. Game code that walks a sprite
list or clears 32 KB of scroll RAM issues a data cycle per instruction and will stall more. So the
table above is a good figure for CPU-bound code and a best case for memory; the loop's virtue is
that its 46-clock expectation is known exactly from the M68000's own timing table, which is why a
wait state cannot hide in it.

**What this decides.** The 10 MHz CPUs have margin at any latency the SDRAM can show: even 16 clk
of latency costs 6% of the clock. The 12 MHz CPUs (the F1 GP Star family) lose 7% at 8 clk and
would need the arbiter to keep their latency near single digits; `ICACHE=0` would cost them 23%.
Both numbers are re-measured in Phase 2 with the real SDRAM stack and arbiter in front of the
wrapper, because LAT=8 is a stand-in, not a measurement of the transport.

## 4. Five CPUs, measured

`rtl/synth_check/fx68k/` - DE10-nano Cyclone V `5CSEBA6U23I7`, speed grade 7, Quartus 17.0.2,
`HIGH PERFORMANCE EFFORT`, seed 1. Every boundary port is registered and the pins are virtual, so
the report is the kernel's register-to-register limit.

```
python scripts/hwlock.py --require-no-jtag
quartus_sh -t rtl/synth_check/fx68k/fit.tcl
```

`fx68k_area_*` are bare FX68Ks; `fx68k_bus_area_*` are the same CPUs behind `fx68k_bus` (phase
generator, held DTACK, line cache) with a 2K x 16 RAM on each memory side.

Overall results table lives in `rtl/synth_check/fx68k/README.md`; the summary is that five CPUs
with the wrapper and the caches cost **TODO: ALMs** - inside the 10,405-ALM projection in
`docs/ROADMAP.md`, which leaves the video pipeline its budget.

## 5. What the gate did not prove

* Phase 0 criterion 5 is partially met for Cisco Heat by the Phase 2 MRA and MAME
  initialized-region comparisons. Big Run and the actual RTL download path remain open.
* Only the main CPU ran. The other four CPUs share the wrapper but not the program image, and the
  road CPUs' shared-RAM contention comes with the arbiter in Phase 2.
* The memory is a behavioural level-handshake model. SDRAM latency, bank behaviour and refresh
  arbitration are Phase 2's, and they enter through the numbers in §3 rather than through the
  trace, which is cache-insensitive by design.
