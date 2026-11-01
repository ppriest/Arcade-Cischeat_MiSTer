# Shared simulation models

## `sdram_chip_model_timed.sv`

Written for this core, for `rtl/memory/sdram_sched.sv`; not vendored. It replaces
`sdram_chip_model_wide.sv` (from `Arcade-Seta_MiSTer/sim/common/`), which served one burst at a time
and checked no timing.
