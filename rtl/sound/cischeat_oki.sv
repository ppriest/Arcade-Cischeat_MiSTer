// SPDX-License-Identifier: GPL-3.0-or-later
//
// The board's two OKI M6295 (jt6295) at 4 MHz, pin 7 high (cischeat.cpp 1809-1815), each on its
// 512 KB sample region in SDRAM with a one-bit bank latched by the sound CPU (256 KB halves,
// okim6295 set_rom_bank). The chip's ROM bus goes through oki_rom_bridge and sample_cache to one
// SDRAM client per chip.
//
// okim6295::write ignores a start for a voice that is already playing; jt6295 restarts it. The
// second byte of a start therefore reaches the chip with the busy voices masked off (dout[3:0]
// is busy | start); the first/second byte state follows jt6295_ctrl's own.

module cischeat_oki #(
	parameter logic [25:0] BASE0 = 26'h0e00000,
	parameter logic [25:0] BASE1 = 26'h0e80000
) (
	input  logic         clk,           // 48 MHz
	input  logic         reset,

	input  logic [1:0]   wr,            // one clk per CPU write to chip k
	input  logic [7:0]   wdata,
	output logic [7:0]   dout [2],
	input  logic [1:0]   bank,

	output logic [1:0]   g_req,         // held until g_valid
	output logic [25:0]  g_addr [2],
	input  logic [1:0]   g_valid,
	input  logic [63:0]  g_data,

	output logic signed [13:0] snd [2]
);

	// 4 MHz: one enable in 12
	logic [3:0] div;
	logic       cen;
	always_ff @(posedge clk)
		if (reset) begin
			div <= 4'd0;
			cen <= 1'b0;
		end else begin
			div <= (div == 4'd11) ? 4'd0 : div + 4'd1;
			cen <= div == 4'd11;
		end

	genvar k;
	generate
		for (k = 0; k < 2; k++) begin : chip
			logic pend;
			always_ff @(posedge clk)
				if (reset)      pend <= 1'b0;
				else if (wr[k]) pend <= !pend && wdata[7];
			wire [7:0] din = pend ? {wdata[7:4] & ~dout[k][3:0], wdata[3:0]} : wdata;

			logic [17:0] rom_addr;
			logic [7:0]  rom_data;
			logic        rom_ok;
			jt6295 #(.INTERPOL(0)) u_oki (
				.rst(reset), .clk, .cen, .ss(1'b1),
				.wrn(~wr[k]), .din, .dout(dout[k]),
				.rom_addr, .rom_data, .rom_ok,
				.sound(snd[k]), .sample()
			);

			logic        b_req, c_valid;
			logic [19:0] b_addr;
			logic [7:0]  c_data;
			oki_rom_bridge u_bridge (
				.clk, .reset,
				.rom_addr, .rom_data, .rom_ok, .bank({1'b0, bank[k]}),
				.req(b_req), .addr(b_addr), .valid(c_valid), .data(c_data)
			);

			sample_cache u_cache (
				.clk, .reset, .inval(1'b0),
				.req(b_req), .addr((k == 0 ? BASE0 : BASE1) + {7'd0, b_addr[18:0]}),
				.valid(c_valid), .data(c_data),
				.g_req(g_req[k]), .g_addr(g_addr[k]), .g_valid(g_valid[k]), .g_data
			);
		end
	endgenerate

endmodule
