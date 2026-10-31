// jaleco_zoomspr_line against scripts/sprite_acc.py, every case in
// debug/sprite_tb/cases.txt. Per case: one frame precompute (y0 = 0), then
// lines 0..255 in order. The bench applies the line-buffer ops to three group
// buffers and compares every pixel of every group on every line. It also
// reports the worst clocks per line, precompute included in none of them.
//
// Each of the four gfx ports answers its request after a pseudo-random 2..24
// clocks, or after exactly +LAT=n clocks.

`timescale 1ns/1ps

module tb_sprite #(
	parameter int LINE_CLK = 0    // -GLINE_CLK=3072: the cutoff the video uses
);

	localparam logic [25:0] GFX_BASE = 26'h0400000;
	localparam logic [23:0] GRP      = {3'd0, 3'd0, 3'd0, 3'd0, 3'd0, 3'd1, 3'd2, 3'd2};  // pri 7..0

	logic clk = 0, reset = 1;
	always #10.4 clk = ~clk;

	logic         frame_start, start, busy;
	logic [7:0]   vpos;
	logic [15:0]  code_mask;
	logic [7:0]   list_addr;
	logic [127:0] list_q;
	logic [3:0]   gfx_req, gfx_valid;
	logic [25:0]  gfx_addr [4];
	logic [63:0]  gfx_rdata [4];
	logic         lb_we, lb_shadow;
	logic [2:0]   lb_group;
	logic [7:0]   lb_x;
	logic [10:0]  lb_d;

	jaleco_zoomspr_line #(.LINE_CLK(LINE_CLK)) dut (
		.clk, .reset, .frame_start, .y0(8'd0), .start, .vpos, .busy, .cut(),
		.bigrun(1'b0), .grp_of_pri(GRP), .gfx_base(GFX_BASE), .code_mask,
		.list_addr, .list_q,
		.gfx_req, .gfx_addr, .gfx_valid, .gfx_rdata,
		.lb_we, .lb_shadow, .lb_group, .lb_x, .lb_d
	);

	logic [15:0] list_w [0:2047];
	logic [63:0] gfx    [0:524287];
	logic [15:0] expect_px [0:196607];

	always_ff @(posedge clk)
		for (int k = 0; k < 8; k++) list_q[16*k +: 16] <= list_w[{list_addr, 3'(k)}];

	int unsigned lfsr [4] = '{32'h0bad_cafe, 32'h1234_5678, 32'h0dea_dbee, 32'h7777_1111};
	int          wait_n [4];
	logic [3:0]  pending;
	logic [25:0] p_addr [4];
	int          fetches;
	int          lat = -1;
	always_ff @(posedge clk) begin
		for (int k = 0; k < 4; k++) begin
			gfx_valid[k] <= 1'b0;
			if (gfx_req[k]) begin
				if (pending[k]) $fatal(1, "gfx_req[%0d] while a request is outstanding", k);
				pending[k] <= 1'b1;
				p_addr[k]  <= gfx_addr[k];
				lfsr[k]    <= lfsr[k] * 1103515245 + 12345;
				wait_n[k]  <= (lat >= 0) ? lat : 2 + ((lfsr[k] >> 16) % 23);
			end else if (pending[k]) begin
				if (wait_n[k] == 0) begin
					int unsigned off;
					off = p_addr[k] - GFX_BASE;
					if (p_addr[k][2:0] != 3'b000) $fatal(1, "unaligned granule %h", p_addr[k]);
					if (off >= 4194304) $fatal(1, "granule %h outside the sprite region", p_addr[k]);
					gfx_rdata[k] <= gfx[off >> 3];
					gfx_valid[k] <= 1'b1;
					pending[k]   <= 1'b0;
				end else
					wait_n[k] <= wait_n[k] - 1;
			end
		end
		fetches <= fetches + $countones(gfx_req);
	end

	// three group line buffers: {shadow, opaque, color, pen}
	logic [12:0] buf_px [3][256];
	always_ff @(posedge clk)
		if (lb_we) begin
			if (lb_group > 3'd2) $fatal(1, "group %0d", lb_group);
			if (lb_shadow) buf_px[lb_group][lb_x][12] <= 1'b1;
			else           buf_px[lb_group][lb_x]     <= {2'b01, lb_d};
		end

	string cases_path, name, dir;
	int    fd, mfd, cm, errors, total_errors, ncases, clocks, worst, worst_y, pre_clocks;
	int    total_fetch;

	initial begin
		void'($value$plusargs("LAT=%d", lat));
		if (!$value$plusargs("CASES=%s", cases_path)) cases_path = "debug/sprite_tb/cases.txt";
		fd = $fopen(cases_path, "r");
		if (fd == 0) $fatal(1, "cannot open %s (run scripts/sprite_acc.py --cases)", cases_path);
		mfd = $fopen("debug/sprite_tb/mask.txt", "r");
		void'($fscanf(mfd, "%h", cm));
		$fclose(mfd);
		code_mask = cm;
		$readmemh("debug/sprite_tb/gfx.hex", gfx);
		frame_start = 0; start = 0; vpos = 0; pending = '0; fetches = 0;
		repeat (4) @(posedge clk);
		reset = 0;
		total_errors = 0; ncases = 0;
		while ($fscanf(fd, "%s", name) == 1) begin
			dir = {"debug/sprite_tb/", name, "/"};
			$readmemh({dir, "list.hex"}, list_w);
			$readmemh({dir, "expect.hex"}, expect_px);
			errors = 0; worst = 0; worst_y = 0;
			@(negedge clk); frame_start = 1;
			@(negedge clk); frame_start = 0;
			pre_clocks = 1;
			while (busy) begin @(negedge clk); pre_clocks++; end
			fetches = 0;
			for (int y = 0; y < 256; y++) begin
				for (int g = 0; g < 3; g++)
					for (int x = 0; x < 256; x++) buf_px[g][x] = 13'd0;
				@(negedge clk); vpos = y; start = 1;
				@(negedge clk); start = 0;
				clocks = 1;
				while (busy) begin @(negedge clk); clocks++; end
				if (clocks > worst) begin worst = clocks; worst_y = y; end
				repeat (2) @(negedge clk);
				for (int g = 0; g < 3; g++)
					for (int x = 0; x < 256; x++)
						if ({3'd0, buf_px[g][x]} !== expect_px[(g*256 + y)*256 + x]) begin
							if (errors < 10)
								$display("  %s g=%0d y=%0d x=%0d: got %h expected %h",
									name, g, y, x, buf_px[g][x], expect_px[(g*256 + y)*256 + x]);
							errors++;
						end
			end
			$display("%-20s %0d mismatches; precompute %0d clk; worst line %0d clk (y=%0d); %0d fetches",
				name, errors, pre_clocks, worst, worst_y, fetches);
			total_errors += errors;
			ncases++;
		end
		$fclose(fd);
		if (ncases == 0) $fatal(1, "no cases in %s", cases_path);
		if (total_errors == 0) $display("PASS: %0d cases, 256 lines x 3 groups each", ncases);
		else                   $display("FAIL: %0d mismatches", total_errors);
		$finish;
	end

endmodule
