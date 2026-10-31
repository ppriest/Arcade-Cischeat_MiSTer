# hiscore.v provenance

MAME `hiscore.dat` support for MiSTer arcade cores by Alan Steremberg and Jim Gregory
(<https://github.com/JimmyStones/Hiscores_MiSTer>), GPL-3.0-or-later, **module version 14**
(`localparam HS_VERSION = 14`; dump format 1).

## Chain of custody

| Stage | What |
|---|---|
| Upstream | JimmyStones v14 |
| Then | `Arcade-Psikyo_MiSTer/rtl/hiscore.v` at `7500d51` - version 14 with Psikyo's work-RAM read registered next to the RAM (`// Psikyo:`: one dead cycle in the compare, two skipped cycles in the start/end checks, so `CHECK_HOLD` must be at least 2) |
| Then | `Arcade-KonamiGX_MiSTer/rtl/hiscore/` - Psikyo's file with the `[GX]` changes below |
| Here | copied from that KonamiGX tree **unchanged** (`hiscore.v` matches byte for byte, SHA-256) |

`hiscore.v_psikyo_reference` is the Psikyo input unchanged, so the `[GX]` diff stays checkable.

## Local changes carried in (all marked `[GX]`)

- A dump download counts as loaded only if one of its bytes is non-zero. Main_MiSTer sends the
  `.mra`'s whole `<nvram size>`, zero-filled past a shorter file; a file saved before hiscore
  support would otherwise restore a table of zeros over the game's. The module never saves an
  all-zero dump (`compare_nonzero`), so nothing it wrote is refused.
- `dpram_hs` is written as two ports that each read the old data, and `hiscore_buffer`'s unused
  port B is tied off. Upstream's ports returned the written byte on a write; Quartus then built
  `hiscore_data` and `hiscore_buffer` from registers (~4,400 ALMs at `HS_SCOREWIDTH` 9) and the
  GX core no longer fitted at 105 %. No state reads a byte in the cycle it writes it.
- `hiscore_data` is a simple dual-port RAM (`dpram_hs_sdp`): one write port, one read port. With
  two writing ports Quartus refused it ("unsupported read-during-write behavior") and again built
  it from registers.

## Use here

`docs/ROADMAP.md` budgets hiscore for every set. The work-RAM read must be registered next to the
RAM (the `// Psikyo:` shape), and `CHECK_HOLD` must be at least 2 as that change requires. This is
the reason for taking GX's file rather than upstream: the same problem, already solved and fitted.

## Tests

The sibling cores exercise it on hardware with each game's `hiscore.dat` entry (Phase 4/5 adds the
entries). There is no unit bench upstream; the risk it carries is Quartus inferring registers
instead of block RAM, which the area report catches at fit time and the `[GX]` changes address.
