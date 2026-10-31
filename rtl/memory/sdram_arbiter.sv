// N clients, round-robin, onto one sdram_phy port, plus the ROM download
// write path at absolute priority. A client whose LOW bit is set is served only
// when no other client is pending; LOW clients share the rest round-robin. A read moves a 64-bit granule at an
// 8-byte-aligned address; a client write (c_we) moves one byte, lane from
// addr[0], or with c_we16 the word at an even addr, and its c_valid pulses once
// the phy has taken it, so a later read through this arbiter sees it.
//
// A client request is captured on its rising edge, so pulse and held clients
// share the arbiter. c_valid follows phy_valid by one cycle, and rdata is
// latched on phy_valid: sdram.sv's port outputs share one register.
//
// The pick is registered (pick_q), so the priority search and the client mux
// are a cycle each at 96 MHz. It is searched from the base rr_ptr will hold in
// the next idle cycle; a request pending one cycle is picked a cycle later.

module sdram_arbiter #(
	parameter int N = 4,
	parameter logic [N-1:0] LOW = '0
) (
	input  logic clk,
	input  logic reset,

	output logic         phy_req,
	output logic         phy_we,
	output logic         phy_we16,
	output logic [25:0]  phy_addr,
	output logic [15:0]  phy_wdata,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [63:0]  phy_rdata,

	input  logic [N-1:0]      c_req,
	input  logic [26*N-1:0]   c_addr,
	input  logic [N-1:0]      c_we,
	input  logic [N-1:0]      c_we16,
	input  logic [16*N-1:0]   c_wdata,
	output logic [N-1:0]      c_valid,
	output logic [63:0]       c_rdata,     // shared; capture it on your own valid

	// download write path
	input  logic         dl_req,
	input  logic [25:0]  dl_addr,
	input  logic [15:0]  dl_data,
	input  logic         dl_we16,
	output logic         dl_busy
);

	typedef enum logic [1:0] {S_IDLE, S_READ, S_WRITE} state_t;
	state_t st;

	logic [$clog2(N)-1:0] rr_ptr;    // round-robin start point
	logic [$clog2(N)-1:0] serving;

	// set on c_req's rising edge, cleared when served
	logic [N-1:0] pend, c_req_d;

	logic       c_write;                 // S_WRITE is serving a client, not the download
	logic       have_pick, have_pick_q;
	logic [$clog2(N)-1:0] pick, pick_q, rr_base;

	// rr_ptr after this service: serving + 1 once a client's read or write ends
	always_comb
		if (st == S_READ || (st == S_WRITE && c_write))
			rr_base = (int'(serving) == N-1) ? '0 : $bits(rr_base)'(int'(serving) + 1);
		else
			rr_base = rr_ptr;

	logic                 have_hi, have_lo;
	logic [$clog2(N)-1:0] pick_hi, pick_lo;
	always_comb begin
		have_hi = 1'b0;
		have_lo = 1'b0;
		pick_hi = rr_base;
		pick_lo = rr_base;
		for (int k = 0; k < N; k++) begin
			int unsigned idx;
			idx = (int'(rr_base) + k) % N;
			if (!have_hi && pend[idx] && !LOW[idx]) begin
				have_hi = 1'b1;
				pick_hi = $bits(pick_hi)'(idx);
			end
			if (!have_lo && pend[idx] && LOW[idx]) begin
				have_lo = 1'b1;
				pick_lo = $bits(pick_lo)'(idx);
			end
		end
		have_pick = have_hi || have_lo;
		pick      = have_hi ? pick_hi : pick_lo;
	end

	logic [25:0] pick_addr;
	logic        pick_we, pick_we16;
	logic [15:0] pick_wdata;
	always_comb begin
		pick_addr  = 26'd0;
		pick_we    = 1'b0;
		pick_we16  = 1'b0;
		pick_wdata = 16'd0;
		for (int k = 0; k < N; k++)
			if (k == int'(pick_q)) begin
				pick_addr  = c_addr[26*k +: 26];
				pick_we    = c_we[k];
				pick_we16  = c_we16[k];
				pick_wdata = c_wdata[16*k +: 16];
			end
	end

	logic [63:0] rdata_l;
	assign c_rdata = rdata_l;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st       <= S_IDLE;
			phy_req  <= 1'b0;
			c_valid  <= '0;
			dl_busy  <= 1'b0;
			c_write  <= 1'b0;
			rr_ptr   <= '0;
			serving  <= '0;
			have_pick_q <= 1'b0;
			pick_q   <= '0;
			pend     <= '0;
			c_req_d  <= '0;
		end else begin
			phy_req <= 1'b0;
			c_valid <= '0;
			pick_q      <= pick;
			have_pick_q <= have_pick;

			// in every state, so a request during service is kept
			c_req_d <= c_req;
			pend    <= pend | (c_req & ~c_req_d);

			case (st)
			S_IDLE: begin
				if (!phy_busy) begin
					if (dl_req) begin
						phy_req   <= 1'b1;
						phy_we    <= 1'b1;
						phy_we16  <= dl_we16;
						phy_addr  <= dl_addr;
						phy_wdata <= dl_data;
						dl_busy   <= 1'b1;
						st        <= S_WRITE;
						c_write   <= 1'b0;
					end else if (have_pick_q) begin
						phy_req   <= 1'b1;
						phy_we    <= pick_we;
						phy_we16  <= pick_we16;
						phy_addr  <= pick_addr;
						phy_wdata <= pick_wdata;
						serving   <= pick_q;
						pend[pick_q] <= 1'b0;
						have_pick_q <= 1'b0;
						c_write   <= pick_we;
						st        <= pick_we ? S_WRITE : S_READ;
					end
				end
			end

			S_READ: begin
				if (phy_valid) begin
					rdata_l <= phy_rdata;
					c_valid[serving] <= 1'b1;
					rr_ptr <= (int'(serving) == N-1) ? '0
					                                 : $bits(rr_ptr)'(int'(serving) + 1);
					st     <= S_IDLE;
				end
			end

			S_WRITE: begin
				if (!phy_busy) begin
					dl_busy <= 1'b0;
					if (c_write) begin
						c_valid[serving] <= 1'b1;
						rr_ptr <= (int'(serving) == N-1) ? '0
						                                 : $bits(rr_ptr)'(int'(serving) + 1);
					end
					st      <= S_IDLE;
				end
			end

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule
