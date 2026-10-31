// SPDX-License-Identifier: GPL-3.0-or-later
//
// One jaleco_road layer, one scanline, fixed-width format (Cisco Heat, Big Run).
// Transcribes MAME's jaleco/jaleco_road.cpp as scripts/render_model.py models it.
//
// The line list holds four words per bitmap row: code, x scroll, attribute,
// unused. A row is 16 tiles of 64x1 pixels, 1,024 px wide and wrapping:
// screen x reads source (scroll + x) & 0x3ff, tile (code << 4) | source >> 6.
// The attribute's bits 10-8 are the line's priority and bits 5-0 its colour.
//
// Output: all 256 pixels as {color[5:0], pen[3:0]}, and the line's priority
// on lb_pri (valid from the first lb_we to the next start). Transparency and
// the priority window are the mixer's. The list port is a registered read.
// gfx_req is a one-clock pulse per 64-bit granule; a granule is 16 pixels,
// low nibble first, granule byte k at rdata[8k +: 8].

module jaleco_road_line (
	input  logic        clk,
	input  logic        reset,

	input  logic        start,       // pulse: render line vpos
	input  logic [7:0]  vpos,        // bitmap row, 0..255
	output logic        busy,

	input  logic [25:0] gfx_base,    // byte address of the layer's 64x1 tiles
	input  logic [15:0] code_mask,   // tiles in the region - 1

	output logic [9:0]  list_addr,
	input  logic [15:0] list_q,

	output logic        gfx_req,
	output logic [25:0] gfx_addr,
	input  logic        gfx_valid,
	input  logic [63:0] gfx_rdata,

	output logic        lb_we,
	output logic [7:0]  lb_x,
	output logic [9:0]  lb_d,         // {color[5:0], pen[3:0]}
	output logic [2:0]  lb_pri
);

	typedef enum logic [2:0] {F_IDLE, F_CODE, F_SCROLL, F_ATTR, F_REQ, F_WAIT, F_HOLD} fstate_t;
	fstate_t fst;

	logic [7:0]  vpos_l;
	logic [15:0] code;
	logic [5:0]  gran;        // 16-px granule within the 1,024-px row
	logic [4:0]  issued;      // granules issued this line, 0..17
	logic [5:0]  f_color;
	logic [63:0] f_gran;

	// F_CODE/F_SCROLL/F_ATTR present words 0-2; each is read a clock later
	always_comb
		case (fst)
			F_IDLE:   list_addr = {vpos, 2'd0};
			F_CODE:   list_addr = {vpos_l, 2'd1};
			default:  list_addr = {vpos_l, 2'd2};
		endcase

	logic [15:0] tile;
	assign tile = {code[11:0], gran[5:2]} & code_mask;

	// ---- pixel side ------------------------------------------------------
	logic        p_busy;
	logic [3:0]  p_cnt;
	logic [63:0] p_row;
	logic [9:0]  p_x;         // signed screen x of the next pixel

	logic        p_load;
	assign p_load = (fst == F_HOLD) && (!p_busy || p_cnt == 4'd15);

	assign busy = (fst != F_IDLE) || p_busy;

	always_ff @(posedge clk) begin
		if (reset) begin
			fst     <= F_IDLE;
			gfx_req <= 1'b0;
		end else begin
			gfx_req <= 1'b0;
			case (fst)
				F_IDLE: if (start) begin
					vpos_l <= vpos;
					fst    <= F_CODE;
				end

				F_CODE: begin
					code <= list_q;
					fst  <= F_SCROLL;
				end

				F_SCROLL: begin
					gran   <= list_q[9:4];
					issued <= 5'd0;
					fst    <= F_ATTR;
				end

				F_ATTR: begin
					f_color <= list_q[5:0];
					lb_pri  <= list_q[10:8];
					fst     <= F_REQ;
				end

				F_REQ: begin
					gfx_addr <= gfx_base + {5'd0, tile, gran[1:0], 3'b000};
					gfx_req  <= 1'b1;
					fst      <= F_WAIT;
				end

				F_WAIT: if (gfx_valid) begin
					f_gran <= gfx_rdata;
					fst    <= F_HOLD;
				end

				// 17 granules cover 256 pixels at any fine scroll
				F_HOLD: if (p_load) begin
					gran   <= gran + 6'd1;
					issued <= issued + 5'd1;
					fst    <= (issued == 5'd16) ? F_IDLE : F_REQ;
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
			if (fst == F_SCROLL)
				p_x <= -{6'd0, list_q[3:0]};
			if (p_busy) begin
				lb_we <= (p_x[9:8] == 2'b00);
				lb_x  <= p_x[7:0];
				lb_d  <= {f_color, p_row[3:0]};
				p_row <= {4'h0, p_row[63:4]};
				p_x   <= p_x + 10'd1;
				p_cnt <= p_cnt + 4'd1;
				if (p_cnt == 4'd15) p_busy <= 1'b0;
			end
			if (p_load) begin
				p_busy <= 1'b1;
				p_cnt  <= 4'd0;
				p_row  <= f_gran;
			end
		end
	end

endmodule
