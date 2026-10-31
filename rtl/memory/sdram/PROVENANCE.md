# SDRAM controller - provenance and modifications

## Chain of custody

| Stage | What |
|---|---|
| Upstream | Sorgelig's `sdram.v`, GPL-3.0-or-later, from `MiSTer-devel/Arcade-Jackal_MiSTer/rtl/ram_rom/sdram.sv`. Kept verbatim here as `sdram_upstream_reference.sv` for diffing. |
| Then | `Arcade-Psikyo_MiSTer/rtl/memory/sdram/` - extended to burst-4 reads and proved on real DE10-nano hardware. |
| Then | `Arcade-Fuuki_MiSTer/rtl/memory/sdram/` - carried across, with the surrounding stack widened to 26-bit addresses for a 128 MB module. |
| Then | `Arcade-Seta_MiSTer/rtl/memory/sdram/` - copied from Fuuki untouched. |
| Here | Copied from that Seta tree **untouched**: `sdram.sv` and `sdram_upstream_reference.sv` both match byte for byte (SHA-256, checked at vendoring). Do not edit. |

## Why it is not upstream-verbatim

Every graphics consumer in this project speaks in 64-bit granules - one packed row of a 4bpp
16-pixel tile. Upstream's read state machine captures exactly **one** 16-bit word per transaction
regardless of the mode register's burst-length field, so a 64-bit granule would cost four separate
transactions (~28 cycles uncontended). Psikyo extended it to a real burst-4 read; that extension is
what this project depends on, and it is the reason to vendor this file rather than write one.

Three bugs were found while building that extension, worth knowing because they are invisible
without a chip model that decodes commands:

- The row/column address split needed swapping. A hardware burst auto-increments the **column**, so
  four consecutive word addresses must land in four consecutive columns of one row. The
  non-bursting upstream had it the other way, which only matters once bursting exists.
- The chip model silently ignored the `DQML`/`DQMH` write mask.
- An off-by-one in burst-read CAS timing, from a dropped registration-delay margin.

LESSONS_LEARNED, "Verify a burst extension against a command-decoding chip model, not a latency
stub".

## The address width

`addr0`/`addr1`/`addr2` are `[25:1]` - 25 bits of **word** address, 64 MB of the 128 MB module's
first chip, with bit 25 driven onto A9 at column time (the FG-3 layout). This core needs 15.0 MB
of a stock 32 MB `MT48LC16M16` (`docs/ROADMAP.md`, SDRAM map), so the wider path is headroom, not
a requirement. Keeping it identical to the proven tree avoids a narrowing pass that would be pure
risk; the top bit is simply held low by the map.

## Facts worth not rediscovering

- **Upstream has no reset port at all** - it is driven purely by `init`, deliberately, so that a
  core reset cannot disturb memory contents. Do not add one. Psikyo's wrapper did, and it pinned
  the download FSM in idle for the entire ROM transfer, because MiSTer holds core `RESET` asserted
  for the whole download (LESSONS_LEARNED, "Never hold the memory path in the core reset").
- **`dout0`/`dout1`/`dout2` are literally the same register.** Sampling later than your own
  valid/ack cycle reads another port's in-flight data. Capture read data on the valid pulse.
- **The three ports are fixed priority, not fair.** Port 0 always preempts port 1, which always
  preempts port 2. Choosing which client sits behind which port is the only bandwidth tuning
  available; there is one physical chip, so "more ports" is not more parallel bandwidth.
- **`SDRAM_CLK` phase shift** is the standard MiSTer `-3 ns` convention, expressed as a positive
  equivalent because `altera_pll` rejects negative values here. It is a poor first suspect for data
  faults; sweeping it to 0 ps on Psikyo gave byte-identical results.
- The uninitialized `state`/`ack0..2` signals get explicit initializers, the same
  simulation-fidelity class of fix as the TG68K one.
