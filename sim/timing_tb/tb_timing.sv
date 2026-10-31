// SPDX-License-Identifier: GPL-3.0-or-later
//
// cischeat_timing over four frames: line and frame periods, blank and sync
// widths, the interrupt pattern per frame parity, and the video schedule's
// order (latch, frame_go, line_go for rows 16..240, once each).

`timescale 1ns/1ps

module tb_timing;

	logic clk = 0, reset = 1;
	always #10.4167 clk = ~clk;

	logic       ce_pix, hblank, vblank, hsync, vsync, odd_frame;
	logic [8:0] hcount, vcount;
	logic       irq_main1, irq_main2, irq_main4, irq_road4, latch, frame_go, line_go;
	logic [7:0] line_vpos;

	logic run = 1'b1, odd_we = 1'b0, odd_d = 1'b0;
	cischeat_timing dut (.*);

	int errors = 0;
	task automatic fail(input string s);
		errors++;
		if (errors < 20) $display("FAIL %s", s);
	endtask

	longint clk_n = 0, last_line = -1, last_frame = -1;
	int     ce_n, hs_n, vs_lines, vis_lines;
	int     n1, n2, n4, nr, nlatch, nfg, nlg, frames;
	int     latch_row, fg_row, lg_first, lg_last, lg_expect;
	logic   prev_hs, prev_vs;

	always @(posedge clk) if (!reset) begin
		clk_n++;
		if (ce_pix) ce_n++;

		// a line starts when hcount returns to 0 (seen the clock after)
		if (dut.row_first) begin
			if (last_line >= 0 && clk_n - last_line != 3072)
				fail($sformatf("line period %0d at row %0d", clk_n - last_line, vcount));
			last_line = clk_n;
			if (hcount != 0) fail($sformatf("row_first at hcount %0d", hcount));
		end

		if (hsync && !prev_hs) hs_n = 0;
		if (hsync) hs_n++;
		if (!hsync && prev_hs && hs_n != 28 * 8) fail($sformatf("hsync %0d clocks", hs_n));
		prev_hs = hsync;

		if (irq_main1) n1++;
		if (irq_main2) n2++;
		if (irq_main4) n4++;
		if (irq_road4) nr++;
		if (irq_main1 && !odd_frame) fail("IRQ1 on an even frame");
		if (irq_main4 &&  odd_frame) fail("IRQ4 on an odd frame");
		if ((irq_main1 || irq_main4 || irq_road4) && vcount != 240) fail("vblank IRQ off row 240");
		if (irq_main2 && vcount != 0) fail("IRQ2 off row 0");
		if (irq_road4 != (irq_main1 || irq_main4)) fail("road IRQ4 not with the main vblank IRQ");

		if (latch)    begin nlatch++; latch_row = vcount; end
		if (frame_go) begin
			nfg++; fg_row = vcount;
			if (nlatch != nfg) fail("frame_go without a latch before it");
			lg_expect = 16;
		end
		if (line_go) begin
			nlg++;
			if (!vblank && vcount + 2 != line_vpos) fail("line_vpos");
			if (nfg > 0 && line_vpos != lg_expect)
				fail($sformatf("line_go vpos %0d, expected %0d", line_vpos, lg_expect));
			lg_expect++;
			if (line_vpos > 240 || line_vpos < 16) fail($sformatf("line_go vpos %0d", line_vpos));
		end

		// frame boundary at row 0
		if (dut.row_first && vcount == 0) begin
			if (last_frame >= 0) begin
				if (clk_n - last_frame != 3072 * 260) fail($sformatf("frame period %0d", clk_n - last_frame));
				if (ce_n != 384 * 260) fail($sformatf("%0d pixel enables per frame", ce_n));
				if (vis_lines != 224) fail($sformatf("%0d visible lines", vis_lines));
				if (vs_lines != 3) fail($sformatf("%0d vsync lines", vs_lines));
				frames++;
			end else begin
				n1 = 0; n2 = 0; n4 = 0; nr = 0; nlatch = 0; nfg = 0; nlg = 0;
			end
			last_frame = clk_n;
			ce_n = 0; vis_lines = 0; vs_lines = 0;
		end
		if (dut.row_first && !vblank) vis_lines++;
		if (dut.row_first && vsync) vs_lines++;
	end

	initial begin
		repeat (5) @(posedge clk);
		reset = 0;
		wait (frames == 4);
		@(posedge clk);

		// counted from the first row 0 after reset to the fifth, inclusive of the fifth
		$display("IRQ1 %0d  IRQ2 %0d  IRQ4 %0d  road IRQ4 %0d  latch %0d (row %0d)  frame_go %0d (row %0d)  line_go %0d",
		         n1, n2, n4, nr, nlatch, latch_row, nfg, fg_row, nlg);
		if (n1 + n4 != 4)          fail("vblank IRQs per four frames");
		if (n1 != 2 || n4 != 2)    fail("IRQ1/IRQ4 do not alternate");
		if (n2 != 2)               fail("IRQ2 count");
		if (nr != 4)               fail("road IRQ4 count");
		if (nlatch != 4 || nfg != 4) fail("latch/frame_go per frame");
		if (fg_row != latch_row + 1) fail("frame_go not the row after latch");
		if (nlg != 4 * 225)        fail($sformatf("line_go %0d, expected %0d", nlg, 4 * 225));

		if (errors == 0) $display("PASS: 4 frames");
		else             $display("FAILED: %0d errors", errors);
		$finish;
	end

	initial begin
		#100ms;
		$display("FAILED: timeout");
		$finish;
	end

endmodule
