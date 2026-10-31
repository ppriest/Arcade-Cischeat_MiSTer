# Cischeat state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| main work RAM | `cischeat_board` `u_work` | 16 x 32K | 65,536 | yes; port B is free outside the latch copy |
| shared RAM, road1 | `u_sh1` | 16 x 16K | 32,768 | yes |
| shared RAM, road2 | `u_sh2` | 16 x 16K | 32,768 | yes |
| scroll RAM 0..2 | `scr[n].u` | 16 x 16K each | 98,304 | yes |
| palette | `u_pal` | 16 x 16K | 32,768 | yes |
| road line lists | `u_rl0`, `u_rl1` | 16 x 1K each | 4,096 | yes |
| road CPU local RAM | `road[n].u_loc` | 16 x 8K each | 32,768 | yes; port B unused |
| link RAM | `u_link` | 16 x 1K | 2,048 | yes; port B unused |
| latched sprite list | `sl[k].mem` | 8 lanes of 16 x 256 | 4,096 | no if restored at `frame_start` before the latch: re-copied at row 4 |
| display line buffer | `u_disp` | 24 x 512 | — | no: rewritten every line |
| video line buffers | `cischeat_video` | — | — | no: rewritten every line |
| sound work RAM | SDRAM `0x03e0000` | 16 x 32K | 65,536 | yes, through the SDRAM |
| io shared RAM (F-1 Grand Prix Star II) | `u_iosh` | 16 x 2K | 4,096 | yes, section 19 |
| io CPU local RAM | `u_ioloc` | 16 x 8K | 16,384 | yes, section 20; port B unused |
| Wild Pilot sprite DMA buffer | `u_dma` | 16 x 2K | 4,096 | yes, section 21 |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| scroll registers, CPU side and latched | `scroll`, `v_scroll` | 2 x 9 x 16 | yes | `m_scrollx`, `m_scrolly`, `m_scroll_flag` |
| sound latches | `sl_to_sound`, `sl_to_main` | 32 | yes | `generic_latch_16` |
| ip_select, comms | `ip_select`, `comms` | 19 | yes | `m_ip_select`; comms is the CPUs' reset lines |
| gate array handshake | `ga_ram`, `ga_hs` | 81 | yes | `m_gatearray_hs_ram`, `m_gatearray_hs` |
| M6295 bank bits | `oki_bank` | 2 | yes | `set_rom_bank` |
| io CPU write and ready flag | `io_value`, `io_ready` | 9 | yes | `m_io_value`, `m_f1gpstr2_ioready` |
| Wild Pilot input mux, sprite DMA register | `wp_out`, `dma_reg` | 20 | yes | `m_wildplt_output`, `m_sprite_dma_reg` |
| pending interrupts | `board_cpu` `pend` | 7 per CPU | yes | HOLD_LINE state |
| screen counters, frame parity | `cischeat_timing` | 19 | yes | `screen` frame number |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| | | | | |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| | |

## Frame alignment

Restore point (normally `frame_start`), and anything whose phase must be saved with it: sprite or
tile double-buffer selection, snapshot ownership bits.
