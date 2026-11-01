// SPDX-License-Identifier: GPL-3.0-or-later
//
// Big Run, Cisco Heat and F1 GP Star video: three ms1_tmap_line, two road
// engines (jaleco_road_line, or jaleco_zoomroad_line on F1 GP Star) and one
// jaleco_zoomspr_line engine into double-buffered line buffers (up to seven
// sprite pass groups), the pass-ordered mixer, and the palette with MAME's
// shadow half.
//
// line_go(vpos) starts every engine on line vpos into bank vpos[0], and the
// readout of line vpos - 1 from the other bank. Each must finish before the
// next line_go; overrun latches if one has not. frame_go(y0) runs the sprite
// precompute; line_go must then follow for every line from y0 upward.
//
// Readout: two clocks per pixel (read, then clear the sprite buffers), out as
// pix_valid with pix_x, pix_y, 8-bit RGB and the palette index ({shadow, idx}).
//
// The scroll RAMs, road line lists, latched sprite list and palette are
// outside, each a registered read port. Each engine has its own gfx client port.

module cischeat_video (
	input  logic         clk,
	input  logic         reset,
	input  logic [2:0]   board,         // 0 Big Run, 1 Cisco Heat, 2 F1 GP Star

	input  logic         frame_go,
	input  logic [7:0]   y0,
	input  logic         line_go,
	input  logic [7:0]   vpos,
	output logic         busy,
	output logic         overrun,
	output logic         spr_busy,      // sprite engine working
	output logic         spr_cut_line,  // pulse at line_go: the sprite cutoff shortened the last line
	output logic [16:0]  spr_dbg,       // probes: {line, granules issued, the engine's dbg}

	// layer registers, held for the frame by the caller
	input  logic [15:0]  scroll_x [3],
	input  logic [15:0]  scroll_y [3],
	input  logic [15:0]  scroll_ctrl [3],
	input  logic [25:0]  tmap_base [3],
	input  logic [13:0]  tmap_mask [3],
	input  logic [25:0]  road_base [2],
	input  logic [15:0]  road_mask [2],
	input  logic [25:0]  spr_base,
	input  logic [15:0]  spr_mask,

	// memories
	output logic [12:0]  vram_addr [3],
	input  logic [15:0]  vram_q [3],
	output logic [9:0]   rlist_addr [2],
	input  logic [15:0]  rlist_q [2],
	output logic [7:0]   slist_addr,
	input  logic [127:0] slist_q,
	output logic [13:0]  pal_addr,
	input  logic [15:0]  pal_q,

	// gfx clients: 0-2 tilemaps, 3-4 roads, 5-8 sprites
	output logic [8:0]   gfx_req,
	output logic [25:0]  gfx_addr [9],
	input  logic [8:0]   gfx_valid,
	input  logic [63:0]  gfx_rdata [9],

	output logic         pix_valid,
	output logic [7:0]   pix_x,
	output logic [7:0]   pix_y,
	output logic [7:0]   pix_r, pix_g, pix_b,
	output logic [14:0]  pix_idx
);

	// sprite pass group by priority, 3 bits each, priority 7 first.
	// Cisco Heat: 7..3 -> 0, 2 -> 1, 1..0 -> 2.
	// Big Run: the last pass that draws priority p is max(p - 1, 0)
	// (draw_sprites(i + 1, i), cischeat.cpp 399-423).
	localparam logic [23:0] GRP_CH = {3'd0, 3'd0, 3'd0, 3'd0, 3'd0, 3'd1, 3'd2, 3'd2};
	localparam logic [23:0] GRP_BR = {3'd6, 3'd5, 3'd4, 3'd3, 3'd2, 3'd1, 3'd0, 3'd0};
	// F1 GP Star: 7..2 -> 0, 1 -> 1, 0 -> 2 (screen_update_f1gpstar, 460-488)
	localparam logic [23:0] GRP_F1 = {3'd0, 3'd0, 3'd0, 3'd0, 3'd0, 3'd0, 3'd1, 3'd2};

	logic bigrun, f1;
	assign bigrun = board == 3'd0;
	assign f1     = board >= 3'd2;

	logic       ro_start, ro_active, ro_ph;
	logic [8:0] ro_x;
	logic [8:0] rd_addr;
	logic       rd_clear;

	logic       wb;                 // bank the engines write
	logic [7:0] ro_y;
	logic       ro_pending;         // a line to read out
	always_ff @(posedge clk)
		if (reset) begin
			wb <= 1'b0;
			ro_pending <= 1'b0;
		end else if (line_go) begin
			wb         <= vpos[0];
			ro_y       <= vpos - 8'd1;
			ro_pending <= 1'b1;
		end else if (ro_start)
			ro_pending <= 1'b0;

	// ---- engines -------------------------------------------------------
	logic [5:0] eng_busy;
	logic       spr_cut;

	logic       t_we [3];
	logic [7:0] t_x  [3];
	logic [8:0] t_d  [3];
	logic [8:0] t_q  [3];

	genvar i;
	generate
		for (i = 0; i < 3; i++) begin : tm
			ms1_tmap_line u (
				.clk, .reset, .start(line_go), .vpos, .busy(eng_busy[i]),
				.scroll_x(scroll_x[i]), .scroll_y(scroll_y[i]), .ctrl(scroll_ctrl[i]),
				.color5(board == 3'd1), .gfx_base(tmap_base[i]), .code_mask(tmap_mask[i]),
				.vram_addr(vram_addr[i]), .vram_q(vram_q[i]),
				.gfx_req(gfx_req[i]), .gfx_addr(gfx_addr[i]),
				.gfx_valid(gfx_valid[i]), .gfx_rdata(gfx_rdata[i]),
				.lb_we(t_we[i]), .lb_x(t_x[i]), .lb_d(t_d[i])
			);
			line_buffer #(.W(9)) lb (
				.clk,
				.a_we(t_we[i]), .a_addr({wb, t_x[i]}), .a_d(t_d[i]),
				.b_addr(rd_addr), .b_we(1'b0), .b_d('0), .b_q(t_q[i])
			);
		end
	endgenerate

	logic       r_we  [2];
	logic [7:0] r_x   [2];
	logic [10:0] r_d  [2];
	logic [2:0] r_pri [2];
	logic [10:0] r_q  [2];
	logic [2:0] r_pri_bank [2][2];   // [road][bank]: the line's priority

	generate
		for (i = 0; i < 2; i++) begin : rd
			// both engines are built; the board picks one
			logic       fx_busy, zm_busy, fx_req, zm_req, fx_we, zm_we;
			logic [9:0] fx_la, zm_la;
			logic [25:0] fx_ga, zm_ga;
			logic [7:0] fx_x, zm_x;
			logic [9:0] fx_d;
			logic [10:0] zm_d;
			logic [2:0] fx_pri, zm_pri;
			jaleco_road_line u (
				.clk, .reset, .start(line_go && !f1), .vpos, .busy(fx_busy),
				.gfx_base(road_base[i]), .code_mask(road_mask[i]),
				.list_addr(fx_la), .list_q(rlist_q[i]),
				.gfx_req(fx_req), .gfx_addr(fx_ga),
				.gfx_valid(gfx_valid[3 + i] && !f1), .gfx_rdata(gfx_rdata[3 + i]),
				.lb_we(fx_we), .lb_x(fx_x), .lb_d(fx_d), .lb_pri(fx_pri)
			);
			jaleco_zoomroad_line z (
				.clk, .reset, .start(line_go && f1), .vpos, .busy(zm_busy),
				.gfx_base(road_base[i]), .code_mask(road_mask[i]),
				.list_addr(zm_la), .list_q(rlist_q[i]),
				.gfx_req(zm_req), .gfx_addr(zm_ga),
				.gfx_valid(gfx_valid[3 + i] && f1), .gfx_rdata(gfx_rdata[3 + i]),
				.lb_we(zm_we), .lb_x(zm_x), .lb_d(zm_d), .lb_pri(zm_pri)
			);
			assign eng_busy[3 + i]  = f1 ? zm_busy : fx_busy;
			assign rlist_addr[i]    = f1 ? zm_la : fx_la;
			assign gfx_req[3 + i]   = f1 ? zm_req : fx_req;
			assign gfx_addr[3 + i]  = f1 ? zm_ga : fx_ga;
			assign r_we[i]  = f1 ? zm_we : fx_we;
			assign r_x[i]   = f1 ? zm_x : fx_x;
			assign r_d[i]   = f1 ? zm_d : {1'b1, fx_d};
			assign r_pri[i] = f1 ? zm_pri : fx_pri;
			line_buffer #(.W(11)) lb (
				.clk,
				.a_we(r_we[i]), .a_addr({wb, r_x[i]}), .a_d(r_d[i]),
				.b_addr(rd_addr), .b_we(1'b0), .b_d('0), .b_q(r_q[i])
			);
			always_ff @(posedge clk)
				if (r_we[i]) r_pri_bank[i][wb] <= r_pri[i];
		end
	endgenerate

	logic        s_we, s_shadow;
	logic [2:0]  s_group;
	logic [7:0]  s_x;
	logic [10:0] s_d;

	logic [5:0] spr_dbg_e;
	logic [7:0] spr_vpos;

	// cut a sprite line before the next line_go (384 pixels x 8 clocks)
	jaleco_zoomspr_line #(.LINE_CLK(3072)) spr (
		.clk, .reset, .frame_start(frame_go), .y0, .start(line_go), .vpos, .busy(eng_busy[5]), .cut(spr_cut),
		.bigrun, .grp_of_pri(bigrun ? GRP_BR : f1 ? GRP_F1 : GRP_CH), .gfx_base(spr_base), .code_mask(spr_mask),
		.list_addr(slist_addr), .list_q(slist_q),
		.gfx_req(gfx_req[8:5]), .gfx_addr(gfx_addr[5:8]),
		.gfx_valid(gfx_valid[8:5]), .gfx_rdata(gfx_rdata[5:8]),
		.lb_we(s_we), .lb_shadow(s_shadow), .lb_group(s_group), .lb_x(s_x), .lb_d(s_d),
		.dbg(spr_dbg_e)
	);
	always_ff @(posedge clk) if (line_go) spr_vpos <= vpos;
	assign spr_dbg = {spr_vpos, 3'(gfx_req[5]) + 3'(gfx_req[6]) + 3'(gfx_req[7]) + 3'(gfx_req[8]), spr_dbg_e};

	// sprite groups: {opaque, color, pen} and the shadow bit in separate buffers,
	// so an opaque write clears shadow and a shadow write leaves the rest
	logic [11:0] sm_q [7];
	logic        ss_q [7];
	logic [12:0] spr_q [7];
	generate
		for (i = 0; i < 7; i++) begin : sg
			assign spr_q[i] = {ss_q[i], sm_q[i]};
			line_buffer #(.W(12)) lbm (
				.clk,
				.a_we(s_we && !s_shadow && s_group == 3'(i)), .a_addr({wb, s_x}),
				.a_d({1'b1, s_d}),
				.b_addr(rd_addr), .b_we(rd_clear), .b_d('0), .b_q(sm_q[i])
			);
			line_buffer #(.W(1)) lbs (
				.clk,
				.a_we(s_we && s_group == 3'(i)), .a_addr({wb, s_x}), .a_d(s_shadow),
				.b_addr(rd_addr), .b_we(rd_clear), .b_d(1'b0), .b_q(ss_q[i])
			);
		end
	endgenerate

	// ---- readout -------------------------------------------------------

	assign ro_start = ro_pending && !ro_active;
	assign rd_addr  = {~wb, ro_x[7:0]};
	assign rd_clear = ro_active && ro_ph;

	// pipeline: ph1 has the buffer data -> mixer; +1 idx -> palette; +1 RGB
	logic       m_v, p_v;
	logic [7:0] m_x, p_x;

	always_ff @(posedge clk) begin
		if (reset) begin
			ro_active <= 1'b0;
			m_v <= 1'b0;
			p_v <= 1'b0;
		end else begin
			if (ro_start) begin
				ro_active <= 1'b1;
				ro_x      <= 9'd0;
				ro_ph     <= 1'b0;
			end else if (ro_active) begin
				ro_ph <= ~ro_ph;
				if (ro_ph) begin
					ro_x <= ro_x + 9'd1;
					if (ro_x == 9'd255) ro_active <= 1'b0;
				end
			end
			m_v <= rd_clear;
			m_x <= ro_x[7:0];
			p_v <= m_v;
			p_x <= m_x;
		end
	end

	logic [14:0] idx;
	cischeat_mixer mix (
		.clk, .board,
		.tmap0(t_q[0]), .tmap1(t_q[1]), .tmap2(t_q[2]),
		.road0(r_q[0]), .road1(r_q[1]),
		.road0_pri(r_pri_bank[0][~wb]), .road1_pri(r_pri_bank[1][~wb]),
		.spr(spr_q),
		.idx
	);

	assign pal_addr = idx[13:0];

	// MAME's shadow: (8-bit channel as float32) * 0.6, truncated, by 5-bit value
	function automatic logic [7:0] shade(input logic [4:0] v);
		case (v)
			5'd0:  shade = 8'd0;   5'd1:  shade = 8'd4;   5'd2:  shade = 8'd9;   5'd3:  shade = 8'd14;
			5'd4:  shade = 8'd19;  5'd5:  shade = 8'd24;  5'd6:  shade = 8'd29;  5'd7:  shade = 8'd34;
			5'd8:  shade = 8'd39;  5'd9:  shade = 8'd44;  5'd10: shade = 8'd49;  5'd11: shade = 8'd54;
			5'd12: shade = 8'd59;  5'd13: shade = 8'd64;  5'd14: shade = 8'd69;  5'd15: shade = 8'd73;
			5'd16: shade = 8'd79;  5'd17: shade = 8'd84;  5'd18: shade = 8'd88;  5'd19: shade = 8'd93;
			5'd20: shade = 8'd99;  5'd21: shade = 8'd103; 5'd22: shade = 8'd108; 5'd23: shade = 8'd113;
			5'd24: shade = 8'd118; 5'd25: shade = 8'd123; 5'd26: shade = 8'd128; 5'd27: shade = 8'd133;
			5'd28: shade = 8'd138; 5'd29: shade = 8'd143; 5'd30: shade = 8'd148; default: shade = 8'd153;
		endcase
	endfunction

	// RRRRGGGGBBBBRGBx
	logic [4:0]  r5, g5, b5;
	logic        p_shadow;
	logic [14:0] p_idx;
	assign r5 = {pal_q[15:12], pal_q[3]};
	assign g5 = {pal_q[11:8],  pal_q[2]};
	assign b5 = {pal_q[7:4],   pal_q[1]};

	always_ff @(posedge clk) begin
		p_idx     <= idx;
		pix_valid <= p_v;
		pix_x     <= p_x;
		pix_y     <= ro_y;
		pix_idx   <= p_idx;
		pix_r     <= p_idx[14] ? shade(r5) : {r5, r5[4:2]};
		pix_g     <= p_idx[14] ? shade(g5) : {g5, g5[4:2]};
		pix_b     <= p_idx[14] ? shade(b5) : {b5, b5[4:2]};
	end

	assign busy = (|eng_busy) || ro_pending || ro_active || m_v || p_v || pix_valid;

	always_ff @(posedge clk)
		if (reset)                       overrun <= 1'b0;
		else if (line_go && busy)        overrun <= 1'b1;

	assign spr_busy = eng_busy[5];
	always_ff @(posedge clk) spr_cut_line <= line_go && spr_cut;

endmodule
