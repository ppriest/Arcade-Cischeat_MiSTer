# The field tables for this core's ISSP probes, read by the MCP's read_issp.tcl and
# probe_sequence; moved from scripts/read_issp.tcl. Keep them in step with the probe
# bus the top-level .sv builds.
set fields_F {
    {frames           0  15 dec}
    {cpu_addr_w      16  38 hex}
    {cpu_cycles      39  54 dec}
    {video_overrun   55  55 bit}
    {ldr_active      56  56 bit}
    {rom_loaded      57  57 bit}
    {core_reset      58  58 bit}
    {ioctl_download  59  59 bit}
    {pause           60  60 bit}
    {spr_cut_lines   61  84 dec}
    {spr_cut_frames  85 100 dec}
    {spr_cut_max_fr 101 108 dec}
    {spr_line_max   109 120 dec}
    {pll_locked     127 127 bit}
}
set fields_G {
    {cut_clk          0  11 dec}
    {cut_pix         12  23 dec}
    {cut_wait        24  35 dec}
    {cut_records     36  43 dec}
    {cut_granules    44  53 dec}
    {cut_inflight    54  67 dec}
    {cut_line        68  75 dec}
    {cut_frame       76  91 dec}
    {long_pix        92 103 dec}
    {long_wait      104 115 dec}
    {long_granules  116 125 dec}
}
set fields_H {
    {snd_addr         0  23 hex}
    {snd_cycles      24  39 dec}
    {ym_writes       40  55 dec}
    {oki0_writes     56  67 dec}
    {oki1_writes     68  79 dec}
    {ym_peak         80  94 dec}
    {oki_peak        95 107 dec}
    {out_peak       108 122 dec}
    {snd_reset      123 123 bit}
}
