// SPDX-License-Identifier: GPL-3.0-or-later
//
// board_cpu's state stub on cischeat's main CPU, running its boot code from the
// real ROM (debug/cischeat-rom, scripts/mame_rom_dump.py) on an ideal memory.
//
// Run A: no stub; log the main CPU's writes and non-ROM reads.
// Run B, from reset again:
//   at access K1, save: park, keep the registers and a copy of RAM, release;
//   at access K2, restore: park, put back the K1 registers and RAM, release.
// B must match A access for access up to K2 (saving is invisible), then from
// the restore on B must repeat A from K1 (restoring returns to that point).
// ROM reads are left out: the RTE refetches the words at PC that the CPU had
// already prefetched before the stub.
//
// The one access the stub lets through is the interrupt's push of PC[15:0]
// below the stack pointer, before its acknowledge. B drops it from its log and
// checks it equals the captured PC low word.
//
// The defaults put K1 and K2 near the end of the boot's 65,536-iteration
// delay loop, so the restored D0 decides when the loop's exit and the write
// to 0x82308 (MAME's access 655,391) happen. +MUTATE=1 restores D0 + 1 and
// must fail.
//
// PLUSARGS: +K1=n +K2=n +N=n (accesses of run A), +LAT=n, +MUTATE=1

`timescale 1ns / 1ps

module tb_cpu_state;

	logic clk = 1'b0;
	always #10.416667 clk = ~clk;
	logic reset = 1'b1;

	int k1 = 650000, k2 = 652000, n_max = 660000, lat = 6, mutate = 0;
	initial begin
		void'($value$plusargs("K1=%d", k1));
		void'($value$plusargs("K2=%d", k2));
		void'($value$plusargs("N=%d", n_max));
		void'($value$plusargs("LAT=%d", lat));
		void'($value$plusargs("MUTATE=%d", mutate));
	end

	logic [15:0] rom [0:524287];
	logic [15:0] ram [0:262143];          // a[17:1] of every non-ROM address
	logic [15:0] ram_k1 [0:262143];

	function automatic bit is_rom(input [23:0] a);
		return a < 24'h080000 || (a >= 24'h100000 && a < 24'h180000);
	endfunction
	function automatic bit is_ram(input [23:0] a);
		return (a >= 24'h084000 && a < 24'h0c0000) || (a >= 24'h0f0000 && a < 24'h100000);
	endfunction

	logic [23:1] addr;
	logic        we, int_stb, ext_req, ext_ready;
	logic [15:0] wdata, int_rdata, ext_rdata;
	logic [1:0]  be;
	logic        ss_req, ss_parked, ss_release, ss_we;
	logic [4:0]  ss_idx;
	logic [31:0] ss_wd, ss_rd;
	logic        dbg_stb, dbg_we, dbg_uds, dbg_lds;
	logic [23:1] dbg_addr;
	logic [15:0] dbg_data;

	board_cpu #(.PHASE_NUM(24), .PHASE_DEN(5)) dut (.fast(1'b0),
		.clk, .reset, .cpu_run(1'b1), .irq_set(7'd0),
		.addr, .we, .wdata, .be,
		.is_ext(is_rom({addr, 1'b0})), .int_stb, .int_rdata, .ext_req, .ext_ready, .ext_rdata,
		.ss_req, .ss_parked, .ss_release, .ss_idx, .ss_we, .ss_wd, .ss_rd,
		.dbg_stb, .dbg_we, .dbg_addr, .dbg_data, .dbg_uds, .dbg_lds
	);

	// internal: registered RAM; I/O reads 0, as MAME's watchdog read does
	always_ff @(posedge clk)
		if (int_stb) begin
			if (we && is_ram({addr, 1'b0})) begin
				if (be[1]) ram[addr[17:1]][15:8] <= wdata[15:8];
				if (be[0]) ram[addr[17:1]][7:0]  <= wdata[7:0];
			end
			int_rdata <= is_ram({addr, 1'b0}) ? ram[addr[17:1]] : 16'h0000;
		end

	// external: ROM, LAT clocks
	int ext_wait;
	logic ext_req_d;
	always_ff @(posedge clk) begin
		ext_ready <= 1'b0;
		ext_req_d <= ext_req;
		if (ext_req && !ext_req_d) ext_wait <= 1;
		else if (ext_req && ext_wait > 0) begin
			if (ext_wait >= lat) begin
				ext_ready <= 1'b1;
				ext_rdata <= {addr, 1'b0} < 24'h080000 ? rom[addr[18:1]] : rom[262144 + addr[18:1]];
				ext_wait  <= 0;
			end else ext_wait <= ext_wait + 1;
		end
	end

	// ---- logs: {we, addr, data} of writes and non-ROM reads, and the access count
	localparam int LOGN = 1 << 20;
	logic [40:0] log_a [LOGN], log_b [LOGN];
	int          na = 0, nb = 0, acc = 0;
	int          b_at_k1, b_at_k2;            // B's log length at the two parks
	logic        run_b = 1'b0, logging = 1'b0;
	int          errors = 0;

	always_ff @(posedge clk)
		if (dbg_stb && logging) begin
			acc <= acc + 1;
			if (dbg_we || !is_rom({dbg_addr, 1'b0})) begin
				logic [15:0] m;
				m = {dbg_uds ? 8'hff : 8'h00, dbg_lds ? 8'hff : 8'h00};
				if (!run_b) begin log_a[na] <= {dbg_we, dbg_addr, 1'b0, dbg_data & m}; na <= na + 1; end
				else        begin log_b[nb] <= {dbg_we, dbg_addr, 1'b0, dbg_data & m}; nb <= nb + 1; end
			end
		end

	// The PC-low push precedes the acknowledge: drop B's last logged write.
	logic [15:0] pushed;
	always @(posedge clk)
		if (run_b && dut.iack && dut.iack_level == 3'd7) begin
			@(negedge clk);
			if (!log_b[nb - 1][40]) begin
				$display("FAIL the last access before the acknowledge was not a write");
				errors++;
			end
			pushed = log_b[nb - 1][15:0];
			nb = nb - 1;
		end

	task automatic park();
		ss_req = 1'b1;
		wait (ss_parked);
		@(negedge clk);
		ss_req = 1'b0;
	endtask

	task automatic release_cpu();
		@(negedge clk);
		ss_release = 1'b1;
		@(negedge clk);
		ss_release = 1'b0;
		wait (!dut.stub);
	endtask

	logic [31:0] regs_k1 [19];

	initial begin
		ss_req = 0; ss_release = 0; ss_we = 0; ss_idx = 0; ss_wd = 0;
		$readmemh("debug/cischeat-rom/cischeat_rom.hex", rom);
		if (rom[0] !== 16'h000f) $fatal(1, "ROM did not load");

		// ---- run A
		for (int i = 0; i < 262144; i++) ram[i] = 16'h0000;
		repeat (20) @(negedge clk);
		reset = 0; logging = 1;
		wait (acc >= n_max);
		@(negedge clk);
		logging = 0;
		$display("A: %0d accesses, %0d logged", acc, na);

		// ---- run B
		reset = 1; run_b = 1; acc = 0;
		for (int i = 0; i < 262144; i++) ram[i] = 16'h0000;
		repeat (20) @(negedge clk);
		reset = 0; logging = 1;

		wait (acc >= k1);
		park();
		b_at_k1 = nb;
		for (int i = 0; i < 19; i++) begin ss_idx = 5'(i); #1 regs_k1[i] = ss_rd; end
		ram_k1 = ram;
		$display("K1 parked after %0d accesses: PC %06h SR %04h A7 %06h USP %06h D0 %08h, pushed PC low %04h",
		         acc, regs_k1[17], regs_k1[18][15:0], regs_k1[15], regs_k1[16], regs_k1[0], pushed);
		if (pushed != regs_k1[17][15:0]) begin
			$display("FAIL the snooped push %04h is not the frame's PC low %04h", pushed, regs_k1[17][15:0]);
			errors++;
		end
		if (!is_rom(regs_k1[17][23:0])) begin $display("FAIL PC %06h is not in ROM", regs_k1[17]); errors++; end
		release_cpu();

		wait (acc >= k2);
		park();
		b_at_k2 = nb;
		for (int i = 0; i < 19; i++) begin
			ss_idx = 5'(i); ss_wd = regs_k1[i] + ((mutate != 0 && i == 0) ? 1 : 0); ss_we = 1;
			@(negedge clk);
		end
		ss_we = 0;
		ram = ram_k1;
		release_cpu();
		$display("K2 parked after %0d accesses; restored K1", acc);

		wait (nb >= b_at_k2 + (na - b_at_k1));
		@(negedge clk);
		logging = 0;

		// ---- compare
		for (int i = 0; i < b_at_k2; i++)
			if (log_b[i] != log_a[i]) begin
				if (errors < 10) $display("FAIL before K2, entry %0d: A %h, B %h", i, log_a[i], log_b[i]);
				errors++;
			end
		for (int i = 0; i < na - b_at_k1; i++)
			if (log_b[b_at_k2 + i] != log_a[b_at_k1 + i]) begin
				if (errors < 10) $display("FAIL after restore, entry %0d: A %h, B %h",
				                          i, log_a[b_at_k1 + i], log_b[b_at_k2 + i]);
				errors++;
			end
		for (int i = 0; i < na; i++)
			if (log_a[i][39:16] == 24'h082308 && log_a[i][40]) $display("A writes 0x82308 at log entry %0d", i);
		$display("compared %0d entries before K2 and %0d after the restore", b_at_k2, na - b_at_k1);
		if (errors == 0) $display("PASS");
		else             $display("FAILED: %0d errors", errors);
		$finish;
	end

	initial begin
		#(64'd5 * 1000 * 1000 * 1000);
		$display("FAILED: timeout (acc %0d, na %0d, nb %0d)", acc, na, nb);
		$finish;
	end

endmodule
