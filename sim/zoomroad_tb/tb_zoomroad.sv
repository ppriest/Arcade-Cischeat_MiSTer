// jaleco_zoomroad_line against scripts/zoomroad_ref.py, every case in
// debug/zoomroad_tb/cases.txt. Each case renders all 256 lines; every pixel must
// be written exactly once per line and equal the model's, and the line priority
// must match.
//
// The gfx port answers each request after a pseudo-random 2..24 clocks.
//
//   +CASES=path    case list (default debug/zoomroad_tb/cases.txt)

`timescale 1ns/1ps

module tb_zoomroad;

	localparam logic [25:0] GFX_BASE = 26'h0a00000;

	logic clk = 0, reset = 1;
	always #10.4 clk = ~clk;

	logic        start;
	logic [7:0]  vpos;
	logic        busy;
	logic [15:0] code_mask;
	logic [9:0]  list_addr;
	logic [15:0] list_q;
	logic        gfx_req, gfx_valid;
	logic [25:0] gfx_addr;
	logic [63:0] gfx_rdata;
	logic        lb_we;
	logic [7:0]  lb_x;
	logic [10:0] lb_d;
	logic [2:0]  lb_pri;

	jaleco_zoomroad_line dut (
		.clk, .reset, .start, .vpos, .busy,
		.gfx_base(GFX_BASE), .code_mask,
		.list_addr, .list_q,
		.gfx_req, .gfx_addr, .gfx_valid, .gfx_rdata,
		.lb_we, .lb_x, .lb_d, .lb_pri
	);

	logic [15:0] list [0:1023];
	logic [7:0]  gfx  [0:2097151];
	logic [15:0] expect_px [0:65535];

	always_ff @(posedge clk) list_q <= list[list_addr];

	int unsigned lfsr = 32'h8765_4321;
	int          wait_n;
	logic        pending;
	logic [25:0] p_addr;
	always_ff @(posedge clk) begin
		gfx_valid <= 1'b0;
		if (gfx_req) begin
			if (pending) $fatal(1, "gfx_req while a request is outstanding");
			pending <= 1'b1;
			p_addr  <= gfx_addr;
			lfsr    <= lfsr * 1103515245 + 12345;
			wait_n  <= 2 + ((lfsr >> 16) % 23);
		end else if (pending) begin
			if (wait_n == 0) begin
				int unsigned off;
				off = p_addr - GFX_BASE;
				if (p_addr[2:0] != 3'b000) $fatal(1, "unaligned granule %h", p_addr);
				if (off >= 2097152) $fatal(1, "granule %h outside the road region", p_addr);
				for (int k = 0; k < 8; k++)
					gfx_rdata[8*k +: 8] <= gfx[off + k];
				gfx_valid <= 1'b1;
				pending   <= 1'b0;
			end else
				wait_n <= wait_n - 1;
		end
	end

	logic [10:0] line_px [0:255];
	logic [8:0] line_n  [0:255];
	always_ff @(posedge clk)
		if (lb_we) begin
			line_px[lb_x] <= lb_d;
			line_n[lb_x]  <= line_n[lb_x] + 9'd1;
		end

	string cases_path, name, dir;
	int    fd, mfd, cm, errors, total_errors, ncases;
	logic [15:0] got;

	initial begin
		if (!$value$plusargs("CASES=%s", cases_path)) cases_path = "debug/zoomroad_tb/cases.txt";
		fd = $fopen(cases_path, "r");
		if (fd == 0) $fatal(1, "cannot open %s (run scripts/zoomroad_ref.py)", cases_path);
		start = 0; vpos = 0; pending = 0;
		repeat (4) @(posedge clk);
		reset = 0;
		total_errors = 0; ncases = 0;
		while ($fscanf(fd, "%s", name) == 1) begin
			dir = {"debug/zoomroad_tb/", name, "/"};
			mfd = $fopen({dir, "mask.txt"}, "r");
			void'($fscanf(mfd, "%h", cm));
			$fclose(mfd);
			code_mask = cm;
			$readmemh({dir, "gfx.hex"}, gfx);
			$readmemh({dir, "list.hex"}, list);
			$readmemh({dir, "expect.hex"}, expect_px);
			errors = 0;
			for (int y = 0; y < 256; y++) begin
				for (int x = 0; x < 256; x++) line_n[x] = 0;
				@(negedge clk); vpos = y; start = 1;
				@(negedge clk); start = 0;
				@(negedge clk);
				while (busy) @(negedge clk);
				repeat (2) @(negedge clk);
				for (int x = 0; x < 256; x++) begin
					got = {2'd0, lb_pri, line_px[x]};
					if (line_n[x] != 1 || got !== expect_px[y*256 + x]) begin
						if (errors < 10)
							$display("  %s y=%0d x=%0d: got %h (%0d writes) expected %h",
								name, y, x, got, line_n[x], expect_px[y*256 + x]);
						errors++;
					end
				end
			end
			$display("%-24s %0d mismatches", name, errors);
			total_errors += errors;
			ncases++;
		end
		$fclose(fd);
		if (ncases == 0) $fatal(1, "no cases in %s", cases_path);
		if (total_errors == 0) $display("PASS: %0d cases, 256 lines each", ncases);
		else                   $display("FAIL: %0d mismatches", total_errors);
		$finish;
	end

endmodule
