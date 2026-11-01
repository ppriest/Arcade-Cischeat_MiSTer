// SPDX-License-Identifier: GPL-3.0-or-later
//
// The board's memory clients on the SDRAM: five CPU ports and nine gfx clients
// in the clk (48 MHz) domain, onto sdram_sched (bank-interleaved, clk_mem 96 MHz,
// 2 x clk, same PLL, rising edges aligned).
//
// Crossing: a client's request is a level from a clk register, held until its
// valid; the scheduler captures its rising edge. Its one-cycle valid is
// stretched to two clk_mem cycles, which covers exactly one clk edge, and is
// registered there with the shared read data (held until the next granule
// returns, 4 or more clk_mem cycles later).
//
// CPU ports (clk): a request is a rising edge of ext_req; ext_ready is one
// clock. Each port keeps the last granule it read (ready the next clock), so the
// line fills of fx68k_bus (eight word requests) cost two lookups, and a
// 256-granule direct-mapped cache behind it (ready a clock later), so a loop's
// code is read from the SDRAM once. Port 3, the sound CPU, also writes (its work
// RAM); a write drops the granule and the cache entry at its index. No other
// port can hold sound work RAM.
//
// gfx clients (clk): gfx_req is a one-clock pulse, gfx_valid one clock with
// gfx_rdata; the address is taken with the request.
//
// Sample clients (clk, the two OKI caches): snd_req is held until snd_valid,
// one clock with snd_rdata; a request is its rising edge.
//
// Bank remap: every address goes to the scheduler with bits 4:3 XORed with bits
// 8:7 (swz, its own inverse). The gfx regions hold 128-byte tiles of 16 eight-byte
// rows, so bits 4:3 are a tile's row and a line's fetches along one row would all
// land in one bank, one every tRC; with the tile code's low bits in the bank they
// interleave. The download goes through the same remap, so the layout is unchanged
// for every client.
//
// Word k of a granule is bits 16k+15..16k, the word at the granule's address
// plus 2k; in a word, bits 15..8 are the 68000's even byte.

module cischeat_sdram (
	input  logic         clk,
	input  logic         clk_mem,
	input  logic         reset,         // clk domain: the clients (ports, granules)
	input  logic         mem_reset,     // clk domain: the arbiter and phy; low during a ROM load
	input  logic         init,          // sdram.sv's power-up sequence restarts on its fall

	input  logic [4:0]   ext_req,
	input  logic [4:0]   ext_we,
	input  logic [25:1]  ext_addr [5],
	input  logic [15:0]  ext_wdata [5],
	input  logic [1:0]   ext_be [5],
	output logic [4:0]   ext_ready,
	output logic [15:0]  ext_rdata [5],

	input  logic [8:0]   gfx_req,
	input  logic [25:0]  gfx_addr [9],
	output logic [8:0]   gfx_valid,
	output logic [63:0]  gfx_rdata [9],

	input  logic [1:0]   snd_req,
	input  logic [25:0]  snd_addr [2],
	output logic [1:0]   snd_valid,
	output logic [63:0]  snd_rdata,

	// ROM download, clk_mem domain (sdram_download's port)
	input  logic         dl_req,
	input  logic [25:0]  dl_addr,
	input  logic [15:0]  dl_data,
	input  logic         dl_we16,
	output logic         dl_busy,

	inout  wire  [15:0]  SDRAM_DQ,
	output logic [12:0]  SDRAM_A,
	output logic         SDRAM_DQML,
	output logic         SDRAM_DQMH,
	output logic [1:0]   SDRAM_BA,
	output logic         SDRAM_nCS,
	output logic         SDRAM_nWE,
	output logic         SDRAM_nRAS,
	output logic         SDRAM_nCAS,
	output logic         SDRAM_CKE
);

	localparam int N = 16;              // 0-4 CPU ports, 5-13 gfx, 14-15 samples

	function automatic logic [25:0] swz(input logic [25:0] a);
		return {a[25:5], a[4:3] ^ a[8:7], a[2:0]};
	endfunction

	// ---- clk side: requests ------------------------------------------
	logic [N-1:0]  req;                 // to the arbiter, held until valid
	logic [25:0]   addr [N];
	logic [4:0]    we, we16;
	logic [15:0]   wd [5];
	logic [N-1:0]  valid;               // from the arbiter, one clk
	logic [63:0]   rdata;

	// CPU ports: the last granule read (L0, ready the next clock), then a
	// 256-granule direct-mapped cache (ready the clock after), then the SDRAM.
	// A write drops the L0 granule and the cache entry at its index.
	logic [4:0]    ext_req_d;
	logic [4:0]    g_ok;                // the port's L0 granule is held
	logic [25:3]   g_tag [5];
	logic [63:0]   g_data [5];

	always_ff @(posedge clk) ext_req_d <= reset ? 5'h0 : ext_req;

	genvar gp;
	generate
		for (gp = 0; gp < 5; gp++) begin : port
			logic [63:0]  c_data [0:255];
			logic [14:0]  c_tag  [0:255];   // granule address bits 25:11
			logic [255:0] c_ok;
			logic [63:0]  c_dq;
			logic [14:0]  c_tq;
			logic         look, fill_we;
			logic [25:1]  la;
			logic [25:0]  ra;            // the request's own address (swz undone)
			assign ra = swz(addr[gp]);
			logic [7:0]   fill_i;
			logic [63:0]  fill_d;
			logic [14:0]  fill_t;

			always_ff @(posedge clk) begin
				c_dq <= c_data[ext_addr[gp][10:3]];
				c_tq <= c_tag[ext_addr[gp][10:3]];
				if (fill_we) begin
					c_data[fill_i] <= fill_d;
					c_tag[fill_i]  <= fill_t;
				end
			end

			always_ff @(posedge clk) begin
				ext_ready[gp] <= 1'b0;
				fill_we       <= 1'b0;
				if (reset) begin
					req[gp]  <= 1'b0;
					g_ok[gp] <= 1'b0;
					c_ok     <= '0;
					look     <= 1'b0;
				end else if (ext_req[gp] && !ext_req_d[gp]) begin
					if (ext_we[gp]) begin
						req[gp]  <= 1'b1;
						addr[gp] <= swz({ext_addr[gp], ext_be[gp] == 2'b10});
						we[gp]   <= 1'b1;
						we16[gp] <= ext_be[gp] == 2'b11;
						wd[gp]   <= ext_be[gp] == 2'b10 ? {8'h00, ext_wdata[gp][15:8]} : ext_wdata[gp];
						if (g_tag[gp] == ext_addr[gp][25:3]) g_ok[gp] <= 1'b0;
						c_ok[ext_addr[gp][10:3]] <= 1'b0;
					end else if (g_ok[gp] && g_tag[gp] == ext_addr[gp][25:3]) begin
						ext_rdata[gp] <= g_data[gp][16 * ext_addr[gp][2:1] +: 16];
						ext_ready[gp] <= 1'b1;
					end else begin
						look <= 1'b1;
						la   <= ext_addr[gp];
					end
				end else if (look) begin
					look <= 1'b0;
					if (c_ok[la[10:3]] && c_tq == la[25:11]) begin
						g_ok[gp]      <= 1'b1;
						g_tag[gp]     <= la[25:3];
						g_data[gp]    <= c_dq;
						ext_rdata[gp] <= c_dq[16 * la[2:1] +: 16];
						ext_ready[gp] <= 1'b1;
					end else begin
						req[gp]  <= 1'b1;
						addr[gp] <= swz({la[25:3], 3'b000});
						we[gp]   <= 1'b0;
						g_ok[gp] <= 1'b0;
					end
				end else if (req[gp] && valid[gp]) begin
					req[gp]       <= 1'b0;
					ext_ready[gp] <= 1'b1;
					if (!we[gp]) begin
						g_ok[gp]      <= 1'b1;
						g_tag[gp]     <= ra[25:3];
						g_data[gp]    <= rdata;
						ext_rdata[gp] <= rdata[16 * ext_addr[gp][2:1] +: 16];
						fill_we       <= 1'b1;
						fill_i        <= ra[10:3];
						fill_d        <= rdata;
						fill_t        <= ra[25:11];
						c_ok[ra[10:3]] <= 1'b1;
					end
				end
			end
		end
	endgenerate

	// gfx clients
	always_ff @(posedge clk)
		for (int c = 0; c < 9; c++) begin
			gfx_valid[c] <= 1'b0;
			if (reset)
				req[5 + c] <= 1'b0;
			else if (gfx_req[c]) begin
				req[5 + c]  <= 1'b1;
				addr[5 + c] <= swz({gfx_addr[c][25:3], 3'b000});
			end else if (req[5 + c] && valid[5 + c]) begin
				req[5 + c]   <= 1'b0;
				gfx_valid[c] <= 1'b1;
			end
		end

	always_comb for (int c = 0; c < 9; c++) gfx_rdata[c] = rdata;

	// sample clients
	logic [1:0] snd_req_d;
	always_ff @(posedge clk)
		for (int c = 0; c < 2; c++) begin
			snd_valid[c] <= 1'b0;
			snd_req_d[c] <= reset ? 1'b0 : snd_req[c];
			if (reset)
				req[14 + c] <= 1'b0;
			else if (snd_req[c] && !snd_req_d[c]) begin
				req[14 + c]  <= 1'b1;
				addr[14 + c] <= swz({snd_addr[c][25:3], 3'b000});
			end else if (req[14 + c] && valid[14 + c]) begin
				req[14 + c]  <= 1'b0;
				snd_valid[c] <= 1'b1;
			end
		end

	assign snd_rdata = rdata;

	// ---- clk_mem side --------------------------------------------------
	logic          m_reset, m_reset_s;
	always_ff @(posedge clk_mem) {m_reset, m_reset_s} <= {m_reset_s, mem_reset};

	logic [N-1:0]    a_valid, a_valid_d;
	logic [63:0]     a_rdata;
	logic [26*N-1:0] a_addr;
	logic [16*N-1:0] a_wdata;
	logic [N-1:0]    a_we, a_we16;

	always_comb begin
		for (int k = 0; k < N; k++) a_addr[26*k +: 26] = addr[k];
		a_wdata = '0;
		a_we    = '0;
		a_we16  = '0;
		for (int k = 0; k < 5; k++) begin
			a_wdata[16*k +: 16] = wd[k];
			a_we[k]             = we[k];
			a_we16[k]           = we16[k];
		end
	end

	always_ff @(posedge clk_mem) a_valid_d <= m_reset ? '0 : a_valid;

	// back in clk: the stretched valid is seen at exactly one edge
	always_ff @(posedge clk) begin
		valid <= reset ? '0 : (a_valid | a_valid_d);
		if (|(a_valid | a_valid_d)) rdata <= a_rdata;
	end

	// sprites (gfx clients 5-8, ports 10-13) only when nothing else can be served:
	// their engine has a cutoff, the tilemaps and roads do not
	sdram_sched #(.N(N), .LOW(16'h3c00)) u_sched (
		.clk(clk_mem), .reset(m_reset), .init,
		.c_req(req), .c_addr(a_addr), .c_we(a_we), .c_we16(a_we16), .c_wdata(a_wdata),
		.c_valid(a_valid), .c_rdata(a_rdata),
		.dl_req, .dl_addr(swz(dl_addr)), .dl_data, .dl_we16, .dl_busy,
		.SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
		.SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE
	);

endmodule
