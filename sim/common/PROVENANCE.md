# Shared simulation models

## `sdram_chip_model_wide.sv`

From `Arcade-Seta_MiSTer/sim/common/` (itself from Fuuki, a widened copy of Psikyo's
`sdram_chip_model.sv`). Decodes `{nRAS, nCAS, nWE}` and models CAS latency and burst length.

One change: `open_row` has four entries, not two. `SDRAM_BA` is two bits, so the original dropped
the ACTIVE row of banks 2 and 3 (word addresses from `0x800000`, byte `0x1000000`).
