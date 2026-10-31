// SPDX-License-Identifier: GPL-3.0-or-later
//
// One 68000 of the board: fx68k_bus, its HOLD_LINE interrupt latches, and the
// bus slave that splits each access between on-chip resources and an external
// (SDRAM) port.
//
// The parent decodes addr combinationally and says which side an access goes
// to with is_ext. An internal access gets int_stb for one clock: a write
// happens then, and a read presents addr to a registered RAM, so int_rdata is
// taken the clock after. An external access holds ext_req until an ext_ready
// pulse brings ext_rdata. Either way the CPU sees ready as a level until it
// ends the cycle.
//
// irq_set[n] latches level n + 1 pending until the CPU acknowledges that
// level, as MAME's HOLD_LINE does. Reset clears them.

module board_cpu #(
	parameter int PHASE_NUM = 24,
	parameter int PHASE_DEN = 5,
	parameter int PHASE_NUM_FAST = PHASE_NUM
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        cpu_run,
	input  logic        fast,        // PHASE_NUM_FAST

	input  logic [6:0]  irq_set,     // one-clock events, levels 1..7

	output logic [23:1] addr,
	output logic        we,
	output logic [15:0] wdata,
	output logic [1:0]  be,          // {UDS, LDS}

	input  logic        is_ext,
	output logic        int_stb,
	input  logic [15:0] int_rdata,

	output logic        ext_req,
	input  logic        ext_ready,
	input  logic [15:0] ext_rdata,

	// state stub (docs/SAVESTATES.md): park the CPU, read or write its registers
	input  logic        ss_req,
	output logic        ss_parked,
	input  logic        ss_release,
	input  logic [4:0]  ss_idx,
	input  logic        ss_we,
	input  logic [31:0] ss_wd,
	output logic [31:0] ss_rd,
	output logic [7:1]  ss_pend,
	input  logic        ss_pend_we,
	input  logic [7:1]  ss_pend_wd,

	output logic        dbg_stb,
	output logic        dbg_we,
	output logic [23:1] dbg_addr,
	output logic [15:0] dbg_data,
	output logic        dbg_uds,
	output logic        dbg_lds
);

	logic        bus_req, bus_we, bus_uds, bus_lds, bus_ready;
	logic [15:0] bus_wdata, bus_rdata;
	logic [23:1] bus_addr;
	logic        iack;
	logic [2:0]  iack_level;
	logic [7:1]  pend;
	logic [2:0]  ipl;
	logic        dbg_raw, dbg_mask;      // the trace leaves out the stub's accesses
	assign dbg_stb = dbg_raw && !dbg_mask;

	fx68k_bus #(.PHASE_NUM(PHASE_NUM), .PHASE_DEN(PHASE_DEN), .PHASE_NUM_FAST(PHASE_NUM_FAST)) u_cpu (
		.clk, .reset, .cpu_run, .fast, .ipl_level(ipl),
		.bus_req, .bus_we, .bus_addr, .bus_wdata, .bus_uds, .bus_lds,
		.bus_fc(), .bus_is_fill(), .bus_rdata, .bus_ready,
		.dbg_stb(dbg_raw), .dbg_we, .dbg_addr, .dbg_data, .dbg_uds, .dbg_lds,
		.cycle_tick(), .stall_tick(), .iack, .iack_level
	);

	always_ff @(posedge clk)
		if (reset)           pend <= '0;
		else if (ss_pend_we) pend <= ss_pend_wd;
		else
			for (int n = 1; n <= 7; n++)
				if (irq_set[n - 1])                 pend[n] <= 1'b1;
				else if (iack && iack_level == 3'(n)) pend[n] <= 1'b0;

	// ---- state stub ----------------------------------------------------
	// ss_req raises IPL 7, which no Cisco Heat CPU uses. From its acknowledge
	// to the RTE that ends the stub, every access of this CPU is answered
	// here and none reaches memory: the vector fetch points into STUB, the
	// stub's MOVEMs land in ss_reg, the exception frame is captured and later
	// served from ss_reg. The stub parks on a read held until ss_release; the
	// engine reads or rewrites ss_reg meanwhile. Saving and restoring run the
	// same stub: what is in ss_reg at release is what the CPU continues with.
	//
	//   FFFE00  MOVEM.L D0-D7/A0-A7,$FFFF00   capture (A7 = SSP - 6 here)
	//           MOVE.L  USP,A0
	//           MOVE.L  A0,$FFFF40
	//           TST.W   $FFFF80                park
	//           MOVEA.L $FFFF40,A0
	//           MOVE.L  A0,USP
	//           MOVEM.L $FFFF00,D0-D7/A0-A7    restore
	//           RTE                            SR, PC from ss_reg
	//
	// ss_reg: 0-7 D0-D7, 8-15 A0-A7, 16 USP, 17 PC, 18 SR. The interrupt
	// pushes PC low before its acknowledge, so that one write reaches memory,
	// below the stack pointer; it is snooped here to get PC[15:0].
	localparam int STUB_N = 21;
	localparam logic [15:0] STUB [STUB_N] = '{
		16'h48f9, 16'hffff, 16'h00ff, 16'hff00,
		16'h4e68,
		16'h23c8, 16'h00ff, 16'hff40,
		16'h4a79, 16'h00ff, 16'hff80,
		16'h2079, 16'h00ff, 16'hff40,
		16'h4e60,
		16'h4cf9, 16'hffff, 16'h00ff, 16'hff00,
		16'h4e73, 16'h4e71
	};

	logic        stub, parked, restoring;
	logic [31:0] ss_reg [19];
	logic [23:1] lw_addr;              // the last write before the acknowledge
	logic [15:0] lw_data;
	logic [23:1] fr_addr [3];          // frame writes: PC low (snooped), then two
	logic [15:0] fr_data [3];
	logic [1:0]  fr_n;
	logic [2:0]  rte_seen;

	always_comb begin
		ipl = 3'd0;
		for (int n = 1; n <= 7; n++)
			if (pend[n]) ipl = 3'(n);
		if (ss_req && !stub) ipl = 3'd7;
	end

	assign addr  = bus_addr;
	assign we    = bus_we;
	assign wdata = bus_wdata;
	assign be    = {bus_uds, bus_lds};

	typedef enum logic [2:0] {S_IDLE, S_INT, S_EXT, S_DONE, S_STUB, S_PARK} st_t;
	st_t st;

	assign int_stb   = st == S_IDLE && bus_req && !is_ext && !stub;
	assign ext_req   = st == S_EXT;
	assign ss_parked = st == S_PARK;
	assign ss_rd     = ss_reg[ss_idx];
	assign ss_pend   = pend;

	// the access the stub answers
	logic [23:0] ba;
	logic [23:0] fp;                   // the frame's base: the A7 the stub holds
	logic [23:0] off;
	logic [15:0] stub_q;
	assign ba  = {bus_addr, 1'b0};
	assign fp  = ss_reg[15][23:0];
	assign off = ba - fp;

	always_comb begin
		stub_q = 16'h0000;
		if (ba >= 24'hfffe00 && ba < 24'hfffe00 + 24'(2 * STUB_N))
			stub_q = STUB[(ba - 24'hfffe00) >> 1];
		else if (ba[23:7] == 17'h1fffe && ba[6] == 1'b0)          // FFFF00-FFFF3F
			stub_q = ba[1] ? ss_reg[ba[5:2]][15:0] : ss_reg[ba[5:2]][31:16];
		else if (ba == 24'hffff40) stub_q = ss_reg[16][31:16];
		else if (ba == 24'hffff42) stub_q = ss_reg[16][15:0];
		else if (ba == 24'h00007c) stub_q = 16'h00ff;               // vector 31
		else if (ba == 24'h00007e) stub_q = 16'hfe00;
		else if (off == 24'd0)     stub_q = ss_reg[18][15:0];
		else if (off == 24'd2)     stub_q = ss_reg[17][31:16];
		else if (off == 24'd4)     stub_q = ss_reg[17][15:0];
	end

	function automatic logic [31:0] put(input logic [31:0] r, input logic lo, input logic [15:0] d);
		return lo ? {r[31:16], d} : {d, r[15:0]};
	endfunction

	always_ff @(posedge clk)
		if (reset) begin
			st        <= S_IDLE;
			bus_ready <= 1'b0;
			stub      <= 1'b0;
			dbg_mask  <= 1'b0;
			fr_n      <= '0;
		end else begin
			if (ss_we && st == S_PARK) ss_reg[ss_idx] <= ss_wd;

			case (st)
				S_IDLE: if (bus_req) begin
					if (stub) st <= S_STUB;
					else begin
						st <= is_ext ? S_EXT : S_INT;
						if (bus_we) begin lw_addr <= bus_addr; lw_data <= bus_wdata; end
					end
				end
				S_INT: begin
					bus_rdata <= int_rdata;
					bus_ready <= 1'b1;
					st        <= S_DONE;
				end
				S_EXT: if (ext_ready) begin
					bus_rdata <= ext_rdata;
					bus_ready <= 1'b1;
					st        <= S_DONE;
				end
				S_STUB: begin
					st <= S_DONE;
					bus_ready <= 1'b1;
					bus_rdata <= stub_q;
					if (bus_we) begin
						if (ba[23:7] == 17'h1fffe && ba[6] == 1'b0)
							ss_reg[ba[5:2]] <= put(ss_reg[ba[5:2]], ba[1], bus_wdata);
						else if (ba == 24'hffff40) ss_reg[16] <= put(ss_reg[16], 1'b0, bus_wdata);
						else if (ba == 24'hffff42) ss_reg[16] <= put(ss_reg[16], 1'b1, bus_wdata);
						else if (fr_n != 2'd3) begin
							fr_addr[fr_n] <= bus_addr;
							fr_data[fr_n] <= bus_wdata;
							fr_n <= fr_n + 2'd1;
						end
					end else if (ba == 24'hffff80) begin
						// park: resolve the frame against the captured A7
						bus_ready <= 1'b0;
						st        <= S_PARK;
						for (int k = 0; k < 3; k++)
							case (24'({fr_addr[k], 1'b0}) - fp)
								24'd0: ss_reg[18] <= {16'h0000, fr_data[k]};
								24'd2: ss_reg[17][31:16] <= fr_data[k];
								24'd4: ss_reg[17][15:0]  <= fr_data[k];
								default: ;
							endcase
					end else if (restoring && off <= 24'd4 && !off[0] &&
					             !(ba >= 24'hfffe00)) begin
						// the RTE's reads; the third ends the stub
						if ((rte_seen | (3'b001 << off[2:1])) == 3'b111)
							stub <= 1'b0;
						rte_seen <= rte_seen | (3'b001 << off[2:1]);
					end
				end
				S_PARK: if (ss_release) begin
					bus_rdata <= 16'h0000;
					bus_ready <= 1'b1;
					restoring <= 1'b1;
					rte_seen  <= '0;
					st        <= S_DONE;
				end
				S_DONE: if (!bus_req) begin
					bus_ready <= 1'b0;
					st        <= S_IDLE;
				end
				default: st <= S_IDLE;
			endcase

			if (st == S_IDLE && bus_req && !stub) dbg_mask <= 1'b0;
			if (iack && iack_level == 3'd7) begin
				dbg_mask   <= 1'b1;
				stub       <= 1'b1;
				restoring  <= 1'b0;
				fr_addr[0] <= lw_addr;
				fr_data[0] <= lw_data;
				fr_n       <= 2'd1;
			end
		end

endmodule
