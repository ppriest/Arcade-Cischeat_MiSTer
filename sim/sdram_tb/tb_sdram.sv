// SPDX-License-Identifier: GPL-3.0-or-later
//
// Granules per 64 us line through sdram_sched -> the timing-checking chip model
// at 96 MHz, every client always asking. Client N-1 alternates writes (the
// pattern's own value, of one or both bytes) with reads. Each granule is checked
// against the pattern; the model counts timing violations.
//
//     scripts/run_verilator.sh sdram_tb [+SPREAD=1]
//
// +SPREAD=1 gives each client the whole 16 MB, so bank 11 rows (DQM) occur.

`timescale 1ns / 1ps

module tb_sdram;

	localparam int N = 10;

	int spread = 0;
	initial void'($value$plusargs("SPREAD=%d", spread));
	logic clk = 1'b0;
	always #5.208 clk = ~clk;
	logic reset = 1'b1, init = 1'b1;

	wire  [15:0] dq;
	logic [12:0] a;
	logic [1:0]  ba;
	logic        ncs, nwe, nras, ncas, dqml, dqmh, cke;

	logic [N-1:0]    c_req, c_valid, c_we, c_we16;
	logic [26*N-1:0] c_addr;
	logic [16*N-1:0] c_wdata;
	logic [63:0]     c_rdata;
	logic            dl_busy;

	sdram_sched #(.N(N)) u_sched (
		.clk, .reset, .init,
		.c_req, .c_addr, .c_we, .c_we16, .c_wdata, .c_valid, .c_rdata,
		.dl_req(1'b0), .dl_addr('0), .dl_data('0), .dl_we16(1'b0), .dl_busy,
		.SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(ba),
		.SDRAM_nCS(ncs), .SDRAM_nWE(nwe), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_CKE(cke)
	);

	sdram_chip_model_timed u_chip (
		.clk, .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba), .SDRAM_nCS(ncs), .SDRAM_nWE(nwe),
		.SDRAM_nRAS(nras), .SDRAM_nCAS(ncas)
	);

	// word w of the pattern: a hash of its address
	function automatic logic [15:0] pat(input logic [23:0] w);
		return w[15:0] ^ {w[23:16], w[23:16]} ^ 16'h5a3c;
	endfunction

	localparam int WORDS = 1 << 23;     // 16 MB

	logic [31:0] lfsr [N];
	logic [N-1:0] running = '0;
	longint served = 0, bad = 0, worst = 0, nwrites = 0;
	longint since [N], cworst [N];

	function automatic logic [25:0] next_addr(input int c, input logic [31:0] r);
		if (spread != 0) return {2'b00, r[20:0], 3'b000};
		return {1'b0, 6'(c), r[15:0], 3'b000};   // 512 KB window per client
	endfunction

	always_ff @(posedge clk)
		for (int c = 0; c < N; c++) begin
			if (!running[c]) begin
				c_req[c] <= 1'b0;
			end else if (c_req[c] && c_valid[c]) begin
				logic [23:0] w;
				logic [31:0] r;
				w = 24'(c_addr[26*c +: 26] >> 1);
				if (c_we[c]) nwrites++;
				else begin
					for (int k = 0; k < 4; k++)
						if (c_rdata[16*k +: 16] !== pat(w + 24'(k))) begin
							if (bad < 10) $display("bad: client %0d word %h: %h, want %h",
							                       c, w + 24'(k), c_rdata[16*k +: 16], pat(w + 24'(k)));
							bad++;
						end
					served++;
				end
				if (since[c] > worst) worst = since[c];
				if (since[c] > cworst[c]) cworst[c] = since[c];
				c_req[c] <= 1'b0;
				r = {lfsr[c][30:0], lfsr[c][31] ^ lfsr[c][21] ^ lfsr[c][1] ^ lfsr[c][0]};
				lfsr[c] <= r;
				c_we[c] <= 1'b0;
				c_addr[26*c +: 26] <= next_addr(c, r);
				if (c == N-1 && !c_we[c]) begin
					// a write of the pattern's value: both bytes, or the one at addr[0]
					logic [25:0] wa;
					logic [15:0] v;
					wa = {next_addr(c, r)[25:3], r[25:24], r[26] & ~r[27]};
					v  = pat(24'(wa >> 1));
					c_we[c]   <= 1'b1;
					c_we16[c] <= r[27];
					c_addr[26*c +: 26] <= r[27] ? {wa[25:1], 1'b0} : wa;
					c_wdata[16*c +: 16] <= r[27] ? v : wa[0] ? {8'h00, v[15:8]} : {8'h00, v[7:0]};   // addr[0]: bits 15:8
				end
				since[c] <= 0;
			end else begin
				c_req[c] <= 1'b1;
				since[c] <= since[c] + 1;
			end
		end

	initial begin
		for (int c = 0; c < N; c++) begin
			lfsr[c] = 32'h1234567 * (c + 1) + 1;
			since[c] = 0;
			cworst[c] = 0;
		end
		c_addr = '0;
		c_we = '0;
		c_we16 = '0;
		c_wdata = '0;
		for (int c = 0; c < N; c++) c_addr[26*c +: 26] = next_addr(c, 32'(c * 77));
		for (int w = 0; w < WORDS; w++) u_chip.poke_word_addr(24'(w), pat(24'(w)));
		repeat (4) @(posedge clk);
		init  <= 1'b0;
		reset <= 1'b0;
		repeat (1000) @(posedge clk);   // controller init
		running <= '1;
		repeat (100 * 64 * 96) @(posedge clk);
		$display("96 MHz, %0d clients%s: %0d granules in 100 lines = %0d per line, %0.2f clk each; %0d writes; worst wait %0d clk; %0d bad words; %0d reads, %0d writes at the chip; refresh gap max %0d; %0d timing errors",
		         N, spread != 0 ? " over 16 MB" : "", served, served / 100, 6400.0 * 96 / served, nwrites,
		         worst, bad, u_chip.reads, u_chip.writes, u_chip.ref_gap_max, u_chip.errors);
		for (int c = 0; c < N; c++) $write("%0d ", cworst[c]);
		$display("worst wait per client");
		if (bad != 0 || u_chip.errors != 0) $display("FAIL");
		else $display("PASS");
		$finish;
	end

endmodule
