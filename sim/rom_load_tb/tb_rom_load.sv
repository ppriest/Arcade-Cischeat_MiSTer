// SPDX-License-Identifier: GPL-3.0-or-later
//
// The fast ROM load end to end: the .mra image in a DDR3 model ->
// cischeat_rom_load -> cischeat_sdram -> the command-decoding SDRAM chip
// model, then the chip's contents against what MAME holds after machine init.
//
//     python scripts/build_mra.py --check --image debug/board/rom_image.hex
//     python scripts/board_image.py
//     scripts/run_verilator.sh rom_load_tb
//
// Expected: debug/board/sdram.hex (MAME's regions after init, sound bitswap
// sprite untangle and scroll tile pairing applied) below 0x0e00000, the raw image above it (the
// OKI samples, untransformed). The DDR3 model holds DDRAM_BUSY high on a
// pseudo-random quarter of clocks and answers a read 4 to 19 clocks later.

`timescale 1ns / 1ps

module tb_rom_load;

	logic clk = 1'b0, clk_mem = 1'b0;
	always #10.416 clk = ~clk;
	always #5.208 clk_mem = ~clk_mem;

	localparam int IMG_BYTES = 26'h0f00000;
	localparam int GOLD_WORDS = 26'h0e00000 / 2;

	logic [63:0] ddr [IMG_BYTES / 8];
	logic [15:0] gold [IMG_BYTES / 2];     // compared below GOLD_WORDS only

	// ---- DDR3 model ----
	logic        d_busy, d_rd, d_ready, d_we;
	logic [28:0] d_addr;
	logic [63:0] d_dout, d_din;
	logic [7:0]  d_cnt, d_be;
	logic [31:0] lfsr = 32'hace1;
	int          d_wait = -1;
	logic [24:0] d_a;

	always_ff @(posedge clk_mem) begin
		lfsr    <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
		d_busy  <= lfsr[3:2] == 2'b00;
		d_ready <= 1'b0;
		if (d_rd && !d_busy) begin
			if (d_addr[28:25] != 4'b0011) $fatal(1, "DDR3 read outside the window: %h", d_addr);
			d_a    <= d_addr[24:0];
			d_wait <= 4 + int'(lfsr[7:4]);
		end else if (d_wait > 0)
			d_wait <= d_wait - 1;
		else if (d_wait == 0) begin
			d_dout  <= ddr[d_a];
			d_ready <= 1'b1;
			d_wait  <= -1;
		end
		if (d_we) $fatal(1, "DDR3 write during the load");
	end

	// ---- DUT ----
	logic        reset = 1'b1, init = 1'b1, start = 1'b0, busy;
	logic        dl_req, dl_we16, dl_busy;
	logic [25:0] dl_addr;
	logic [15:0] dl_data;

	cischeat_rom_load u_load (
		.clk(clk_mem), .reset, .gatearray(1'b1), .gs88000(1'b1), .start, .length(28'(IMG_BYTES)), .busy,
		.DDRAM_BUSY(d_busy), .DDRAM_BURSTCNT(d_cnt), .DDRAM_ADDR(d_addr), .DDRAM_DOUT(d_dout),
		.DDRAM_DOUT_READY(d_ready), .DDRAM_RD(d_rd), .DDRAM_DIN(d_din), .DDRAM_BE(d_be),
		.DDRAM_WE(d_we),
		.dl_req, .dl_addr, .dl_data, .dl_we16, .dl_busy
	);

	logic [25:1] ext_addr [5];
	logic [15:0] ext_wdata [5], ext_rdata [5];
	logic [1:0]  ext_be [5];
	logic [25:0] gfx_addr [9];
	logic [25:0] snd_addr [2];
	logic [1:0]  snd_valid;
	logic [63:0] snd_rdata;
	logic [63:0] gfx_rdata [9];
	logic [4:0]  ext_ready;
	logic [8:0]  gfx_valid;
	wire  [15:0] sd_dq;
	logic [12:0] sd_a;
	logic [1:0]  sd_ba;
	logic        sd_ncs, sd_nwe, sd_nras, sd_ncas, sd_dqml, sd_dqmh, sd_cke;

	initial begin for (int i = 0; i < 9; i++) gfx_addr[i] = '0; snd_addr[0] = '0; snd_addr[1] = '0; end
	initial for (int i = 0; i < 5; i++) begin ext_addr[i] = '0; ext_wdata[i] = '0; ext_be[i] = '0; end

	cischeat_sdram u_mem (
		.clk, .clk_mem, .reset, .mem_reset(reset), .init,
		.ext_req(5'h0), .ext_we(5'h0), .ext_addr, .ext_wdata, .ext_be, .ext_ready, .ext_rdata,
		.gfx_req(9'h000), .gfx_addr, .gfx_valid, .gfx_rdata,
		.snd_req(2'b00), .snd_addr, .snd_valid, .snd_rdata,
		.dl_req, .dl_addr, .dl_data, .dl_we16, .dl_busy,
		.SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh), .SDRAM_BA(sd_ba),
		.SDRAM_nCS(sd_ncs), .SDRAM_nWE(sd_nwe), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_CKE(sd_cke)
	);

	sdram_chip_model_timed #(.SWIZZLE(1'b1)) u_chip (
		.clk(clk_mem), .SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_nCS(sd_ncs),
		.SDRAM_nWE(sd_nwe), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas)
	);

	// ---- run ----
	initial begin
		longint t0, bad, region_bad;
		logic [15:0] want, got;
		$readmemh("debug/board/rom_image.hex", ddr);
		$readmemh("debug/board/sdram.hex", gold);
		if (ddr[0] === 64'hx || gold[0] !== 16'h000f) $fatal(1, "inputs did not load");
		for (int w = 0; w < (1 << 24); w++) u_chip.mem[w] = 16'h0000;
		repeat (4) @(posedge clk);
		init <= 1'b0;
		repeat (400) @(posedge clk);
		reset <= 1'b0;
		repeat (20) @(posedge clk_mem);
		@(negedge clk_mem) start = 1'b1;
		@(negedge clk_mem) start = 1'b0;
		t0 = $time;
		wait (!busy);
		$display("loaded %0d bytes in %0.3f ms", IMG_BYTES, real'($time - t0) / 1.0e6);
		repeat (40) @(posedge clk_mem);

		bad = 0;
		for (int blk = 0; blk < IMG_BYTES / 2; blk += 26'h80000 / 2) begin
			region_bad = 0;
			for (int w = blk; w < blk + 26'h80000 / 2; w++) begin
				logic [63:0] q;
				q    = ddr[w / 4];
				want = w < GOLD_WORDS ? gold[w] : q[16 * (w % 4) +: 16];
				got  = u_chip.mem[w];
				if (got !== want) begin
					if (region_bad == 0)
						$display("  %07h: first difference at %07h, SDRAM %04h, expected %04h",
						         2 * blk, 2 * w, got, want);
					region_bad++;
				end
			end
			if (region_bad != 0) $display("DIFF %07h-%07h: %0d words", 2 * blk, 2 * blk + 26'h7ffff, region_bad);
			bad += region_bad;
		end
		if (bad == 0 && u_chip.errors == 0) $display("PASS: %0d words equal, 0 SDRAM timing errors", IMG_BYTES / 2);
		else $display("FAIL: %0d words differ, %0d SDRAM timing errors", bad, u_chip.errors);
		$finish;
	end

endmodule
