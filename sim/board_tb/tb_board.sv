// SPDX-License-Identifier: GPL-3.0-or-later
//
// cischeat_board from reset, on cischeat_sdram and the command-decoding chip
// model holding the loader image (scripts/board_image.py), or with +IDEAL=1 on
// a behavioural memory. Logs the main CPU's accesses in the boot
// trace format for scripts/compare_boot_trace.py, and reports what the other
// CPUs and the video did.
//
//     python scripts/board_image.py
//     scripts/run_sim.sh board_tb +N=1350000
//     python scripts/compare_boot_trace.py compare cischeat --rtl debug/cischeat-boot/cischeat_board.trace
//
// +IDEAL=1: every external port and gfx client is served LAT clocks after its
// request, independently, which tests the board and not the memory system.
//
// Inputs are idle with MAME's default DIPs (scripts/mame/ports.lua reads them).
//
// PLUSARGS
//   +IMAGE=path   SDRAM image (default debug/board/sdram.hex)
//   +TRACE=path   main CPU trace (default debug/cischeat-boot/cischeat_board.trace)
//   +N=n          main CPU accesses to log, then stop (default 100000)
//   +IDEAL=1      the behavioural memory instead of the SDRAM stack
//   +LAT=n        its latency in clk (default 8)
//   +STATE=1      the savestate test instead of the trace: save A at the first
//                 row 1, save B one frame later, load A, save C one frame later.
//                 C must equal B section by section, and the main CPU's trace
//                 from A to B must equal the one from the load to C. Sections
//                 that differ are listed; the YM2151 is not in the state
//                 (Tier 1), so the sound CPU may diverge. With +LOADSTATE, A is
//                 that file, loaded, instead of a save: a boot-time A leaves
//                 most RAM unchanged from A to B and hides a load that never
//                 writes it.
//   +LOADSTATE=path  load this state (scripts/state.py's .hex) at the first
//                 row 1, then write +FRAMES=n displayed frames (default 2) to
//                 debug/state/frame<k>.hex, one RGB pixel per line, 256 x 224,
//                 for scripts/compare_state_frames.py.
//   +NOPIX=1      with +DUMPFRAMES, keep only the last frame (frame_last.hex)
//   +DUMPFRAMES=n write the first n displayed frames from reset, the same way, to
//                 debug/board/frame<k>.hex, for scripts/compare_reset_frames.py.

`timescale 1ns / 1ps

module tb_board;

	// clk_mem is 2 x clk with edges aligned: the half periods are exact multiples
	// of the 1 ps precision, so the two never drift
	logic clk = 1'b0, clk_mem = 1'b0;
	always #10.416 clk = ~clk;
	always #5.208 clk_mem = ~clk_mem;
	logic reset = 1'b1;

	string image_path = "debug/board/sdram.hex";
	string trace_path = "debug/cischeat-boot/cischeat_board.trace";
	int    n_max = 100000;
	int    lat   = 8;
	int    ideal = 0;
	int    state_test = 0;
	string load_path = "";
	int    frames_out = 2;
	int    dump_frames = 0;
	logic  loaded = 1'b0;                // frames are written (and counted) while set
	string frame_dir = "debug/state";
	int    nopix = 0;
	int    board_sel = 1;                // +BOARD: 0 Big Run, 1 Cisco Heat

	initial begin
		void'($value$plusargs("IMAGE=%s", image_path));
		void'($value$plusargs("TRACE=%s", trace_path));
		void'($value$plusargs("N=%d", n_max));
		void'($value$plusargs("LAT=%d", lat));
		void'($value$plusargs("IDEAL=%d", ideal));
		void'($value$plusargs("STATE=%d", state_test));
		void'($value$plusargs("LOADSTATE=%s", load_path));
		void'($value$plusargs("FRAMES=%d", frames_out));
		void'($value$plusargs("NOPIX=%d", nopix));
		void'($value$plusargs("BOARD=%d", board_sel));
		if ($value$plusargs("DUMPFRAMES=%d", dump_frames)) begin
			frames_out = dump_frames;
			frame_dir  = "debug/board";
			n_max      = 1 << 30;
			loaded     = 1'b1;
		end
		void'($value$plusargs("FRAMEDIR=%s", frame_dir));
	end

	localparam int WORDS = 26'h0f00000 / 2;      // through the OKI sample regions
	logic [15:0] sdram [0:WORDS-1];

	logic [4:0]  ext_req, ext_we, ext_ready;
	logic [25:1] ext_addr [5];
	logic [15:0] ext_wdata [5], ext_rdata [5];
	logic [1:0]  ext_be [5];
	logic [8:0]  gfx_req, gfx_valid;
	logic [25:0] gfx_addr [9];
	logic [63:0] gfx_rdata [9];
	logic        ce_pix, hblank, vblank, hsync, vsync, overrun;
	logic [7:0]  r, g, b;
	logic        dbg_stb, dbg_we, dbg_uds, dbg_lds;
	logic [23:1] dbg_addr;
	logic [15:0] dbg_data;

	logic [1:0]  snd_req, snd_valid, s_snd_valid, i_snd_valid;
	logic [25:0] snd_addr [2];
	logic [63:0] snd_rdata, s_snd_rdata, i_snd_rdata;
	logic signed [15:0] audio_l, audio_r;

	logic        ss_save = 1'b0, ss_load = 1'b0, ss_busy, ss_error;
	logic        so_valid, si_valid = 1'b0, si_ready;
	logic [15:0] so_data, si_data;

	// inputs at rest and the .mra's default switches, as Cischeat.sv forms the ports
	// (the F1 GP Star pedal is PORT_REVERSE: released reads 0xff; Wild Pilot's sticks
	// centred, {x 0x80, reversed y 0x7f})
	logic f1_set;
	assign f1_set = board_sel >= 2;

	cischeat_board dut (
		.clk, .reset, .pause(1'b0), .board(3'(board_sel)),
		.pedal(board_sel == 4 ? 16'h807f : f1_set ? 16'h00ff : 16'h0000),
		.in1(f1_set && board_sel != 4 ? 16'hfdff : 16'hffff), .in2(16'hffff), .in3(16'hffff), .in4(board_sel == 3 ? 16'hfff1 : 16'hffff),
		.dsw3(board_sel == 0 ? 16'hfff0 : 16'hffff), .wheel(board_sel == 4 ? 16'h807f : 16'hff7f),
		.ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_be, .ext_ready, .ext_rdata,
		.gfx_req, .gfx_addr, .gfx_valid, .gfx_rdata,
		.snd_req, .snd_addr, .snd_valid, .snd_rdata, .audio_l, .audio_r,
		.ce_pix, .hblank, .vblank, .hsync, .vsync, .r, .g, .b,
		.video_overrun(overrun),
		.ss_save, .ss_load, .ss_busy, .ss_error, .so_valid, .so_data, .so_ready(1'b1),
		.si_valid, .si_data, .si_ready,
		.dbg_stb, .dbg_we, .dbg_addr, .dbg_data, .dbg_uds, .dbg_lds
	);

	// ---- the SDRAM stack and the chip --------------------------------------
	logic [4:0]  s_ext_ready, i_ext_ready;
	logic [15:0] s_ext_rdata [5], i_ext_rdata [5];
	logic [8:0]  s_gfx_valid, i_gfx_valid;
	logic [63:0] s_gfx_rdata [9], i_gfx_rdata [9];
	logic        init = 1'b1, dl_busy;
	wire  [15:0] sd_dq;
	logic [12:0] sd_a;
	logic [1:0]  sd_ba;
	logic        sd_ncs, sd_nwe, sd_nras, sd_ncas, sd_dqml, sd_dqmh, sd_cke;

	cischeat_sdram u_mem (
		.clk, .clk_mem, .reset, .mem_reset(reset), .init,
		.ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_be, .ext_ready(s_ext_ready), .ext_rdata(s_ext_rdata),
		.gfx_req, .gfx_addr, .gfx_valid(s_gfx_valid), .gfx_rdata(s_gfx_rdata),
		.snd_req, .snd_addr, .snd_valid(s_snd_valid), .snd_rdata(s_snd_rdata),
		.dl_req(1'b0), .dl_addr('0), .dl_data('0), .dl_we16(1'b0), .dl_busy,
		.SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh), .SDRAM_BA(sd_ba),
		.SDRAM_nCS(sd_ncs), .SDRAM_nWE(sd_nwe), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_CKE(sd_cke)
	);

	sdram_chip_model_wide u_chip (
		.clk(clk_mem), .SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_nCS(sd_ncs),
		.SDRAM_nWE(sd_nwe), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas)
	);

	always_comb begin
		ext_ready = ideal ? i_ext_ready : s_ext_ready;
		gfx_valid = ideal ? i_gfx_valid : s_gfx_valid;
		snd_valid = ideal ? i_snd_valid : s_snd_valid;
		snd_rdata = ideal ? i_snd_rdata : s_snd_rdata;
		for (int p = 0; p < 5; p++) ext_rdata[p] = ideal ? i_ext_rdata[p] : s_ext_rdata[p];
		for (int c = 0; c < 9; c++) gfx_rdata[c] = ideal ? i_gfx_rdata[c] : s_gfx_rdata[c];
	end

	// every word handed to a CPU against the image, ROM regions only (below sound RAM)
	longint ext_bad = 0;
	always_ff @(posedge clk) if (!ideal)
		for (int p = 0; p < 5; p++)
			if (s_ext_ready[p] && !ext_we[p] && {ext_addr[p], 1'b0} < 26'h03e0000 &&
			    s_ext_rdata[p] !== sdram[ext_addr[p]]) begin
				if (ext_bad < 5) $display("BAD port %0d word %06h: %04h, image %04h", p, {ext_addr[p], 1'b0},
				                          s_ext_rdata[p], sdram[ext_addr[p]]);
				ext_bad++;
			end
	longint gfx_bad = 0;
	always_ff @(posedge clk) if (!ideal)
		for (int c = 0; c < 9; c++)
			if (s_gfx_valid[c])
				for (int k = 0; k < 4; k++)
					if (s_gfx_rdata[c][16 * k +: 16] !== sdram[{u_mem.addr[5 + c][25:3], 2'(k)}]) begin
						if (gfx_bad < 5) $display("BAD gfx %0d granule %07h word %0d: %04h, image %04h", c,
						                          u_mem.addr[5 + c], k, s_gfx_rdata[c][16 * k +: 16],
						                          sdram[{u_mem.addr[5 + c][25:3], 2'(k)}]);
						gfx_bad++;
					end

	// ---- external ports: a request is its rising edge; ready is one clock ----
	int   ext_wait [5];
	logic ext_busy [5];
	logic [4:0] ext_req_d;
	longint ext_n [5], ext_w [5];

	always_ff @(posedge clk) begin
		ext_req_d <= reset ? 5'h0 : ext_req;
		for (int p = 0; p < 5; p++) begin
			i_ext_ready[p] <= 1'b0;
			if (reset) begin
				ext_busy[p] <= 1'b0;
			end else if (ext_req[p] && !ext_req_d[p]) begin
				ext_busy[p] <= 1'b1;
				ext_wait[p] <= 1;
			end else if (ext_busy[p]) begin
				if (ext_wait[p] >= lat) begin
					ext_busy[p]  <= 1'b0;
					i_ext_ready[p] <= 1'b1;
					ext_n[p]++;
					if (ext_we[p]) begin
						ext_w[p]++;
						if (ext_be[p][1]) sdram[ext_addr[p]][15:8] <= ext_wdata[p][15:8];
						if (ext_be[p][0]) sdram[ext_addr[p]][7:0]  <= ext_wdata[p][7:0];
					end else
						i_ext_rdata[p] <= sdram[ext_addr[p]];
				end else
					ext_wait[p] <= ext_wait[p] + 1;
			end
		end
	end

	// ---- gfx clients: a one-clock request, a one-clock valid ----
	int     gfx_wait [9];
	logic   gfx_busy [9];
	logic [25:0] gfx_a [9];
	longint gfx_n = 0;

	always_ff @(posedge clk)
		for (int c = 0; c < 9; c++) begin
			i_gfx_valid[c] <= 1'b0;
			if (reset) gfx_busy[c] <= 1'b0;
			else if (gfx_req[c]) begin
				gfx_busy[c] <= 1'b1;
				gfx_wait[c] <= 1;
				gfx_a[c]    <= gfx_addr[c];
			end else if (gfx_busy[c]) begin
				if (gfx_wait[c] >= lat) begin
					gfx_busy[c]  <= 1'b0;
					i_gfx_valid[c] <= 1'b1;
					gfx_n++;
					for (int k = 0; k < 4; k++)
						i_gfx_rdata[c][16 * k +: 16] <= sdram[{gfx_a[c][25:3], 2'(k)}];
				end else
					gfx_wait[c] <= gfx_wait[c] + 1;
			end
		end

	// ---- sample clients (ideal memory): held req, answered lat clocks after its rise ----
	int   snd_wait [2];
	logic [1:0] snd_req_d = 2'b00;
	always_ff @(posedge clk) begin
		i_snd_valid <= 2'b00;
		snd_req_d   <= snd_req;
		for (int c = 0; c < 2; c++)
			if (snd_req[c] && !snd_req_d[c]) snd_wait[c] <= 1;
			else if (snd_wait[c] > 0) begin
				if (snd_wait[c] >= lat) begin
					snd_wait[c]    <= 0;
					i_snd_valid[c] <= 1'b1;
					for (int k = 0; k < 4; k++)
						i_snd_rdata[16 * k +: 16] <= sdram[{snd_addr[c][25:3], 2'(k)}];
				end else
					snd_wait[c] <= snd_wait[c] + 1;
			end
	end

	// audio peaks per frame: the mix, the YM2151, each M6295
	int a_pk = 0, y_pk = 0, o_pk [2] = '{0, 0}, o_wr = 0;
	function automatic int iabs(input int v); return v < 0 ? -v : v; endfunction
	always @(posedge clk) if (loaded) begin
		if (iabs(int'(audio_l)) > a_pk) a_pk = iabs(int'(audio_l));
		if (iabs(int'(dut.ym_l)) > y_pk) y_pk = iabs(int'(dut.ym_l));
		for (int c = 0; c < 2; c++) if (iabs(int'(dut.oki_snd[c])) > o_pk[c]) o_pk[c] = iabs(int'(dut.oki_snd[c]));
		if (|dut.u_oki.wr) o_wr++;
	end

	// +AUDIO=path: the mix at 48 kHz (one sample in 1,000 clk), "L R" per line
	int a_fd = 0, a_div = 0;
	string a_path;
	initial if ($value$plusargs("AUDIO=%s", a_path)) a_fd = $fopen(a_path, "w");
	always @(posedge clk) if (loaded && a_fd != 0) begin
		if (a_div == 999) begin
			a_div = 0;
			$fdisplay(a_fd, "%0d %0d", audio_l, audio_r);
		end else
			a_div++;
	end

	// ---- savestate test ----
	localparam int SN = 1 << 18;
	logic [15:0] st_a [SN], st_b [SN], st_c [SN];
	int          na_s = 0, nb_s = 0, nc_s = 0;
	int          which = 0;              // 1 A, 2 B, 3 C
	logic [40:0] tr1 [1 << 20], tr2 [1 << 20];
	int          n1 = 0, n2 = 0, trace_to = 0;   // 1: A to B, 2: load to C

	always_ff @(posedge clk) if (so_valid) begin
		case (which)
			1: begin st_a[na_s] <= so_data; na_s <= na_s + 1; end
			2: begin st_b[nb_s] <= so_data; nb_s <= nb_s + 1; end
			3: begin st_c[nc_s] <= so_data; nc_s <= nc_s + 1; end
			default: ;
		endcase
	end

	always_ff @(posedge clk)
		if (dbg_stb && trace_to != 0 && (dbg_we || !((dbg_addr < 23'h040000) ||
		    (dbg_addr >= 23'h080000 && dbg_addr < 23'h0c0000)))) begin
			if (trace_to == 1) begin tr1[n1] <= {dbg_we, dbg_addr, 1'b0, dbg_data}; n1 <= n1 + 1; end
			else               begin tr2[n2] <= {dbg_we, dbg_addr, 1'b0, dbg_data}; n2 <= n2 + 1; end
		end

	// a CPU that does not park stalls the engine in E_PARK: say which
	int park_wait = 0;
	always_ff @(posedge clk)
		if (dut.ss_park) begin                 // high while the engine is in E_PARK
			park_wait <= park_wait + 1;
			if (park_wait == 200000)
				$display("STALL in E_PARK: parked %b, in reset %b%b%b%b, main PC area %06h",
				         dut.c_parked, dut.c_reset[3], dut.c_reset[2], dut.c_reset[1], dut.c_reset[0],
				         {dut.c_addr[0], 1'b0});
		end else
			park_wait <= 0;

	task automatic do_save(input int w);
		@(negedge clk); which = w; ss_save = 1'b1;
		@(negedge clk); ss_save = 1'b0;
		wait (ss_busy);
		wait (!ss_busy);
		@(negedge clk);
	endtask

	task automatic do_load();
		int i;
		@(negedge clk); ss_load = 1'b1;
		@(negedge clk); ss_load = 1'b0;
		i = 0;
		while (i < na_s) begin
			logic moved;
			si_valid = 1'b1; si_data = st_a[i];
			#1 moved = si_ready;              // the engine's ready for this clock
			@(posedge clk);
			if (moved) i++;
			@(negedge clk);
		end
		si_valid = 1'b0;
		wait (!ss_busy);
		@(negedge clk);
	endtask

	// section boundaries, words: header 8, then the board's SEC_LEN
	localparam int NSEC = 18;
	localparam int LEN [NSEC] = '{38, 38, 38, 38, 25, 32768, 16384, 16384, 16384, 16384, 16384,
	                              16384, 1024, 1024, 1024, 8192, 8192, 32768};
	localparam string NAME [NSEC] = '{"cpu main", "cpu road1", "cpu road2", "cpu sound", "board regs",
	                                  "work RAM", "shared road1", "shared road2", "scroll0", "scroll1",
	                                  "scroll2", "palette", "link", "road list 0", "road list 1",
	                                  "road1 local", "road2 local", "sound RAM"};

	task automatic write_state(input string path, input int which_s, input int n);
		int fd;
		fd = $fopen(path, "w");
		for (int i = 0; i < n; i++) begin
			logic [15:0] w;
			w = which_s == 1 ? st_a[i] : which_s == 2 ? st_b[i] : st_c[i];
			$fdisplay(fd, "%04h", w);
		end
		$fclose(fd);
	endtask

	// ---- load a state, then write the frames shown after it ----
	int  fr_fd = 0, fr_k = 0;
	logic vbl_d = 1'b1;

	// per-frame counts, to place a blank frame: engine output, palette index, gfx data
	int n_pix = 0, n_idx = 0, n_rgb = 0, n_gfx = 0, n_gfx_nz = 0, n_lgo = 0, n_spr = 0;
	int n_cyc = 0, n_stall = 0;
	int stall_at [256];                    // held clk by main address bits 23:16, over the frame            // main CPU clocks run, and clk held waiting for memory
	longint fg_t = -1, pre_max = 0;      // sprite precompute, frame_go to idle
	always @(posedge clk) if (loaded) begin
		if (dut.pix_valid) begin
			n_pix++;
			if (dut.u_video.pix_idx != 0) n_idx++;
			if ({dut.pix_r, dut.pix_g, dut.pix_b} != 0) n_rgb++;
		end
		for (int c = 0; c < 9; c++) if (gfx_valid[c]) begin
			n_gfx++;
			if (gfx_rdata[c] != 0) n_gfx_nz++;
		end
		n_spr += $countones(gfx_valid[8:5]);
		if (dut.line_go) n_lgo++;
		if (dut.cpu[0].u.u_cpu.cycle_tick) n_cyc++;
		if (dut.cpu[0].u.u_cpu.stall_tick) begin
			n_stall++;
			stall_at[dut.c_addr[0][23:16]]++;
		end
	end

	// SDRAM transactions a line would cost (granules): gfx requests, cache fills
	// (8 words = 2 granules), and every other external access as one. Lines are
	// hsync to hsync; d_fill counts each CPU port's SDRAM accesses in the frame.
	int d_line = 0, d_vid = 0, d_cpu = 0, d_max = 0, d_vmax = 0, d_cmax = 0, d_n = 0, d_over [3];
	longint d_sum = 0;
	int d_fill [5];
	int d_k [3], d_kmax [3];           // per line: tilemaps, roads, sprites; worst in the frame
	logic hs_d = 1'b0;
	logic [4:0] dreq_d = 5'h0;
	always @(posedge clk) if (loaded) begin
		int v, c;
		v = 0; c = 0;
		for (int k = 0; k < 9; k++) if (gfx_req[k]) begin
			v++;
			d_k[k < 3 ? 0 : k < 5 ? 1 : 2]++;
		end
		// CPU accesses the SDRAM serves (after each port's granule and cache)
		for (int p = 0; p < 5; p++) if (u_mem.req[p] && u_mem.valid[p]) begin
			c++;
			d_fill[p] = d_fill[p] + 1;
		end
		dreq_d <= ext_req;
		d_vid = d_vid + v; d_cpu = d_cpu + c;
		hs_d <= hsync;
		if (hsync && !hs_d) begin
			d_line = d_vid + d_cpu;
			if (d_line > d_max) d_max = d_line;
			if (d_vid > d_vmax) d_vmax = d_vid;
			if (d_cpu > d_cmax) d_cmax = d_cpu;
			if (d_line > 192) d_over[0]++;
			if (d_line > 256) d_over[1]++;
			if (d_line > 279) d_over[2]++;
			d_sum += d_line; d_n++;
			for (int i = 0; i < 3; i++) begin
				if (d_k[i] > d_kmax[i]) d_kmax[i] = d_k[i];
				d_k[i] = 0;
			end
			d_vid = 0; d_cpu = 0;
		end
	end
	initial begin for (int p = 0; p < 5; p++) d_fill[p] = 0; for (int i = 0; i < 3; i++) begin d_over[i] = 0; d_k[i] = 0; d_kmax[i] = 0; end end

	// sprite engine: clocks from line_go to idle, worst per frame and over the run;
	// lines the cutoff shortened
	int sl_t = -1, sl_max = 0, sl_y = 0, sl_all = 0, sl_cut = 0, sl_cut_all = 0;
	logic sl_busy_d = 1'b0;
	// where the worst line's clocks went: pixels drawn, L_PIX waiting on a granule, everything
	// else (record pass and setup), and the records drawn
	int sl_pix = 0, sl_wait = 0, sl_rec = 0, sw_pix = 0, sw_wait = 0, sw_rec = 0, sl_gr = 0, sw_gr = 0;
	always @(posedge clk) if (loaded) begin
		sl_busy_d <= dut.u_video.eng_busy[5];
		if (dut.line_go) begin sl_t = 0; sl_pix = 0; sl_wait = 0; sl_rec = 0; sl_gr = 0; end
		else if (sl_t >= 0) begin
			sl_t++;
			sl_gr += $countones(dut.u_video.spr.gfx_req);
			if (dut.u_video.spr.st == 4'd10 && dut.u_video.spr.mul_n == 0) sl_rec++;
			if (dut.u_video.spr.st == 4'd11) begin
				if (dut.u_video.spr.have_gran
				    && !(dut.u_video.spr.px[8] || dut.u_video.spr.s >= dut.u_video.spr.wsrc || dut.u_video.spr.late))
					sl_pix++;
				else
					sl_wait++;
			end
		end
		if (sl_busy_d && !dut.u_video.eng_busy[5] && sl_t >= 0 && !dut.u_video.spr.st_frame) begin
			if (sl_t > sl_max) begin
				sl_max = sl_t; sl_y = dut.u_video.spr.vpos_l;
				sw_pix = sl_pix; sw_wait = sl_wait; sw_rec = sl_rec; sw_gr = sl_gr;
			end
			if (sl_t > sl_all) sl_all = sl_t;
			if (dut.u_video.spr.cut) begin sl_cut++; sl_cut_all++; end
			sl_t = -1;
		end
	end

	always @(posedge clk) if (loaded && ce_pix) begin
		vbl_d <= vblank;
		if (vbl_d && !vblank) begin
			fr_fd = nopix ? $fopen($sformatf("%s/frame_last.hex", frame_dir), "w")
			              : $fopen($sformatf("%s/frame%0d.hex", frame_dir, fr_k), "w");
		end
		if (!vblank && !hblank && fr_fd != 0) $fdisplay(fr_fd, "%02h%02h%02h", r, g, b);
		if (!vbl_d && vblank && fr_fd != 0) begin
			$fclose(fr_fd);
			fr_fd = 0;
			$display("frame %0d written: line_go %0d, pixels %0d, index != 0 %0d, rgb != 0 %0d, gfx words %0d (%0d nonzero, %0d sprite), sprite precompute at most %0d clk; scroll ctrl %h %h %h; main CPU %0d clocks, %0d clk held; main PC %06h",
			         fr_k, n_lgo, n_pix, n_idx, n_rgb, n_gfx, n_gfx_nz, n_spr, pre_max, dut.sc[0], dut.sc[1], dut.sc[2], n_cyc, n_stall,
			         {dut.c_addr[0], 1'b0});
			$display("  sdram demand per line: max %0d (video %0d, cpu %0d), mean %0d; lines over 192 %0d, 256 %0d, 279 %0d",
			         d_max, d_vmax, d_cmax, d_n ? int'(d_sum / d_n) : 0, d_over[0], d_over[1], d_over[2]);
			$display("  cpu sdram accesses this frame: main %0d, road1 %0d, road2 %0d, sound %0d, io %0d",
			         d_fill[0], d_fill[1], d_fill[2], d_fill[3], d_fill[4]);
			$display("  video accesses per line at most: tilemaps %0d, roads %0d, sprites %0d", d_kmax[0], d_kmax[1], d_kmax[2]);
			for (int i = 0; i < 3; i++) d_kmax[i] = 0;
			for (int p = 0; p < 5; p++) d_fill[p] = 0;
			if (!ideal) $display("  sdram: %0d wrong CPU words, %0d wrong gfx words so far", ext_bad, gfx_bad);
			$display("  audio peak %0d (YM2151 %0d, M6295 %0d / %0d, %0d M6295 writes)", a_pk, y_pk, o_pk[0], o_pk[1], o_wr);
			a_pk = 0; y_pk = 0; o_pk[0] = 0; o_pk[1] = 0; o_wr = 0;
			$display("  sprite line at most %0d clk (y=%0d: %0d records drawn, %0d granules, %0d pixel clk, %0d waiting in L_PIX, %0d other), %0d lines cut; run: at most %0d clk, %0d cut",
			         sl_max, sl_y, sw_rec, sw_gr, sw_pix, sw_wait, sl_max - sw_pix - sw_wait, sl_cut, sl_all, sl_cut_all);
			sl_max = 0; sl_cut = 0;
			d_max = 0; d_vmax = 0; d_cmax = 0; d_sum = 0; d_n = 0; d_over[0] = 0; d_over[1] = 0; d_over[2] = 0;
			for (int a = 0; a < 256; a++) begin
				if (stall_at[a] > 20000) $display("  main held %0d clk at %02h0000", stall_at[a], a);
				stall_at[a] = 0;
			end
			n_lgo = 0; n_pix = 0; n_idx = 0; n_rgb = 0; n_gfx = 0; n_gfx_nz = 0; n_spr = 0; n_cyc = 0; n_stall = 0;
			fr_k++;
			if (fr_k >= frames_out) $finish;
		end
	end

	initial if (load_path != "" && state_test == 0) begin
		$readmemh(load_path, st_a);
		na_s = 8 + 152 + 25 + 32768 + 6 * 16384 + 3 * 1024 + 2 * 8192 + 32768;
		if (st_a[0] !== 16'h4348) $fatal(1, "%s did not load", load_path);
		wait (!reset);
		wait (dut.sys_reset == 1'b0);
		do_load();
		$display("loaded %s: frame %0d%s", load_path, {st_a[4], st_a[5]}, ss_error ? " -- HEADER ERROR" : "");
		loaded = 1'b1;
	end

	initial if (state_test != 0) begin
		int base, diff, first, bad;
		wait (!reset);
		wait (dut.sys_reset == 1'b0);
		if (load_path != "") begin
			$readmemh(load_path, st_a);
			na_s = 8 + 152 + 25 + 32768 + 6 * 16384 + 3 * 1024 + 2 * 8192 + 32768;
			do_load();
			$display("A loaded from %s%s", load_path, ss_error ? " -- HEADER ERROR" : "");
		end else
			do_save(1);
		$display("A: %0d words, frame %0d, main PC %06h SR %04h", na_s,
		         {st_a[4], st_a[5]}, {st_a[8 + 34], st_a[8 + 35]}, st_a[8 + 37]);
		trace_to = 1;
		do_save(2);
		trace_to = 0;
		$display("B saved: %0d words, frame %0d; %0d main accesses logged A..B", nb_s, {st_b[4], st_b[5]}, n1);
		do_load();
		$display("A loaded%s", ss_error ? " -- HEADER ERROR" : "");
		trace_to = 2;
		do_save(3);
		trace_to = 0;
		$display("C saved: %0d words, frame %0d; %0d main accesses logged load..C", nc_s, {st_c[4], st_c[5]}, n2);

		write_state("debug/state/A.hex", 1, na_s);
		write_state("debug/state/B.hex", 2, nb_s);
		write_state("debug/state/C.hex", 3, nc_s);

		bad = 0;
		if (nb_s != nc_s) begin $display("FAIL B has %0d words, C %0d", nb_s, nc_s); bad++; end
		for (int i = 0; i < 8; i++)
			if (st_b[i] != st_c[i]) begin $display("FAIL header word %0d: B %h C %h", i, st_b[i], st_c[i]); bad++; end
		base = 8;
		for (int sct = 0; sct < NSEC; sct++) begin
			diff = 0; first = -1;
			for (int i = 0; i < LEN[sct]; i++)
				if (st_b[base + i] != st_c[base + i]) begin
					diff++;
					if (first < 0) first = i;
				end
			if (diff != 0) begin
				$display("DIFF %-13s %6d of %6d words, first at %0d: B %h C %h", NAME[sct], diff, LEN[sct],
				         first, st_b[base + first], st_c[base + first]);
				bad++;
			end else
				$display("SAME %-13s %6d words", NAME[sct], LEN[sct]);
			base += LEN[sct];
		end
		diff = 0;
		for (int i = 0; i < (n1 < n2 ? n1 : n2); i++)
			if (tr1[i] != tr2[i]) begin
				if (diff < 5) $display("TRACE entry %0d: A..B %h, load..C %h", i, tr1[i], tr2[i]);
				diff++;
			end
		if (n1 != n2 || diff != 0) begin
			$display("FAIL main trace: %0d and %0d entries, %0d differ", n1, n2, diff);
			bad++;
		end else
			$display("SAME main trace, %0d writes and non-ROM reads", n1);
		if (bad == 0) $display("PASS");
		else          $display("FAILED: %0d", bad);
		$finish;
	end

	// ---- trace ----
	int  fd, seq = 0;
	longint frames = 0;
	logic vb_d, spr_busy_d;

	function automatic [15:0] lanes(input logic uds, lds);
		return {uds ? 8'hFF : 8'h00, lds ? 8'hFF : 8'h00};
	endfunction

	always_ff @(posedge clk) begin
		vb_d <= vblank;
		if (vblank && !vb_d) frames++;
		// sprite precompute time, frame_go to the engine going idle
		if (dut.frame_go) fg_t = $time;
		if (spr_busy_d && !dut.u_video.eng_busy[5] && fg_t >= 0) begin
			pre_max = longint'(real'($time - fg_t) / 20.832) > pre_max ? longint'(real'($time - fg_t) / 20.832) : pre_max;
			fg_t = -1;
		end
		spr_busy_d <= dut.u_video.eng_busy[5];
		if (overrun) begin
			$display("FAIL video overrun at frame %0d, row %0d: engines busy %b",
			         frames, dut.vcount, dut.u_video.eng_busy);
			$finish;
		end
		if (dbg_stb) begin
			seq <= seq + 1;
			if (dbg_we && {dbg_addr, 1'b0} == 24'h082308)
				$display("comms %04h at frame %0d row %0d, access %0d", dbg_data, frames, dut.vcount, seq + 1);
			$fdisplay(fd, "%0d\t%s\t%06X\t%04X\t%04X", seq + 1, dbg_we ? "w" : "r",
			          {dbg_addr, 1'b0}, lanes(dbg_uds, dbg_lds),
			          dbg_data & lanes(dbg_uds, dbg_lds));
			if (seq + 1 >= n_max && state_test == 0 && load_path == "") begin
				$fdisplay(fd, "# %0d accesses", seq + 1);
				$fclose(fd);
				$display("TRACE %0d main accesses -> %s, %0d frames", seq + 1, trace_path, frames);
				for (int p = 1; p < 5; p++)
					$display("PORT  %0d: %0d accesses, %0d writes", p, ext_n[p], ext_w[p]);
				$display("GFX   %0d granules; sprite precompute at most %0d clk", gfx_n, pre_max);
				if (!ideal) $display("SDRAM %0d wrong CPU words, %0d wrong gfx words", ext_bad, gfx_bad);
				$finish;
			end
		end
	end

	initial begin
		for (int p = 0; p < 5; p++) begin ext_n[p] = 0; ext_w[p] = 0; end
		fd = $fopen(trace_path, "w");
		if (fd == 0) $fatal(1, "cannot open %s", trace_path);
		$readmemh(image_path, sdram);
		if (sdram[0] !== 16'h000f) $fatal(1, "image %s did not load (word 0 = %h)", image_path, sdram[0]);
		for (int w = 0; w < WORDS; w++) u_chip.mem[w] = sdram[w];
		if (ideal) $display("IMAGE %s, ideal memory, LAT=%0d", image_path, lat);
		else       $display("IMAGE %s, SDRAM stack and chip model", image_path);
		repeat (4) @(posedge clk);
		init <= 1'b0;
		// sdram.sv's power-up sequence: 32 passes of its 11-state cycle on clk_mem
		repeat (400) @(posedge clk);
		reset <= 1'b0;
	end

endmodule
