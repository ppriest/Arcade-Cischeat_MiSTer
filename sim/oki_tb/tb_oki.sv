// SPDX-License-Identifier: GPL-3.0-or-later
//
// cischeat_oki chip 0 on its sample region (debug/oki_tb/oki0.hex: 256 K words of
// the loader image from 0x0e00000, even byte low), served LAT clk after each
// granule request. Starts phrase +PHRASE=n (default 1) on voice 0 and reports
// the output peak and the chip's ROM traffic.
//
//     scripts/run_verilator.sh oki_tb +PHRASE=1

`timescale 1ns / 1ps

module tb_oki;

	logic clk = 1'b0;
	always #10.416 clk = ~clk;
	logic reset = 1'b1;

	logic [15:0] rom [0:262143];
	initial $readmemh("debug/oki_tb/oki0.hex", rom);

	logic [1:0]  wr = 2'b00;
	logic [7:0]  wdata = 8'h00;
	logic [7:0]  dout [2];
	logic [1:0]  g_req, g_valid = 2'b00;
	logic [25:0] g_addr [2];
	logic [63:0] g_data;
	logic signed [13:0] snd [2];

	cischeat_oki dut (
		.clk, .reset, .wr, .wdata, .dout, .bank(2'b00),
		.g_req, .g_addr, .g_valid, .g_data, .snd
	);

	int lat = 8, wait_c = 0, reqs = 0;
	logic [1:0] req_d = 2'b00;
	always_ff @(posedge clk) begin
		g_valid <= 2'b00;
		req_d   <= g_req;
		if (g_req[0] && !g_valid[0]) begin
			if (wait_c == lat) begin
				wait_c     <= 0;
				g_valid[0] <= 1'b1;
				reqs       <= reqs + 1;
				for (int k = 0; k < 4; k++)
					g_data[16 * k +: 16] <= rom[{g_addr[0][18:3], 2'(k)}];
			end else wait_c <= wait_c + 1;
		end
	end

	int pk = 0, nz = 0, okc = 0, mn = 0, mx = 0;
	always_ff @(posedge clk) if (!reset) begin
		if ((snd[0] < 0 ? -int'(snd[0]) : int'(snd[0])) > pk) pk <= snd[0] < 0 ? -int'(snd[0]) : int'(snd[0]);
		if (snd[0] != 0) nz <= nz + 1;
		if (int'(snd[0]) < mn) mn <= int'(snd[0]);
		if (int'(snd[0]) > mx) mx <= int'(snd[0]);
		if (dut.chip[0].rom_ok) okc <= okc + 1;
	end

	task automatic cpu_wr(input logic [7:0] d);
		@(posedge clk) begin wdata <= d; wr <= 2'b01; end
		@(posedge clk) wr <= 2'b00;
		repeat (200) @(posedge clk);
	endtask

	int phrase = 1;
	initial begin
		void'($value$plusargs("PHRASE=%d", phrase));
		void'($value$plusargs("LAT=%d", lat));
		repeat (20) @(posedge clk);
		reset <= 1'b0;
		repeat (20000) @(posedge clk);
		$display("idle: dout %02x, peak %0d", dout[0], pk);
		cpu_wr(8'h80 | 8'(phrase));
		cpu_wr(8'h10);
		for (int ms = 1; ms <= 20; ms++) begin
			repeat (48000) @(posedge clk);
			$display("%2d ms: dout %02x, min %0d max %0d, peak %0d, nonzero clk %0d, granules %0d, rom_ok clk %0d, ctrl st %0d, start %06x stop %06x",
				ms, dout[0], mn, mx, pk, nz, reqs, okc, dut.chip[0].u_oki.u_ctrl.st,
				dut.chip[0].u_oki.u_ctrl.start_addr, dut.chip[0].u_oki.u_ctrl.stop_addr);
		end
		$finish;
	end

endmodule
