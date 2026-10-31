# Cisco Heat video: area and Fmax

`cischeat_video` - three `ms1_tmap_line`, two `jaleco_road_line`, one `jaleco_zoomspr_line`,
eleven line buffers (three tilemap, two road, three sprite groups split into a 12-bit and a 1-bit
shadow buffer), the pass-ordered mixer and the palette conversion - with the memories it reads:
8K x 16 scroll RAMs, 1K x 16 road line lists, the 256 x 128 latched sprite list, the 16K x 16
palette. Each memory is filled through a write port so nothing is pruned as a constant. Every
port is registered and every pin virtual. Cyclone V 5CSEBA6U23I7, Quartus 17.0.2,
`HIGH PERFORMANCE EFFORT`, seed 1, constrained at 48 MHz (20.833 ns).

```
python scripts/hwlock.py --require-no-jtag        # a compile blocks JTAG
cd rtl/synth_check/video
quartus_sh --flow compile video_area -c video_area
```

## Result

| | ALMs | registers |
|---|---|---|
| `ms1_tmap_line`, each | 74-79 | 194-198 |
| `jaleco_road_line`, each | 76-87 | 230-236 |
| `jaleco_zoomspr_line` | 487 | 992 |
| `cischeat_mixer` | 79 | 79 |
| `cischeat_video` total | 998 | 2,224 |
| **whole harness** | **1,193** | 2,547 |

**100 M10K** for everything above, memories included; 0 DSP. Fmax **120.2 MHz** (slow 1100 mV
100 C) against the 48 MHz constraint.

The harness writes the sprite list in 64-bit halves: written one 16-bit word at a time, Quartus
built it from registers. The road list RAMs keep 11 of 16 bits because the harness fixes the
road code mask, and the scroll RAMs are the drawn 8K words, not the 32 KB window the core backs.
