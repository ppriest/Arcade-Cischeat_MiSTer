# Video helpers - provenance

Two modules at the video-output boundary. Neither is part of the emulated hardware; both are MiSTer
integration code, vendored because they are the family's proven implementations and rewriting them
would be a needless divergence.

## `screen_rotate_two.sv`

Screen +90/-90 degree rotation for HDMI, Copyright (C) 2020 Sorgelig, GPL-2.0-or-later as stated in
the file header. It rotates through a DDR3 frame buffer.

Taken from `Arcade-Seta_MiSTer/rtl/video/screen_rotate_two.sv`. This file is **byte-identical in
all 15 sibling `Arcade-*_MiSTer` cores** (SHA-256 compared across the family at vendoring), so
there is no sibling variant to choose between and no local change to carry: it is MiSTer-devel's
file, unmodified everywhere. **Unchanged** here.

This is one of the two sanctioned DDR3 users in this core (`docs/ROADMAP.md`: "DDR3 is the loader
and the rotator only"). Rotation is an OSD option; with it off the DDR3 port is idle.

## `crt_adjust.sv`

"CRT Adjust" - core-side CRT geometry (H-Size, H-Position, V-Shift) by Umberto Parisi (rmonic79),
GPL-3.0-or-later, from `rmonic79/Arcade-Raiden_MiSTer` `rtl/Raiden/crt_adjust.sv`, via
`Arcade-Fuuki_MiSTer`.

Taken from `Arcade-Seta_MiSTer/rtl/video/crt_adjust.sv`, which is the copy shared by Eolith,
GStream, JalecoMS32, NixPirates and Vamphalf (SHA-256 identical). It carries **one** change against
Fuuki's copy:

| change | why |
|---|---|
| `hoff_s`'s zero branch is `$signed({(AW+2){1'b0}})` instead of an unsigned constant | the ternary was otherwise unsigned, so `hoffset` zero-extended and a negative H-Position blanked the picture instead of shifting it. Found by Seta's `sim/seta_crt_tb`. |

Otherwise **unchanged**; re-vendor rather than edit. The file's own header records the change.

`crt_adjust.sv` needs an external read-rate generator for `pxl2_cen` when H-Size is non-zero;
`crt_chain.sv` provides it.

## `crt_vsize.sv`

"CRT V-Size" by Umberto Parisi (rmonic79), GPL-3.0-or-later, from `rmonic79/MiSTer-CRT-Adjust`
`rtl/crt_vsize.sv` (commit c682de9, per its header). Taken from `Arcade-Pandora_MiSTer`; SHA-256
identical in DecoMLC, DreamWorld, Pandora and Silkroad. **Unchanged**.

## `crt_chain.sv`

The glue: native raster -> `crt_vsize` -> `crt_adjust` -> `arcade_video`, with the H-Size read-rate
generator and the PVM-mode VSync delay. Taken from `Arcade-Pandora_MiSTer` at 23ffd9a, the newest
of the four sibling variants: it carries the HBlank regeneration through vertical blank that the
framework's scandoubler needs (Pandora issue #1). One change: a comment named Psikyo's blanking.
The board's numbers are parameters set in `Cischeat.sv` (384 x 260 total, 256 active, 8 clk a
pixel, 4 lines between the picture and VSync).

## Tests

`crt_adjust.sv` was proved in Seta's `sim/seta_crt_tb`, which is where the signed-offset bug was
found. That bench depends on Seta's own video timing module, so it is not carried over; Phase 2
re-proves the wiring against captured frames (`docs/WORKFLOW.md`, video comparison), which catches
a mis-driven offset far more directly than the unit bench. `screen_rotate_two.sv` is unchanged
MiSTer-devel code proved in the sibling cores on hardware.
