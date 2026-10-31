module tb_rom_transform;
	localparam logic [25:0] SOUND_BASE = 26'h0280000;
	localparam logic [25:0] SOUND_BYTES = 26'h0040000;
	localparam logic [25:0] SPRITE_BASE = 26'h0400000;
	localparam logic [25:0] SPRITE_BYTES = 26'h0400000;
	logic        gs88000 = 1'b1;
	logic [25:0] raw_addr;
	logic [15:0] raw_word;
	logic [25:0] xf_addr;
	logic [15:0] xf_data;
	integer i;

	cischeat_rom_transform dut (.*);

	function automatic logic [15:0] reference_swap(
		input logic [15:0] value, input logic [63:0] order);
		for (int b = 0; b < 16; b++)
			reference_swap[15-b] = value[order[63-b*4 -: 4]];
	endfunction

	function automatic logic [63:0] reference_order(input integer index);
		if ((index < 'h4000) || ((index >= 'h8000) && (index < 'hC000))) begin
			if ((index | 'h124) != index)
				reference_order = {4'hD,4'hE,4'hF,4'h0,4'hA,4'h9,4'h8,4'h1,
					4'h6,4'h5,4'hC,4'hB,4'h7,4'h2,4'h3,4'h4};
			else
				reference_order = {4'hF,4'hD,4'hB,4'h9,4'h7,4'h5,4'h3,4'h1,
					4'h8,4'hA,4'hC,4'hE,4'h0,4'h2,4'h4,4'h6};
		end else if ((index >= 'h4000) && (index < 'h8000) || index >= 'h10000)
			reference_order = {4'h4,4'h5,4'h6,4'h7,4'h0,4'h1,4'h2,4'h3,
				4'hB,4'hA,4'h9,4'h8,4'hF,4'hE,4'hD,4'hC};
		else
			reference_order = {4'hF,4'hD,4'hB,4'h9,4'h7,4'h5,4'h3,4'h1,
				4'h8,4'hA,4'hC,4'hE,4'h0,4'h2,4'h4,4'h6};
	endfunction

	logic [15:0] source_be, expected_be, sample;
	logic [25:0] expected_sprite_addr;
	integer word_index, row_index, source_half, source_col;

	initial begin
		raw_addr = '0;
		raw_word = '0;
		#1;
		// Check every sound word address, including each gate-array decode window.
		for (i = 0; i < SOUND_BYTES/2; i = i + 1) begin
			raw_addr = SOUND_BASE + i*2;
			raw_word = (i * 16'h9E37) ^ (i >> 3) ^ 16'hA65C;
			sample = raw_word;
			source_be = {sample[7:0], sample[15:8]};
			expected_be = reference_swap(source_be, reference_order(i));
			#1;
			if (xf_addr !== raw_addr || xf_data !== expected_be)
				$fatal(1, "sound transform mismatch at word %h: got %h:%h expected %h:%h",
					i, xf_addr, xf_data, raw_addr, expected_be);
		end

		// The other CPU programs, below the sound region, are byte swapped in place.
		for (i = 0; i < SOUND_BASE/2; i = i + 1) begin
			raw_addr = i*2;
			raw_word = (i * 16'h6F1D) ^ 16'h3C5A;
			#1;
			if (xf_addr !== raw_addr || xf_data !== {raw_word[7:0], raw_word[15:8]})
				$fatal(1, "CPU word mismatch at %h: got %h:%h", raw_addr, xf_addr, xf_data);
		end

		// Check every word's address in the 4 MiB Cisco Heat sprite region.
		for (i = 0; i < SPRITE_BYTES/2; i = i + 1) begin
			raw_addr = SPRITE_BASE + i*2;
			raw_word = i ^ 16'h5A3C;
			row_index = (i % 32) / 2;
			source_half = ((i % 64) >= 32) ? 1 : 0;
			source_col = i % 2;
			word_index = row_index*4 + source_half*2 + source_col;
			expected_sprite_addr = SPRITE_BASE + ((i / 64)*128) + word_index*2;
			#1;
			if (xf_addr !== expected_sprite_addr || xf_data !== raw_word)
				$fatal(1, "sprite transform mismatch at word %h: got %h:%h expected %h:%h",
					i, xf_addr, xf_data, expected_sprite_addr, raw_word);
		end
		$display("PASS: %0d CPU words, %0d sound words and %0d sprite words", SOUND_BASE/2,
			SOUND_BYTES/2, SPRITE_BYTES/2);
		$finish;
	end
endmodule
