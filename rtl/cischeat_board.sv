// SPDX-License-Identifier: GPL-3.0-or-later
//
// Cisco Heat board: main, two road and the sound 68000, their memory maps
// (jaleco/cischeat.cpp: cischeat_map 749, cischeat_map2/3 1013-1031,
// cischeat_sound_map 1112), the on-chip RAMs, the board registers, the sound
// gate array's handshake overlay, the YM2151 and both M6295s, timing and
// cischeat_video.
//
// Outside: one external port per CPU (program ROM; for the sound CPU also its
// work RAM), word-wide, holding req until a one-clock ready, with SDRAM byte
// addresses from docs/ROADMAP.md's map; the nine gfx clients of the video; the
// two sample clients of the M6295s.
//
// Unmapped reads return 0, as MAME's do on this board (the main CPU's read of
// 0x82308 in debug/cischeat-boot/cischeat_boot.trace).
//
// Audio: MAME's mix (1806-1815), the YM2151 at 0.50 to each side and each
// M6295 at 0.25 to both. A full-scale M6295 voice is 12 bits and jt6295 sums
// four, so a chip is x16 to 16-bit full scale, x4 at 0.25.

module cischeat_board (
	input  logic         clk,
	input  logic         reset,
	input  logic         pause,         // suspends the main CPU
	input  logic [2:0]   board,         // 0 Big Run, 1 Cisco Heat, 2 F1 GP Star (docs/ROADMAP.md, Per-game configuration)

	input  logic [15:0]  in1, in2, in3, in4,    // 0x80000..0x80006; F1 GP Star: 0x80000, 0x80004, 0x80006, 0x8000c
	input  logic [15:0]  dsw3,                  // 0x82200
	input  logic [15:0]  wheel,                 // ip_select 0; F1 GP Star 0x80010 high byte; Wild Pilot P1 {x, y}
	input  logic [15:0]  pedal,                 // ip_select 3, Big Run; F1 GP Star 0x80010 low byte; Wild Pilot P2 {x, y}

	// external ports: 0 main, 1 road1, 2 road2, 3 sound
	output logic [4:0]   ext_req,
	output logic [4:0]   ext_we,
	output logic [25:1]  ext_addr [5],
	output logic [15:0]  ext_wdata [5],
	output logic [1:0]   ext_be [5],
	input  logic [4:0]   ext_ready,
	input  logic [15:0]  ext_rdata [5],

	// gfx clients: 0-2 tilemaps, 3-4 roads, 5-8 sprites
	output logic [8:0]   gfx_req,
	output logic [25:0]  gfx_addr [9],
	input  logic [8:0]   gfx_valid,
	input  logic [63:0]  gfx_rdata [9],

	// M6295 sample fetches, held until valid
	output logic [1:0]   snd_req,
	output logic [25:0]  snd_addr [2],
	input  logic [1:0]   snd_valid,
	input  logic [63:0]  snd_rdata,

	output logic signed [15:0] audio_l, audio_r,

	output logic         ce_pix,
	output logic         hblank, vblank, hsync, vsync,
	output logic [7:0]   r, g, b,

	output logic         video_overrun,

	// savestate (docs/SAVESTATES.md): a 16-bit word stream out on save, in on load
	input  logic         ss_save,
	input  logic         ss_load,
	output logic         ss_busy,
	output logic         ss_error,
	output logic         so_valid,
	output logic [15:0]  so_data,
	input  logic         so_ready,
	input  logic         si_valid,
	input  logic [15:0]  si_data,
	output logic         si_ready,

	output logic         dbg_stb,       // main CPU access trace
	output logic         dbg_we,
	output logic [23:1]  dbg_addr,
	output logic [15:0]  dbg_data,
	output logic         dbg_uds,
	output logic         dbg_lds
);

	logic br, ch, f1, io, wp;
	assign br = board == 3'd0;
	assign ch = board == 3'd1;
	assign f1 = board >= 3'd2;          // the F1 GP Star family, F-1 Grand Prix Star II
	assign io = board >= 3'd3;          // F-1 Grand Prix Star II and Wild Pilot: the io CPU
	assign wp = board == 3'd4;          // Wild Pilot (wildplt_map, 894-934)

	// SDRAM byte addresses
	localparam logic [25:0] SD_MAIN = 26'h0000000, SD_ROAD1 = 26'h0100000, SD_ROAD2 = 26'h0180000;
	localparam logic [25:0] SD_SND  = 26'h0280000, SD_SRAM  = 26'h03e0000, SD_IO = 26'h0200000;

	// ---- power-up fill: scroll RAM reads 0xffff after reset (ms1_tmap.cpp 130-137)
	logic        fill_busy;
	logic [13:0] fill_a;
	always_ff @(posedge clk)
		if (reset) begin
			fill_busy <= 1'b1;
			fill_a    <= '0;
		end else if (fill_busy) begin
			fill_a <= fill_a + 14'd1;
			if (&fill_a) fill_busy <= 1'b0;
		end

	logic sys_reset;
	assign sys_reset = reset || fill_busy;

	// ---- timing ---------------------------------------------------------
	logic [8:0] hcount, vcount;
	logic       odd_frame, irq_main1, irq_main2, irq_main4, irq_road4;
	logic       latch, frame_go, line_go;
	logic [7:0] line_vpos;
	logic       t_hblank, t_vblank, t_hsync, t_vsync;

	logic       ss_freeze, odd_we, odd_d;

	cischeat_timing u_timing (
		.clk, .reset(sys_reset), .run(!ss_freeze), .odd_we, .odd_d, .ce_pix, .hcount, .vcount,
		.hblank(t_hblank), .vblank(t_vblank), .hsync(t_hsync), .vsync(t_vsync), .odd_frame,
		.irq_main1, .irq_main2, .irq_main4, .irq_road4,
		.latch, .frame_go, .line_go, .line_vpos
	);

	// ---- registers written by the main CPU ------------------------------
	logic [15:0] scroll [3][3];         // [layer][x, y, ctrl], CPU side
	logic [15:0] sl_to_sound, sl_to_main, ip_select;
	logic [2:0]  comms;
	logic        snd_irq_main;

	// ---- CPUs -----------------------------------------------------------
	// [0] main, [1] road1, [2] road2, [3] sound, [4] io (F-1 Grand Prix Star II)
	logic [23:1] c_addr  [5];
	logic        c_we    [5];
	logic [15:0] c_wdata [5];
	logic [1:0]  c_be    [5];
	logic [4:0]  c_ext, c_stb;
	logic [15:0] c_rdata [5];
	logic [6:0]  c_irq   [5];
	logic        c_reset [5];
	logic        c_run   [5];

	logic ym_irq_edge;
	logic io_irq2, io_irq4;             // f1gpstr2_io_w (647-655)

	// ---- state port: the engine's word accesses ------------------------
	// Sections, in file order (scripts/state.py's manifest):
	//   0-3 the CPUs' stub registers, 19 x 32 bits, high word first (io CPU: 18)
	//   4   board registers (st_reg below)
	//   5 work RAM, 6-7 shared RAM road1/road2, 8-10 scroll RAM 0-2, 11 palette,
	//   12 link RAM, 13-14 road line lists, 15-16 road CPU local RAM,
	//   17 sound work RAM (SDRAM, through the sound CPU's external port),
	//   18 io CPU stub registers, 19 io shared RAM, 20 io CPU local RAM,
	//   21 Wild Pilot's sprite DMA buffer
	// The CPUs are parked during the walk, so a section's RAM is reached through
	// its CPU-side port.
	localparam int NSEC = 22;
	localparam int SEC_LEN [NSEC] = '{38, 38, 38, 38, 30,
	                                  32768, 16384, 16384, 16384, 16384, 16384, 16384,
	                                  1024, 1024, 1024, 8192, 8192, 32768,
	                                  38, 2048, 8192, 2048};
	logic        op_req, op_we, op_ack;
	logic [4:0]  op_sec;
	logic [17:0] op_idx;
	logic [15:0] op_wdata, op_rdata;
	logic        op_t;                  // the clock after an access is issued
	logic        e_wr;                  // the write clock of an engine access
	logic        ss_park, ss_release;
	logic [4:0]  c_parked;
	logic [31:0] c_ss_rd [5];
	logic [7:1]  c_pend [5];
	logic [15:0] ss_hi;                 // high word of a CPU register being loaded
	logic [4:0]  c_ss_we;
	logic        reg_we;                // a board register write from the engine
	logic [4:0]  c_ext_req;

	assign e_wr   = op_req && op_we && !op_t;
	assign reg_we = e_wr && op_sec == 5'd4;
	always_ff @(posedge clk) op_t <= op_req && !op_ack;

	// one write strobe per section, as a signal: a function reading e_wr and
	// op_sec, called with constant arguments in a port expression, is not
	// re-evaluated when they change (ModelSim), and the loads never wrote
	logic [NSEC-1:0] e_sel;
	assign e_sel = e_wr ? NSEC'(1) << op_sec : '0;

	always_ff @(posedge clk)
		if (e_wr && (op_sec < 5'd4 || op_sec == 5'd18) && !op_idx[0]) ss_hi <= op_wdata;
	always_comb
		for (int n = 0; n < 5; n++)
			c_ss_we[n] = e_wr && op_sec == (n == 4 ? 5'd18 : 5'(n)) && op_idx[0];

	assign c_reset[0] = sys_reset;
	// cischeat_comms_w / f1gpstar_comms_w (cischeat.cpp 590-596, 638-644)
	assign c_reset[1] = sys_reset || (f1 ? comms[0] : comms[1]);
	assign c_reset[2] = sys_reset || comms[1];
	assign c_reset[3] = sys_reset || (f1 ? comms[2] : comms[0]);
	assign c_run[0]   = !pause;
	assign c_run[1]   = 1'b1;
	assign c_run[2]   = 1'b1;
	assign c_run[3]   = 1'b1;
	assign c_reset[4] = sys_reset || !io;
	assign c_run[4]   = 1'b1;
	assign c_irq[0]   = {3'b000, irq_main4, 1'b0, irq_main2, irq_main1};
	assign c_irq[1]   = {3'b000, irq_road4, 3'b000};
	assign c_irq[2]   = {3'b000, irq_road4, 3'b000};
	assign c_irq[3]   = {3'b000, snd_irq_main || ym_irq_edge, 3'b000};
	assign c_irq[4]   = {3'b000, io_irq4, 1'b0, io_irq2, 1'b0};

	genvar ci;
	generate
		for (ci = 0; ci < 5; ci++) begin : cpu
			logic        d_stb, d_we, d_uds, d_lds;
			logic [23:1] d_addr;
			logic [15:0] d_data;
			// 10 MHz, 12 MHz on F1 GP Star (main and road); the sound CPU 6 MHz
			board_cpu #(.PHASE_NUM(ci == 3 ? 8 : 24), .PHASE_DEN(ci == 3 ? 1 : 5),
			            .PHASE_NUM_FAST(ci == 3 ? 8 : 20)) u (
				.clk, .reset(c_reset[ci]), .cpu_run(c_run[ci]), .fast(f1 && ci < 3), .irq_set(c_irq[ci]),
				.addr(c_addr[ci]), .we(c_we[ci]), .wdata(c_wdata[ci]), .be(c_be[ci]),
				.is_ext(c_ext[ci]), .int_stb(c_stb[ci]), .int_rdata(c_rdata[ci]),
				.ext_req(c_ext_req[ci]), .ext_ready(ext_ready[ci]), .ext_rdata(ext_rdata[ci]),
				.ss_req(ss_park), .ss_parked(c_parked[ci]), .ss_release,
				.ss_idx(op_idx[5:1]), .ss_we(c_ss_we[ci]), .ss_wd({ss_hi, op_wdata}),
				.ss_rd(c_ss_rd[ci]), .ss_pend(c_pend[ci]),
				.ss_pend_we(reg_we && op_idx == 18'(ci == 4 ? 25 : 21 + ci)), .ss_pend_wd(op_wdata[7:1]),
				.dbg_stb(d_stb), .dbg_we(d_we), .dbg_addr(d_addr), .dbg_data(d_data),
				.dbg_uds(d_uds), .dbg_lds(d_lds)
			);
			if (ci != 3) begin : ext
				assign ext_req[ci]   = c_ext_req[ci];
				assign ext_we[ci]    = c_we[ci];
				assign ext_wdata[ci] = c_wdata[ci];
				assign ext_be[ci]    = c_be[ci];
			end
			if (ci == 0) begin : trace
				assign dbg_stb = d_stb; assign dbg_we = d_we; assign dbg_addr = d_addr;
				assign dbg_data = d_data; assign dbg_uds = d_uds; assign dbg_lds = d_lds;
			end
		end
	endgenerate

	// byte-lane write enables for an internal write
	// each CPU's byte write enables, for the RAM it selects
	logic [1:0] c_wbe [5];
	always_comb
		for (int n = 0; n < 5; n++) c_wbe[n] = (c_stb[n] && c_we[n]) ? c_be[n] : 2'b00;

	// =====================================================================
	// Main CPU
	// =====================================================================
	logic [23:0] ma;
	assign ma = {c_addr[0], 1'b0};

	// Cisco Heat (cischeat_map, cischeat.cpp 749-787): link 088000, shared RAM
	// road2 090000 / road1 098000, scroll RAM 0a0000-0b7fff, palette 0b8000,
	// 32 KB each. Big Run (bigrun_map, 694-730): link 084000, 16 KB windows from
	// 088000 in the same order.
	logic m_rom, m_link, m_sh2, m_sh1, m_scr0, m_scr1, m_scr2, m_pal, m_work, m_io;
	logic [13:0] m_wa;                  // word address inside a 16K-word RAM
	assign m_rom  = ma < 24'h080000 || (ma >= 24'h100000 && ma < 24'h180000);
	assign m_link = br ? ma[23:11] == 13'h0108 : ma[23:11] == 13'h0110;
	assign m_sh2  = br ? ma[23:14] == 10'h022  : ma[23:15] == 9'h012;
	assign m_sh1  = br ? ma[23:14] == 10'h023  : ma[23:15] == 9'h013;
	assign m_scr0 = br ? ma[23:14] == 10'h024  : ma[23:15] == 9'h014;
	assign m_scr1 = br ? ma[23:14] == 10'h025  : ma[23:15] == 9'h015;
	assign m_scr2 = br ? ma[23:14] == 10'h026  : ma[23:15] == 9'h016;
	assign m_pal  = br ? ma[23:14] == 10'h027  : ma[23:15] == 9'h017;
	assign m_work = ma[23:16] == 8'h0f;
	assign m_io   = io && ma[23:12] == 12'h081;   // io shared RAM (f1gpstr2_map, 938-975)
	assign m_wa   = {br ? 1'b0 : c_addr[0][14], c_addr[0][13:1]};

	assign c_ext[0]    = m_rom && !c_we[0];          // a ROM write is dropped
	assign ext_addr[0] = 25'((ma < 24'h080000 ? ma : ma - 24'h080000) >> 1) + 25'(SD_MAIN >> 1);

	// RAM read data, valid the clock after int_stb
	logic [15:0] q_link, q_sh2_m, q_sh1_m, q_scr_m [3], q_pal_m, q_work_m, q_io_m;
	logic [7:0]  io_value;              // last byte the main wrote to 080000
	logic        io_ready;              // the io CPU's write to 100000, bit 0
	logic [3:0]  wp_out;                // Wild Pilot's input mux select (wildplt_mux_w)
	logic [15:0] dma_reg;               // Wild Pilot's sprite DMA register (sprite_dma_w)
	logic        dma_go;                // its bit 13 rose

	// registers and the main side's read mux. The address is held, so the
	// selects are still valid in the clock after int_stb.
	logic [15:0] m_reg;
	always_comb begin
		m_reg = 16'h0000;
		case (ma)
			// f1gpstar_map (812-848): IN1 0, IN2 4, IN3 6, latch 8, IN4 c, wheel_r 10
			24'h080000: m_reg = in1;
			24'h080002: m_reg = f1 ? 16'h0000 : in2;
			// Wild Pilot: wildplt_mux_r, in2 = IN1_1, in3 = IN1_2, in4 = IN1_COMMON
			24'h080004: m_reg = wp ? ((wp_out == 4'h4 ? in2 : wp_out == 4'h8 ? in3 : 16'hffff) & in4) :
			                    f1 ? in2 : in3;
			24'h080006: m_reg = wp ? 16'h0000 : f1 ? in3 : in4;
			24'h080008: m_reg = ch ? 16'h0000 : sl_to_main;
			24'h08000c: m_reg = f1 && !wp ? in4 : 16'h0000;
			24'h080018: m_reg = io ? (io_ready ? 16'h00ff : 16'h00f0) : 16'h0000;   // f1gpstr2_ioready_r
			24'h080010: m_reg = wp ? (ip_select == 16'd1 ? pedal : ip_select == 16'd2 ? wheel : 16'hffff) :   // wildplt_xy_r
			                    f1 ? {wheel[7:0], pedal[7:0]} :
			                    (ip_select[1:0] == 2'd0) ? wheel :
			                    (br && ip_select[1:0] == 2'd3) ? pedal : 16'hffff;
			24'h082000: m_reg = scroll[0][0];
			24'h082002: m_reg = scroll[0][1];
			24'h082004: m_reg = scroll[0][2];
			24'h082008: m_reg = scroll[1][0];
			24'h08200a: m_reg = scroll[1][1];
			24'h08200c: m_reg = scroll[1][2];
			24'h082100: m_reg = scroll[2][0];
			24'h082102: m_reg = scroll[2][1];
			24'h082104: m_reg = scroll[2][2];
			24'h082200: m_reg = f1 ? 16'h0000 : dsw3;
			24'h082300: m_reg = ch ? sl_to_main : 16'h0000;
			default:    m_reg = 16'h0000;
		endcase
	end

	always_comb
		if      (m_link) c_rdata[0] = q_link;
		else if (m_sh2)  c_rdata[0] = q_sh2_m;
		else if (m_sh1)  c_rdata[0] = q_sh1_m;
		else if (m_scr0) c_rdata[0] = q_scr_m[0];
		else if (m_scr1) c_rdata[0] = q_scr_m[1];
		else if (m_scr2) c_rdata[0] = q_scr_m[2];
		else if (m_pal)  c_rdata[0] = q_pal_m;
		else if (m_work) c_rdata[0] = q_work_m;
		else if (m_io)   c_rdata[0] = q_io_m;
		else             c_rdata[0] = m_reg;

	function automatic logic [15:0] combine(input logic [15:0] old, input logic [15:0] d,
	                                        input logic [1:0] be);
		return {be[1] ? d[15:8] : old[15:8], be[0] ? d[7:0] : old[7:0]};
	endfunction

	logic m_wr;
	assign m_wr = c_stb[0] && c_we[0];

	always_ff @(posedge clk) begin
		snd_irq_main <= 1'b0;
		io_irq2      <= 1'b0;
		io_irq4      <= 1'b0;
		dma_go       <= 1'b0;
		if (sys_reset) begin
			io_value    <= 8'h00;
			wp_out      <= 4'h0;
			dma_reg     <= 16'h0000;
			for (int l = 0; l < 3; l++)
				for (int k = 0; k < 3; k++) scroll[l][k] <= 16'h0000;
			ip_select   <= 16'h0000;
			comms       <= 3'b000;
			sl_to_sound <= 16'h0000;
		end else if (reg_we) begin
			case (op_idx)
				18'd0: scroll[0][0] <= op_wdata;
				18'd1: scroll[0][1] <= op_wdata;
				18'd2: scroll[0][2] <= op_wdata;
				18'd3: scroll[1][0] <= op_wdata;
				18'd4: scroll[1][1] <= op_wdata;
				18'd5: scroll[1][2] <= op_wdata;
				18'd6: scroll[2][0] <= op_wdata;
				18'd7: scroll[2][1] <= op_wdata;
				18'd8: scroll[2][2] <= op_wdata;
				18'd9:  sl_to_sound <= op_wdata;
				18'd11: ip_select   <= op_wdata;
				18'd12: comms       <= op_wdata[2:0];
				18'd26: io_value    <= op_wdata[7:0];
				18'd28: wp_out      <= op_wdata[3:0];
				18'd29: dma_reg     <= op_wdata;
				default: ;
			endcase
		end else if (m_wr) begin
			case (ma)
				24'h080000: if (io && c_be[0][0]) begin
					io_value <= c_wdata[0][7:0];
					io_irq4  <= io_value[2] && !c_wdata[0][2];
					io_irq2  <= io_value[1] && !c_wdata[0][1];
				end
				24'h08000a: if (!f1) sl_to_sound <= c_wdata[0];
				24'h080008: if (f1) sl_to_sound <= c_wdata[0];
				24'h080018: if (f1) snd_irq_main <= 1'b1;   // f1gpstar_soundint_w
				24'h080010: if (!f1 || wp) ip_select <= c_wdata[0];
				24'h080004: if (wp) wp_out <= {c_wdata[0][3:2], 2'b00};
				24'h08000c: if (wp) begin
					dma_reg <= combine(dma_reg, c_wdata[0], c_be[0]);
					dma_go  <= combine(dma_reg, c_wdata[0], c_be[0]) & ~dma_reg & 16'h2000 ? 1'b1 : 1'b0;
				end
				24'h080012: if (br) ip_select <= c_wdata[0] + 16'd1;
				24'h082000: scroll[0][0] <= combine(scroll[0][0], c_wdata[0], c_be[0]);
				24'h082002: scroll[0][1] <= combine(scroll[0][1], c_wdata[0], c_be[0]);
				24'h082004: scroll[0][2] <= combine(scroll[0][2], c_wdata[0], c_be[0]);
				24'h082008: scroll[1][0] <= combine(scroll[1][0], c_wdata[0], c_be[0]);
				24'h08200a: scroll[1][1] <= combine(scroll[1][1], c_wdata[0], c_be[0]);
				24'h08200c: scroll[1][2] <= combine(scroll[1][2], c_wdata[0], c_be[0]);
				24'h082100: scroll[2][0] <= combine(scroll[2][0], c_wdata[0], c_be[0]);
				24'h082102: scroll[2][1] <= combine(scroll[2][1], c_wdata[0], c_be[0]);
				24'h082104: scroll[2][2] <= combine(scroll[2][2], c_wdata[0], c_be[0]);
				24'h082300: if (ch) begin sl_to_sound <= c_wdata[0]; snd_irq_main <= 1'b1; end
				24'h082308: comms <= c_wdata[0][2:0];
				default: ;
			endcase
		end
	end

	// =====================================================================
	// Road CPUs: [1] road1 (road list 0, shared at main 098000),
	//            [2] road2 (road list 1, shared at main 090000)
	// =====================================================================
	logic [23:0] ra [3];
	logic        r_sh [3], r_list [3], r_loc [3];
	logic [15:0] q_sh_r [3], q_list_r [3], q_loc_r [3];

	generate
		for (ci = 1; ci <= 2; ci++) begin : road
			logic [25:0] base;
			assign base     = ci == 1 ? SD_ROAD1 : SD_ROAD2;
			assign ra[ci]   = {c_addr[ci], 1'b0};
			// shared RAM, road line list, local RAM: 040000 / 080000 / 0c0000 on Big Run
			// and Cisco Heat, 080000 / 100000 / 180000 on F1 GP Star (991-1016)
			assign r_sh[ci]   = f1 ? ra[ci][23:15] == 9'h010 :
			                    br ? ra[ci][23:14] == 10'h010 : ra[ci][23:15] == 9'h008;
			assign r_list[ci] = f1 ? ra[ci][23:11] == 13'h0200 : ra[ci][23:11] == 13'h0100;
			assign r_loc[ci]  = f1 ? ra[ci][23:14] == 10'h060 : ra[ci][23:14] == 10'h030;
			assign c_ext[ci]  = !c_we[ci] && (ra[ci] < 24'h040000 || (!f1 && ra[ci][23:18] == 6'h08));   // + 200000-23ffff
			assign ext_addr[ci] = 25'((base >> 1) + {ra[ci][21], ra[ci][17:1]});
			always_comb
				if      (r_sh[ci])   c_rdata[ci] = q_sh_r[ci];
				else if (r_list[ci]) c_rdata[ci] = q_list_r[ci];
				else if (r_loc[ci])  c_rdata[ci] = q_loc_r[ci];
				else                 c_rdata[ci] = 16'h0000;

			dpram_be #(.AW(13)) u_loc (
				.clk,
				.a_addr(op_req ? op_idx[12:0] : c_addr[ci][13:1]), .a_we((r_loc[ci] ? c_wbe[ci] : 2'b00) | {2{e_sel[14 + ci]}}),
			.a_d(op_req ? op_wdata : c_wdata[ci]), .a_q(q_loc_r[ci]),
				.b_addr('0), .b_we(2'b00), .b_d('0), .b_q()
			);
		end
	endgenerate

	// =====================================================================
	// Sound CPU
	// =====================================================================
	logic [23:0] sa;
	assign sa = {c_addr[3], 1'b0};

	// gate array: GS88000 on Cisco Heat, D65006 elsewhere (ms1_gatearray.cpp
	// 139-184, unlock sequences in ms1_gatearray.h 55, 69)
	logic [15:0] ga_ram [5];
	logic        ga_hs, ga_hit;
	assign ga_hit = ga_hs && ({ga_ram[4][11:0], 6'd0} == {sa[17:6], 6'd0});
	logic [15:0] ga_seq0, ga_seq3, ga_val;
	assign ga_seq0 = ch ? 16'h00ff : 16'h0000;
	assign ga_seq3 = ch ? 16'h0000 : 16'h00ff;
	assign ga_val  = ch ? 16'h889e : 16'h835d;

	logic s_rom, s_ram, s_ga_w;
	assign s_rom  = sa < 24'h040000;
	assign s_ram  = f1 ? sa[23:17] == 7'h07 : sa[23:16] == 8'h0f;   // 0e0000-0fffff on F1 GP Star
	assign s_ga_w = sa[23:16] == 8'h02;
	assign c_ext[3]    = (s_rom && !c_we[3] && !ga_hit) || s_ram;
	logic e_sram;
	assign e_sram       = op_req && op_sec == 5'd17;
	assign ext_req[3]   = c_ext_req[3] || (e_sram && !op_ack);
	assign ext_we[3]    = e_sram ? op_we : c_we[3];
	assign ext_wdata[3] = e_sram ? op_wdata : c_wdata[3];
	assign ext_be[3]    = e_sram ? 2'b11 : c_be[3];
	assign ext_addr[3]  = e_sram ? 25'((SD_SRAM >> 1) + op_idx[14:0]) :
	                      s_ram  ? 25'((SD_SRAM >> 1) + sa[16:1]) : 25'((SD_SND >> 1) + sa[17:1]);

	logic [7:0]  ym_dout;
	logic [7:0]  oki_dout [2];
	logic [15:0] oki_bank;
	always_comb
		if (s_rom)                    c_rdata[3] = ga_val;          // only the overlay is internal
		else if (sa == (br ? 24'h040000 : f1 && !io ? 24'h060000 : 24'h060004)) c_rdata[3] = sl_to_sound;
		else if (sa[23:2] == 22'h020000) c_rdata[3] = {8'h00, ym_dout};
		else if (sa[23:2] == 22'h028000) c_rdata[3] = {8'h00, oki_dout[0]};
		else if (sa[23:2] == 22'h030000) c_rdata[3] = {8'h00, oki_dout[1]};
		else                          c_rdata[3] = 16'h0000;

	logic s_wr;
	assign s_wr = c_stb[3] && c_we[3];

	always_ff @(posedge clk) begin
		if (sys_reset) begin
			ga_hs      <= 1'b0;
			sl_to_main <= 16'h0000;
			oki_bank   <= 16'h0000;
		end else if (reg_we) begin
			case (op_idx)
				18'd10: sl_to_main <= op_wdata;
				18'd13: oki_bank   <= op_wdata;
				18'd14, 18'd15, 18'd16, 18'd17, 18'd18: ga_ram[op_idx - 18'd14] <= op_wdata;
				18'd19: ga_hs      <= op_wdata[0];
				default: ;
			endcase
		end else if (s_wr) begin
			if (s_ga_w && sa[3:1] <= 3'd4) begin
				logic [15:0] v [5];
				for (int k = 0; k < 5; k++) v[k] = ga_ram[k];
				v[sa[3:1]] = combine(ga_ram[sa[3:1]], c_wdata[3], c_be[3]);
				ga_ram[sa[3:1]] <= v[sa[3:1]];
				ga_hs <= sa[3:1] == 3'd4 && v[0] == ga_seq0 && v[1] == 16'h0055 &&
				         v[2] == 16'h00aa && v[3] == ga_seq3;
			end else if (s_ga_w)
				ga_hs <= 1'b0;
			if (br) begin                   // bigrun_soundbank_w, bigrun_sound_map (1072-1090)
				if (sa == 24'h040000 && c_be[3][0]) oki_bank[1:0] <= {c_wdata[3][4], c_wdata[3][0]};
				if (sa == 24'h060000) sl_to_main <= c_wdata[3];
			end else if (f1) begin          // f1gpstar_sound_map (1150-1160), f1gpstr2_sound_map (1139-1150)
				if (sa == 24'h040004 && c_be[3][0]) oki_bank[0] <= c_wdata[3][0];
				if (sa == 24'h040008 && c_be[3][0]) oki_bank[1] <= c_wdata[3][0];
				if (sa == (io ? 24'h060002 : 24'h060000)) sl_to_main <= c_wdata[3];
			end else begin
				if (sa == 24'h040002 && c_be[3][0]) oki_bank[0] <= c_wdata[3][0];
				if (sa == 24'h040004 && c_be[3][0]) oki_bank[1] <= c_wdata[3][0];
				if (sa == 24'h060002) sl_to_main <= c_wdata[3];
			end
		end
	end

	// YM2151 at 3.5 MHz: 48 * 7 / 96
	logic [6:0] ym_acc;
	logic       ym_cen, ym_cen_p1, ym_half, ym_irq_n, ym_irq_n_d;
	always_ff @(posedge clk)
		if (reset) begin
			ym_acc <= '0; ym_cen <= 1'b0; ym_half <= 1'b0;
		end else begin
			ym_cen <= 1'b0;
			if (ym_acc + 7'd7 >= 7'd96) begin
				ym_acc  <= ym_acc + 7'd7 - 7'd96;
				ym_cen  <= 1'b1;
				ym_half <= ~ym_half;
			end else
				ym_acc <= ym_acc + 7'd7;
		end
	assign ym_cen_p1 = ym_cen && ym_half;

	logic signed [15:0] ym_l, ym_r;
	logic ym_cs;
	assign ym_cs = s_wr && sa[23:2] == 22'h020000 && c_be[3][0];

	jt51 u_ym (
		.rst(reset), .clk, .cen(ym_cen), .cen_p1(ym_cen_p1),
		.cs_n(!ym_cs), .wr_n(!ym_cs), .a0(sa[1]), .din(c_wdata[3][7:0]), .dout(ym_dout),
		.ct1(), .ct2(), .irq_n(ym_irq_n), .sample(), .left(ym_l), .right(ym_r), .xleft(), .xright()
	);

	logic signed [13:0] oki_snd [2];
	cischeat_oki u_oki (
		.clk, .reset,
		.wr({s_wr && sa[23:2] == 22'h030000 && c_be[3][0], s_wr && sa[23:2] == 22'h028000 && c_be[3][0]}),
		.wdata(c_wdata[3][7:0]), .dout(oki_dout), .bank(oki_bank[1:0]),
		.g_req(snd_req), .g_addr(snd_addr), .g_valid(snd_valid), .g_data(snd_rdata),
		.snd(oki_snd)
	);

	logic signed [17:0] mix_l, mix_r, oki_mix;
	always_ff @(posedge clk) begin
		oki_mix <= (18'(oki_snd[0]) <<< 2) + (18'(oki_snd[1]) <<< 2);
		mix_l   <= 18'(ym_l >>> 1) + oki_mix;
		mix_r   <= 18'(ym_r >>> 1) + oki_mix;
		audio_l <= mix_l > 18'sd32767 ? 16'sh7fff : mix_l < -18'sd32768 ? 16'sh8000 : mix_l[15:0];
		audio_r <= mix_r > 18'sd32767 ? 16'sh7fff : mix_r < -18'sd32768 ? 16'sh8000 : mix_r[15:0];
	end

	always_ff @(posedge clk) ym_irq_n_d <= reset ? 1'b1 : ym_irq_n;
	assign ym_irq_edge = ym_irq_n_d && !ym_irq_n;

	// =====================================================================
	// RAMs
	// =====================================================================
	dpram_be #(.AW(10)) u_link (
		.clk,
		.a_addr(op_req ? op_idx[9:0] : c_addr[0][10:1]), .a_we((m_link ? c_wbe[0] : 2'b00) | {2{e_sel[12]}}),
			.a_d(op_req ? op_wdata : c_wdata[0]), .a_q(q_link),
		.b_addr('0), .b_we(2'b00), .b_d('0), .b_q()
	);

	// shared RAM: main on A, the road CPU on B
	dpram_be #(.AW(14)) u_sh1 (
		.clk,
		.a_addr(op_req ? op_idx[13:0] : m_wa), .a_we((m_sh1 ? c_wbe[0] : 2'b00) | {2{e_sel[6]}}),
			.a_d(op_req ? op_wdata : c_wdata[0]), .a_q(q_sh1_m),
		.b_addr(c_addr[1][14:1]), .b_we((r_sh[1] ? c_wbe[1] : 2'b00)), .b_d(c_wdata[1]), .b_q(q_sh_r[1])
	);
	dpram_be #(.AW(14)) u_sh2 (
		.clk,
		.a_addr(op_req ? op_idx[13:0] : m_wa), .a_we((m_sh2 ? c_wbe[0] : 2'b00) | {2{e_sel[7]}}),
			.a_d(op_req ? op_wdata : c_wdata[0]), .a_q(q_sh2_m),
		.b_addr(c_addr[2][14:1]), .b_we((r_sh[2] ? c_wbe[2] : 2'b00)), .b_d(c_wdata[2]), .b_q(q_sh_r[2])
	);

	// =====================================================================
	// Io CPU (f1gpstr2_io_map, 1161-1168): ROM 000000-07ffff, shared RAM
	// 080000-080fff (main 081000), ready flag 100000, RAM 180000-183fff
	// =====================================================================
	logic [23:0] ia;
	logic        i_sh, i_loc, i_rdy;
	logic [15:0] q_io_i, q_ioloc;
	assign ia    = {c_addr[4], 1'b0};
	assign i_sh  = ia[23:12] == 12'h080;
	assign i_rdy = ia[23:1] == 23'h080000;
	assign i_loc = ia[23:14] == 10'h060;
	assign c_ext[4]    = !c_we[4] && ia < 24'h080000;
	assign ext_addr[4] = 25'((SD_IO >> 1) + ia[18:1]);
	always_comb
		if      (i_sh)  c_rdata[4] = q_io_i;
		else if (i_loc) c_rdata[4] = q_ioloc;
		else            c_rdata[4] = 16'h0000;

	always_ff @(posedge clk)
		if (sys_reset)                                     io_ready <= 1'b0;
		else if (reg_we && op_idx == 18'd27)               io_ready <= op_wdata[0];
		else if (c_stb[4] && c_we[4] && i_rdy && c_be[4][0]) io_ready <= c_wdata[4][0];

	dpram_be #(.AW(11)) u_iosh (
		.clk,
		.a_addr(op_req ? op_idx[10:0] : c_addr[0][11:1]), .a_we((m_io ? c_wbe[0] : 2'b00) | {2{e_sel[19]}}),
			.a_d(op_req ? op_wdata : c_wdata[0]), .a_q(q_io_m),
		.b_addr(c_addr[4][11:1]), .b_we(i_sh ? c_wbe[4] : 2'b00), .b_d(c_wdata[4]), .b_q(q_io_i)
	);
	dpram_be #(.AW(13)) u_ioloc (
		.clk,
		.a_addr(op_req ? op_idx[12:0] : c_addr[4][13:1]), .a_we((i_loc ? c_wbe[4] : 2'b00) | {2{e_sel[20]}}),
			.a_d(op_req ? op_wdata : c_wdata[4]), .a_q(q_ioloc),
		.b_addr('0), .b_we(2'b00), .b_d('0), .b_q()
	);

	// video-side memories
	logic [12:0]  vram_addr [3];
	logic [15:0]  vram_q [3];
	logic [9:0]   rlist_addr [2];
	logic [15:0]  rlist_q [2];
	logic [7:0]   slist_addr;
	logic [127:0] slist_q;
	logic [13:0]  pal_addr;
	logic [15:0]  pal_q;

	logic         m_scr [3];
	assign m_scr[0] = m_scr0;
	assign m_scr[1] = m_scr1;
	assign m_scr[2] = m_scr2;

	// scroll RAM: main on A, video (and the reset fill) on B. The video reads
	// the first 16 KB; the main CPU sees all 32 KB.
	generate
		for (ci = 0; ci < 3; ci++) begin : scr
			dpram_be #(.AW(14)) u (
				.clk,
				.a_addr(op_req ? op_idx[13:0] : m_wa), .a_we((m_scr[ci] ? c_wbe[0] : 2'b00) | {2{e_sel[8 + ci]}}),
			.a_d(op_req ? op_wdata : c_wdata[0]), .a_q(q_scr_m[ci]),
				.b_addr(fill_busy ? fill_a : {1'b0, vram_addr[ci]}), .b_we({2{fill_busy}}),
				.b_d(16'hffff), .b_q(vram_q[ci])
			);
		end
	endgenerate

	dpram_be #(.AW(14)) u_pal (
		.clk,
		.a_addr(op_req ? op_idx[13:0] : m_wa), .a_we((m_pal ? c_wbe[0] : 2'b00) | {2{e_sel[11]}}),
			.a_d(op_req ? op_wdata : c_wdata[0]), .a_q(q_pal_m),
		.b_addr(pal_addr), .b_we(2'b00), .b_d('0), .b_q(pal_q)
	);

	// road line lists: the road CPU on A, video on B
	dpram_be #(.AW(10)) u_rl0 (
		.clk,
		.a_addr(op_req ? op_idx[9:0] : c_addr[1][10:1]), .a_we((r_list[1] ? c_wbe[1] : 2'b00) | {2{e_sel[13]}}),
			.a_d(op_req ? op_wdata : c_wdata[1]), .a_q(q_list_r[1]),
		.b_addr(rlist_addr[0]), .b_we(2'b00), .b_d('0), .b_q(rlist_q[0])
	);
	dpram_be #(.AW(10)) u_rl1 (
		.clk,
		.a_addr(op_req ? op_idx[9:0] : c_addr[2][10:1]), .a_we((r_list[2] ? c_wbe[2] : 2'b00) | {2{e_sel[14]}}),
			.a_d(op_req ? op_wdata : c_wdata[2]), .a_q(q_list_r[2]),
		.b_addr(rlist_addr[1]), .b_we(2'b00), .b_d('0), .b_q(rlist_q[1])
	);

	// work RAM: main on A, the sprite-list copy on B
	logic        cp_busy, cp_wr;
	logic [11:0] cp_a;
	logic [10:0] cp_wa;
	logic [15:0] q_work_b;

	logic        dm_busy, dm_wr, dm_pend, cp_pend, wr_wait;
	assign wr_wait = dm_wr;
	logic [10:0] dm_a, dm_wa;
	logic [15:0] q_dma_b, q_dma_s;

	dpram_be #(.AW(15)) u_work (
		.clk,
		.a_addr(op_req ? op_idx[14:0] : c_addr[0][15:1]), .a_we((m_work ? c_wbe[0] : 2'b00) | {2{e_sel[5]}}),
			.a_d(op_req ? op_wdata : c_wdata[0]), .a_q(q_work_m),
		.b_addr({4'h8, dm_busy ? dm_a : cp_a[10:0]}), .b_we(2'b00), .b_d('0), .b_q(q_work_b)
	);

	// Wild Pilot's sprite DMA (sprite_dma_w, 374-383): bit 13 rising copies the
	// sprite RAM into this buffer, and the frame latch copies the buffer instead
	// of the sprite RAM. MAME's copy is instant; this one takes 2,048 clocks, and
	// a DMA and the latch copy wait for each other.
	dpram_be #(.AW(11)) u_dma (
		.clk,
		.a_addr(op_req ? op_idx[10:0] : dm_wa), .a_we({2{dm_wr && !op_req}} | {2{e_sel[21]}}),
			.a_d(op_req ? op_wdata : q_work_b), .a_q(q_dma_s),
		.b_addr(cp_a[10:0]), .b_we(2'b00), .b_d('0), .b_q(q_dma_b)
	);

	always_ff @(posedge clk)
		if (sys_reset) begin
			dm_busy <= 1'b0;
			dm_wr   <= 1'b0;
			dm_pend <= 1'b0;
		end else begin
			dm_wr <= dm_busy;
			dm_wa <= dm_a;
			if ((dma_go || dm_pend) && !dm_busy && !cp_busy) begin
				dm_busy <= 1'b1;
				dm_pend <= 1'b0;
				dm_a    <= '0;
			end else begin
				if (dma_go) dm_pend <= 1'b1;
				if (dm_busy) begin
					dm_a <= dm_a + 11'd1;
					if (dm_a == 11'h7ff) dm_busy <= 1'b0;
				end
			end
		end

	// latch: copy the sprite list (work RAM +0x8000, 4 KB) into the video's
	// 256 x 128-bit list, one 16-bit lane RAM per record word, and hold the
	// scroll registers for the frame.
	always_ff @(posedge clk)
		if (sys_reset) begin
			cp_busy <= 1'b0;
			cp_wr   <= 1'b0;
			cp_pend <= 1'b0;
		end else begin
			cp_wr <= cp_busy;
			cp_wa <= cp_a[10:0];
			if ((latch || cp_pend) && !dm_busy && !wr_wait) begin
				cp_busy <= 1'b1;
				cp_pend <= 1'b0;
				cp_a    <= '0;
			end else if (latch) begin
				cp_pend <= 1'b1;
			end else if (cp_busy) begin
				cp_a <= cp_a + 12'd1;
				if (cp_a[10:0] == 11'h7ff) cp_busy <= 1'b0;
			end
		end

	logic [15:0] v_scroll [3][3];
	always_ff @(posedge clk)
		if (latch) v_scroll <= scroll;

	generate
		for (ci = 0; ci < 8; ci++) begin : sl
			logic [15:0] mem [0:255];
			always_ff @(posedge clk) begin
				if (cp_wr && cp_wa[2:0] == 3'(ci)) mem[cp_wa[10:3]] <= wp ? q_dma_b : q_work_b;
				slist_q[16 * ci +: 16] <= mem[slist_addr];
			end
		end
	endgenerate

	// =====================================================================
	// State engine
	// =====================================================================
	// board registers, section 4
	logic [15:0] st_reg;
	always_comb begin
		st_reg = 16'h0000;
		case (op_idx)
			18'd0: st_reg = scroll[0][0];
			18'd1: st_reg = scroll[0][1];
			18'd2: st_reg = scroll[0][2];
			18'd3: st_reg = scroll[1][0];
			18'd4: st_reg = scroll[1][1];
			18'd5: st_reg = scroll[1][2];
			18'd6: st_reg = scroll[2][0];
			18'd7: st_reg = scroll[2][1];
			18'd8: st_reg = scroll[2][2];
			18'd9:  st_reg = sl_to_sound;
			18'd10: st_reg = sl_to_main;
			18'd11: st_reg = ip_select;
			18'd12: st_reg = {13'd0, comms};
			18'd13: st_reg = oki_bank;
			18'd14, 18'd15, 18'd16, 18'd17, 18'd18: st_reg = ga_ram[op_idx - 18'd14];
			18'd19: st_reg = {15'd0, ga_hs};
			18'd20: st_reg = {15'd0, odd_frame};
			18'd21, 18'd22, 18'd23, 18'd24: st_reg = {8'd0, c_pend[op_idx - 18'd21], 1'b0};
			18'd25: st_reg = {8'd0, c_pend[4], 1'b0};
			18'd26: st_reg = {8'd0, io_value};
			18'd27: st_reg = {15'd0, io_ready};
			18'd28: st_reg = {12'd0, wp_out};
			18'd29: st_reg = dma_reg;
			default: ;
		endcase
	end
	assign odd_we = reg_we && op_idx == 18'd20;
	assign odd_d  = op_wdata[0];

	always_comb begin
		op_ack = op_sec == 5'd17 ? ext_ready[3] : op_t;
		case (op_sec)
			5'd0, 5'd1, 5'd2, 5'd3:
				op_rdata = op_idx[0] ? c_ss_rd[op_sec[1:0]][15:0] : c_ss_rd[op_sec[1:0]][31:16];
			5'd4:  op_rdata = st_reg;
			5'd5:  op_rdata = q_work_m;
			5'd6:  op_rdata = q_sh1_m;
			5'd7:  op_rdata = q_sh2_m;
			5'd8:  op_rdata = q_scr_m[0];
			5'd9:  op_rdata = q_scr_m[1];
			5'd10: op_rdata = q_scr_m[2];
			5'd11: op_rdata = q_pal_m;
			5'd12: op_rdata = q_link;
			5'd13: op_rdata = q_list_r[1];
			5'd14: op_rdata = q_list_r[2];
			5'd15: op_rdata = q_loc_r[1];
			5'd16: op_rdata = q_loc_r[2];
			5'd18: op_rdata = op_idx[0] ? c_ss_rd[4][15:0] : c_ss_rd[4][31:16];
			5'd19: op_rdata = q_io_m;
			5'd20: op_rdata = q_ioloc;
			5'd21: op_rdata = q_dma_s;
			default: op_rdata = ext_rdata[3];
		endcase
	end

	// frames since reset, counted at vblank start; saved in the header
	logic [31:0] frame_no, frame_ld;
	logic        frame_we;
	always_ff @(posedge clk)
		if (sys_reset)     frame_no <= '0;
		else if (frame_we) frame_no <= frame_ld;
		else if (irq_road4) frame_no <= frame_no + 32'd1;

	logic [8:0] vcount_d;
	always_ff @(posedge clk) vcount_d <= vcount;

	state_engine #(.NSEC(NSEC), .LEN(SEC_LEN), .VERSION(16'd2)) u_state (
		.clk, .reset(sys_reset), .save(ss_save), .load(ss_load), .busy(ss_busy), .error(ss_error),
		.row1(vcount == 9'd1 && vcount_d != 9'd1), .freeze(ss_freeze),
		.park(ss_park), .all_parked(&(c_parked | {c_reset[4], c_reset[3], c_reset[2], c_reset[1], c_reset[0]})),
		.release_cpus(ss_release),
		.frame_in(frame_no), .frame_out(frame_ld), .frame_we,
		.op_req, .op_sec, .op_idx, .op_we, .op_wdata, .op_ack, .op_rdata,
		.so_valid, .so_data, .so_ready, .si_valid, .si_data, .si_ready
	);

	// =====================================================================
	// Video
	// =====================================================================
	logic        pix_valid;
	logic [7:0]  pix_x, pix_y, pix_r, pix_g, pix_b;
	logic [15:0] sx [3], sy [3], sc [3];
	always_comb
		for (int l = 0; l < 3; l++) begin
			sx[l] = v_scroll[l][0]; sy[l] = v_scroll[l][1]; sc[l] = v_scroll[l][2];
		end

	// 8x8 tiles in each scroll ROM - 1: scroll0/1 256 KB, 512 KB on F1 GP Star;
	// scroll2 64 KB on Cisco Heat, 128 KB elsewhere. Road tiles (32 bytes) and
	// sprite tiles (128 bytes) likewise; road1 has its own ROM on F1 GP Star
	// (1 MB, 2 MB on F-1 Grand Prix Star II).
	logic [13:0] tmask [3];
	assign tmask[0] = f1 ? 14'h3fff : 14'h1fff;
	assign tmask[1] = f1 ? 14'h3fff : 14'h1fff;
	assign tmask[2] = ch ? 14'h07ff : 14'h0fff;
	logic [25:0] rbase [2];
	logic [15:0] rmask [2];
	assign rbase[0] = 26'h0a00000;
	assign rbase[1] = f1 ? 26'h0c00000 : 26'h0a00000;
	assign rmask[0] = f1 ? 16'hffff : 16'h7fff;
	assign rmask[1] = io ? 16'hffff : 16'h7fff;

	cischeat_video u_video (
		.clk, .reset(sys_reset), .board, .frame_go, .y0(8'd16), .line_go, .vpos(line_vpos),
		.busy(), .overrun(video_overrun),
		.scroll_x(sx), .scroll_y(sy), .scroll_ctrl(sc),
		.tmap_base('{26'h02c0000, 26'h0340000, 26'h03c0000}),
		.tmap_mask(tmask),
		.road_base(rbase), .road_mask(rmask),
		.spr_base(26'h0400000), .spr_mask(f1 ? 16'hffff : 16'h7fff),
		.vram_addr, .vram_q, .rlist_addr, .rlist_q, .slist_addr, .slist_q, .pal_addr, .pal_q,
		.gfx_req, .gfx_addr, .gfx_valid, .gfx_rdata,
		.pix_valid, .pix_x, .pix_y, .pix_r, .pix_g, .pix_b, .pix_idx()
	);

	// display buffer: line y is read out during row y - 1 and shown in row y
	logic [23:0] disp_q;
	line_buffer #(.W(24)) u_disp (
		.clk,
		.a_we(pix_valid), .a_addr({pix_y[0], pix_x}), .a_d({pix_r, pix_g, pix_b}),
		.b_addr({vcount[0], hcount[7:0]}), .b_we(1'b0), .b_d('0), .b_q(disp_q)
	);

	always_ff @(posedge clk)
		if (ce_pix) begin
			hblank <= t_hblank;
			vblank <= t_vblank;
			hsync  <= t_hsync;
			vsync  <= t_vsync;
			{r, g, b} <= (t_hblank || t_vblank) ? 24'h000000 : disp_q;
		end

endmodule
