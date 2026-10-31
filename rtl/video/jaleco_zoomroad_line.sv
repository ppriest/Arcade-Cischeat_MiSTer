// SPDX-License-Identifier: GPL-3.0-or-later
//
// One jaleco_zoom_road layer (F1 GP Star family), one scanline.
// MAME: jaleco/jaleco_road.cpp, jaleco_zoom_road_device::draw.
//
// The line list holds four words per bitmap row: x scroll with the priority in
// bits 14-12, x zoom (bits 9-0), attribute (colour in bits 13-8), code. A row is
// 16 tiles of 64x1 pixels, 1,024 source pixels, drawn once (no wrap). With
// z = zoom + 1, MAME's row starts at screen x
//     xstart = 1024 - (scroll mod 2048) - z
// and a source pixel is z / 512 screen pixels wide. Screen pixel x >= xstart
// shows source floor((x - xstart) * 512 / z) while that is below 1,024; the
// rest of the line is empty. One accumulator spans the row: MAME draws each
// 64-pixel tile on its own, rounded up a pixel, so tile edges can differ by a
// pixel (docs/HACKS.md).
//
// Output: all 256 pixels, as {covered, color[5:0], pen[3:0]}; covered = 0 is a
// pixel no tile reaches. lb_pri is the line's priority. The list port is a
// registered read. gfx_req is a one-clock pulse per 64-bit granule (16 pixels,
// low nibble first); one fetch at a time. A fetch pointer runs ahead of the
// draw pointer, queueing each new granule it reaches in a 4-entry FIFO.

module jaleco_zoomroad_line (
	input  logic        clk,
	input  logic        reset,

	input  logic        start,       // pulse: render line vpos
	input  logic [7:0]  vpos,
	output logic        busy,

	input  logic [25:0] gfx_base,
	input  logic [15:0] code_mask,   // tiles in the region - 1

	output logic [9:0]  list_addr,
	input  logic [15:0] list_q,

	output logic        gfx_req,
	output logic [25:0] gfx_addr,
	input  logic        gfx_valid,
	input  logic [63:0] gfx_rdata,

	output logic        lb_we,
	output logic [7:0]  lb_x,
	output logic [10:0] lb_d,         // {covered, color[5:0], pen[3:0]}
	output logic [2:0]  lb_pri
);

	typedef enum logic [3:0] {
		S_IDLE, S_W0, S_W1, S_W2, S_W3, S_DIV0, S_DIV1, S_RUN
	} state_t;
	state_t st;

	logic [7:0]  vpos_l;
	logic [10:0] z;              // zoom + 1, 1..1024
	logic [5:0]  color;
	logic [15:0] code;
	logic signed [12:0] xstart;
	logic [9:0]  q;              // 512 / z
	logic [10:0] r;              // 512 mod z

	always_comb
		case (st)
			S_IDLE:  list_addr = {vpos, 2'd0};
			S_W0:    list_addr = {vpos_l, 2'd1};
			S_W1:    list_addr = {vpos_l, 2'd2};
			default: list_addr = {vpos_l, 2'd3};
		endcase

	// ---- serial divider: 21-bit numerator / 11-bit denominator -----------
	logic        dv_start, dv_busy, dv_done;
	logic [20:0] dv_num, dv_q;
	logic [10:0] dv_rem;
	logic [4:0]  dv_n;
	logic [11:0] dv_r2;
	assign dv_r2 = {dv_rem, dv_q[20]};

	always_ff @(posedge clk) begin
		dv_done <= 1'b0;
		if (reset)
			dv_busy <= 1'b0;
		else if (dv_start) begin
			dv_q    <= dv_num;
			dv_rem  <= 11'd0;
			dv_n    <= 5'd21;
			dv_busy <= 1'b1;
		end else if (dv_busy) begin
			if (dv_r2 >= {1'b0, z}) begin
				dv_rem <= 11'(dv_r2 - {1'b0, z});
				dv_q   <= {dv_q[19:0], 1'b1};
			end else begin
				dv_rem <= dv_r2[10:0];
				dv_q   <= {dv_q[19:0], 1'b0};
			end
			dv_n <= dv_n - 5'd1;
			if (dv_n == 5'd1) begin
				dv_busy <= 1'b0;
				dv_done <= 1'b1;
			end
		end
	end

	// ---- accumulators: fetch (f_) runs ahead of draw (d_) -----------------
	// source pixel s (11 bits, 1024 = past the row), remainder e < z
	logic [10:0] f_s, d_s;
	logic [10:0] f_e, d_e;
	logic [8:0]  f_x, d_x;       // screen x, 256 = done
	logic        f_first;
	logic [5:0]  f_last;         // last granule queued

	function automatic logic [21:0] step(input logic [10:0] s, input logic [10:0] e);
		logic [11:0] es;
		es = {1'b0, e} + {1'b0, r};
		if (es >= {1'b0, z}) return {11'(s + {1'b0, q} + 11'd1), 11'(es - {1'b0, z})};
		else                 return {11'(s + {1'b0, q}), es[10:0]};
	endfunction

	logic f_in, d_in;            // the pointer is on the row
	assign f_in = !f_x[8] && $signed({4'd0, f_x}) >= xstart && !f_s[10];
	assign d_in = !d_x[8] && $signed({4'd0, d_x}) >= xstart && !d_s[10];

	// granule FIFO
	logic [5:0]  q_tag  [4];
	logic [63:0] q_dat  [4];
	logic [3:0]  q_ok;           // data arrived
	logic [1:0]  q_wp, q_rp, q_fp;   // write (issue), read, fill (arrival)
	logic [2:0]  q_n;            // entries issued and not popped
	logic        f_busy;         // a fetch in flight

	logic        f_need, f_issue;
	assign f_need  = st == S_RUN && f_in && (f_first || f_s[9:4] != f_last);
	assign f_issue = f_need && q_n != 3'd4 && !f_busy;

	logic [15:0] tile;
	assign tile = {code[11:0], f_s[9:6]} & code_mask;

	// draw side: the head entry holds d_s's granule once it has arrived
	logic        d_hit, d_pop;
	assign d_hit = q_n != 3'd0 && q_tag[q_rp] == d_s[9:4] && q_ok[q_rp];
	assign d_pop = q_n != 3'd0 && d_in && q_tag[q_rp] != d_s[9:4];

	logic [3:0] pen;
	assign pen = q_dat[q_rp][{d_s[3:0], 2'b00} +: 4];

	assign busy = st != S_IDLE;

	always_ff @(posedge clk) begin
		dv_start <= 1'b0;
		gfx_req  <= 1'b0;
		lb_we    <= 1'b0;
		if (reset) begin
			st     <= S_IDLE;
			f_busy <= 1'b0;
			q_n    <= 3'd0;
		end else begin
			case (st)
				S_IDLE: if (start) begin
					vpos_l <= vpos;
					st     <= S_W0;
				end

				S_W0: begin                 // word 0: scroll, priority
					lb_pri <= list_q[14:12];
					xstart <= 13'sd1024 - $signed({2'b00, list_q[10:0]});
					st     <= S_W1;
				end

				S_W1: begin                 // word 1: zoom
					z      <= {1'b0, list_q[9:0]} + 11'd1;
					xstart <= xstart - $signed({2'b00, list_q[9:0]}) - 13'sd1;
					st     <= S_W2;
				end

				S_W2: begin                 // word 2: attribute
					color <= list_q[13:8];
					st    <= S_W3;
				end

				S_W3: begin                 // word 3: code; 512 / z
					code     <= list_q;
					dv_num   <= 21'd512;
					dv_start <= 1'b1;
					st       <= S_DIV0;
				end

				S_DIV0: if (dv_done) begin
					q <= dv_q[9:0];
					r <= dv_rem;
					// source at screen x 0 when the row starts left of it
					dv_num   <= xstart[12] ? {(12'(-xstart)), 9'd0} : 21'd0;
					dv_start <= 1'b1;
					st       <= S_DIV1;
				end

				S_DIV1: if (dv_done) st <= S_RUN;

				S_RUN: begin
					// fetch pointer
					if (f_x[8] || (f_in == 1'b0 && $signed({4'd0, f_x}) >= xstart)) begin
						// past the screen or the row: nothing more to fetch
					end else if (!f_in) begin
						f_x <= f_x + 9'd1;              // left of the row
					end else if (!f_need || f_issue) begin
						if (f_issue) begin
							gfx_addr     <= gfx_base + {5'd0, tile, f_s[5:4], 3'b000};
							gfx_req      <= 1'b1;
							f_busy       <= 1'b1;
							q_tag[q_wp]  <= f_s[9:4];
							q_ok[q_wp]   <= 1'b0;
							q_wp         <= q_wp + 2'd1;
							f_last       <= f_s[9:4];
							f_first      <= 1'b0;
						end
						f_x <= f_x + 9'd1;
						{f_s, f_e} <= step(f_s, f_e);
					end

					// draw pointer
					if (d_x[8]) begin
						st <= S_IDLE;
					end else if (!d_in) begin
						lb_we <= 1'b1;
						lb_x  <= d_x[7:0];
						lb_d  <= 11'd0;
						d_x   <= d_x + 9'd1;
					end else if (d_hit) begin
						lb_we <= 1'b1;
						lb_x  <= d_x[7:0];
						lb_d  <= {1'b1, color, pen};
						d_x   <= d_x + 9'd1;
						{d_s, d_e} <= step(d_s, d_e);
					end
				end

				default: st <= S_IDLE;
			endcase

			if (st == S_DIV1 && dv_done) begin
				f_x     <= 9'd0;
				d_x     <= 9'd0;
				f_s     <= (dv_q[20:10] != 0) ? 11'h400 : dv_q[10:0];
				d_s     <= (dv_q[20:10] != 0) ? 11'h400 : dv_q[10:0];
				f_e     <= dv_rem;
				d_e     <= dv_rem;
				f_first <= 1'b1;
				q_wp    <= 2'd0;
				q_rp    <= 2'd0;
				q_fp    <= 2'd0;
			end

			if (gfx_valid && f_busy) begin
				q_dat[q_fp] <= gfx_rdata;
				q_ok[q_fp]  <= 1'b1;
				q_fp        <= q_fp + 2'd1;
				f_busy      <= 1'b0;
			end

			if (d_pop) q_rp <= q_rp + 2'd1;
			q_n <= (st == S_DIV1) ? 3'd0 : q_n + {2'd0, f_issue} - {2'd0, d_pop};
		end
	end

endmodule
