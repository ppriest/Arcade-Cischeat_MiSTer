// Raw MRA byte-stream transforms for rom_loader, every set.
//
// raw_word is the loader's little-endian word: image byte 2k in bits 7..0. The
// .mra holds the CPU programs in 68000 order (even byte first), and the board
// reads an SDRAM word as the 68000 word, so every word below CPU_TOP is byte
// swapped; the sound program is also bitswapped by the gate array's
// rom_decode, GS88000 on Cisco Heat and D65006 on the others
// (ms1_gatearray.cpp, megasys1_gatearray_*_device::rom_decode). The gfx
// regions are byte-wide, even byte in bits 7..0 as loaded; the sprites are
// untangled.
module cischeat_rom_transform #(
	parameter logic [25:0] CPU_TOP     = 26'h02c0000,
	parameter logic [25:0] SOUND_BASE  = 26'h0280000,
	parameter logic [25:0] SOUND_BYTES = 26'h0040000,
	parameter logic [25:0] SPRITE_BASE = 26'h0400000,
	parameter logic [25:0] SPRITE_BYTES = 26'h0600000
) (
	input  logic        gs88000,        // Cisco Heat's gate array, else D65006
	input  logic [25:0] raw_addr,
	input  logic [15:0] raw_word,
	output logic [25:0] xf_addr,
	output logic [15:0] xf_data
);

	function automatic logic [15:0] bitswap16(input logic [15:0] value,
											 input logic [63:0] order);
		logic [15:0] result;
		for (int bitno = 0; bitno < 16; bitno++)
			result[15-bitno] = value[order[63-bitno*4 -: 4]];
		return result;
	endfunction

	logic [25:0] sound_word_index;
	logic [15:0] source_be, decoded_be;
	logic [63:0] order;
	logic [25:0] sprite_offset;
	logic [6:0] sprite_byte_in_block;
	logic [3:0] sprite_row;
	logic [1:0] sprite_col;
	logic [5:0] sprite_word_in_block;

	// bitswap<16> orders, source bit of result bit 15 first
	logic [63:0] swap0, swap1, swap2;
	assign swap0 = gs88000 ? 64'hDEF0A981_65CB7234 : 64'hDEF0189A_BC567234;
	assign swap1 = gs88000 ? 64'hFDB97531_8ACE0246 : 64'hFDB97531_ECA86420;
	assign swap2 = gs88000 ? 64'h45670123_BA98FEDC : 64'h01234567_BA98FEDC;

	always_comb begin
		xf_addr = raw_addr;
		xf_data = raw_addr < CPU_TOP ? {raw_word[7:0], raw_word[15:8]} : raw_word;
		order = 64'd0;
		sound_word_index = (raw_addr - SOUND_BASE) >> 1;
		source_be = {raw_word[7:0], raw_word[15:8]};
		decoded_be = 16'd0;
		sprite_offset = raw_addr - SPRITE_BASE;
		sprite_byte_in_block = sprite_offset[6:0];
		sprite_row = sprite_byte_in_block[5:2];
		sprite_col = sprite_byte_in_block[1:0];
		sprite_word_in_block = {sprite_row, 2'b00}
							 + {4'b0, sprite_byte_in_block[6], 1'b0}
							 + {5'b0, sprite_col[1]};

		if ((raw_addr >= SOUND_BASE) && (raw_addr < SOUND_BASE + SOUND_BYTES)) begin
			if (sound_word_index < 26'h4000 || (sound_word_index >= 26'h8000 && sound_word_index < 26'hC000))
				order = ((sound_word_index | 26'h124) != sound_word_index) ? swap0 : swap1;
			else if (sound_word_index >= 26'h4000 && sound_word_index < 26'h8000)
				order = swap2;
			else if (sound_word_index < 26'h10000)
				order = swap1;
			else
				order = swap2;
			decoded_be = bitswap16(source_be, order);
			xf_data = decoded_be;
		end else if ((raw_addr >= SPRITE_BASE)
				 && (raw_addr < SPRITE_BASE + SPRITE_BYTES)) begin
			// Each source word stays intact; only its destination within the
			// 128-byte untangle block changes.
			xf_addr = SPRITE_BASE + (sprite_offset & 26'h3FFFF80)
				+ {19'd0, sprite_word_in_block, 1'b0};
		end
	end

endmodule
