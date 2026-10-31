// SPDX-License-Identifier: GPL-3.0-or-later
//
// jt51 conformance bench, derived from jotego/jt51 `ver/common/jt51_test.vh`
// at commit 985a573. The upstream harness cannot run at that commit:
//
//   * jt51_test.vh is missing the comma after `.xright (xright)`, so it does
//     not parse on any simulator;
//   * ver/common/basic.f lists jt51_lfo_lfsr.v and jt51_csr_ch.v, which no
//     longer exist (renamed to jt51_noise_lfsr.v / jt51_reg_ch.v);
//   * ver/jt51_con/jt51_con.cc drives `d_in`/`d_out`, renamed to `din`/`dout`,
//     lacks `using namespace std`, and its config.vlt uses Verilator 4 lint
//     syntax that Verilator 5.050 rejects.
//
// This file is the upstream stimulus/replay logic with those mechanical fixes
// and the sample dump the C++ harness used to do, so the chip can be checked
// with the reference generator the bench itself uses (`bin/print_con`). The
// RTL under test and the stimuli in inputs.vh are upstream, unchanged.
// docs/VENDOR_TESTS.md records the run and the comparison.
`timescale 1ns / 1ps

module tb_jt51;

	reg clk;
	reg rst;
	reg cs_n;
	reg wr_n;
	reg a0;
	reg [7:0] din;

	wire [7:0] dout;
	wire ct1;
	wire ct2;
	wire irq_n;
	wire sample;
	wire signed [15:0] left, right, xleft, xright;

	reg cen_p1 = 0;

	always @(posedge clk)
		cen_p1 <= ~cen_p1;

	jt51 uut (
		.clk     (clk),
		.rst     (rst),
		.cen     (1'b1),
		.cen_p1  (cen_p1),
		.cs_n    (cs_n),
		.wr_n    (wr_n),
		.a0      (a0),
		.din     (din),
		.dout    (dout),
		.ct1     (ct1),
		.ct2     (ct2),
		.irq_n   (irq_n),
		.left    (left),
		.right   (right),
		.xleft   (xleft),
		.xright  (xright),
		.sample  (sample)
	);

	initial begin
		clk = 0;
		forever #140 clk = ~clk;
	end

	initial begin
		rst  = 0;
		cs_n = 1;
		wr_n = 1;
		a0   = 0;
		din  = 0;
		#10   rst = 1;
		#800  rst = 0;
		$display("dump start");
	end

	reg [15:0] cfg [0:511];

	initial begin
		`include "inputs.vh"
	end

	// The C++ harness dumped `left` on every rising edge of `sample`, skipping
	// the leading zeros until the first non-zero sample arrives.
	reg last_sample = 1'b0;
	reg wait_nonzero = 1'b1;

	always @(negedge clk) begin
		if (sample && !last_sample) begin
			if (!(left == 16'sd0 && wait_nonzero))
				$display("%0d", $signed(left));
			wait_nonzero <= 1'b0;
		end
		last_sample <= sample;
	end

	reg [8:0] data_cnt;
	reg [3:0] state, next;
	reg prog_done;
	reg [15:0] waitcnt;

	parameter WAIT_FREE = 0, WR_ADDR = 1, WR_VAL = 2, DONE = 3, WRITE = 4,
	          BLANK = 5, WAIT_CNT = 6;

	always @(posedge clk or posedge rst) begin
		if (rst) begin
			data_cnt  <= 0;
			prog_done <= 0;
			next      <= WR_ADDR;
			state     <= WAIT_FREE;
			waitcnt   <= 16'h0;
		end else begin
			case (state)
				BLANK: state <= WAIT_FREE;
				WAIT_FREE: begin
					{cs_n, wr_n} = 2'b01;
					if (!dout[7]) begin
						case (cfg[data_cnt][15:8])
							8'h0: state <= DONE;
							8'h1: begin
								waitcnt <= {cfg[data_cnt][7:0], 8'h0};
								state   <= WAIT_CNT;
							end
							8'h3: if (dout[1:0] & cfg[data_cnt][1:0]) state <= next;
							default: state <= next;
						endcase
					end
				end
				WAIT_CNT: begin
					if (!waitcnt) begin
						data_cnt <= data_cnt + 1'b1;
						state    <= WAIT_FREE;
					end else
						waitcnt <= waitcnt - 1'b1;
				end
				WRITE: begin
					{cs_n, wr_n} = 2'b00;
					state <= BLANK;
				end
				WR_ADDR: begin
					a0    <= 1'b0;
					din   <= cfg[data_cnt][15:8];
					next  <= WR_VAL;
					state <= WRITE;
				end
				WR_VAL: begin
					a0    <= 1'b1;
					din   <= cfg[data_cnt][7:0];
					state <= WRITE;
					if (data_cnt == 9'd511)
						next <= DONE;
					else begin
						data_cnt <= data_cnt + 1'b1;
						next     <= WR_ADDR;
					end
				end
				DONE: prog_done <= 1'b1;
			endcase
		end
	end

	// jt51_test.v: 80 ms after programming finishes, then stop.
	integer cnt0;

	initial cnt0 = 0;

	always @(posedge clk) begin
		if (rst) begin
			cnt0 <= 0;
		end else if (prog_done) begin
			#80000000;
			$display("dump end");
			$finish;
		end
	end

	initial #(100 * 1000 * 1000) $finish;

endmodule
