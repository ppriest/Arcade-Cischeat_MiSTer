// SPDX-License-Identifier: GPL-3.0-or-later
//
// N clients onto one SDR SDRAM (MT48LC16M16 / AS4C32M16), bank-interleaved:
// arbiter and controller in one, replacing sdram_arbiter -> sdram_phy -> sdram.sv
// with the same client interface and the same pin timing (command registers
// one clock ahead of the chip, CAS latency 2, burst 4, the bus captured once
// into dq_in, lanes taken from it 4..7 clocks after READ is registered).
//
// Mapping (byte address a): bank = a[4:3], column = {a[25] at A9, a[11:5],
// a[2:1]}, row = a[24:12]. Consecutive granules fall in consecutive banks.
// The chip model (sim/common/sdram_chip_model_timed.sv) inverts this, so its
// memory is indexed by word address.
//
// Every access is ACTIVE at t, READ or WRITE with auto-precharge at t+2. The
// next ACTIVE may follow 2 clocks after a READ, so a READ every 4 clocks when
// the banks allow. The pick prefers clients whose bank is free.
//
// DQML/DQMH are A11/A12 (sys and the MiSTer modules that tie them): DQM masks
// read data 2 clocks later, so an ACTIVE whose row has bit 11 or 12 set waits
// 4 clocks after the last READ, and A[12:11] is 0 on every other command.
//
// A read's c_valid pulses one cycle with c_rdata, which holds until the next
// read returns (4 or more cycles). A write's c_valid follows its WRITE; a later
// read of that bank waits for the precharge, so it sees the write. A request is
// the rising edge of c_req; the ROM download (dl_req, a level until dl_busy)
// goes first.

module sdram_sched #(
	parameter int N = 4,
	parameter logic [N-1:0] LOW = '0     // served only when no other client can be
) (
	input  logic clk,
	input  logic reset,                   // clients and returns only; timing state runs on
	input  logic init,                    // the power-up sequence restarts on its fall

	input  logic [N-1:0]      c_req,
	input  logic [26*N-1:0]   c_addr,
	input  logic [N-1:0]      c_we,
	input  logic [N-1:0]      c_we16,
	input  logic [16*N-1:0]   c_wdata,
	output logic [N-1:0]      c_valid,
	output logic [63:0]       c_rdata,

	input  logic         dl_req,
	input  logic [25:0]  dl_addr,
	input  logic [15:0]  dl_data,
	input  logic         dl_we16,
	output logic         dl_busy,

	inout  wire  [15:0]  SDRAM_DQ,
	output logic [12:0]  SDRAM_A,
	output logic         SDRAM_DQML,
	output logic         SDRAM_DQMH,
	output logic [1:0]   SDRAM_BA,
	output logic         SDRAM_nCS,
	output logic         SDRAM_nWE,
	output logic         SDRAM_nRAS,
	output logic         SDRAM_nCAS,
	output logic         SDRAM_CKE
);

	localparam int TW = (N > 1) ? $clog2(N) : 1;

	localparam logic [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100,
	                       C_PRE = 3'b010, C_REF = 3'b001, C_MODE = 3'b000;
	// burst 4, sequential, CAS latency 2, single-word writes
	localparam logic [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'd2, 1'b0, 3'd2};

	assign SDRAM_nCS = 1'b0;
	assign SDRAM_CKE = 1'b1;
	assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];

	logic [2:0]  cmd = C_NOP;
	assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

	logic        dq_oe = 1'b0;
	logic [15:0] dq_out, dq_in;
	assign SDRAM_DQ = dq_oe ? dq_out : 16'bz;

	// ---- power-up: precharge all, 8 refreshes, load mode ----------------
	logic        ready = 1'b0, init_d = 1'b0;
	logic [9:0]  icnt = '0;

	// ---- timing state, counted in clocks since the command was registered --
	logic [3:0]  bcnt [4] = '{4'd0, 4'd0, 4'd0, 4'd0};   // ACTIVE to bank b when 0
	logic [3:0]  since_act = 4'd15, since_cas = 4'd15;    // saturating
	logic [3:0]  ref_wait = '0;
	logic [9:0]  rfs_cnt = '0;
	logic        rfs_due = 1'b0;

	// the access between its ACTIVE and its READ/WRITE
	logic [1:0]  cas_st = '0;
	logic        cas_we;
	logic [1:0]  cas_ba;
	logic [12:0] cas_a;
	logic [15:0] cas_d;
	logic [TW-1:0] cas_tag;
	logic        cas_client;          // a client write: c_valid on its WRITE

	// read returns: tag pipeline from READ, lanes at +4..+7
	logic [6:0]  rd_v;
	logic [TW-1:0] rd_tag [7];
	logic [47:0] acc;

	// ---- pick (registered), then issue ------------------------------------
	logic [N-1:0] pend, c_req_d;
	logic [TW-1:0] rr_ptr;

	function automatic logic [1:0] bank_of(input logic [25:0] a);
		return a[4:3];
	endfunction

	logic [N-1:0] elig;
	always_comb
		for (int k = 0; k < N; k++)
			elig[k] = pend[k] && bcnt[bank_of(c_addr[26*k +: 26])] <= 4'd2;

	// rr_ptr moves past a client only when the pick is the first pending one of
	// its class, so a client skipped for a busy bank stays at the head
	logic          have_hi, have_lo, have_pick, have_q;
	logic [TW-1:0] pick_hi, pick_lo, pick, pick_q;
	logic          seen_hi, seen_lo, head, head_q;
	logic [TW-1:0] first_hi, first_lo;
	always_comb begin
		have_hi = 1'b0;
		have_lo = 1'b0;
		pick_hi = rr_ptr;
		pick_lo = rr_ptr;
		seen_hi = 1'b0;
		seen_lo = 1'b0;
		first_hi = rr_ptr;
		first_lo = rr_ptr;
		for (int k = 0; k < N; k++) begin
			int unsigned idx;
			idx = (int'(rr_ptr) + k) % N;
			if (!seen_hi && pend[idx] && !LOW[idx]) begin
				seen_hi = 1'b1;
				first_hi = TW'(idx);
			end
			if (!seen_lo && pend[idx] && LOW[idx]) begin
				seen_lo = 1'b1;
				first_lo = TW'(idx);
			end
			if (!have_hi && elig[idx] && !LOW[idx]) begin
				have_hi = 1'b1;
				pick_hi = TW'(idx);
			end
			if (!have_lo && elig[idx] && LOW[idx]) begin
				have_lo = 1'b1;
				pick_lo = TW'(idx);
			end
		end
		have_pick = have_hi || have_lo;
		pick      = have_hi ? pick_hi : pick_lo;
		head      = have_hi ? pick_hi == first_hi : pick_lo == first_lo;
	end

	// the picked client's access
	logic [25:0] p_addr;
	logic        p_we, p_we16;
	logic [15:0] p_wdata;
	always_comb begin
		p_addr  = '0;
		p_we    = 1'b0;
		p_we16  = 1'b0;
		p_wdata = '0;
		for (int k = 0; k < N; k++)
			if (k == int'(pick_q)) begin
				p_addr  = c_addr[26*k +: 26];
				p_we    = c_we[k];
				p_we16  = c_we16[k];
				p_wdata = c_wdata[16*k +: 16];
			end
	end

	// the picked access, registered: issued the clock after, so the client mux is
	// a cycle of its own (a pick looks two clocks ahead at its bank)
	logic          s_v, s_head, s_we, s_we16;
	logic [TW-1:0] s_tag;
	logic [25:0]   s_addr;
	logic [15:0]   s_wdata;
	logic [3:0]    s_gap;

	// clocks after a READ before this ACTIVE: 2, 4 if it raises DQM, 6 to turn the bus for a write
	function automatic logic [3:0] gap_of(input logic we, input logic [25:0] a);
		return we ? 4'd6 : (a[24:23] != 2'b00) ? 4'd4 : 4'd2;
	endfunction

	// the access to start: the download first, then the pick
	logic        dl_go, go_dl, go_c, go;
	logic [25:0] g_addr;
	logic        g_we, g_we16;
	logic [15:0] g_wdata;
	always_comb begin
		dl_go   = dl_req && !dl_busy;
		go_dl   = dl_go && bcnt[bank_of(dl_addr)] == 4'd0;
		g_addr  = dl_go ? dl_addr : s_addr;
		g_we    = dl_go || s_we;
		g_we16  = dl_go ? dl_we16 : s_we16;
		g_wdata = dl_go ? dl_data : s_wdata;
		go_c    = !dl_go && s_v && pend[s_tag];
		go      = ready && !rfs_due && ref_wait == 4'd0 && cas_st == 2'd0 && since_act >= 4'd3
		          && (dl_go ? since_cas >= 4'd6 : since_cas >= s_gap) && (go_dl || go_c);
	end

	always_ff @(posedge clk) begin
		dq_in <= SDRAM_DQ;

		// defaults: NOP with A[12:11] low, so DQM never masks a read
		cmd     <= C_NOP;
		SDRAM_A <= '0;
		dq_oe   <= 1'b0;

		for (int b = 0; b < 4; b++) if (bcnt[b] != 4'd0) bcnt[b] <= bcnt[b] - 4'd1;
		if (since_act != 4'd15) since_act <= since_act + 4'd1;
		if (since_cas != 4'd15) since_cas <= since_cas + 4'd1;
		if (ref_wait != 4'd0) ref_wait <= ref_wait - 4'd1;

		rfs_cnt <= rfs_cnt + 10'd1;
		if (rfs_cnt == 10'd669) begin
			rfs_cnt <= '0;
			rfs_due <= 1'b1;
		end

		pick_q <= pick;
		have_q <= have_pick;
		head_q <= head;
		s_v     <= have_q;
		s_tag   <= pick_q;
		s_head  <= head_q;
		s_addr  <= p_addr;
		s_we    <= p_we;
		s_we16  <= p_we16;
		s_wdata <= p_wdata;
		s_gap   <= gap_of(p_we, p_addr);
		c_req_d <= c_req;
		pend    <= pend | (c_req & ~c_req_d);

		c_valid <= '0;
		rd_v    <= {rd_v[5:0], 1'b0};
		for (int i = 1; i < 7; i++) rd_tag[i] <= rd_tag[i-1];
		if (rd_v[3]) acc[15:0]  <= dq_in;
		if (rd_v[4]) acc[31:16] <= dq_in;
		if (rd_v[5]) acc[47:32] <= dq_in;
		if (rd_v[6]) begin
			c_rdata <= {dq_in, acc};
			c_valid[rd_tag[6]] <= 1'b1;
		end

		init_d <= init;
		if (init_d && !init) begin
			ready <= 1'b0;
			icnt  <= '0;
		end else if (!ready) begin
			icnt <= icnt + 10'd1;
			case (icnt)
				10'd256: begin cmd <= C_PRE; SDRAM_A <= 13'h0400; end
				10'd260, 10'd270, 10'd280, 10'd290, 10'd300, 10'd310, 10'd320, 10'd330:
					cmd <= C_REF;
				10'd340: begin cmd <= C_MODE; SDRAM_A <= MODE; SDRAM_BA <= 2'b00; end
				10'd350: ready <= 1'b1;
				default: ;
			endcase
			rfs_cnt <= '0;
			rfs_due <= 1'b0;
		end else if (cas_st == 2'd2) begin
			cmd       <= cas_we ? C_WRITE : C_READ;
			SDRAM_BA  <= cas_ba;
			SDRAM_A   <= cas_a;
			since_cas <= 4'd1;
			cas_st    <= 2'd0;
			if (cas_we) begin
				dq_oe  <= 1'b1;
				dq_out <= cas_d;
				dl_busy <= 1'b0;
				if (cas_client) c_valid[cas_tag] <= 1'b1;
			end else begin
				rd_v[0]   <= 1'b1;
				rd_tag[0] <= cas_tag;
			end
		end else if (rfs_due) begin
			if (cas_st == 2'd0 && since_act >= 4'd3 && ref_wait == 4'd0
			    && bcnt[0] == 4'd0 && bcnt[1] == 4'd0 && bcnt[2] == 4'd0 && bcnt[3] == 4'd0) begin
				cmd      <= C_REF;
				rfs_due  <= 1'b0;
				ref_wait <= 4'd9;
			end
		end else if (go) begin
			logic wl, wh;
			wl = g_we16 || !g_addr[0];
			wh = g_we16 ||  g_addr[0];
			cmd       <= C_ACT;
			SDRAM_BA  <= bank_of(g_addr);
			SDRAM_A   <= g_addr[24:12];
			bcnt[bank_of(g_addr)] <= 4'd8;
			since_act <= 4'd1;
			cas_st    <= 2'd1;
			cas_we    <= g_we;
			cas_ba    <= bank_of(g_addr);
			cas_a     <= {g_we ? ~{wh, wl} : 2'b00, 1'b1, g_addr[25], g_addr[11:5], g_addr[2:1]};
			cas_d     <= g_we16 ? g_wdata : {g_wdata[7:0], g_wdata[7:0]};
			cas_tag   <= s_tag;
			cas_client <= !go_dl;
			if (go_dl) dl_busy <= 1'b1;
			else begin
				pend[s_tag] <= 1'b0;
				s_v <= 1'b0;
				if (s_head) rr_ptr <= (int'(s_tag) == N-1) ? '0 : TW'(int'(s_tag) + 1);
			end
		end
		if (cas_st == 2'd1) cas_st <= 2'd2;

		if (reset) begin
			pend    <= '0;
			c_req_d <= '0;
			have_q  <= 1'b0;
			s_v     <= 1'b0;
			rr_ptr  <= '0;
			c_valid <= '0;
			rd_v    <= '0;
			dl_busy <= 1'b0;
			if (cas_st != 2'd0) cas_client <= 1'b0;
		end
	end

endmodule
