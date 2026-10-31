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
// Timing: a record that does not draw costs one clock. A drawn pixel costs one
// clock. Granules come through four gfx ports, one per slot: tile column c is
// held in slot c mod 4, and each slot fetches the column of the four from the
// current one in the walk direction that maps to it. Zoom is at least 8, so the
// source step is at most 16 pixels and no column of a row is skipped: none of
// these fetches is wasted except past the screen's right edge. A slot's tag
// ({line parity, record}) marks whose granule it holds; a record ends without
// waiting for its fetches, and one that lands late is never matched.
//
// Cutoff (LINE_CLK > 0): a line must be done LINE_CLK clocks after its start.
// Once the clocks left would only cover passing the remaining records (one
// each) plus CUT_SLACK for a fetch in flight, the engine stops drawing: the
// record being drawn ends where it is, and the rest are passed without
// drawing, which still advances their vertical accumulators. Records are drawn
// in ascending order, so a cut line loses the last ones (docs/HACKS.md).
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
	output logic [10:0]  lb_d           // {color[6:0], pen[3:0]}
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
		L_RD, L_EV, L_ROW, L_PIX, L_NEXT
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

	// line working values
	logic [8:0]  wsrc, hsrc;        // 16 * tiles
	logic [8:0]  ty;                // source row in the sprite
	logic [15:0] row_code;
	logic [8:0]  s, e;              // horizontal accumulator
	logic [8:0]  px;                // screen x, 256 = done
	logic [8:0]  tx;
	logic [3:0]  tile_col;

	// granule slots: column c in slot c[1:0]
	logic [3:0]  sl_busy, sl_full;
	logic [3:0]  sl_col [4];
	logic [8:0]  sl_tag [4];
	logic [63:0] sl_gran [4];
	logic [8:0]  tag;               // the record drawing now
	logic [3:0]  want_col [4];      // the window column slot k should hold
	logic [3:0]  want_ok;           // it exists in this record
	logic [3:0]  sl_have;           // slot k holds it
	assign tag = {vpos_l[0], idx};

	always_comb
		for (int k = 0; k < 4; k++) begin
			logic [1:0] j;
			logic [4:0] c;
			j = pre_q.fx ? 2'(tile_col[1:0] - 2'(k)) : 2'(2'(k) - tile_col[1:0]);
			c = pre_q.fx ? 5'(tile_col) - 5'(j) : 5'(tile_col) + 5'(j);
			want_col[k] = c[3:0];
			want_ok[k]  = !c[4] && c[3:0] <= pre_q.xn1;
			sl_have[k]  = sl_full[k] && sl_col[k] == c[3:0] && sl_tag[k] == tag;
		end

	logic        have_gran;         // the current column's granule is in its slot
	logic [63:0] gran;
	assign have_gran = sl_have[tile_col[1:0]];
	assign gran      = sl_gran[tile_col[1:0]];

	assign wsrc = {1'b0, pre_q.xn1, 4'd0} + 9'd16;
	assign hsrc = {1'b0, pre_q.yn1, 4'd0} + 9'd16;
	assign tx   = pre_q.fx ? 9'(wsrc - 9'd1 - s) : s;
	assign tile_col = tx[7:4];

	// pen at tx within the loaded granule
	logic [7:0] gbyte;
	logic [3:0] pen;
	assign gbyte = gran[{tx[3:1], 3'b000} +: 8];
	assign pen   = tx[0] ? gbyte[3:0] : gbyte[7:4];

	// vertical state of the record being evaluated
	logic [8:0]  sy_s, sy_e;
	logic        on_line;           // the record covers this line
	logic [9:0]  ey_sum;
	assign sy_s    = vst_q[17:9];
	assign sy_e    = vst_q[8:0];
	assign on_line = pre_q.valid && ($signed({4'd0, vpos_l}) >= $signed(pre_q.top)) && (sy_s < hsrc);
	assign ey_sum  = {1'b0, sy_e} + {1'b0, pre_q.ry};
	assign go      = on_line && !(pre_q.x[10] == 1'b0 && pre_q.x[9:8] != 2'b00) && !late;

	// horizontal step
	logic [9:0] ex_sum;
	assign ex_sum = {1'b0, e} + {1'b0, pre_q.rx};

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
			if (late && busy && (st == L_PIX || (st == L_EV && on_line))) cut <= 1'b1;
		end

	logic [15:0] w0, w1, w2, w3, w4, w6, w7;
	assign {w7, w6, w4, w3, w2, w1, w0} =
		{list_q[127:112], list_q[111:96], list_q[79:64], list_q[63:48],
		 list_q[47:32], list_q[31:16], list_q[15:0]};

	logic [8:0] zx_d, zy_d;
	assign zx_d = bigrun ? {1'b0, w1[7:0]}  : w1[8:0];
	assign zy_d = bigrun ? {1'b0, w1[15:8]} : w2[8:0];

	always_ff @(posedge clk) begin
		pre_we   <= 1'b0;
		vst_we   <= 1'b0;
		dv_start <= 1'b0;
		gfx_req  <= 4'h0;
		lb_we    <= 1'b0;
		if (reset) begin
			st      <= S_IDLE;
			idx     <= 8'd0;
			sl_busy <= 4'h0;
			sl_full <= 4'h0;
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
						if (idx == 8'd255) st <= S_IDLE;
					end
				end

				L_ROW:                      // row_code = code + (ty >> 4) * xnum
					if (mul_n != 0) begin
						if (mul_a[0]) mul_acc <= mul_acc + mul_b;
						mul_a <= mul_a >> 1;
						mul_b <= mul_b << 1;
						mul_n <= mul_n - 3'd1;
					end else begin
						row_code  <= pre_q.code + 16'(mul_acc);
						px        <= pre_q.x[10] ? 9'd0 : {1'b0, pre_q.x[7:0]};
						s         <= pre_q.x[10] ? pre_q.s0x : 9'd0;
						e         <= pre_q.x[10] ? pre_q.e0x : 9'd0;
						st        <= L_PIX;
					end

				L_PIX:
					if (px[8] || s >= wsrc || late)
						st <= L_NEXT;
					else begin
						for (int k = 0; k < 4; k++)
							if (want_ok[k] && !sl_have[k] && !sl_busy[k]) begin
								gfx_addr[k] <= gfx_base + {3'd0, (row_code + {12'd0, want_col[k]}) & code_mask,
								                           ty[3:0], 3'b000};
								gfx_req[k]  <= 1'b1;
								sl_busy[k]  <= 1'b1;
								sl_full[k]  <= 1'b0;
								sl_col[k]   <= want_col[k];
								sl_tag[k]   <= tag;
							end
						if (have_gran) begin
							if (pen != 4'hf) begin
								lb_we     <= 1'b1;
								lb_shadow <= (pen == 4'h0) && pre_q.shadow;
								lb_group  <= pre_q.group;
								lb_x      <= px[7:0];
								lb_d      <= {pre_q.color, pen};
							end
							px <= px + 9'd1;
							if (ex_sum >= {1'b0, pre_q.zx}) begin
								s <= 9'(s + pre_q.qx + 9'd1);
								e <= 9'(ex_sum - {1'b0, pre_q.zx});
							end else begin
								s <= 9'(s + pre_q.qx);
								e <= ex_sum[8:0];
							end
						end
					end

				L_NEXT: begin
					idx <= idx + 8'd1;
					if (idx == 8'd255)
						st <= S_IDLE;
					else
						st <= (st_frame) ? P_RD : L_RD;
				end

				default: st <= S_IDLE;
			endcase

			for (int k = 0; k < 4; k++)
				if (sl_busy[k] && gfx_valid[k]) begin
					sl_gran[k] <= gfx_rdata[k];
					sl_full[k] <= 1'b1;
					sl_busy[k] <= 1'b0;
				end
		end
	end

endmodule
