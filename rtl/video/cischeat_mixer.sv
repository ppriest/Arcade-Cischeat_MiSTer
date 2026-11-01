// SPDX-License-Identifier: GPL-3.0-or-later
//
// The draw sequence for one pixel, as a painter's chain over the layer line
// buffers. Roads and tilemaps are transparent at pen 15 except where marked
// opaque. A sprite shadow sets bit 14 (MAME's shadow palette half) on whatever
// lies beneath it, once. The sprite passes are the engine's pass groups.
//
// Cisco Heat, screen_update_cischeat (cischeat.cpp 430-453), backdrop pen 0:
//   road0 7..5 opaque; road1 7..5; tmap0; tmap1; sprites 7..3 (group 0);
//   road0 4..1; road1 4..1; sprites 2 (1); road0 0; road1 0; sprites 1..0 (2); tmap2
// MAME's last pass, sprites (16, 16), can match no sprite and is left out
// (docs/ROADMAP.md, Video).
//
// Big Run, screen_update_bigrun (399-423), backdrop pen 0x1000:
//   for i = 7..4: road0 i (opaque at 7); road1 i; sprites (i + 1, i);
//   tmap0; tmap1; for i = 3..0: road0 i; road1 i; sprites (i + 1, i); tmap2
// A sprite of priority p is drawn in passes p and p - 1; the second draw covers
// the first, so it is kept once, in group max(p - 1, 0) (cischeat_video).
//
// F1 GP Star, screen_update_f1gpstar (460-488), backdrop road0's colour base,
// road1 before road0:
//   road1 6..7; road0 6..7; tmap0; tmap1; road1 1..5; road0 1..5;
//   sprites 2..7 (group 0); road1 0; road0 0; sprites 1 (1); tmap2; sprites 0 (2)
// A zooming road leaves pixels no tile reaches (covered = 0); MAME draws nothing
// there, opaque pass or not.
//
// Output: palette index[13:0] and shadow in idx[14], one clock after the inputs.

module cischeat_mixer (
	input  logic        clk,
	input  logic [2:0]  board,          // 0 Big Run, 1 Cisco Heat, 2 F1 GP Star

	input  logic [8:0]  tmap0, tmap1, tmap2,       // {color[4:0], pen}
	input  logic [10:0] road0, road1,              // {covered, color[5:0], pen}
	input  logic [2:0]  road0_pri, road1_pri,      // the line's priority
	input  logic [12:0] spr [7],                   // per group: {shadow, opaque, color[6:0], pen}

	output logic [14:0] idx
);

	// colour bases, palette words (driver byte offsets / 2)
	localparam logic [13:0] CH_TMAP0 = 14'h0e00, CH_TMAP1 = 14'h1600, CH_TMAP2 = 14'h3600;
	localparam logic [13:0] CH_ROAD0 = 14'h1c00, CH_ROAD1 = 14'h2400, CH_SPR   = 14'h2800;
	localparam logic [13:0] BR_TMAP0 = 14'h0700, BR_TMAP1 = 14'h0b00, BR_TMAP2 = 14'h1b00;
	localparam logic [13:0] BR_ROAD0 = 14'h1000, BR_ROAD1 = 14'h0c00, BR_SPR   = 14'h1400;
	localparam logic [13:0] F1_TMAP0 = 14'h0f00, F1_TMAP1 = 14'h1700, F1_TMAP2 = 14'h3700;
	localparam logic [13:0] F1_ROAD0 = 14'h1c00, F1_ROAD1 = 14'h2400, F1_SPR   = 14'h2800;

	function automatic logic [14:0] tmap(input logic [14:0] v, input logic [8:0] p,
	                                     input logic [13:0] base);
		return (p[3:0] != 4'hf) ? {1'b0, base + {5'd0, p}} : v;
	endfunction

	function automatic logic [14:0] road(input logic [14:0] v, input logic [10:0] p,
	                                     input logic [2:0] pri, input logic [2:0] lo,
	                                     input logic [2:0] hi, input logic opaque,
	                                     input logic [13:0] base);
		return (p[10] && pri >= lo && pri <= hi && (opaque || p[3:0] != 4'hf))
		       ? {1'b0, base + {4'd0, p[9:0]}} : v;
	endfunction

	function automatic logic [14:0] sprite(input logic [14:0] v, input logic [12:0] p,
	                                       input logic [13:0] base);
		logic [14:0] r;
		r = p[11] ? {1'b0, base + {3'd0, p[10:0]}} : v;
		if (p[12]) r[14] = 1'b1;
		return r;
	endfunction

	logic [14:0] v_ch, v_br, v_f1, v;
	always_comb begin
		v_ch = 15'd0;
		v_ch = road(v_ch, road0, road0_pri, 3'd5, 3'd7, 1'b1, CH_ROAD0);
		v_ch = road(v_ch, road1, road1_pri, 3'd5, 3'd7, 1'b0, CH_ROAD1);
		v_ch = tmap(v_ch, tmap0, CH_TMAP0);
		v_ch = tmap(v_ch, tmap1, CH_TMAP1);
		v_ch = sprite(v_ch, spr[0], CH_SPR);
		v_ch = road(v_ch, road0, road0_pri, 3'd1, 3'd4, 1'b0, CH_ROAD0);
		v_ch = road(v_ch, road1, road1_pri, 3'd1, 3'd4, 1'b0, CH_ROAD1);
		v_ch = sprite(v_ch, spr[1], CH_SPR);
		v_ch = road(v_ch, road0, road0_pri, 3'd0, 3'd0, 1'b0, CH_ROAD0);
		v_ch = road(v_ch, road1, road1_pri, 3'd0, 3'd0, 1'b0, CH_ROAD1);
		v_ch = sprite(v_ch, spr[2], CH_SPR);
		v_ch = tmap(v_ch, tmap2, CH_TMAP2);

		v_br = 15'h1000;
		for (int i = 7; i >= 0; i--) begin
			v_br = road(v_br, road0, road0_pri, 3'(i), 3'(i), i == 7, BR_ROAD0);
			v_br = road(v_br, road1, road1_pri, 3'(i), 3'(i), 1'b0, BR_ROAD1);
			if (i < 7) v_br = sprite(v_br, spr[i], BR_SPR);
			if (i == 4) begin
				v_br = tmap(v_br, tmap0, BR_TMAP0);
				v_br = tmap(v_br, tmap1, BR_TMAP1);
			end
		end
		v_br = tmap(v_br, tmap2, BR_TMAP2);

		v_f1 = {1'b0, F1_ROAD0};
		v_f1 = road(v_f1, road1, road1_pri, 3'd6, 3'd7, 1'b0, F1_ROAD1);
		v_f1 = road(v_f1, road0, road0_pri, 3'd6, 3'd7, 1'b0, F1_ROAD0);
		v_f1 = tmap(v_f1, tmap0, F1_TMAP0);
		v_f1 = tmap(v_f1, tmap1, F1_TMAP1);
		v_f1 = road(v_f1, road1, road1_pri, 3'd1, 3'd5, 1'b0, F1_ROAD1);
		v_f1 = road(v_f1, road0, road0_pri, 3'd1, 3'd5, 1'b0, F1_ROAD0);
		v_f1 = sprite(v_f1, spr[0], F1_SPR);
		v_f1 = road(v_f1, road1, road1_pri, 3'd0, 3'd0, 1'b0, F1_ROAD1);
		v_f1 = road(v_f1, road0, road0_pri, 3'd0, 3'd0, 1'b0, F1_ROAD0);
		v_f1 = sprite(v_f1, spr[1], F1_SPR);
		v_f1 = tmap(v_f1, tmap2, F1_TMAP2);
		v_f1 = sprite(v_f1, spr[2], F1_SPR);

		v = board == 3'd0 ? v_br : board >= 3'd2 ? v_f1 : v_ch;
	end

	always_ff @(posedge clk) idx <= v;

endmodule
