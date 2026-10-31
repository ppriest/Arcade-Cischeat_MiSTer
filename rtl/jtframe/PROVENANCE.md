# jtframe primitives - provenance

One file so far: `jtframe_dual_ram16.v`, a 16-bit dual-port RAM with clock enables and optional
input/output latches, from <https://github.com/jotego/jtcores> at commit
`e7958c86d79d549cf5b14b7bbdb517b109a21691`, path `modules/jtframe/hdl/jtframe_dual_ram16.v`.
SPDX header: `GPL-3.0-or-later`.

Taken from `Arcade-KonamiGX_MiSTer/rtl/jtframe/jtframe_dual_ram16.v`, where it is recorded as
**unmodified** and marked `-text`. Copied here **unchanged** (SHA-256 checked). `.gitattributes`
marks this directory `-text` too.

## Why it is here

The line buffer and the per-CPU instruction cache both need small dual-port RAMs with a clean
read-during-write policy and synthesis attributes that keep Quartus from building them from
registers. This is jotego's tested primitive for exactly that, and the sibling cores already
depend on its behaviour.

It is **not** a vendoring of jtframe. Only the file an instantiation needs belongs in `rtl/`; anything
a bench needs and the design does not (`jtframe_frac_cen`, `jtframe_vtimer`,
`jtframe_test_clocks`, `test_tasks.vh`) goes to `sim/` if it is needed at all. The framework
(`jtframe_*.v` bus, clocks, video) is not used: `sys/` is the framework here.

Add files to this directory one at a time as a vendored module needs them, and record what pulled
each one in.

## Tests

Upstream's jtframe benches are not part of this copy. The module is small enough that its
behaviour is proved where it is used: the line-buffer and line-cache benches in `rtl/synth_check/`
check read-during-write and the latch settings the design selects. Do not modify it; if a change
is unavoidable, keep the unmodified file beside it as `jtframe_dual_ram16.v_upstream_reference.v`
with the GPL-3.0 section 5(a) notice, as the sibling cores do.
