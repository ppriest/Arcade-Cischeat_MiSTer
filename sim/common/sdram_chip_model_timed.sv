// SPDX-License-Identifier: GPL-3.0-or-later
//
// SDR SDRAM (32 MB, 4 banks x 8192 rows x 512 columns) for sdram_sched.sv:
// overlapping bursts, DQM read masking two clocks after it is sampled, and
// checks of the command timing at 96 MHz (tRCD 2, tRP 2, tRAS 5, tRC 7, tRRD 2,
// tRFC 7, tWR 2, bank state, bus turnaround, refresh interval). Each violation
// is counted in `errors` and the first 20 are printed.
//
// mem is indexed by word address under sdram_sched's mapping, so a bench can
// fill it linearly: word w = {row, col[8:2], bank, col[1:0]}. SWIZZLE = 1 undoes
// cischeat_sdram's bank remap (bank = a[4:3] ^ a[8:7], col[5:4] = a[8:7]).

module sdram_chip_model_timed #(
	parameter int REF_MAX = 750,         // clocks between refreshes (7.8 us at 96 MHz)
	parameter bit SWIZZLE = 1'b0
) (
	input  logic         clk,
	inout  wire  [15:0]  SDRAM_DQ,
	input  logic [12:0]  SDRAM_A,
	input  logic [1:0]   SDRAM_BA,
	input  logic         SDRAM_nCS,
	input  logic         SDRAM_nWE,
	input  logic         SDRAM_nRAS,
	input  logic         SDRAM_nCAS
);

	localparam logic [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100,
	                       C_PRE = 3'b010, C_REF = 3'b001, C_MODE = 3'b000, C_BST = 3'b110;
	localparam int T_RCD = 2, T_RP = 2, T_RAS = 5, T_RC = 7, T_RRD = 2, T_RFC = 7, T_WR = 2;

	wire [2:0] cmd = SDRAM_nCS ? C_NOP : {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};

	logic [15:0] mem [0:16777215];

	function automatic int unsigned widx(input logic [1:0] b, input logic [12:0] row, input logic [8:0] col);
		return {row, col[8:2], SWIZZLE ? b ^ col[5:4] : b, col[1:0]};
	endfunction

	longint cyc = 0;
	int     errors = 0;
	longint ref_gap_max = 0, last_ref = -1, reads = 0, writes = 0;

	logic        open [4];
	logic [12:0] row [4];
	longint      t_act [4], t_idle [4];
	longint      t_act_any = -100, t_read = -100, t_mode = -1;
	logic [12:0] mode_reg = '0;

	// read data: slot s drives the word sampled at cycle s+1
	logic        sl_v [16];
	int unsigned sl_w [16];
	logic [1:0]  dqm_h [4];               // DQM sampled at cyc, cyc-1, ...

	logic        driving = 1'b0;
	logic [15:0] drive_word;
	longint      last_drive = -100;
	assign SDRAM_DQ = driving ? drive_word : 16'bz;

	initial
		for (int b = 0; b < 4; b++) begin
			open[b] = 1'b0;
			t_act[b] = -100;
			t_idle[b] = 0;
		end
	initial for (int s = 0; s < 16; s++) sl_v[s] = 1'b0;
	initial for (int k = 0; k < 4; k++) dqm_h[k] = 2'b00;

	task automatic err(input string what);
		if (errors < 20) $display("sdram model: cycle %0d: %s", cyc, what);
		errors++;
	endtask

	always_ff @(posedge clk) begin
		int s;
		logic [1:0] b;
		b = SDRAM_BA;
		cyc <= cyc + 1;
		for (int k = 3; k > 0; k--) dqm_h[k] <= dqm_h[k-1];
		dqm_h[0] <= SDRAM_A[12:11];

		// banks with auto-precharge close themselves at t_idle
		for (int k = 0; k < 4; k++) if (open[k] && t_idle[k] != 0 && cyc >= t_idle[k]) open[k] <= 1'b0;

		if (last_ref >= 0 && cyc < last_ref + T_RFC && cmd != C_NOP)
			err("command inside tRFC");

		case (cmd)
			C_ACT: begin
				if (open[b] && !(t_idle[b] != 0 && cyc >= t_idle[b])) err($sformatf("ACTIVE to open bank %0d", b));
				if (cyc < t_idle[b]) err($sformatf("ACTIVE to bank %0d before precharge done", b));
				if (cyc - t_act[b] < T_RC) err($sformatf("tRC bank %0d", b));
				if (cyc - t_act_any < T_RRD) err("tRRD");
				open[b]  <= 1'b1;
				row[b]   <= SDRAM_A;
				t_act[b] <= cyc;
				t_idle[b] <= 0;
				t_act_any <= cyc;
			end
			C_READ, C_WRITE: begin
				longint pre;
				if (!open[b] || t_idle[b] != 0) err($sformatf("CAS to closed bank %0d", b));
				if (cyc - t_act[b] < T_RCD) err($sformatf("tRCD bank %0d", b));
				if (!SDRAM_A[10]) err("CAS without auto-precharge");
				if (cmd == C_READ) begin
					reads <= reads + 1;
					if (cyc - t_read < 4) err("READ interrupts a burst");
					t_read <= cyc;
					for (int k = 0; k < 4; k++) begin
						s = int'((cyc + 1 + k) % 16);
						if (sl_v[s]) err("read data overlap");
						sl_v[s] <= 1'b1;
						sl_w[s] <= widx(b, row[b], {SDRAM_A[8:2], 2'(SDRAM_A[1:0] + 2'(k))});
					end
					pre = cyc + 4;
				end else begin
					int unsigned w;
					writes <= writes + 1;
					if (cyc - last_drive < 2) err("WRITE while the chip drives the bus");
					w = widx(b, row[b], SDRAM_A[8:0]);
					if (!SDRAM_A[11]) mem[w][7:0]  <= SDRAM_DQ[7:0];
					if (!SDRAM_A[12]) mem[w][15:8] <= SDRAM_DQ[15:8];
					pre = cyc + T_WR;
				end
				if (pre < t_act[b] + T_RAS) pre = t_act[b] + T_RAS;
				t_idle[b] <= pre + T_RP;
			end
			C_PRE: begin
				for (int k = 0; k < 4; k++)
					if (SDRAM_A[10] || k == int'(b)) begin
						if (open[k] && cyc - t_act[k] < T_RAS) err("tRAS at PRECHARGE");
						open[k] <= 1'b0;
						t_idle[k] <= cyc + T_RP;
					end
			end
			C_REF: begin
				for (int k = 0; k < 4; k++)
					if ((open[k] && !(t_idle[k] != 0 && cyc >= t_idle[k])) || cyc < t_idle[k])
						err($sformatf("REFRESH with bank %0d not idle", k));
				if (last_ref >= 0 && cyc - last_ref > ref_gap_max) ref_gap_max <= cyc - last_ref;
				if (t_mode >= 0 && last_ref >= 0 && cyc - last_ref > REF_MAX)
					err($sformatf("refresh interval %0d", cyc - last_ref));
				last_ref <= cyc;
			end
			C_MODE: begin
				mode_reg <= SDRAM_A;
				t_mode   <= cyc;
				if (SDRAM_A[6:4] != 3'd2 || SDRAM_A[2:0] != 3'd2 || SDRAM_A[3])
					err("mode is not CL2, burst 4 sequential");
			end
			C_BST: err("BURST TERMINATE");
			default: ;
		endcase

		// drive the word sampled next cycle; DQM sampled two cycles before that masks it
		s = int'(cyc % 16);
		driving <= 1'b0;
		if (sl_v[s]) begin
			sl_v[s] <= 1'b0;
			driving <= 1'b1;
			last_drive <= cyc;
			drive_word <= mem[sl_w[s]];
			// sampled at cyc+1; DQM at cyc-1 is dqm_h[0] before this edge's update
			if (dqm_h[0] != 2'b00) begin
				err("DQM masks read data");
				drive_word <= 16'hdead;
			end
		end
	end

	// word address in the controller's mapping
	function automatic void poke_word_addr(input logic [23:0] word_addr, input logic [15:0] data);
		mem[word_addr] = data;
	endfunction

	function automatic logic [15:0] peek_word_addr(input logic [23:0] word_addr);
		return mem[word_addr];
	endfunction

endmodule
