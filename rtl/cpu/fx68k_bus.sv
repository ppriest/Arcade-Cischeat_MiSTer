// SPDX-License-Identifier: GPL-3.0-or-later
//
// FX68K on a 48 MHz clock: two-phase enables, held-DTACK bus sequencing and a
// 16-byte instruction line cache.
//
// WHY ENABLES AND NOT A CPU CLOCK
// -------------------------------
// FX68K is the cycle-accurate 68000 from ijor/fx68k (rtl/cpu/fx68k). Its
// phi1/phi2 phases advance on clock enables, not on clock edges, so one phase
// pattern can serve 10 MHz (48/10 = 24/5 clk per CPU clock) or 12 MHz (48/12 =
// 4/1) without a second clock domain. PHASE_NUM/PHASE_DEN are the clk cycles
// per CPU clock; the accumulator carries the fraction exactly instead of
// drifting a little every CPU clock.
//
// The phase that samples DTACK is HELD until the access is ready, so a slow
// read costs clk_sys cycles rather than a 68000 wait state. That pattern is
// Arcade-Seta's (rtl/cpu/maincpu.sv, proved by its sim/fx68k_pace_tb): the
// first phi2 after AS is allowed through, any later one waits for `ready`.
//
// THE BUS
// -------
// One word request: drive bus_req with address, strobes and (for a write) data,
// hold all of them, raise bus_ready with the read data. bus_ready is a LEVEL
// and must stay up until the CPU ends the cycle; the wrapper enforces that by
// holding DTACK low while a ready access is active.
//
// THE LINE CACHE
// --------------
// Program reads are served from 2^ICACHE_LB 16-byte lines per CPU, direct
// mapped on address bits 4 and up: eight words plus a tag each, no
// write-back. Data reads and all writes bypass it; a write to a cached line
// invalidates that line, so code in RAM is never served stale. One line was
// not enough: Cisco Heat's boot ROM checksum loop (0x2118-0x2123) spans two
// lines and refilled both every iteration, 41 frames behind MAME by frame 199. On a miss the line is
// filled word by word before the CPU's access completes, and the seven other
// words are free for the fetches that follow. The memory port behind this
// (rtl/memory/cischeat_sdram.sv) keeps the last 8-byte granule it read, so the
// eight word requests of a fill cost two SDRAM reads. ICACHE=0 removes the cache, which is how the CPI
// measurement gets its "cache out" number from the same wrapper.
//
// dbg_* is one pulse per completed CPU access, in order, for the boot trace
// (scripts/compare_boot_trace.py). It reports what the CPU asked for, not what
// the cache or the memory did underneath, so a cache hit and a miss produce
// the same trace.
`default_nettype none

module fx68k_bus #(
    // clk_sys cycles per CPU clock: 48/10 = 24/5, 48/12 = 4/1.
    parameter int PHASE_NUM = 24,
    parameter int PHASE_DEN = 5,
    parameter int PHASE_NUM_FAST = PHASE_NUM,   // used while fast is high, same DEN
    parameter bit ICACHE    = 1'b1,
    parameter int ICACHE_LB = 2           // log2 of the line count
) (
    input  wire         clk,
    input  wire         reset,

    input  wire         cpu_run,      // low freezes the CPU (OSD Pause)
    input  wire         fast,         // PHASE_NUM_FAST instead of PHASE_NUM; static while running
    input  wire  [2:0]  ipl_level,    // 0 = no interrupt

    // Memory-side word bus: hold the request until bus_ready.
    output logic        bus_req,
    output logic        bus_we,
    output logic [23:1] bus_addr,
    output logic [15:0] bus_wdata,
    output logic        bus_uds,      // active high: D15..D8 valid
    output logic        bus_lds,      // active high: D7..D0 valid
    output logic  [2:0] bus_fc,
    output logic        bus_is_fill,  // this request is the cache, not the CPU
    input  wire  [15:0] bus_rdata,
    input  wire         bus_ready,

    // One pulse per completed CPU access, for the boot trace.
    output logic        dbg_stb,
    output logic        dbg_we,
    output logic [23:1] dbg_addr,
    output logic [15:0] dbg_data,
    output logic        dbg_uds,
    output logic        dbg_lds,

    // Cycle accounting: one pulse per CPU clock, one per clk spent held.
    output logic        cycle_tick,
    output logic        stall_tick,

    // One pulse at the start of each interrupt acknowledge, with its level,
    // for a board that holds its interrupt lines until acknowledged.
    output logic        iack,
    output logic  [2:0] iack_level
);
    localparam int PH_DEN2 = 2 * PHASE_DEN;   // accumulator modulus

    logic [23:1] eab;
    logic [15:0] cpu_dout, cpu_din;
    logic        as_n, n_uds, n_lds, rw_n;
    logic        fc0, fc1, fc2;
    logic        en_phi1, en_phi2;
    logic        acc_ready;
    logic        halted, stop_out;

    wire [2:0] fc      = {fc2, fc1, fc0};
    wire       in_iack = !as_n && (fc == 3'b111);
    wire       dtack_n = !(acc_ready && !as_n && !in_iack);

    fx68k u_cpu (
        .clk        (clk),
        .HALTn      (1'b1),
        .extReset   (reset),
        .pwrUp      (reset),
        .enPhi1     (en_phi1),
        .enPhi2     (en_phi2),
        .eRWn       (rw_n),
        .ASn        (as_n),
        .LDSn       (n_lds),
        .UDSn       (n_uds),
        .E          (),
        .VMAn       (),
        // E_PosClkEn/E_NegClkEn exist only with `USE_E_CLKEN, which this build
        // does not define: 68000 bus users do not need the E clock.
        .FC0        (fc0),
        .FC1        (fc1),
        .FC2        (fc2),
        .BGn        (),
        .oRESETn    (),
        .oHALTEDn   (halted),
        .DTACKn     (dtack_n),
        .VPAn       (!in_iack),
        .BERRn      (1'b1),
        .BRn        (1'b1),
        .BGACKn     (1'b1),
        .IPL0n      (~ipl_level[0]),
        .IPL1n      (~ipl_level[1]),
        .IPL2n      (~ipl_level[2]),
        .iEdb       (cpu_din),
        .oEdb       (cpu_dout),
        .eab        (eab),
        .stop_out   (stop_out)
    );

    // An access: AS and at least one data strobe. A write's strobes follow AS
    // by a state, with the data bus already driven.
    wire acc_active = !as_n && !in_iack && !(n_uds && n_lds);
    wire acc_write  = !rw_n;

    // ------------------------------------------------------------------
    // Phase generator
    // ------------------------------------------------------------------
    // ph_due_raw says a phase is due this clk. The accumulator adds 2*DEN per
    // clk and subtracts NUM when it fires: NUM/(2*DEN) phases per clk, which
    // is one per NUM/(2*DEN) clks = one every half a CPU clock.
    //
    // ph_hold freezes the accumulator AND the phi2 enable while an access is
    // active and not ready. The first phi2 after AS is exempt (phi2_in_as =
    // 0), because that is the earliest a peripheral can answer.
    logic [15:0] ph_acc;
    logic        next_phi2;
    logic  [1:0] phi2_in_as;
    logic        ph_due_raw;

    wire [15:0] ph_num = fast ? 16'(PHASE_NUM_FAST) : 16'(PHASE_NUM);
    assign ph_due_raw = (ph_acc + PH_DEN2) >= ph_num;
    wire   ph_due     = cpu_run && ph_due_raw;
    wire   ph_hold    = next_phi2 && acc_active && !acc_ready && (phi2_in_as != 2'd0);

    assign en_phi1 = ph_due && !next_phi2;
    assign en_phi2 = ph_due &&  next_phi2 && !ph_hold;

    assign cycle_tick = en_phi1;
    assign stall_tick = ph_hold;

    always_ff @(posedge clk) begin
        if (reset) begin
            ph_acc     <= '0;
            next_phi2  <= 1'b0;
            phi2_in_as <= '0;
        end else if (cpu_run) begin
            if (ph_hold) begin
                // frozen: the phase is waiting for the memory
            end else if (ph_due_raw) begin
                ph_acc    <= ph_acc + PH_DEN2 - ph_num;
                next_phi2 <= ~next_phi2;
            end else begin
                ph_acc <= ph_acc + PH_DEN2;
            end
        end
        // Counted from AS, not from the enable, so the exempt first phi2
        // still counts and every held clk after it is visible.
        if (as_n)                                 phi2_in_as <= 2'd0;
        else if (en_phi2 && phi2_in_as != 2'd3)   phi2_in_as <= phi2_in_as + 2'd1;
    end

    // ------------------------------------------------------------------
    // Instruction line cache: 2^ICACHE_LB 16-byte lines, direct-mapped
    // ------------------------------------------------------------------
    localparam int NL = 1 << ICACHE_LB;
    localparam int TB = 4 + ICACHE_LB;    // lowest tag bit

    logic [NL-1:0]   cache_valid;
    logic [23:TB]    cache_tag  [NL];
    logic [15:0]     cache_line [NL * 8]; // {set, address[3:1]}

    typedef enum logic [1:0] {C_IDLE, C_REQ, C_GAP, C_SERVE} cstate_t;
    cstate_t     cstate;
    logic [2:0]  fill_idx;
    logic [23:4] fill_tag;                // the line being filled, set included

    wire        acc_prog    = acc_active && fc[1];
    wire        use_cache   = ICACHE && acc_prog && !acc_write && !in_iack;
    wire [ICACHE_LB-1:0] set = eab[TB-1:4];
    wire        cache_hit   = cache_valid[set] && (cache_tag[set] == eab[23:TB]);
    wire        cache_miss  = use_cache && !cache_hit;
    wire        fill_req    = (cstate == C_REQ);
    wire [23:1] fill_addr   = {fill_tag, fill_idx};
    wire [15:0] cache_word  = cache_line[{set, eab[3:1]}];
    wire [ICACHE_LB-1:0] fill_set = fill_tag[TB-1:4];

    always_ff @(posedge clk) begin
        if (reset) begin
            cstate      <= C_IDLE;
            cache_valid <= '0;
            fill_tag    <= '0;
            fill_idx    <= '0;
        end else begin
            if (acc_active && acc_write && cache_valid[set] && cache_tag[set] == eab[23:TB])
                cache_valid[set] <= 1'b0;
            case (cstate)
                C_IDLE: if (cache_miss) begin
                    fill_tag <= eab[23:4];
                    fill_idx <= 3'd0;
                    cstate   <= C_REQ;
                end
                C_REQ: if (bus_ready) begin
                    cache_line[{fill_set, fill_idx}] <= bus_rdata;
                    if (fill_idx == 3'd7) begin
                        cache_tag[fill_set]   <= fill_tag[23:TB];
                        cache_valid[fill_set] <= 1'b1;
                        cstate      <= C_SERVE;
                    end else begin
                        fill_idx <= fill_idx + 3'd1;
                        cstate   <= C_GAP;
                    end
                end
                // A request per word, with a gap between them: the downstream
                // arbiter sees a clean rising edge for each, not a burst.
                C_GAP: cstate <= C_REQ;
                // The line is complete; the CPU's own access finishes here.
                C_SERVE: if (!acc_active) cstate <= C_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Bus and ready
    // ------------------------------------------------------------------
    assign bus_req     = fill_req ? 1'b1 : (use_cache ? 1'b0 : acc_active);
    assign bus_we      = fill_req ? 1'b0 : (use_cache ? 1'b0 : acc_write);
    assign bus_addr    = fill_req ? fill_addr : eab;
    assign bus_wdata   = fill_req ? 16'h0000 : cpu_dout;
    assign bus_uds     = fill_req ? 1'b1 : !n_uds;
    assign bus_lds     = fill_req ? 1'b1 : !n_lds;
    assign bus_fc      = fill_req ? 3'b110 : fc;
    assign bus_is_fill = fill_req;

    // A hit is ready at once. A miss is ready in C_SERVE, the cycle after the
    // last word landed, when the requested word is in cache_line. A line
    // invalidated by a write cannot be mid-fill: the CPU is writing, not
    // fetching.
    assign acc_ready = use_cache ? (cache_hit || (cstate == C_SERVE)) : bus_ready;

    assign cpu_din = use_cache ? cache_word : bus_rdata;

    logic iack_prev;
    always_ff @(posedge clk) iack_prev <= reset ? 1'b0 : in_iack;
    assign iack       = in_iack && !iack_prev;
    assign iack_level = eab[3:1];

    // ------------------------------------------------------------------
    // Debug trace
    // ------------------------------------------------------------------
    logic dbg_sent;

    always_ff @(posedge clk) begin
        dbg_stb <= 1'b0;
        if (reset) begin
            dbg_sent <= 1'b0;
        end else if (!acc_active) begin
            dbg_sent <= 1'b0;
        end else if (acc_ready && !dbg_sent) begin
            dbg_stb  <= 1'b1;
            dbg_we   <= acc_write;
            dbg_addr <= eab;
            dbg_data <= acc_write ? cpu_dout : cpu_din;
            dbg_uds  <= !n_uds;
            dbg_lds  <= !n_lds;
            dbg_sent <= 1'b1;
        end
    end

endmodule
`default_nettype wire
