// SPDX-License-Identifier: GPL-3.0-or-later
//
// One ms1_tmap layer, one scanline: 33 8-pixel tile rows into a line buffer.
// Transcribes MAME's jaleco/ms1_tmap.cpp as scripts/render_model.py models it.
//
// ctrl[4] selects 8x8 tiles; ctrl[1:0] the page arrangement (pages_x x pages_y):
//   16x16 tiles: 16x2, 8x4, 4x8, 2x16    8x8 tiles: 8x1, 4x2, 4x2, 2x4
// A page is 256x256 px either way, and every arrangement fills 8,192 words.
// A 16x16 tile is four consecutive 8x8 codes: code*4 + row[0] + 2*col[0].
//
// Output: all 256 pixels of the line are written as {color, pen}; pen 15 is
// transparent and left to the mixer. The vram port is a registered read
// (q valid one clock after addr). gfx_req is a one-clock pulse per 64-bit
// granule (sdram_sched captures its rising edge); granule byte k is
// rdata[8k +: 8], the loader's little-endian order. The loader pairs tiles
// (cischeat_rom_transform.sv): the granule at {code[13:2], code[0], py} * 8
// holds row py of code (bytes 0..3) and of code + 2 (bytes 4..7), a tile row's
// first pixel in its first byte's high nibble. A 16x16 tile's two halves are
// codes c and c + 2, so its row is one fetch: a column reuses the granule the
// column before it fetched when the address is the same.
//
// The next tile's vram read and gfx fetch overlap the current tile's eight
// pixel writes.

module ms1_tmap_line (
	input  logic        clk,
	input  logic        reset,

	input  logic        start,       // pulse: render line vpos
	input  logic [7:0]  vpos,        // bitmap row, 0..255
	output logic        busy,

	input  logic [15:0] scroll_x,
	input  logic [15:0] scroll_y,
	input  logic [15:0] ctrl,
	input  logic        color5,      // 5-bit colour (cischeat) instead of 4
	input  logic [25:0] gfx_base,    // byte address of the layer's 8x8 tiles
	input  logic [13:0] code_mask,   // 8x8 tiles in the region - 1

	output logic [12:0] vram_addr,
	input  logic [15:0] vram_q,

	output logic        gfx_req,
	output logic [25:0] gfx_addr,
	input  logic        gfx_valid,
	input  logic [63:0] gfx_rdata,

	output logic        lb_we,
	output logic [7:0]  lb_x,
	output logic [8:0]  lb_d          // {color[4:0], pen[3:0]}
);

	// ---- geometry, fixed for the line ----------------------------------
	logic       tiles8;
	logic [2:0] lpx;         // log2(pages_x)
	logic [8:0] col_mask;    // 8-px columns - 1
	logic [8:0] row_mask;    // 8-px rows - 1

	always_comb begin
		tiles8 = ctrl[4];
		if (tiles8)
			case (ctrl[1:0])
				2'd0:    begin lpx = 3'd3; col_mask = 9'd255; row_mask = 9'd31;  end // 8x1
				2'd3:    begin lpx = 3'd1; col_mask = 9'd63;  row_mask = 9'd127; end // 2x4
				default: begin lpx = 3'd2; col_mask = 9'd127; row_mask = 9'd63;  end // 4x2
			endcase
		else
			case (ctrl[1:0])
				2'd0:    begin lpx = 3'd4; col_mask = 9'd511; row_mask = 9'd63;  end // 16x2
				2'd1:    begin lpx = 3'd3; col_mask = 9'd255; row_mask = 9'd127; end // 8x4
				2'd2:    begin lpx = 3'd2; col_mask = 9'd127; row_mask = 9'd255; end // 4x8
				default: begin lpx = 3'd1; col_mask = 9'd63;  row_mask = 9'd511; end // 2x16
			endcase
	end

	// ---- fetch side -----------------------------------------------------
	typedef enum logic [2:0] {F_IDLE, F_VADDR, F_VDATA, F_WAIT, F_HOLD} fstate_t;
	fstate_t fst;

	logic [8:0]  row;         // 8-px row, masked
	logic [2:0]  py;          // pixel row within the 8x8 tile
	logic [8:0]  col;         // 8-px column, masked
	logic [5:0]  tile;        // tiles issued this line, 0..33

	logic        f_half;      // which half of the granule holds the row
	logic [4:0]  f_color;
	logic [63:0] f_gran;
	logic        g_have;      // f_gran holds granule g_addr from this line
	logic [25:0] g_addr, g_next;

	// vram word for (col, row)
	//   8x8:   col*32 + (row>>5)*1024*pages_x + row%32
	//   16x16: (col>>1)*16 + (row>>5)*256*pages_x + (row>>1)%16
	logic [12:0] vidx;
	always_comb begin
		if (tiles8)
			vidx = 13'(({17'd0, row[8:5]} << (10 + lpx)) | ({12'd0, col} << 5) | {16'd0, row[4:0]});
		else
			vidx = 13'(({17'd0, row[8:5]} << (8 + lpx)) | ({13'd0, col[8:1]} << 4) | {17'd0, row[4:1]});
	end

	// 8x8 code for the word just read
	assign vram_addr = vidx;

	logic [13:0] code;
	always_comb begin
		if (tiles8) code = {2'b00, vram_q[11:0]};
		else       code = {vram_q[11:0], col[0], row[0]};
		code = code & code_mask;
	end
	assign g_next = gfx_base + {7'd0, code[13:2], code[0], py, 3'b000};

	// ---- pixel side ------------------------------------------------------
	logic        p_busy;
	logic [2:0]  p_cnt;
	logic [31:0] p_row;
	logic [4:0]  p_color;
	logic [9:0]  p_x;         // signed screen x of the next pixel

	logic        p_load;      // fetch side hands a tile to the pixel side
	assign p_load = (fst == F_HOLD) && (!p_busy || p_cnt == 3'd7);

	assign busy = (fst != F_IDLE) || p_busy;

	always_ff @(posedge clk) begin
		if (reset) begin
			fst     <= F_IDLE;
			gfx_req <= 1'b0;
		end else begin
			gfx_req <= 1'b0;
			case (fst)
				F_IDLE: if (start) begin
					// row/py from the bitmap row; col from the coarse x scroll
					{row, py} <= 12'(({4'd0, vpos} + scroll_y[11:0])) & {row_mask, 3'b111};
					col       <= scroll_x[11:3] & col_mask;
					tile      <= 6'd0;
					g_have    <= 1'b0;
					fst       <= F_VADDR;
				end

				F_VADDR: fst <= F_VDATA;   // vram_addr = vidx is presented

				F_VDATA: begin
					f_half  <= code[1];
					f_color <= color5 ? vram_q[15:11] : {1'b0, vram_q[15:12]};
					if (g_have && g_addr == g_next)
						fst <= F_HOLD;
					else begin
						gfx_addr <= g_next;
						gfx_req  <= 1'b1;
						g_addr   <= g_next;
						fst      <= F_WAIT;
					end
				end

				F_WAIT: if (gfx_valid) begin
					f_gran <= gfx_rdata;
					g_have <= 1'b1;
					fst    <= F_HOLD;
				end

				F_HOLD: if (p_load) begin
					col  <= (col + 9'd1) & col_mask;
					tile <= tile + 6'd1;
					fst  <= (tile == 6'd32) ? F_IDLE : F_VADDR;
				end

				default: fst <= F_IDLE;
			endcase
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			p_busy <= 1'b0;
			lb_we  <= 1'b0;
		end else begin
			lb_we <= 1'b0;
			if (fst == F_IDLE && start)
				p_x <= -{7'd0, scroll_x[2:0]};
			if (p_busy) begin
				// p_x is 0..255 when on screen; the sign bit or bit 8 is off it
				lb_we   <= (p_x[9:8] == 2'b00);
				lb_x    <= p_x[7:0];
				lb_d    <= {p_color, p_row[31:28]};
				p_row   <= {p_row[27:0], 4'h0};
				p_x     <= p_x + 10'd1;
				p_cnt   <= p_cnt + 3'd1;
				if (p_cnt == 3'd7) p_busy <= 1'b0;
			end
			if (p_load) begin
				p_busy  <= 1'b1;
				p_cnt   <= 3'd0;
				p_color <= f_color;
				// bytes 0..3 (or 4..7) with byte 0's high nibble first
				p_row   <= f_half ? {f_gran[39:32], f_gran[47:40], f_gran[55:48], f_gran[63:56]}
				                  : {f_gran[7:0],   f_gran[15:8],  f_gran[23:16], f_gran[31:24]};
			end
		end
	end

endmodule
