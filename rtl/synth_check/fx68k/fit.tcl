# Run from the repository root: the vendored fx68k $readmemb paths are
# root-relative ("rtl/cpu/fx68k/microrom.mem").
#
#   cd E:/Arcade-Cischeat_MiSTer
#   quartus_sh -t rtl/synth_check/fx68k/fit.tcl
#
# Coordinate first: scripts/hwlock.py --require-no-jtag
#
# fx68k_area_*   bare FX68K, one, four and five instances
# fx68k_bus_area_*  the same behind fx68k_bus (phase generator, held DTACK,
#                   line cache) with a synchronous ROM, one and five
load_package flow

foreach rev {fx68k_area_1 fx68k_area_4 fx68k_area_5 fx68k_bus_area_1 fx68k_bus_area_5} {
    project_open rtl/synth_check/fx68k/fx68k_area -revision $rev
    execute_flow -compile
    project_close
}
