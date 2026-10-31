# jt6295 (OKI M6295) provenance

jotego's jt6295 (<https://github.com/jotego/jt6295>, `master` at commit
`7d76b0be8cd8f85f3ae741178c9830b20e2071a1`), copied from `Arcade-Fuuki_MiSTer`
`rtl/sound/jt6295/` (`hdl/` and `LICENSE`) at Fuuki commit
`8e706177f38dd43064db8341e6b2e07da627ba54`. The same `hdl/*.v` is in the Eolith, Vamphalf,
NixPirates and GStream cores (diffed there: identical). **Unchanged**; every file matches the
Fuuki copy byte for byte (SHA-256, checked at vendoring).

`jt12_comb.v` and `jt12_interpol.v` are jt12 modules jt6295 carries for its optional
interpolator (`INTERPOL`). There is no jt12 tree in this core, so this copy of them is the one to
compile if the interpolator is enabled.

**Licence: GPL-3.0** (`LICENSE`).

## Use here

Two M6295 at 4 MHz with pin 7 high (`PIN7_HIGH`), `jaleco/cischeat.cpp`: both chips are plain
`okim6295_device` instances, one per `oki1`/`oki2` 512 KB sample region, with the bank bit taken
from a latch rather than the chip's own pin. The ROM bus is a level interface (`rom_addr` out,
`rom_data`/`rom_ok` in) that expects data within two `cen32` ticks of the address changing;
Fuuki's `rtl/sound/sample_cache.sv` is the worked answer for serving that from SDRAM, and Phase 4
reuses the idea.

Not instantiated before Phase 4.

## Tests

The upstream repository's benches were not part of the copy. `sim/oki_tb` in the sibling cores
plays a phrase through the chip and checks the decoded samples; Phase 4 ports it if the sample
path is changed at all. Vendoring alone changes nothing to test.
