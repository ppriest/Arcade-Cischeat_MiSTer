// SPDX-License-Identifier: GPL-3.0-or-later
//
// Granules per 64 us line through sdram_arbiter -> sdram_phy -> sdram.sv -> the
// command-decoding chip model, every client always asking, at 48 or 96 MHz.
// Checks each granule against the pattern written at the start.
//
//     scripts/run_verilator.sh sdram_tb [+MHZ=48]

`timescale 1ns / 1ps

module tb_sdram;

	localparam int N = 10;

	int mhz = 96;
	initial void'($value$plusargs("MHZ=%d", mhz));
	logic clk = 1'b0;
	always #(mhz == 48 ? 10.416 : 5.208) clk = ~clk;
	logic reset = 1'b1, init = 1'b1;

	wire  [15:0] dq;
	logic [12:0] a;
	logic [1:0]  ba;
	logic        ncs, nwe, nras, ncas, dqml, dqmh;

	logic [25:1] p_addr;
	logic        p_wrl, p_wrh, p_req, p_ack;
	logic [15:0] p_din;
	logic [63:0] p_dout;

	sdram u_sdram (
		.SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(ba),
		.SDRAM_nCS(ncs), .SDRAM_nWE(nwe), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas),
		.SDRAM_CLK(), .SDRAM_CKE(),
		.init, .clk,
		.addr0(p_addr), .wrl0(p_wrl), .wrh0(p_wrh), .din0(p_din), .dout0(p_dout), .req0(p_req), .ack0(p_ack),
		.addr1('0), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(), .req1(1'b0), .ack1(),
		.addr2('0), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(), .req2(1'b0), .ack2()
	);

	sdram_chip_model_wide u_chip (
		.clk, .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba), .SDRAM_nCS(ncs), .SDRAM_nWE(nwe),
		.SDRAM_nRAS(nras), .SDRAM_nCAS(ncas)
	);

	logic        phy_req, phy_we, phy_we16, phy_busy, phy_valid;
	logic [25:0] phy_addr;
	logic [15:0] phy_wdata;
	logic [63:0] phy_rdata;

	sdram_phy u_phy (
		.clk, .reset,
		.port_addr(p_addr), .port_wrl(p_wrl), .port_wrh(p_wrh), .port_din(p_din),
		.port_dout(p_dout), .port_req(p_req), .port_ack(p_ack),
		.req(phy_req), .we(phy_we), .we16(phy_we16), .addr(phy_addr), .wdata(phy_wdata),
		.busy(phy_busy), .valid(phy_valid), .rdata(phy_rdata)
	);

	logic [N-1:0]    c_req, c_valid;
	logic [26*N-1:0] c_addr;
	logic [63:0]     c_rdata;
	logic            dl_req = 1'b0, dl_busy;
	logic [25:0]     dl_addr = '0;
	logic [15:0]     dl_data = '0;

	sdram_arbiter #(.N(N)) u_arb (
		.clk, .reset,
		.phy_req, .phy_we, .phy_we16, .phy_addr, .phy_wdata, .phy_busy, .phy_valid, .phy_rdata,
		.c_req, .c_addr, .c_we('0), .c_we16('0), .c_wdata('0), .c_valid, .c_rdata,
		.dl_req, .dl_addr, .dl_data, .dl_we16(1'b1), .dl_busy
	);

	// word w of the pattern: a hash of its address
	function automatic logic [15:0] pat(input logic [23:0] w);
		return w[15:0] ^ {w[23:16], w[23:16]} ^ 16'h5a3c;
	endfunction

	// each client asks again the clock after its valid, at a pseudo-random granule
	logic [31:0] lfsr [N];
	logic [N-1:0] running = '0;
	longint served = 0, bad = 0, t0 = 0, worst = 0;
	longint since [N];

	always_ff @(posedge clk)
		for (int c = 0; c < N; c++) begin
			if (!running[c]) begin
				c_req[c] <= 1'b0;
			end else if (c_valid[c]) begin
				logic [23:0] w;
				w = {c_addr[26*c +: 26]} >> 1;
				for (int k = 0; k < 4; k++)
					if (c_rdata[16*k +: 16] !== pat(w + 24'(k))) bad++;
				served++;
				if (since[c] > worst) worst = since[c];
				c_req[c] <= 1'b0;
				lfsr[c]  <= {lfsr[c][30:0], lfsr[c][31] ^ lfsr[c][21] ^ lfsr[c][1] ^ lfsr[c][0]};
				// 512 KB window per client, granule aligned
				c_addr[26*c +: 26] <= {1'b0, 6'(c), lfsr[c][15:0], 3'b000};
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
		end
		c_addr = '0;
		for (int c = 0; c < N; c++) c_addr[26*c +: 26] = {1'b0, 6'(c), 16'(c * 77), 3'b000};
		for (int c = 0; c < N; c++)
			for (int w = 0; w < (1 << 19); w++)
				u_chip.poke_word_addr(24'({c[5:0], 18'd0}) + 24'(w), pat(24'({c[5:0], 18'd0}) + 24'(w)));
		repeat (4) @(posedge clk);
		init  <= 1'b0;
		reset <= 1'b0;
		repeat (1000) @(posedge clk);   // controller init
		running <= '1;
		t0 = $time;
		repeat (100 * 64 * mhz) @(posedge clk);
		$display("%0d MHz, %0d clients: %0d granules in 100 lines = %0d per line, %0.2f clk each; worst wait %0d clk; %0d bad words",
		         mhz, N, served, served / 100, 6400.0 * mhz / served, worst, bad);
		$finish;
	end

endmodule
