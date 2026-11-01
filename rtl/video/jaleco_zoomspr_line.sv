// SPDX-License-Identifier: GPL-3.0-or-later
//
// Jaleco zoom sprites, the standard record format (Cisco Heat, F1 GP Star) or
// Big Run's (bigrun = 1, jaleco_zoomspr.cpp 196-235), one scanline at a time. Bit-exact to scripts/sprite_acc.py, which documents the
// algorithm and how it departs from MAME's per-tile scaling (docs/HACKS.md).
//
// One accumulator spans the whole sprite: line d below the top edge shows
// source row floor(d * 128 / zoom_y), pixel d right of the left edge source
// column floor(d * 128 / zoom_x). Both are stepped as quotient q and remainder
// r of 128 / zoom, so the pixel path only adds.
//
// frame_start runs the per-frame precompute over the latched list: q and r,
// the top edge y - ceil(ynum * zoom_y / 8), and the accumulator state at the
// first rendered line y0 and at screen x 0, from a serial divider and a serial
// shift-add. After it, start must be given for every line from y0 upward, in
// order: each line advances the vertical accumulators it passes.
//
// Line buffer ops: lb_we with lb_shadow = 0 writes {color, pen} opaque and
// clears shadow; with lb_shadow = 1 it sets shadow only. lb_group is the pass
// group from grp_of_pri[3*pri +: 3]. Records are drawn in ascending order.
//
// Timing: the line runs as three parts. The scanner walks the records, one
// clock for a record that does not draw and a handful for one that does, and
// queues each drawing record as a job (up to four). The fetcher issues the
// queued jobs' granules in drawing order, one a clock, on whichever of the four
// gfx ports is free, into an eight-entry ring; it runs ahead across records, so
// a record's first granule is usually in by the time it is drawn. The drawer
// takes the jobs in order and draws a pixel a clock while the ring's head holds
// the column under it. Zoom is at least 8, so the source step is at most 16
// pixels and no column is skipped: the only granules fetched and not drawn are
// those of a record that runs off the screen's right edge, which the drawer
// discards (it stops the fetcher on that record).
//
// Cutoff (LINE_CLK > 0): a line must be done LINE_CLK clocks after its start.
// Once the clocks left would only cover passing the remaining records (one
// each) plus CUT_SLACK for the fetches in flight, the engine stops drawing: the
// record being drawn ends where it is, the queued ones are dropped once the
// fetches in flight return, and the rest are passed without drawing, which
// still advances their vertical accumulators. Records are drawn in ascending
// order, so a cut line loses the last ones (docs/HACKS.md).
//
// Ports: the list is the latched 4 KB copy, eight words per record
// (word k at list_q[16k +: 16]), registered read. gfx_req[k] is a one-clock
// pulse per 64-bit granule, one 16-pixel tile row (untangled at load), granule
// byte j at rdata[8j +: 8], high nibble first; a port has one fetch at a time.

module jaleco_zoomspr_line #(
	parameter int LINE_CLK  = 0,         // 0: no cutoff
	parameter int CUT_SLACK = 128
) (
	input  logic         clk,
	input  logic         reset,

	input  logic         frame_start,   // pulse: precompute for this frame
	input  logic [7:0]   y0,            // first line that will be rendered
	input  logic         start,         // pulse: render line vpos
	input  logic [7:0]   vpos,
	output logic         busy,
	output logic         cut,           // this line was cut

	input  logic         bigrun,        // Big Run record format
	input  logic [23:0]  grp_of_pri,
	input  logic [25:0]  gfx_base,
	input  logic [15:0]  code_mask,     // tiles in the region - 1

	output logic [7:0]   list_addr,
	input  logic [127:0] list_q,

	output logic [3:0]   gfx_req,
	output logic [25:0]  gfx_addr [4],
	input  logic [3:0]   gfx_valid,
	input  logic [63:0]  gfx_rdata [4],

	output logic         lb_we,
	output logic         lb_shadow,
	output logic [2:0]   lb_group,
	output logic [7:0]   lb_x,
	output logic [10:0]  lb_d,          // {color[6:0], pen[3:0]}

	// probes: {fetches in flight, job queued, drawer waiting, pixel drawn}, per clock
	output logic [5:0]   dbg
);

	// ---- serial divider: 20-bit numerator / 9-bit denominator ------------
	logic        dv_start, dv_busy, dv_done;
	logic [19:0] dv_num, dv_q;
	logic [8:0]  dv_den, dv_rem;
	logic [4:0]  dv_n;
	logic [9:0]  dv_r2;
	assign dv_r2 = {dv_rem, dv_q[19]};

	always_ff @(posedge clk) begin
		dv_done <= 1'b0;
		if (reset)
			dv_busy <= 1'b0;
		else if (dv_start) begin
			dv_q    <= dv_num;
			dv_rem  <= 9'd0;
			dv_n    <= 5'd20;
			dv_busy <= 1'b1;
		end else if (dv_busy) begin
			if (dv_r2 >= {1'b0, dv_den}) begin
				dv_rem <= 9'(dv_r2 - {1'b0, dv_den});
				dv_q   <= {dv_q[18:0], 1'b1};
			end else begin
				dv_rem <= dv_r2[8:0];
				dv_q   <= {dv_q[18:0], 1'b0};
			end
			dv_n <= dv_n - 5'd1;
			if (dv_n == 5'd1) begin
				dv_busy <= 1'b0;
				dv_done <= 1'b1;
			end
		end
	end

	// quotient saturated to 9 bits: anything past 255 is past every sprite
	logic [8:0] dv_q9;
	assign dv_q9 = (dv_q[19:9] != 0) ? 9'h1ff : dv_q[8:0];

	// ---- states -------------------------------------------------------
	typedef enum logic [3:0] {
		S_IDLE,
		P_RD, P_DEC, P_MUL, P_DX, P_DY, P_D0X, P_D0Y,
		L_RD, L_EV, L_ROW, L_PUSH, L_NEXT, L_END
	} state_t;
	state_t st;

	// ---- per-record tables ---------------------------------------------
	typedef struct packed {
		logic        valid;
		logic [3:0]  xn1, yn1;      // tiles - 1
		logic [11:0] top;           // signed
		logic [10:0] x;             // signed
		logic [8:0]  zx, zy;
		logic [4:0]  qx, qy;
		logic [8:0]  rx, ry;
		logic [8:0]  s0x, e0x;      // horizontal state at screen x 0
		logic        fx, fy, shadow;
		logic [15:0] code;
		logic [6:0]  color;
		logic [2:0]  group;
	} pre_t;

	pre_t        pre_mem [256];
	pre_t        pre_q, pre_w;
	logic        pre_we;
	logic [17:0] vst_mem [256];     // {s_y, e_y}
	logic [17:0] vst_q, vst_w;
	logic        vst_we;
	logic [7:0]  idx, w_idx, rd_idx;
	logic        go;                // L_EV: the record draws on this line
	logic        late;              // past the cutoff: draw nothing more this line
	logic [11:0] lt;                // clocks since the line's start, saturating

	assign list_addr = idx;
	// an L_EV record that does not draw is passed in one clock: read ahead
	assign rd_idx = (st == L_EV && !go) ? idx + 8'd1 : idx;

	always_ff @(posedge clk) begin
		if (pre_we) pre_mem[w_idx] <= pre_w;
		if (vst_we) vst_mem[w_idx] <= vst_w;
		pre_q <= pre_mem[rd_idx];
		vst_q <= vst_mem[rd_idx];
	end

	// ---- control -------------------------------------------------------
	logic        st_frame;          // L_NEXT returns to the precompute loop
	logic [7:0]  y0_l, vpos_l;

	// serial shift-add
	logic [4:0]  mul_a;
	logic [12:0] mul_b, mul_acc;
	logic [2:0]  mul_n;

	// precompute working values
	logic [11:0] sy12;

	// scanner working values
	logic [8:0]  wsrc, hsrc;        // 16 * tiles
	logic [8:0]  ty;                // source row in the sprite

	assign wsrc = {1'b0, pre_q.xn1, 4'd0} + 9'd16;
	assign hsrc = {1'b0, pre_q.yn1, 4'd0} + 9'd16;

	// ---- jobs: one per drawing record, scanner -> fetcher -> drawer ------
	typedef struct packed {
		logic [8:0]  s, e, px;      // horizontal state and screen x at the first pixel
		logic [8:0]  wsrc;
		logic [4:0]  qx;
		logic [8:0]  rx, zx;
		logic        fx, shadow;
		logic [3:0]  c0;            // first column drawn
		logic [4:0]  ncol;          // columns from c0 to the far edge
		logic [15:0] row_code;
		logic [3:0]  ty;
		logic [6:0]  color;
		logic [2:0]  group;
	} job_t;

	job_t        jq [4];
	job_t        j_new;
	logic [2:0]  jw, jf, jd;        // queue (scanner), fetch, draw; bit 2 is the wrap
	logic [3:0]  fdone;             // per job slot: every granule issued, or the fetch stopped
	logic        j_space, j_push;
	assign j_space = 3'(jw - jd) != 3'd4;
	assign j_push  = st == L_PUSH && !late && j_space;

	// the job L_ROW would queue
	logic [8:0]  n_s, n_tx;
	assign n_s  = pre_q.x[10] ? pre_q.s0x : 9'd0;
	assign n_tx = pre_q.fx ? 9'(wsrc - 9'd1 - n_s) : n_s;

	// ---- granule ring, filled in issue order ------------------------------
	logic [7:0]  r_full;
	logic [2:0]  r_job  [8];
	logic [63:0] r_gran [8];
	logic [2:0]  rp, wp;
	logic [3:0]  r_cnt;
	logic [3:0]  p_busy;            // port k has a fetch in flight, for ring entry p_ent[k]
	logic [2:0]  p_ent  [4];

	// fetcher
	logic        f_on;
	logic [3:0]  f_c;
	logic [4:0]  f_n;               // columns left
	logic [1:0]  f_k;
	logic        f_free;
	job_t        fj;
	assign fj = jq[jf[1:0]];
	always_comb begin
		f_free = 1'b0;
		f_k    = 2'd0;
		for (int k = 3; k >= 0; k--)
			if (!p_busy[k]) begin f_free = 1'b1; f_k = 2'(k); end
	end

	// drawer
	logic        d_on, d_skip, kill;
	logic [8:0]  ds, de, dpx;
	job_t        dj;
	assign dj = jq[jd[1:0]];
	logic        head_mine, head_ok;
	assign head_mine = r_cnt != 4'd0 && r_job[rp] == jd;
	assign head_ok   = head_mine && r_full[rp];
	logic [8:0]  d_tx, s_nx, e_nx, tx_nx;
	logic [9:0]  ex_sum;
	assign d_tx   = dj.fx ? 9'(dj.wsrc - 9'd1 - ds) : ds;
	assign ex_sum = {1'b0, de} + {1'b0, dj.rx};
	assign s_nx   = (ex_sum >= {1'b0, dj.zx}) ? 9'(ds + dj.qx + 9'd1) : 9'(ds + dj.qx);
	assign e_nx   = (ex_sum >= {1'b0, dj.zx}) ? 9'(ex_sum - {1'b0, dj.zx}) : ex_sum[8:0];
	assign tx_nx  = dj.fx ? 9'(dj.wsrc - 9'd1 - s_nx) : s_nx;

	// pen at d_tx within the head granule
	logic [63:0] gran;
	logic [7:0]  gbyte;
	logic [3:0]  pen;
	assign gran  = r_gran[rp];
	assign gbyte = gran[{d_tx[3:1], 3'b000} +: 8];
	assign pen   = d_tx[0] ? gbyte[3:0] : gbyte[7:4];

	// a pixel this clock, or the drawer waiting on a granule (both read by sim/board_tb)
	logic        d_draw, d_wait;
	assign d_draw = d_on && !d_skip && head_ok && !late;
	assign d_wait = d_on && !d_skip && !head_ok && !late;
	assign dbg    = {3'(p_busy[0]) + 3'(p_busy[1]) + 3'(p_busy[2]) + 3'(p_busy[3]), j_push, d_wait, d_draw};

	// vertical state of the record being evaluated
	logic [8:0]  sy_s, sy_e;
	logic        on_line;           // the record covers this line
	logic [9:0]  ey_sum;
	assign sy_s    = vst_q[17:9];
	assign sy_e    = vst_q[8:0];
	assign on_line = pre_q.valid && ($signed({4'd0, vpos_l}) >= $signed(pre_q.top)) && (sy_s < hsrc);
	assign ey_sum  = {1'b0, sy_e} + {1'b0, pre_q.ry};
	assign go      = on_line && !(pre_q.x[10] == 1'b0 && pre_q.x[9:8] != 2'b00) && !late;

	assign busy = (st != S_IDLE);

	logic [7:0]  rec_left;          // records after this one
	logic [12:0] lt_need;           // clocks this line would use if it stopped drawing now
	assign rec_left = 8'd255 - idx;
	assign lt_need  = {1'b0, lt} + {5'd0, rec_left} + 13'(CUT_SLACK);
	assign late    = LINE_CLK != 0 && !st_frame && lt_need >= 13'(LINE_CLK);

	always_ff @(posedge clk)
		if (start && st == S_IDLE) begin
			lt  <= 12'd0;
			cut <= 1'b0;
		end else begin
			if (lt != 12'hfff) lt <= lt + 12'd1;
			if (late && busy && (jd != jw || st == L_PUSH || (st == L_EV && on_line))) cut <= 1'b1;
		end

	logic [15:0] w0, w1, w2, w3, w4, w6, w7;
	assign {w7, w6, w4, w3, w2, w1, w0} =
		{list_q[127:112], list_q[111:96], list_q[79:64], list_q[63:48],
		 list_q[47:32], list_q[31:16], list_q[15:0]};

	logic [8:0] zx_d, zy_d;
	assign zx_d = bigrun ? {1'b0, w1[7:0]}  : w1[8:0];
	assign zy_d = bigrun ? {1'b0, w1[15:8]} : w2[8:0];

	// ---- scanner -------------------------------------------------------
	always_ff @(posedge clk) begin
		pre_we   <= 1'b0;
		vst_we   <= 1'b0;
		dv_start <= 1'b0;
		if (reset) begin
			st  <= S_IDLE;
			idx <= 8'd0;
		end else begin
			case (st)
				S_IDLE:
					if (frame_start) begin
						st_frame <= 1'b1;
						y0_l <= y0;
						idx  <= 8'd0;
						st   <= P_RD;
					end else if (start) begin
						st_frame <= 1'b0;
						vpos_l <= vpos;
						idx    <= 8'd0;
						st     <= L_RD;
					end

				// ---------------- per-frame precompute ----------------
				P_RD: st <= P_DEC;          // list_q for idx arrives

				P_DEC: begin
					// Big Run: zoom y/x in word 1, flip in bit 12 of the position
					// words, 9-bit positions and y at the top edge (no ynum * zoom)
					pre_w.valid  <= !w0[12] && zx_d >= 9'd8 && zy_d >= 9'd8;
					pre_w.xn1    <= w0[3:0];
					pre_w.yn1    <= w0[7:4];
					pre_w.zx     <= zx_d;
					pre_w.fx     <= bigrun ? w2[12] : w1[12];
					pre_w.zy     <= zy_d;
					pre_w.fy     <= bigrun ? w3[12] : w2[12];
					pre_w.x      <= bigrun ? {{2{w2[8]}}, w2[8:0]} : w3[10:0];
					pre_w.code   <= w6;
					pre_w.color  <= bigrun ? {1'b0, w7[5:0]} : w7[6:0];
					pre_w.shadow <= w7[12];
					pre_w.group  <= grp_of_pri[{w7[10:8], 1'b0} + {2'b0, w7[10:8]} +: 3];
					sy12         <= bigrun ? {{3{w3[8]}}, w3[8:0]} : {w4[10], w4[10:0]};
					mul_a        <= bigrun ? 5'd0 : 5'(w0[7:4]) + 5'd1;
					mul_b        <= {4'd0, zy_d};
					mul_acc      <= 13'd0;
					mul_n        <= 3'd5;
					st           <= P_MUL;
				end

				P_MUL:                      // ynum * zoom_y
					if (mul_n != 0) begin
						if (mul_a[0]) mul_acc <= mul_acc + mul_b;
						mul_a <= mul_a >> 1;
						mul_b <= mul_b << 1;
						mul_n <= mul_n - 3'd1;
					end else begin
						pre_w.top <= sy12 - 12'((mul_acc + 13'd7) >> 3);
						dv_num    <= 20'd128;
						dv_den    <= pre_w.zx;
						dv_start  <= 1'b1;
						st        <= P_DX;
					end

				P_DX: if (dv_done) begin
					pre_w.qx <= dv_q[4:0];
					pre_w.rx <= dv_rem;
					dv_num   <= 20'd128;
					dv_den   <= pre_w.zy;
					dv_start <= 1'b1;
					st       <= P_DY;
				end

				P_DY: if (dv_done) begin
					pre_w.qy <= dv_q[4:0];
					pre_w.ry <= dv_rem;
					// columns skipped left of the screen
					dv_num   <= pre_w.x[10] ? {2'd0, 11'(-pre_w.x), 7'd0} : 20'd0;
					dv_den   <= pre_w.zx;
					dv_start <= 1'b1;
					st       <= P_D0X;
				end

				P_D0X: if (dv_done) begin
					pre_w.s0x <= dv_q9;
					pre_w.e0x <= dv_rem;
					// lines between the top edge and y0
					dv_num   <= ($signed({4'd0, y0_l}) > $signed(pre_w.top))
					            ? {1'b0, 12'({4'd0, y0_l} - pre_w.top), 7'd0} : 20'd0;
					dv_den   <= pre_w.zy;
					dv_start <= 1'b1;
					st       <= P_D0Y;
				end

				P_D0Y: if (dv_done) begin
					vst_w  <= {dv_q9, dv_rem};
					pre_we <= 1'b1;
					vst_we <= 1'b1;
					w_idx  <= idx;
					st     <= L_NEXT;
				end

				// ---------------- one line ----------------
				L_RD: st <= L_EV;           // pre_q / vst_q for idx arrive

				L_EV: begin
					// advance the vertical accumulator of every record this line passes
					if (on_line) begin
						vst_we <= 1'b1;
						w_idx  <= idx;
						if (ey_sum >= {1'b0, pre_q.zy})
							vst_w <= {9'(sy_s + pre_q.qy + 9'd1), 9'(ey_sum - {1'b0, pre_q.zy})};
						else
							vst_w <= {9'(sy_s + pre_q.qy), ey_sum[8:0]};
					end
					ty      <= pre_q.fy ? 9'(hsrc - 9'd1 - sy_s) : sy_s;
					mul_a   <= 5'((pre_q.fy ? 9'(hsrc - 9'd1 - sy_s) : sy_s) >> 4);
					mul_b   <= 13'(pre_q.xn1) + 13'd1;
					mul_acc <= 13'd0;
					mul_n   <= 3'd4;
					if (go)
						st <= L_ROW;
					else begin
						idx <= idx + 8'd1;
						if (idx == 8'd255) st <= L_END;
					end
				end

				L_ROW:                      // row_code = code + (ty >> 4) * xnum
					if (mul_n != 0) begin
						if (mul_a[0]) mul_acc <= mul_acc + mul_b;
						mul_a <= mul_a >> 1;
						mul_b <= mul_b << 1;
						mul_n <= mul_n - 3'd1;
					end else begin
						j_new.s        <= n_s;
						j_new.e        <= pre_q.x[10] ? pre_q.e0x : 9'd0;
						j_new.px       <= pre_q.x[10] ? 9'd0 : {1'b0, pre_q.x[7:0]};
						j_new.wsrc     <= wsrc;
						j_new.qx       <= pre_q.qx;
						j_new.rx       <= pre_q.rx;
						j_new.zx       <= pre_q.zx;
						j_new.fx       <= pre_q.fx;
						j_new.shadow   <= pre_q.shadow;
						j_new.c0       <= n_tx[7:4];
						j_new.ncol     <= pre_q.fx ? 5'(n_tx[7:4]) + 5'd1
						                           : 5'(pre_q.xn1) + 5'd1 - 5'(n_tx[7:4]);
						j_new.row_code <= pre_q.code + 16'(mul_acc);
						j_new.ty       <= ty[3:0];
						j_new.color    <= pre_q.color;
						j_new.group    <= pre_q.group;
						// wholly left of the screen: nothing to draw
						st <= (n_s >= wsrc) ? L_NEXT : L_PUSH;
					end

				L_PUSH: if (late || j_space) st <= L_NEXT;

				L_NEXT: begin
					idx <= idx + 8'd1;
					if (idx == 8'd255)
						st <= (st_frame) ? S_IDLE : L_END;
					else
						st <= (st_frame) ? P_RD : L_RD;
				end

				L_END:                      // every job drawn or dropped, nothing in flight
					if (jd == jw && !f_on && p_busy == 4'h0) st <= S_IDLE;

				default: st <= S_IDLE;
			endcase
		end
	end

	// ---- fetcher, ring and drawer --------------------------------------
	always_ff @(posedge clk) begin
		logic pop, push;
		pop     = 1'b0;
		push    = 1'b0;
		gfx_req <= 4'h0;
		lb_we   <= 1'b0;
		kill    <= 1'b0;
		if (reset || (start && st == S_IDLE)) begin
			jw     <= 3'd0;
			jf     <= 3'd0;
			jd     <= 3'd0;
			rp     <= 3'd0;
			wp     <= 3'd0;
			r_cnt  <= 4'd0;
			f_on   <= 1'b0;
			d_on   <= 1'b0;
			d_skip <= 1'b0;
			if (reset) p_busy <= 4'h0;
		end else begin
			if (j_push) begin
				jq[jw[1:0]]    <= j_new;
				fdone[jw[1:0]] <= 1'b0;
				jw             <= jw + 3'd1;
			end

			if (late) begin
				// cut: stop; once nothing is in flight drop the ring and every job
				f_on   <= 1'b0;
				d_on   <= 1'b0;
				d_skip <= 1'b0;
				if (p_busy == 4'h0) begin
					rp    <= wp;
					r_cnt <= 4'd0;
					jf    <= jw;
					jd    <= jw;
				end
			end else begin
				// fetcher: the queued jobs' columns in drawing order
				if (!f_on) begin
					if (jf != jw) begin
						f_c  <= fj.c0;
						f_n  <= fj.ncol;
						f_on <= 1'b1;
					end
				end else if (kill && jf == jd) begin
					fdone[jf[1:0]] <= 1'b1;
					jf             <= jf + 3'd1;
					f_on           <= 1'b0;
				end else if (f_free && r_cnt != 4'd8) begin
					gfx_addr[f_k] <= gfx_base + {3'd0, (fj.row_code + {12'd0, f_c}) & code_mask, fj.ty, 3'b000};
					gfx_req[f_k]  <= 1'b1;
					p_busy[f_k]   <= 1'b1;
					p_ent[f_k]    <= wp;
					r_full[wp]    <= 1'b0;
					r_job[wp]     <= jf;
					wp            <= wp + 3'd1;
					push           = 1'b1;
					f_c           <= fj.fx ? f_c - 4'd1 : f_c + 4'd1;
					f_n           <= f_n - 5'd1;
					if (f_n == 5'd1) begin
						fdone[jf[1:0]] <= 1'b1;
						jf             <= jf + 3'd1;
						f_on           <= 1'b0;
					end
				end

				// drawer: a pixel a clock while the head holds the column under it
				if (!d_on) begin
					if (jd != jw) begin
						ds     <= dj.s;
						de     <= dj.e;
						dpx    <= dj.px;
						d_on   <= 1'b1;
						d_skip <= 1'b0;
					end
				end else if (!d_skip) begin
					if (head_ok) begin
						if (pen != 4'hf) begin
							lb_we     <= 1'b1;
							lb_shadow <= (pen == 4'h0) && dj.shadow;
							lb_group  <= dj.group;
							lb_x      <= dpx[7:0];
							lb_d      <= {dj.color, pen};
						end
						ds  <= s_nx;
						de  <= e_nx;
						dpx <= dpx + 9'd1;
						if (s_nx >= dj.wsrc || dpx == 9'd255) begin
							// the record ends: discard the rest of its granules
							pop     = 1'b1;
							d_skip <= 1'b1;
							kill   <= 1'b1;
						end else if (tx_nx[7:4] != d_tx[7:4])
							pop = 1'b1;
					end
				end else if (head_mine) begin
					if (r_full[rp]) pop = 1'b1;
				end else if (fdone[jd[1:0]]) begin
					jd     <= jd + 3'd1;
					d_on   <= 1'b0;
					d_skip <= 1'b0;
				end

				if (pop) rp <= rp + 3'd1;
				r_cnt <= r_cnt + {3'd0, push} - {3'd0, pop};
			end

			for (int k = 0; k < 4; k++)
				if (p_busy[k] && gfx_valid[k]) begin
					r_gran[p_ent[k]] <= gfx_rdata[k];
					r_full[p_ent[k]] <= 1'b1;
					p_busy[k]        <= 1'b0;
				end
		end
	end

endmodule
