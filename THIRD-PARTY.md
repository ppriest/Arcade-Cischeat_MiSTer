# Third-party code and licences

**This project is GPL-3.0-or-later.** `LICENSE` carries the GPLv3 text.

That is forced rather than preferred. Every CPU core and every reusable chip module this project
vendors is GPL-3 (or LGPL-3), so a work containing them must be GPLv3 or GPL-3.0-or-later. The
combination is lawful only because the `sys/` framework carries an "or later" grant - see below -
and the consequence is permanent in one direction:

> **Code can flow in from GPL-2-or-later MiSTer cores. It cannot flow back out to them.**

The sibling cores this project inherits its practice from - `Arcade-Psikyo_MiSTer`,
`Arcade-Fuuki_MiSTer`, `Arcade-Seta_MiSTer`, `Arcade-KonamiGX_MiSTer` - already carry the GPLv3
text, so this is not a divergence from them.

## Status

Entries are marked **in the tree** once their `PROVENANCE.md` exists, and **planned** until then.
Each vendored directory's `PROVENANCE.md` names the exact upstream commit and records every local
change; this file records only what each dependency obliges.

## Dependencies

### ijor/fx68k - GPLv3 - **in the tree**

<https://github.com/ijor/fx68k>, Copyright (c) 2018, 2021 Jorge Cwik. The cycle-accurate 68000,
`rtl/cpu/fx68k/`, taken unchanged from `Arcade-KonamiGX_MiSTer` (which carries Seta's). GPLv3 into
GPL-3.0-or-later is direct. **Five** instances: main CPU, two road CPUs, sound CPU, and the extra
68000 on `wildplt`/`f1gpstr2`. Its `PROVENANCE.md` lists the two carried-in changes (packed structs
for Verilator; `stop_out` for savestates) and the `$readmemb` paths that force the repository root
as the build's working directory. Error-corrected FX68K was chosen over TG68K.C on measured area
(`docs/ROADMAP.md`, area budget).

### jotego/jt51 - GPL-3.0 - **in the tree**

<https://github.com/jotego/jt51>, Jose Tejada Gomez. YM2151, `rtl/sound/jt51/`, upstream
`985a573d` via `Arcade-Silkroad_MiSTer` `ec45cfb`, `hdl/` only, **unmodified**. The repository
`LICENSE` is the GPLv3 text. Obligations: publish the source, and keep the `LICENSE` file beside it.

### jotego/jt6295 - GPL-3.0 - **in the tree**

<https://github.com/jotego/jt6295>, upstream `7d76b0be` via `Arcade-Fuuki_MiSTer` `8e70617`,
`hdl/` and `LICENSE`, **unmodified**. Two OKI M6295 instances at 4 MHz. `rtl/sound/jt6295/PROVENANCE.md`
records that `jt12_comb.v`/`jt12_interpol.v` travel with it for the optional interpolator.

### Sorgelig's `sdram.v`, as adapted by the sibling cores - GPL-3.0-or-later - **in the tree**

Copyright (c) 2018 Sorgelig. `rtl/memory/sdram/sdram.sv` is the burst-4 adaptation proved on
hardware in `Arcade-Psikyo_MiSTer`, carried through Fuuki and Seta untouched, with the upstream file
kept beside it as `sdram_upstream_reference.sv`. The surrounding stack
(`sdram_phy.sv`, `sdram_arbiter.sv`, `sdram_download.sv`, `sdram_narrow_bridge.sv`, `rom_loader.sv`,
`ddram_phy.sv`) came from the same Fuuki tree. See `rtl/memory/PROVENANCE.md` and
`rtl/memory/sdram/PROVENANCE.md`.

### jotego/jtcores - GPL-3.0-or-later - **in the tree** (one primitive)

<https://github.com/jotego/jtcores>, Jose Tejada Gomez and contributors, commit `e7958c86`, path
`modules/jtframe/hdl/`. Only `jtframe_dual_ram16.v` is taken, and it is **unmodified**; it is the
dual-port RAM the line buffer and instruction caches use. The jtframe framework itself (bus, clocks, video, object pipeline) is not used: `sys/`
is the framework here. Files are added one at a time as a vendored module needs them, recorded in
`rtl/jtframe/PROVENANCE.md`.

Obligations: publish the source, and **GPLv3 section 5(a)** - any modified file must carry a
prominent dated change notice. There are none today.

### rmonic79's CRT Adjust - GPL-3.0-or-later - **in the tree**

Umberto Parisi (rmonic79), from `Arcade-Raiden_MiSTer` `rtl/Raiden/crt_adjust.sv`, via
`Arcade-Fuuki_MiSTer`, in `rtl/video/crt_adjust.sv`. Carries Seta's one fix (a signed offset
constant) so a negative H-Position shifts instead of blanking. `rtl/video/PROVENANCE.md` has it.

### screen_rotate_two - GPL-2.0-or-later - **in the tree**

Copyright (C) 2020 Sorgelig, `rtl/video/screen_rotate_two.sv`. MiSTer-devel code, byte-identical in
all 15 sibling cores, unmodified. GPL-2.0-or-later is upward-compatible with GPL-3. Uses DDR3, as
`docs/ROADMAP.md` permits for the rotator only.

### JimmyStones/Hiscores_MiSTer - GPL-3.0-or-later - **in the tree**

Alan Steremberg and Jim Gregory: `rtl/hiscore/hiscore.v`, version 14, by way of
`Arcade-Psikyo_MiSTer` (read-latency changes) and `Arcade-KonamiGX_MiSTer` (the `[GX]` changes that
keep Quartus from building the tables in registers). `rtl/hiscore/PROVENANCE.md` has both, and
`hiscore.v_psikyo_reference` is the diffable input. The tables are MAME's `hiscore.dat`, written
into the `.mra` at build time.

### MiSTer-devel/Template_MiSTer and `sys/` - GPL-2.0-or-later

<https://github.com/MiSTer-devel/Template_MiSTer> - framework, `hps_io`, the scaler, `sys_top`.
**In the tree already**, as seeded.

The Template repository's own `LICENSE` carries the **GPLv2** text, but every source file header in
`sys/` reads "either version 2 of the License, or (at your option) any later version". **That
or-later clause is the only reason the combination in this repository is lawful**: it permits using
`sys/` under GPL-3.

Do not edit `sys/`. Framework updates overwrite it. Build-time behaviour changes go in the `.qsf`
as `VERILOG_MACRO` settings, which is a project decision rather than a modification of `sys/`.

### wickerwaka's cheat engine - GPL-2.0-or-later - *planned*

Martin Donlon (wickerwaka), after Kitrinx's cheat handling: `cheatengine.sv`, from
MiSTer-devel/Arcade-IremM92_MiSTer. GPL-2.0-or-later, so usable under GPL-3. Only needed if Phase 6's
cheats are built (`docs/ROADMAP.md` calls them optional); byte lanes would change for the
big-endian 68000. The cheats themselves are converted from Pugsy's MAME cheats by script.

## Reference material, not code

MAME (<https://github.com/mamedev/mame>) is this project's **behavioural specification**. No MAME
source is copied into this repository. `src/mame/jaleco/cischeat.cpp`, `jaleco/ms1_gatearray.cpp`
and the device emulations it instantiates are BSD-3-Clause; the roadmap cites them by file and line
as documentation, and simulations use them as the reference to match.

## Release checklist

Before publishing a build:

1. Every vendored directory has a `PROVENANCE.md` naming the upstream repository, the exact commit,
   the licence **as stated in the files** (not as reported by a licence detector), and what was
   changed here.
2. Every modified vendored file carries a dated GPLv3 section 5(a) change notice, appended to
   whatever upstream wrote rather than replacing it.
3. Every file this project wrote starts with `// SPDX-License-Identifier: GPL-3.0-or-later` and a
   copyright line.
4. `sys/` is unmodified against upstream Template_MiSTer.
5. `LICENSE` is the GPLv3 text.
6. Vendored bytes still match their recorded upstream copies (`-text` in `.gitattributes`; re-hash
   against the source tree).
