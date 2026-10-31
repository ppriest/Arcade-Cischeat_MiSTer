// cischeat_video, every engine plus the mixer and palette, against the model's
// full frame (scripts/video_ref.py): bitmap rows 16..239, palette index and RGB.
// Per case: one frame precompute (y0 = 0), then line_go for lines 0..255 and
// one more to read out line 255. Each gfx client answers after a pseudo-random
// 2..24 clocks, or exactly +LAT=n.

`timescale 1ns/1ps

module tb_video;

	logic clk = 0, reset = 1;
	always #10.4 clk = ~clk;

	logic         frame_go, line_go, busy, overrun;
	logic [7:0]   vpos;
	logic [15:0]  scroll_x [3], scroll_y [3], scroll_ctrl [3];
	logic [12:0]  vram_addr [3];
	logic [15:0]  vram_q [3];
	logic [9:0]   rlist_addr [2];
	logic [15:0]  rlist_q [2];
	logic [7:0]   slist_addr;
	logic [127:0] slist_q;
	logic [13:0]  pal_addr;
	logic [15:0]  pal_q;
	logic [8:0]   gfx_req, gfx_valid;
	logic [25:0]  gfx_addr [9];
	logic [63:0]  gfx_rdata [9];
	logic         pix_valid;
	logic [7:0]   pix_x, pix_y, pix_r, pix_g, pix_b;
	logic [14:0]  pix_idx;

	localparam logic [25:0] BASE [9] = '{26'h02c0000, 26'h0340000, 26'h03c0000,
	                                     26'h0a00000, 26'h0a00000,
	                                     26'h0400000, 26'h0400000, 26'h0400000, 26'h0400000};

	cischeat_video dut (
		.clk, .reset, .board(3'd1), .frame_go, .y0(8'd0), .line_go, .vpos, .busy, .overrun,
		.scroll_x, .scroll_y, .scroll_ctrl,
		.tmap_base('{BASE[0], BASE[1], BASE[2]}), .tmap_mask('{14'h1fff, 14'h1fff, 14'h07ff}),
		.road_base('{BASE[3], BASE[4]}), .road_mask('{16'h7fff, 16'h7fff}),
		.spr_base(BASE[5]), .spr_mask(16'h7fff),
		.vram_addr, .vram_q, .rlist_addr, .rlist_q, .slist_addr, .slist_q, .pal_addr, .pal_q,
		.gfx_req, .gfx_addr, .gfx_valid, .gfx_rdata,
		.pix_valid, .pix_x, .pix_y, .pix_r, .pix_g, .pix_b, .pix_idx
	);

	// ---- memories --------------------------------------------------------
	logic [15:0] vram [3][0:8191];
	logic [15:0] rlist [2][0:1023];
	logic [15:0] slist [0:2047];
	logic [15:0] pal [0:16383];
	logic [63:0] g_s0 [0:32767], g_s1 [0:32767], g_s2 [0:8191];
	logic [63:0] g_road [0:131071];
	logic [63:0] g_spr [0:524287];

	always_ff @(posedge clk) begin
		for (int n = 0; n < 3; n++) vram_q[n] <= vram[n][vram_addr[n]];
		for (int n = 0; n < 2; n++) rlist_q[n] <= rlist[n][rlist_addr[n]];
		for (int k = 0; k < 8; k++) slist_q[16*k +: 16] <= slist[{slist_addr, 3'(k)}];
		pal_q <= pal[pal_addr];
	end

	function automatic logic [63:0] gfx_word(input int c, input logic [25:0] a);
		int unsigned w;
		w = (a - BASE[c]) >> 3;
		case (c)
			0: return g_s0[w];
			1: return g_s1[w];
			2: return g_s2[w];
			3, 4: return g_road[w];
			default: return g_spr[w];
		endcase
	endfunction

	int lat = -1;
	int unsigned lfsr [9];
	int          wait_n [9];
	logic [8:0]  pending;
	logic [25:0] p_addr [9];
	always_ff @(posedge clk) begin
		for (int c = 0; c < 9; c++) begin
			gfx_valid[c] <= 1'b0;
			if (gfx_req[c]) begin
				if (pending[c]) $fatal(1, "client %0d: request while one is outstanding", c);
				if (gfx_addr[c][2:0] != 3'd0) $fatal(1, "client %0d: unaligned %h", c, gfx_addr[c]);
				pending[c] <= 1'b1;
				p_addr[c]  <= gfx_addr[c];
				lfsr[c]    <= lfsr[c] * 1103515245 + 12345;
				wait_n[c]  <= (lat >= 0) ? lat : 2 + ((lfsr[c] >> 16) % 23);
			end else if (pending[c]) begin
				if (wait_n[c] == 0) begin
					gfx_rdata[c] <= gfx_word(c, p_addr[c]);
					gfx_valid[c] <= 1'b1;
					pending[c]   <= 1'b0;
				end else
					wait_n[c] <= wait_n[c] - 1;
			end
		end
	end

	// ---- capture ----------------------------------------------------------
	logic [14:0] got_idx [0:65535];
	logic [23:0] got_rgb [0:65535];
	logic [15:0] exp_idx [0:57343];
	logic [23:0] exp_rgb [0:57343];
	always_ff @(posedge clk)
		if (pix_valid) begin
			got_idx[{pix_y, pix_x}] <= pix_idx;
			got_rgb[{pix_y, pix_x}] <= {pix_r, pix_g, pix_b};
		end

	string cases_path, name, dir;
	int    fd, rfd, sx, sy, fl, e_idx, e_rgb, ncases, total, clocks, worst, worst_y;

	initial begin
		void'($value$plusargs("LAT=%d", lat));
		if (!$value$plusargs("CASES=%s", cases_path)) cases_path = "debug/video_tb/cases.txt";
		fd = $fopen(cases_path, "r");
		if (fd == 0) $fatal(1, "cannot open %s (run scripts/video_ref.py)", cases_path);
		$readmemh("debug/video_tb/scroll0.hex", g_s0);
		$readmemh("debug/video_tb/scroll1.hex", g_s1);
		$readmemh("debug/video_tb/scroll2.hex", g_s2);
		$readmemh("debug/video_tb/road0.hex", g_road);
		$readmemh("debug/video_tb/sprites.hex", g_spr);
		for (int c = 0; c < 6; c++) lfsr[c] = 32'h1357_9bdf + c * 32'h0101_0101;
		frame_go = 0; line_go = 0; vpos = 0; pending = '0;
		repeat (4) @(posedge clk);
		reset = 0;
		total = 0; ncases = 0;
		while ($fscanf(fd, "%s", name) == 1) begin
			dir = {"debug/video_tb/", name, "/"};
			$readmemh({dir, "vram0.hex"}, vram[0]);
			$readmemh({dir, "vram1.hex"}, vram[1]);
			$readmemh({dir, "vram2.hex"}, vram[2]);
			$readmemh({dir, "road0.hex"}, rlist[0]);
			$readmemh({dir, "road1.hex"}, rlist[1]);
			$readmemh({dir, "sprites.hex"}, slist);
			$readmemh({dir, "palette.hex"}, pal);
			$readmemh({dir, "expect_idx.hex"}, exp_idx);
			$readmemh({dir, "expect_rgb.hex"}, exp_rgb);
			rfd = $fopen({dir, "regs.txt"}, "r");
			for (int n = 0; n < 3; n++) begin
				void'($fscanf(rfd, "%h %h %h", sx, sy, fl));
				scroll_x[n] = sx; scroll_y[n] = sy; scroll_ctrl[n] = fl;
			end
			$fclose(rfd);

			@(negedge clk); frame_go = 1;
			@(negedge clk); frame_go = 0;
			while (busy) @(negedge clk);
			worst = 0; worst_y = 0;
			for (int y = 0; y <= 256; y++) begin
				@(negedge clk); vpos = 8'(y); line_go = 1;
				@(negedge clk); line_go = 0;
				clocks = 1;
				while (busy) begin @(negedge clk); clocks++; end
				if (y < 256 && clocks > worst) begin worst = clocks; worst_y = y; end
			end
			if (overrun) $fatal(1, "overrun");

			e_idx = 0; e_rgb = 0;
			for (int y = 16; y < 240; y++)
				for (int x = 0; x < 256; x++) begin
					if ({1'b0, got_idx[y*256 + x]} !== exp_idx[(y-16)*256 + x]) begin
						if (e_idx < 8)
							$display("  %s y=%0d x=%0d: idx %h expected %h", name, y, x,
								got_idx[y*256 + x], exp_idx[(y-16)*256 + x]);
						e_idx++;
					end
					if (got_rgb[y*256 + x] !== exp_rgb[(y-16)*256 + x]) e_rgb++;
				end
			$display("%-20s idx mismatches %0d, rgb mismatches %0d (of 57,344); worst line %0d clk (y=%0d)",
				name, e_idx, e_rgb, worst, worst_y);
			total += e_idx + e_rgb;
			ncases++;
		end
		$fclose(fd);
		if (ncases == 0) $fatal(1, "no cases");
		if (total == 0) $display("PASS: %0d frames, rows 16..239", ncases);
		else            $display("FAIL: %0d mismatches", total);
		$finish;
	end

endmodule
