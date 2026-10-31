// SPDX-License-Identifier: GPL-3.0-or-later
//
// Cisco Heat screen timing, interrupts and the video schedule.
//
// 384 x 260 at 6.000 MHz (48 MHz / 8): 15.625 kHz, 60.096 Hz. The pixel clock
// is a hypothesis (docs/HACKS.md, docs/ROADMAP.md Open items). vcount is the
// driver's bitmap row: rows 16..239 are visible (Cisco Heat's MAME visarea ends
// at 231; the core shows the 224-line window), 240..259 and 0..15 are vblank.
// hcount 0..255 is visible; sync sits in the 128-pixel blank.
//
// Interrupts, MAME's guess (cischeat.cpp 1719-1743, docs/MAME_KLUDGES.md): at
// row 240 the main CPU gets IRQ1 on odd frames and IRQ4 on even frames; at row
// 0, IRQ2 on even frames. The frame parity toggles at row 240. The road CPUs
// get IRQ4 at vblank start, row 240. Each is a one-clock event; the board
// holds the line until the CPU acknowledges (HOLD_LINE).
//
// Video schedule, one event per line at hcount 0, pixel-enable aligned:
//   row LATCH_ROW      latch: copy the sprite list, hold the scroll registers.
//                      Row 4 is 24 lines into vblank, after 95-96% of the
//                      sprite writes (docs/write_timing_mame.txt).
//   row LATCH_ROW + 1  frame_go: sprite precompute for row 16, 24,833 clocks
//                      (8.1 lines, sim/board_tb), so it needs the 9 to row 14
//   row v, 14..238     line_go for row v + 2: row v + 2 renders, row v + 1 is
//                      read out into the display buffer, row v is on screen

module cischeat_timing #(
	parameter int LATCH_ROW = 4
) (
	input  logic       clk,
	input  logic       reset,
	input  logic       run,          // low holds the screen (savestate engine)
	input  logic       odd_we,       // savestate load
	input  logic       odd_d,

	output logic       ce_pix,
	output logic [8:0] hcount,       // 0..383
	output logic [8:0] vcount,       // 0..259
	output logic       hblank, vblank, hsync, vsync,
	output logic       odd_frame,

	output logic       irq_main1,    // events, one clock
	output logic       irq_main2,
	output logic       irq_main4,
	output logic       irq_road4,

	output logic       latch,
	output logic       frame_go,
	output logic       line_go,
	output logic [7:0] line_vpos
);

	localparam int H_TOTAL = 384, V_TOTAL = 260;
	localparam int H_SYNC0 = 288, H_SYNC1 = 316;   // 28 px, 4.67 us
	localparam int V_SYNC0 = 244, V_SYNC1 = 247;   // 3 lines
	localparam int V_VIS0  = 16,  V_VIS1  = 240;   // rows 16..239

	logic [2:0] div;
	always_ff @(posedge clk)
		if (reset)    div <= 3'd0;
		else if (run) div <= div + 3'd1;
	assign ce_pix = run && div == 3'd7;

	// the clock on which a new line begins
	logic line_start;
	assign line_start = ce_pix && hcount == 9'(H_TOTAL - 1);

	always_ff @(posedge clk)
		if (reset) begin
			hcount    <= 9'd0;
			vcount    <= 9'd0;
			odd_frame <= 1'b0;
		end else if (odd_we) begin
			odd_frame <= odd_d;
		end else if (ce_pix) begin
			if (hcount == 9'(H_TOTAL - 1)) begin
				hcount <= 9'd0;
				vcount <= (vcount == 9'(V_TOTAL - 1)) ? 9'd0 : vcount + 9'd1;
				if (vcount == 9'(V_VIS1 - 1)) odd_frame <= ~odd_frame;
			end else
				hcount <= hcount + 9'd1;
		end

	assign hblank = hcount >= 9'd256;
	assign vblank = vcount < 9'(V_VIS0) || vcount >= 9'(V_VIS1);
	assign hsync  = hcount >= 9'(H_SYNC0) && hcount < 9'(H_SYNC1);
	assign vsync  = vcount >= 9'(V_SYNC0) && vcount < 9'(V_SYNC1);

	// events fire on the first clock of a row; vcount already holds the new row.
	// odd_frame has toggled at row 240 by then, so row 240's parity is the new
	// frame's and row 0's is the same frame's.
	logic row_first;
	always_ff @(posedge clk) row_first <= line_start && !reset;

	always_comb begin
		irq_main1 = row_first && vcount == 9'd240 &&  odd_frame;
		irq_main4 = row_first && vcount == 9'd240 && !odd_frame;
		irq_main2 = row_first && vcount == 9'd0   && !odd_frame;
		irq_road4 = row_first && vcount == 9'd240;
		latch     = row_first && vcount == 9'(LATCH_ROW);
		frame_go  = row_first && vcount == 9'(LATCH_ROW + 1);
		line_go   = row_first && vcount >= 9'(V_VIS0 - 2) && vcount <= 9'(V_VIS1 - 2);
		line_vpos = 8'(vcount + 9'd2);
	end

endmodule
