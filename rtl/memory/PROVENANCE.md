# Memory transport stack - provenance

The six files beside this one, plus `sdram/sdram.sv` (which has its own
[`sdram/PROVENANCE.md`](sdram/PROVENANCE.md)):

| file | what |
|---|---|
| `sdram/sdram.sv` | Sorgelig's controller with Psikyo's burst-4 read; see its provenance |
| `sdram/sdram_upstream_reference.sv` | upstream Sorgelig `sdram.v`, kept verbatim for diffing |
| `sdram_phy.sv` | pin-level PHY, byte enables, `-3 ns` `SDRAM_CLK` convention |
| `sdram_arbiter.sv` | parameterised `N`-client arbiter, round-robin |
| `sdram_download.sv` | MiSTer `ioctl_download` -> SDRAM writer used by the `.mra` IOCTL loader |
| `sdram_narrow_bridge.sv` | word-width adapter (`WORD_BYTES`) between a client and a port |
| `rom_loader.sv` | loader-side copy of the `ioctl` stream used for load-time transforms |
| `ddram_phy.sv` | DDR3 PHY, used only by the loader/HPS path and the HDMI rotator |

All seven were copied **unmodified** from `Arcade-Seta_MiSTer/rtl/memory/` (SHA-256 checked for
each file), which took the six non-`sdram` files, and `sdram.sv`, from
`Arcade-Fuuki_MiSTer/rtl/memory/` in the same pass. Chain of custody for the whole stack:

| Stage | What |
|---|---|
| Upstream | Sorgelig / MiSTer-devel, GPL-3.0-or-later |
| Then | `Arcade-Psikyo_MiSTer` - `sdram.sv` extended to burst-4, proved on hardware |
| Then | `Arcade-Fuuki_MiSTer` - whole stack to 26-bit addresses; one parameterised `sdram_arbiter.sv` instead of Psikyo's `sdram_arbiter2/5/6` trio |
| Then | `Arcade-Seta_MiSTer` - copied untouched |
| Here | copied from Seta untouched |

Licence: GPL-3.0-or-later. `.gitattributes` marks this directory `-text`.

## Why the Fuuki stack rather than Psikyo's

Fuuki's is the more evolved of the two: a single parameterised arbiter, 26-bit addressing
throughout, and the `sdram_narrow_bridge.sv` that lets a 16-bit client sit on the same bus as
64-bit graphics clients without a bespoke adapter per client. Fuuki records the alternative's
failure mode directly: an arbiter that packed client addresses as `[25*N-1:0]` arithmetic rather
than a named range silently shifted two tilemap layers.

## Use here

`docs/ROADMAP.md` puts every SDRAM client - five CPUs' fetches, six video planes, sound samples -
behind **one** `sdram_arbiter.sv`, because there is one physical chip. `cischeat_sdram.sv` (this
core's own) puts ten clients on it - four CPU ports, six gfx clients - with the arbiter, phy and
`sdram.sv` on a 96 MHz `clk_mem` and the clients on the 48 MHz `clk_sys`. The arbiter is
round-robin among its `N` clients and gives the ROM download path absolute priority, so a load
always completes. `sdram.sv`'s own three ports remain fixed-priority (port 0 preempts 1 preempts
2); the core drives the arbiter into port 0 and leaves the others idle.

**Changed here:** `sdram_arbiter.sv` takes client writes (`c_we`, `c_we16`, `c_wdata`) for the
sound CPU's work RAM; a write is served like a download write and its `c_valid` pulses when the
phy has taken it. `sdram.sv`'s refresh count of 670 is kept: 6.98 us at 96 MHz, inside the chip's
7.8 us.

**Changed here:** `rom_loader.sv` leaves `L_RD` when `ddram_phy` is busy, i.e. has taken the
read. It used to leave when the phy was idle, so a read asked while `DDRAM_BUSY` was high was
never issued and the loader hung (`sim/rom_load_tb`, whose DDR3 model holds `DDRAM_BUSY` on a
quarter of clocks).

DDR3 is used only by the `.mra` loader and the HDMI rotator (`screen_rotate_two.sv`); no game
client runs from it. `ddram_phy.sv` and `rom_loader.sv` are the load-time path: the `.mra` address
`0x30000000` makes the HPS put the image in DDR3, and `rom_loader.sv` copies it into SDRAM with the
core held in reset, applying the sprite-region transform on the way.

The download FSM is never held in core reset - see the `sdram/PROVENANCE.md` note that cost Psikyo
an entire ROM transfer.

## Tests

`rtl/memory/sdram/` is the only part with a chip-level model in the sibling trees. Phase 0 uses the
behavioural SDRAM model in `rtl/synth_check/` to prove the five-CPU harness fetches through this
stack; the burst-4 behaviour itself was proved on hardware in Psikyo and is not re-litigated here.
