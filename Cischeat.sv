// SPDX-License-Identifier: GPL-3.0-or-later
//
// Cisco Heat for MiSTer: framework glue. hps_io and the OSD, the PLL, resets
// and the fast ROM load, input assembly and the DIPs, the video output chain.
// The board is rtl/cischeat_board.sv, its memory rtl/memory/cischeat_sdram.sv.
//
// Clocks (docs/ROADMAP.md, Clocks): clk_sys 48 MHz for the board and the video
// output, clk_mem 96 MHz for the SDRAM controller and the ROM load, SDRAM_CLK
// 96 MHz at 180 degrees. All three from one PLL, edges aligned.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports this core does not use /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign FB_FORCE_BLANK = 0;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[77:76];

assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// Horizontal game: rotation is the HDMI option only
wire [1:0] rot_sel    = status[64:63];
wire       rotate_en  = rot_sel != 2'd0;
wire       rotate_ccw = rot_sel == 2'd2;
wire       flip_180   = status[65];

// 4:3 screen (3:4 when rotated), whatever the pixel count
wire [11:0] base_arx = rotate_en ? 12'd3 : 12'd4;
wire [11:0] base_ary = rotate_en ? 12'd4 : 12'd3;

`include "build_id.v"

// The Debug page (H1) is shown only in the Cischeat_stp revision
`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif

// joystick bit 4 + i is entry i, matching the .mra's <buttons>
localparam CONF_STR = {
	"Cischeat;;",
	"-;",
	"H5O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H5O[64:63],Rotation,Off,CW,CCW;",
	"H5O[65],Flip 180,Off,On;",
	"H5O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"H5O[70:69],Crop,Off,216 lines,224 lines;",
	"H5O[75:71],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H5O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[77:76],Audio mix,No,25%,50%,Mono;",
	"O[94],CRT Adjust,Off,On;",
	"H2O[101:95],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[107:102],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[112:108],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[116:113],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[117],CRT V-Size Mode,PVM,Cabinet;",
	"-;",
	"DIP;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[82],Pause CPU,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J1,Brake,Gear Shift,Accelerator,Horn,-,-,-,-,Start,Coin,Pause,Service;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler, direct_video;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire [31:0]  joystick_0, joystick_1;
wire [15:0]  joystick_l_analog_0, joystick_l_analog_1;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	// H1 the Debug page, H2 CRT Adjust's settings while it is off, H5 HDMI-only options
	.status_menumask({direct_video, 2'b00, ~status[94], DEBUG_MENU_HIDE, 1'b0}),
	.direct_video(direct_video),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_mem, clk_sdram_shifted, clk_sys, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),
	.outclk_1(clk_sdram_shifted),
	.outclk_2(clk_sys),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

///////////////////////   RESET AND ROM LOAD   ///////////////////

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// The .mra's index-0 ROM has address="0x30000000": the HPS puts it in DDR3 and
// the download carries no ioctl_wr. The copy into SDRAM starts when reset
// releases after such a download; ldr_done stops later resets copying again.
// The board is held until a copy has finished; the memory path is never held
// during the download or the copy (LESSONS_LEARNED, "Never hold the memory
// path in the core reset").
wire ldr_active;
reg  rom_loaded = 1'b0, ldr_active_d = 1'b0;
reg  dl_active_d = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0;
reg  ldr_done = 1'b0, dl_seen_wr = 1'b0;
wire dl_index0 = ioctl_download && (ioctl_index == 16'd0);

always @(posedge clk_sys) begin
	ldr_start    <= 1'b0;
	ldr_active_d <= ldr_active;
	dl_active_d  <= dl_index0;
	if (dl_index0 && !dl_active_d)  dl_seen_wr <= 1'b0;
	else if (dl_index0 && ioctl_wr) dl_seen_wr <= 1'b1;
	if (dl_index0 && !dl_active_d)  ldr_done <= 1'b0;

	if (reset) begin
		ldr_pending <= 1'b1;
	end else if (ldr_pending && !ioctl_download && !ldr_active) begin
		ldr_pending <= 1'b0;
		if (!dl_seen_wr && !ldr_done) begin
			ldr_start <= 1'b1;
			ldr_done  <= 1'b1;
		end
	end
	if (ldr_active_d && !ldr_active) rom_loaded <= 1'b1;
end

wire core_reset = reset | ioctl_download | ~rom_loaded | ldr_active;
wire mem_reset  = reset & ~ioctl_download;

reg [1:0] ldr_reset_s = 2'b11;
always @(posedge clk_mem) ldr_reset_s <= {ldr_reset_s[0], mem_reset};

wire        dl_req, dl_we16, dl_busy;
wire [25:0] dl_addr;
wire [15:0] dl_data;

wire [7:0]  ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
wire [63:0] ldr_DDRAM_DIN;

// ldr_start is one clk_sys cycle, two clk_mem cycles; the loader takes the first
cischeat_rom_load u_rom_load (
	.clk(clk_mem), .reset(ldr_reset_s[1]), .gs88000(board == 3'd1),
	.start(ldr_start), .length(28'h0f00000), .busy(ldr_active),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT), .DDRAM_ADDR(ldr_DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.dl_req, .dl_addr, .dl_data, .dl_we16, .dl_busy
);

///////////////////   .mra: board byte   ///////////////////////

// index 1, byte 0: 0 Big Run, 1 Cisco Heat, 2 F1 GP Star (docs/ROADMAP.md, Per-game
// configuration). Held across resets; a new .mra writes it before index 0.
reg [2:0] board = 3'd1;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd1) && !ioctl_addr[24:0])
		board <= ioctl_dout[2:0];

///////////////////   .mra: DIPs   ///////////////////////////////

// <switches> (index 254): sw[0], sw[1] = IN4 low and high byte (DSW 1 and 2),
// sw[2] = IN5 (DSW 3)
reg [7:0] sw [4];
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:2])
		sw[ioctl_addr[1:0]] <= ioctl_dout;

///////////////////////   INPUTS   ///////////////////////////////

// MiSTer joystick: 0 R, 1 L, 2 D, 3 U; 4 Brake, 5 Gear Shift, 6 Accelerator,
// 7 Horn, 12 Start, 13 Coin, 14 Pause, 15 Service. The driver's ports are
// active low (cischeat.cpp, INPUT_PORTS_START( cischeat )).
wire [31:0] joy = joystick_0;

// Gear Shift is PORT_TOGGLE in MAME: each press flips low/high gear
reg gear_btn_d = 1'b0, gear = 1'b0;
always @(posedge clk_sys) begin
	gear_btn_d <= joy[5];
	if (reset)                   gear <= 1'b0;
	else if (joy[5] && !gear_btn_d) gear <= ~gear;
end

// Pause toggles on its button; the Debug page's Pause CPU is ORed in
reg pause_btn_d = 1'b0, pause_toggle = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= joy[14];
	if (reset)                         pause_toggle <= 1'b0;
	else if (joy[14] && !pause_btn_d)  pause_toggle <= ~pause_toggle;
end
wire pause_core = pause_toggle | status[82];

// Wheel (IN6, a paddle centred on 0x80): the left stick's X where it is off
// centre, otherwise a position the d-pad moves 4 a frame and that returns to
// the centre when released. Direction unverified (docs/HACKS.md).
wire signed [7:0] ana_x = joystick_l_analog_0[7:0];
wire        ana_on = (ana_x > 8'sd8) || (ana_x < -8'sd8);
reg  [7:0]  wheel_d = 8'h80;
wire        vblank;
reg         vblank_d = 1'b0;
always @(posedge clk_sys) begin
	vblank_d <= vblank;
	if (reset) wheel_d <= 8'h80;
	else if (vblank && !vblank_d) begin
		if (joy[0] && !joy[1])      wheel_d <= wheel_d > 8'hfb ? 8'hff : wheel_d + 8'd4;
		else if (joy[1] && !joy[0]) wheel_d <= wheel_d < 8'h04 ? 8'h00 : wheel_d - 8'd4;
		else if (wheel_d > 8'h80)   wheel_d <= wheel_d - 8'd4 < 8'h80 ? 8'h80 : wheel_d - 8'd4;
		else if (wheel_d < 8'h80)   wheel_d <= wheel_d + 8'd4 > 8'h80 ? 8'h80 : wheel_d + 8'd4;
	end
end
wire [7:0] wheel = ana_on ? 8'h80 + ana_x : wheel_d;

// Ports by board (INPUT_PORTS_START bigrun / cischeat / f1gpstar). Big Run and
// Cisco Heat: IN1 coins and starts, IN2 controls, IN3 limit switches, IN4 DSW 1-2,
// IN5 (dsw3) DSW 3. F1 GP Star: IN1 DSW 1-2, IN2 coins, starts, gear and brake,
// IN3 unused, IN4 DSW 3.
// The accelerator is the digital IN2 bit 4 on Cisco Heat and a PEDAL port
// elsewhere, 0x00 released to 0xff (cischeat.cpp 1320), read inverted on
// F1 GP Star (PORT_REVERSE). The button gives full travel, the left stick
// pushed up the analogue range.
wire is_bigrun = board == 3'd0;
wire is_f1     = board >= 3'd2;
wire signed [7:0] ana_y = joystick_l_analog_0[15:8];
wire [7:0]  pedal = joy[6] ? 8'hff : (ana_y < -8'sd8) ? {~ana_y[6:0], 1'b1} : 8'h00;
wire [7:0]  coins = {2'b11, 1'b1, ~joy[12], 1'b1, ~joy[15], ~joystick_1[13], ~joy[13]};
// Wild Pilot (INPUT_PORTS_START( wildplt )): IN0 DSW 1-2; the mux's IN1_1 (in2),
// IN1_2 (in3) and IN1_COMMON (in4); buttons 4 Shot, 5 Missile, 6 Bomb per player;
// the two AD sticks on wheel and pedal as {x, y}, y PORT_REVERSE.
wire is_wp = board == 3'd4;
wire [31:0] joy2 = joystick_1;
wire [15:0] wp_in2 = {13'h1fff, ~joy[15], 2'b11};
wire [15:0] wp_in3 = {7'h7f, ~joy2[6], ~joy[5], ~joy[4], ~joy2[5], ~joy2[4], ~joy2[12], ~joy[12], ~joy[6], 1'b1};
wire [15:0] wp_in4 = {15'h7fff, ~(joy[13] | joy2[13])};

function automatic [7:0] stick_x(input [15:0] ana, input [3:0] dpad);
	reg signed [7:0] a;
	begin
		a = ana[7:0];
		stick_x = (a > 8'sd8 || a < -8'sd8) ? 8'h80 + a : dpad[0] ? 8'hff : dpad[1] ? 8'h00 : 8'h80;
	end
endfunction
function automatic [7:0] stick_y_rev(input [15:0] ana, input [3:0] dpad);
	reg signed [7:0] a;
	begin
		a = ana[15:8];
		stick_y_rev = (a > 8'sd8 || a < -8'sd8) ? 8'h7f - a : dpad[3] ? 8'hff : dpad[2] ? 8'h00 : 8'h7f;
	end
endfunction
wire [15:0] wp_p1 = {stick_x(joystick_l_analog_0, joy[3:0]), stick_y_rev(joystick_l_analog_0, joy[3:0])};
wire [15:0] wp_p2 = {stick_x(joystick_l_analog_1, joy2[3:0]), stick_y_rev(joystick_l_analog_1, joy2[3:0])};

wire [15:0] in1 = is_f1 ? {sw[1], sw[0]} : {8'hff, coins};
wire [15:0] in2 = is_wp ? wp_in2 :
                  is_f1 ? {8'hff, ~joystick_1[12], ~joy[4], ~gear, coins[4:0]} :
                  {8'hff, ~joy[7], 2'b11, ~joy[6] | is_bigrun, 2'b11, ~gear, ~joy[4]};
wire [15:0] in3 = is_wp ? wp_in3 : 16'hffff; // cockpit limit switches, all off
wire [15:0] in4 = is_wp ? wp_in4 : is_f1 ? {8'hff, sw[2]} : {sw[1], sw[0]};
wire [15:0] dsw3 = {8'hff, sw[2]};
wire [7:0]  pedal_port = is_f1 ? ~pedal : pedal;

///////////////////////   THE BOARD   ////////////////////////////

wire [4:0]  ext_req, ext_we, ext_ready;
wire [25:1] ext_addr [5];
wire [15:0] ext_wdata [5], ext_rdata [5];
wire [1:0]  ext_be [5];
wire [8:0]  gfx_req, gfx_valid;
wire [25:0] gfx_addr [9];
wire [63:0] gfx_rdata [9];
wire [1:0]  snd_req, snd_valid;
wire [25:0] snd_addr [2];
wire [63:0] snd_rdata;

wire       core_ce, core_hb, core_vb, core_hs, core_vs, video_overrun;
wire        dbg_stb;
wire [23:1] dbg_addr;
wire [7:0] core_r, core_g, core_b;
assign vblank = core_vb;

cischeat_board u_board (
	.clk(clk_sys), .reset(core_reset), .pause(pause_core),
	.board, .in1, .in2, .in3, .in4, .dsw3, .wheel(is_wp ? wp_p1 : {8'hff, wheel}), .pedal(is_wp ? wp_p2 : {8'h00, pedal_port}),
	.ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_be, .ext_ready, .ext_rdata,
	.gfx_req, .gfx_addr, .gfx_valid, .gfx_rdata,
	.snd_req, .snd_addr, .snd_valid, .snd_rdata,
	.ce_pix(core_ce), .hblank(core_hb), .vblank(core_vb), .hsync(core_hs), .vsync(core_vs),
	.r(core_r), .g(core_g), .b(core_b),
	.video_overrun,
	.audio_l(AUDIO_L), .audio_r(AUDIO_R),
	.ss_save(1'b0), .ss_load(1'b0), .ss_busy(), .ss_error(),
	.so_valid(), .so_data(), .so_ready(1'b1),
	.si_valid(1'b0), .si_data(16'd0), .si_ready(),
	.dbg_stb, .dbg_we(), .dbg_addr, .dbg_data(), .dbg_uds(), .dbg_lds()
);

cischeat_sdram u_sdram (
	.clk(clk_sys), .clk_mem, .reset(core_reset), .mem_reset, .init(~pll_locked),
	.ext_req, .ext_we, .ext_addr, .ext_wdata, .ext_be, .ext_ready, .ext_rdata,
	.gfx_req, .gfx_addr, .gfx_valid, .gfx_rdata,
	.snd_req, .snd_addr, .snd_valid, .snd_rdata,
	.dl_req, .dl_addr, .dl_data, .dl_we16, .dl_busy,
	.SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
	.SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE
);

`ifdef DEBUG_ISSP
// Instance F (scripts/read_issp.tcl's fields_F): [15:0] frames, [38:16] the main CPU's last bus word
// address (A23-A1), [54:39] its bus cycles, [59:55] overrun, ldr_active, rom_loaded, core_reset,
// ioctl_download, [60] pause, [127] pll_locked. Source bit 0 clears the counters.
reg  [15:0] issp_frames = 16'd0, issp_cycles = 16'd0;
reg  [23:0] issp_addr = 24'd0;
reg         issp_vb_d = 1'b0;
wire        issp_clear;
always @(posedge clk_sys) begin
	issp_vb_d <= core_vb;
	if (issp_clear) begin
		issp_frames <= 16'd0;
		issp_cycles <= 16'd0;
	end else begin
		if (core_vb && !issp_vb_d) issp_frames <= issp_frames + 16'd1;
		if (dbg_stb)               issp_cycles <= issp_cycles + 16'd1;
	end
	if (dbg_stb) issp_addr <= {dbg_addr, 1'b0};
end
altsource_probe #(
	.sld_auto_instance_index("YES"), .instance_id("F"),
	.probe_width(128), .source_width(1), .source_initial_value("0"),
	.enable_metastability("NO"), .lpm_type("altsource_probe")
) u_issp_f (
	.probe({pll_locked, 66'd0, pause_core, ioctl_download, core_reset, rom_loaded, ldr_active,
	        video_overrun, issp_cycles, issp_addr[23:1], issp_frames}),
	.source(issp_clear), .source_clk(clk_sys), .source_ena(1'b1)
);
`endif

assign LED_USER = ioctl_download | ldr_active;
// a video line that did not finish in time, latched until reset
assign LED_DISK = {1'b1, video_overrun};

///////////////////////   VIDEO   ////////////////////////////////

// CRT Adjust (rtl/video/crt_chain.sv): moves the picture inside the line, sync untouched; HDMI
// follows it. H-Position's list has 97 entries, so its negative half wraps at 97; V-Size's 15 at 15.
wire crt_adj_on   = status[94];
wire crt_scale_en = ~(forced_scandoubler | |status[46:44]);
wire  [6:0] crt_hpos_idx = status[101:95];
wire signed [8:0] crt_hoffset = (crt_hpos_idx <= 7'd48) ? $signed({2'b00, crt_hpos_idx})
                                                         : $signed({2'b00, crt_hpos_idx}) - 9'sd97;
wire signed [5:0] crt_voffset = $signed(status[107:102]);
wire signed [4:0] crt_hsize   = $signed(status[112:108]);
wire  [3:0] crt_vsz_idx  = status[116:113];
wire signed [3:0] crt_vsz_step = (crt_vsz_idx <= 4'd7) ? $signed(crt_vsz_idx) : $signed(crt_vsz_idx - 4'd15);

wire       crt_ce;
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb;

// 8 clk a pixel, x4; rows 240-243 lie between the picture and VSync
crt_chain #(.HTOTAL(384), .VTOTAL(260), .ACTIVE_W(256), .RD_BASE(32), .PVM_FREE_LINES(4)) crt_chain
(
	.clk(clk_sys), .ce_pix(core_ce),
	.active(crt_adj_on), .scale_en(crt_scale_en),
	.hoffset(crt_hoffset), .voffset(crt_voffset), .hsize(crt_hsize),
	.vsize_step(crt_vsz_step), .vsize_cabinet(status[117]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.ce_out(crt_ce), .r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

wire vga_de_raw;

arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_ce),

	.RGB_in({crt_r, crt_g, crt_b}),
	.HBlank(crt_hb),
	.VBlank(crt_vb),
	.HSync(crt_hs),
	.VSync(crt_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

wire  [1:0] vcrop_sel = status[70:69];
wire [11:0] crop_size = (vcrop_sel == 2'd1) ? 12'd216 :
                        (vcrop_sel == 2'd2) ? 12'd224 : 12'd0;

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX((!ar) ? base_arx : (ar - 1'd1)),
	.ARY((!ar) ? base_ary : 12'd0),
	.CROP_SIZE(crop_size),
	.CROP_OFF(status[75:71]),
	.SCALE(status[68:66])
);

// HDMI rotation and flip through DDR3; the analog output keeps the raster.
// DDR3 is the ROM loader's while it copies (board in reset, no picture).
wire        rot_DDRAM_CLK, rot_DDRAM_WE, rot_DDRAM_RD;
wire [7:0]  rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;

screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(flip_180),
	.two_screen(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_active),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR(rot_DDRAM_ADDR),
	.DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE),
	.DDRAM_WE(rot_DDRAM_WE),
	.DDRAM_RD(rot_DDRAM_RD)
);

assign DDRAM_CLK      = ldr_active ? clk_mem            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : rot_DDRAM_RD;

endmodule
