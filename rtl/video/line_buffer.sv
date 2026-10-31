// SPDX-License-Identifier: GPL-3.0-or-later
//
// Double-buffered 256-pixel line: {bank, x} addresses one of two lines. Port A
// is the engine's write port; port B reads, registered, and may write (the
// mixer clears a sprite line after reading it). One M10K at W <= 20.
//
// Written as jtframe_dual_ram is: each port reads and may write, and
// no_rw_check, because the two ports never address the same bank at once.
// Without it Quartus 17 either built the sprite buffers, which write on both
// ports, from registers (13,000 ALMs) or stopped with error 276001.

module line_buffer #(
	parameter int W = 16
) (
	input  logic         clk,

	input  logic         a_we,
	input  logic [8:0]   a_addr,     // {bank, x}
	input  logic [W-1:0] a_d,

	input  logic [8:0]   b_addr,
	input  logic         b_we,
	input  logic [W-1:0] b_d,
	output logic [W-1:0] b_q
);

	(* ramstyle = "no_rw_check" *) reg [W-1:0] mem [0:511];
	reg [W-1:0] a_q;                // unused; keeps port A in the template

	always @(posedge clk) begin
		a_q <= mem[a_addr];
		if (a_we) mem[a_addr] <= a_d;
	end

	always @(posedge clk) begin
		b_q <= mem[b_addr];
		if (b_we) mem[b_addr] <= b_d;
	end

endmodule
