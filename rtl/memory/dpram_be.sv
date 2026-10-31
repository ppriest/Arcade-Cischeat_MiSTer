// SPDX-License-Identifier: GPL-3.0-or-later
//
// True dual-port 16-bit RAM with a byte enable per lane on both ports,
// registered reads. Each lane is its own 8-bit RAM in the jtframe form (see
// line_buffer.sv): Quartus 17 does not infer byte enables on a true dual port.
//
// A read and a write of the same word on different ports in one clock return
// undefined data on the reading port (no_rw_check).

module dpram_be #(
	parameter int AW = 10
) (
	input  logic          clk,

	input  logic [AW-1:0] a_addr,
	input  logic [1:0]    a_we,      // {upper, lower}
	input  logic [15:0]   a_d,
	output logic [15:0]   a_q,

	input  logic [AW-1:0] b_addr,
	input  logic [1:0]    b_we,
	input  logic [15:0]   b_d,
	output logic [15:0]   b_q
);

	(* ramstyle = "no_rw_check" *) reg [7:0] hi [0:(1 << AW) - 1];
	(* ramstyle = "no_rw_check" *) reg [7:0] lo [0:(1 << AW) - 1];

	always @(posedge clk) begin a_q[15:8] <= hi[a_addr]; if (a_we[1]) hi[a_addr] <= a_d[15:8]; end
	always @(posedge clk) begin b_q[15:8] <= hi[b_addr]; if (b_we[1]) hi[b_addr] <= b_d[15:8]; end
	always @(posedge clk) begin a_q[7:0]  <= lo[a_addr]; if (a_we[0]) lo[a_addr] <= a_d[7:0];  end
	always @(posedge clk) begin b_q[7:0]  <= lo[b_addr]; if (b_we[0]) lo[b_addr] <= b_d[7:0];  end

endmodule
