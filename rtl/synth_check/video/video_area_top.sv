// SPDX-License-Identifier: GPL-3.0-or-later
//
// Area and Fmax harness: cischeat_video (three tilemap, two road and one sprite
// line engine, eight line buffers, the mixer, the palette conversion) with the
// memories it reads - 8K x 16 scroll RAMs, 1K x 16 road line lists, the
// 256 x 128 latched sprite list (two 64-bit halves), the 16K x 16 palette -
// each filled through a write port so synthesis cannot treat it as a constant.
// Every port is registered and every pin virtual.

module video_area_top (
	input  logic        clk,
	input  logic        reset,
	input  logic [63:0] din,      // gfx granule for every client, RAM write data
	input  logic [15:0] sel,      // RAM write address; vpos / y0 in [15:8]
	input  logic [3:0]  wsel,     // which RAM or register
	input  logic        wr,
	input  logic        frame_go,
	input  logic        line_go,
	input  logic [5:0]  valid,
	output logic [5:0]  req,
	output logic [25:0] addr [6],
	output logic        busy,
	output logic        overrun,
	output logic        pix_valid,
	output logic [7:0]  pix_x, pix_y, pix_r, pix_g, pix_b
);

	logic        reset_r, wr_r, fg_r, lg_r;
	logic [63:0] din_r;
	logic [15:0] sel_r;
	logic [3:0]  wsel_r;
	logic [5:0]  valid_r;
	always_ff @(posedge clk) begin
		reset_r <= reset; wr_r <= wr; din_r <= din; sel_r <= sel; wsel_r <= wsel;
		fg_r <= frame_go; lg_r <= line_go; valid_r <= valid;
	end

	// layer registers (wsel 15, sel[1:0] = layer)
	logic [15:0] sx [3], sy [3], ctrl [3];
	always_ff @(posedge clk)
		if (wr_r && wsel_r == 4'd15)
			for (int n = 0; n < 3; n++)
				if (sel_r[1:0] == 2'(n)) begin
					sx[n] <= din_r[15:0]; sy[n] <= din_r[31:16]; ctrl[n] <= din_r[47:32];
				end

	// memories
	logic [15:0]  vram0 [8192], vram1 [8192], vram2 [8192];
	logic [15:0]  rl0 [1024], rl1 [1024];
	logic [63:0]  sl_lo [256], sl_hi [256];
	logic [15:0]  pal [16384];

	logic [12:0]  vram_addr [3];
	logic [15:0]  vram_q [3];
	logic [9:0]   rlist_addr [2];
	logic [15:0]  rlist_q [2];
	logic [7:0]   slist_addr;
	logic [127:0] slist_q;
	logic [13:0]  pal_addr;
	logic [15:0]  pal_q;

	always_ff @(posedge clk) begin
		if (wr_r && wsel_r == 4'd0) vram0[sel_r[12:0]] <= din_r[15:0];
		if (wr_r && wsel_r == 4'd1) vram1[sel_r[12:0]] <= din_r[15:0];
		if (wr_r && wsel_r == 4'd2) vram2[sel_r[12:0]] <= din_r[15:0];
		if (wr_r && wsel_r == 4'd3) rl0[sel_r[9:0]] <= din_r[15:0];
		if (wr_r && wsel_r == 4'd4) rl1[sel_r[9:0]] <= din_r[15:0];
		if (wr_r && wsel_r == 4'd5 && !sel_r[0]) sl_lo[sel_r[8:1]] <= din_r;
		if (wr_r && wsel_r == 4'd5 &&  sel_r[0]) sl_hi[sel_r[8:1]] <= din_r;
		if (wr_r && wsel_r == 4'd6) pal[sel_r[13:0]] <= din_r[15:0];
		vram_q[0]  <= vram0[vram_addr[0]];
		vram_q[1]  <= vram1[vram_addr[1]];
		vram_q[2]  <= vram2[vram_addr[2]];
		rlist_q[0] <= rl0[rlist_addr[0]];
		rlist_q[1] <= rl1[rlist_addr[1]];
		slist_q    <= {sl_hi[slist_addr], sl_lo[slist_addr]};
		pal_q      <= pal[pal_addr];
	end

	logic [5:0]  g_req;
	logic [25:0] g_addr [6];
	logic        v_busy, v_ovr, p_v;
	logic [7:0]  p_x, p_y, p_r, p_g, p_b;
	logic [14:0] p_idx;

	cischeat_video u (
		.clk, .reset(reset_r), .frame_go(fg_r), .y0(sel_r[15:8]), .line_go(lg_r),
		.vpos(sel_r[15:8]), .busy(v_busy), .overrun(v_ovr),
		.scroll_x(sx), .scroll_y(sy), .scroll_ctrl(ctrl),
		.tmap_base('{26'h02c0000, 26'h0340000, 26'h03c0000}),
		.tmap_mask('{14'h1fff, 14'h1fff, 14'h07ff}),
		.road_base('{26'h0a00000, 26'h0a00000}), .road_mask(16'h7fff),
		.spr_base(26'h0400000), .spr_mask(16'h7fff),
		.vram_addr, .vram_q, .rlist_addr, .rlist_q, .slist_addr, .slist_q, .pal_addr, .pal_q,
		.gfx_req(g_req), .gfx_addr(g_addr), .gfx_valid(valid_r),
		.gfx_rdata('{din_r, din_r, din_r, din_r, din_r, din_r}),
		.pix_valid(p_v), .pix_x(p_x), .pix_y(p_y), .pix_r(p_r), .pix_g(p_g), .pix_b(p_b),
		.pix_idx(p_idx)
	);

	always_ff @(posedge clk) begin
		req <= g_req; addr <= g_addr; busy <= v_busy; overrun <= v_ovr;
		pix_valid <= p_v; pix_x <= p_x; pix_y <= p_y; pix_r <= p_r; pix_g <= p_g; pix_b <= p_b;
	end

endmodule
