// SPDX-License-Identifier: GPL-3.0-or-later
//
// Savestate sequencer (docs/SAVESTATES.md). At row 1 it freezes the screen
// timing, parks the CPUs in their state stubs, walks every section one 16-bit
// word at a time, then releases the CPUs and the timing together.
//
// Save streams a header and the sections out on so_*; load takes the same
// words in on si_*. Both are valid/ready: a word moves on a clock where both
// are high. The header is checked before anything is touched; a load whose
// magic, version or length does not match sets error and changes nothing.
//
// The board does the word accesses: op_req holds sec, idx, we and wdata until
// op_ack, which brings rdata for a read. What a section is and where it lives
// is the board's (cischeat_board.sv, "state port"); the engine knows only the
// section lengths, which are the file's manifest (scripts/state.py).
//
// Header, 8 words: 'CH' 'ST' VERSION NSEC frame[31:16] frame[15:0] 0 0.

module state_engine #(
	parameter int NSEC = 1,
	parameter int LEN [NSEC] = '{1},       // words per section
	parameter logic [15:0] VERSION = 16'd1
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        save,              // pulses; act at the next row 1
	input  logic        load,
	output logic        busy,
	output logic        error,             // the last load's header did not match

	input  logic        row1,              // first clock of row 1
	output logic        freeze,            // hold the screen timing
	output logic        park,              // ss_req to every running CPU
	input  logic        all_parked,
	output logic        release_cpus,      // one clock

	input  logic [31:0] frame_in,          // saved in the header
	output logic [31:0] frame_out,         // from a loaded header
	output logic        frame_we,

	output logic        op_req,
	output logic [4:0]  op_sec,
	output logic [17:0] op_idx,
	output logic        op_we,
	output logic [15:0] op_wdata,
	input  logic        op_ack,
	input  logic [15:0] op_rdata,

	output logic        so_valid,
	output logic [15:0] so_data,
	input  logic        so_ready,

	input  logic        si_valid,
	input  logic [15:0] si_data,
	output logic        si_ready
);

	localparam int HDR = 8;

	typedef enum logic [3:0] {
		E_IDLE, E_WAIT_ROW, E_HDR, E_PARK, E_OP, E_OUT, E_IN, E_NEXT, E_RELEASE, E_DROP
	} est_t;
	est_t st;

	logic        saving, armed_save, armed_load;
	logic [3:0]  h;                    // header word
	logic [4:0]  sec;
	logic [17:0] idx;
	logic [15:0] word;

	function automatic logic [15:0] hdr_word(input logic [3:0] n, input logic [31:0] f);
		case (n)
			4'd0: return 16'h4348;      // "CH"
			4'd1: return 16'h5354;      // "ST"
			4'd2: return VERSION;
			4'd3: return 16'(NSEC);
			4'd4: return f[31:16];
			4'd5: return f[15:0];
			default: return 16'h0000;
		endcase
	endfunction

	assign busy     = st != E_IDLE;
	assign op_sec   = sec;
	assign op_idx   = idx;
	assign op_we    = !saving;
	assign op_wdata = word;
	assign op_req   = st == E_OP;
	assign so_valid = saving && (st == E_OUT || st == E_HDR);
	assign so_data  = st == E_HDR ? hdr_word(h, frame_in) : word;
	assign si_ready = !saving && (st == E_IN || st == E_HDR || st == E_DROP);

	logic [31:0] frame_l;

	always_ff @(posedge clk)
		if (reset) begin
			st           <= E_IDLE;
			armed_save   <= 1'b0;
			armed_load   <= 1'b0;
			freeze       <= 1'b0;
			park         <= 1'b0;
			release_cpus <= 1'b0;
			frame_we     <= 1'b0;
			error        <= 1'b0;
		end else begin
			release_cpus <= 1'b0;
			frame_we     <= 1'b0;
			if (save) armed_save <= 1'b1;
			if (load) armed_load <= 1'b1;

			case (st)
				E_IDLE: if ((armed_save || armed_load) && row1) begin
					saving     <= armed_save;
					armed_save <= 1'b0;
					armed_load <= 1'b0;
					freeze     <= 1'b1;
					h          <= '0;
					st         <= E_HDR;
					if (!armed_save) error <= 1'b0;
				end

				// save: header out; load: header in and checked
				E_HDR:
					if (saving ? so_ready : si_valid) begin
						if (!saving) begin
							case (h)
								4'd0: if (si_data != 16'h4348) error <= 1'b1;
								4'd1: if (si_data != 16'h5354) error <= 1'b1;
								4'd2: if (si_data != VERSION) error <= 1'b1;
								4'd3: if (si_data != 16'(NSEC)) error <= 1'b1;
								4'd4: frame_l[31:16] <= si_data;
								4'd5: frame_l[15:0]  <= si_data;
								default: ;
							endcase
						end
						h <= h + 4'd1;
						if (h == 4'(HDR - 1)) begin
							park <= 1'b1;
							st   <= E_PARK;
						end
					end

				E_PARK:
					if (error) begin
						park   <= 1'b0;
						freeze <= 1'b0;
						st     <= E_DROP;      // the rest of the stream is not ours
					end else if (all_parked) begin
						park <= 1'b0;
						sec  <= '0;
						idx  <= '0;
						if (!saving) begin
							frame_out <= frame_l;
							frame_we  <= 1'b1;
						end
						st <= saving ? E_OP : E_IN;
					end

				E_IN: if (si_valid) begin
					word <= si_data;
					st   <= E_OP;
				end

				E_OP: if (op_ack) begin
					if (saving) begin
						word <= op_rdata;
						st   <= E_OUT;
					end else
						st <= E_NEXT;
				end

				E_OUT: if (so_ready) st <= E_NEXT;

				E_NEXT: begin
					if (idx == 18'(LEN[sec] - 1)) begin
						idx <= '0;
						if (sec == 5'(NSEC - 1)) st <= E_RELEASE;
						else begin
							sec <= sec + 5'd1;
							st  <= saving ? E_OP : E_IN;
						end
					end else begin
						idx <= idx + 18'd1;
						st  <= saving ? E_OP : E_IN;
					end
				end

				E_RELEASE: begin
					release_cpus <= 1'b1;
					freeze       <= 1'b0;
					st           <= E_IDLE;
				end

				E_DROP: if (!si_valid) st <= E_IDLE;

				default: st <= E_IDLE;
			endcase
		end

endmodule
