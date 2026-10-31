derive_pll_clocks
derive_clock_uncertainty

# clk_sys (48 MHz, PLL counter 2) and clk_mem (96 MHz, counter 0) are one PLL's
# outputs with aligned edges; rtl/memory/cischeat_sdram.sv crosses between
# them as synchronous clocks, so the crossing paths are timed, not cut.

# ---------------------------------------------------------------------------
# SDRAM I/O timing, from Arcade-Seta_MiSTer's Seta.sdc (same controller, same
# 96 MHz and 180-degree SDRAM_CLK). Without it STA times no SDRAM pin, and a
# capture register placed in the fabric failed on Seta's hardware while STA
# was clean (docs/LESSONS_LEARNED.md, "A bidirectional bus captured into
# several lane registers").
#
# The numbers are MT48LC16M16A2 -7E values at CL=2 plus a board allowance,
# ASSUMED, not measured: the module's part is not recorded here.
# ---------------------------------------------------------------------------
set sdram_tAC   6.0    ;# memory CLK -> data valid, max
set sdram_tOH   2.7    ;# memory CLK -> data hold, min
set sdram_tDS   1.5    ;# memory input setup
set sdram_tDH   0.8    ;# memory input hold
set sdram_board 0.5    ;# trace + pin, max, each direction
set sdram_board_min 0.1

create_generated_clock -name sdram_clk_pin -source [get_pins -compatibility_mode {*pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports {SDRAM_CLK}]

set_input_delay -clock sdram_clk_pin -max [expr {$sdram_tAC + $sdram_board}]     [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock sdram_clk_pin -min [expr {$sdram_tOH + $sdram_board_min}] [get_ports {SDRAM_DQ[*]}]

# The first beat is captured on the second clk_mem edge after the memory's
# launch edge (sdram.sv's dq_in; Seta.sdc measured the arrival).
set sdram_dq_regs [get_registers {*sdram:u_sdram|dq_in[*]}]
set_multicycle_path -setup 2 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs
set_multicycle_path -hold  1 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs

set sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk_pin -max [expr {$sdram_tDS + $sdram_board}]      $sdram_outs
set_output_delay -clock sdram_clk_pin -min [expr {-$sdram_tDH + $sdram_board_min}] $sdram_outs
