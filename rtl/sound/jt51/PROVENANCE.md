# jt51 (YM2151) provenance

jotego's JT51, copied from `Arcade-Silkroad_MiSTer` `rtl/sound/jt51/` (`hdl/*.v` and `LICENSE`)
at Silkroad commit `ec45cfb`. Silkroad took it from the `modules/jt51` checkout of jtcores at
`985a573dcfc1ff135553a39f7eae21d18ba57cbe`, `hdl/` only, without `hdl/filter/` (unused: the core
takes the chip's own 16-bit output).

**Licence: GPL-3.0** (`LICENSE`). **Unchanged.** Every file matches the Silkroad copy byte for
byte (SHA-256, checked at vendoring).

## Use here

One YM2151 at 3.5 MHz (`ym2151_device &ymsnd(YM2151(config, "ymsnd", 7000000/2))`,
`jaleco/cischeat.cpp`). On a 48 MHz `clk_sys` that is a 7/96 clock enable, generated exactly
rather than by an accumulated near-3.9 MHz approximation - MAME's own comment history implies a
different divisor, and `docs/HACKS.md` records why the crystal is followed instead.

The chip's output is the 16-bit sample stream; `rtl/sound/` (Phase 4) mixes it with the two
M6295s and feeds the MiSTer sigma-delta DAC. The status register is polled by the sound CPU for
music tempo (`/* Music tempo driven by the YM2151 timers (status reg polled) */`), so the timer
behaviour is load-bearing, not cosmetic.

Not instantiated before Phase 4. `Arcade-Vamphalf_MiSTer`'s `rtl/sound/vh_ymoki.sv` is the
closest worked wrapper (YM2151 plus two M6295, one banked), and is the starting point for the
Phase 4 sound module.

## Tests

`E:\jtcores\modules\jt51\ver\jt51_con` is the upstream conformance bench. It is not part of this
copy; Phase 0 runs it in place, against the upstream tree, to prove the vendored `hdl/` is the
code that bench was written for.
