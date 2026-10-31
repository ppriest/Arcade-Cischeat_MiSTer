// SPDX-License-Identifier: GPL-3.0-or-later
//
// Boot cischeat's main 68000 through fx68k_bus against the real program ROM,
// log every CPU access, and count clocks for the CPI measurement.
//
//     python scripts/mame_boot_trace.py cischeat 1400000
//     python scripts/mame_rom_dump.py cischeat
//     python scripts/compare_boot_trace.py replay cischeat
//     scripts/run_sim.sh cischeat_boot_tb                     # 700,000 accesses
//     python scripts/compare_boot_trace.py compare cischeat
//
// The 700,000-access window covers the reset vector, the init code at 0x7e0 and
// 0x206a, the 65,536-iteration delay loop at 0x2150 (a CLR.W watchdog kick, a
// SUBI.L and a BNE, 46 68000 clocks), the CPU-release write to 0x82308 at
// access 655,391, and the first 44,000 accesses of the next delay loop. MAME's
// trace is captured longer (1,400,000) so the reference is not the end of the
// window; the comparison truncates it to the RTL's last write.
//
// WHAT IS MODELLED
// ----------------
// ROM: MAME's decoded program-space image (scripts/mame_rom_dump.py), so the
// driver's byte interleave is already applied. Work RAM, shared RAM, scroll
// RAM and the cabinet link RAM: a byte-lane-writable array. I/O: reads are
// replayed in order from MAME's own trace, writes are accepted and ignored -
// which is what "every peripheral stubbed to what MAME's returns" means here.
// In this window the main CPU reads the watchdog register once per delay-loop
// iteration (the read half of CLR's read-modify-write) and nothing else, and
// the replay supplies exactly the values MAME's CPU got.
//
// The memory is a LEVEL handshake with LAT clk of latency, not the SDRAM
// stack. That is deliberate for Phase 0: the trace tests the CPU and the
// address decode, and a short-latency model keeps it fast. Phase 2 re-runs the
// same comparison with the production transport in front of it. CPI is
// reported separately for LAT=2 (a floor: memory is never in the way) and
// LAT=8 (a stand-in for SDRAM plus arbitration) so the wrapper's timing does
// not rest on one arbitrary number; docs/PHASE0.md has the sweep.
//
// The line cache changes what the memory sees but not what the CPU does: dbg_*
// reports completed CPU accesses, so a cache hit logs the same read as a miss.
// ICACHE=0 removes the cache for the CPI comparison.
//
// PLUSARGS
//   +ROM=path        ROM image (default debug/cischeat-rom/cischeat_rom.hex)
//   +REPLAY=path     MAME I/O read replay (default debug/cischeat-boot/cischeat_replay.txt)
//   +TRACE=path      output trace (default debug/cischeat-boot/cischeat_rtl.trace)
//   +N=n             accesses to log, then stop (default 700000)
//   +LAT=n           memory latency in clk (default 2)
//   +MARKADDR=hex    write address to mark (default 082208, the watchdog)
//   +MARKMASK=hex    its byte lanes (default FFFF)
//   +MARKA=n         print cycle counts at the n-th such write (0 = off)
//   +MARKB=n         ... and stop there instead of at +N
//
// PARAMETERS (pass with vsim -GNAME=value)
//   ICACHE, PHASE_NUM, PHASE_DEN.
//
// CPI prints CPU clocks per access (a 68000 bus access), the stall clk the
// wrapper added, and the two summed as clk-of-48MHz per access, which is what
// the board actually pays. The delay loop's 46 68000 clocks per iteration is
// the M68000's own timing (CLR.W abs.l 20 + SUBI.L #1,Dn 16 + BNE taken 10),
// so CPU clocks per iteration above 46 is a wait state.

`timescale 1ns / 1ps

module tb_cischeat_boot;

    parameter int ICACHE    = 1;
    parameter int PHASE_NUM = 24;
    parameter int PHASE_DEN = 5;

    // ---- clock: 48 MHz, so a printed time is the real board's ----
    logic clk = 1'b0;
    always #10.416667 clk = ~clk;

    logic reset = 1'b1;

    // ---- plusargs ----
    string  rom_path    = "debug/cischeat-rom/cischeat_rom.hex";
    string  replay_path = "debug/cischeat-boot/cischeat_replay.txt";
    string  trace_path  = "debug/cischeat-boot/cischeat_rtl.trace";
    int     n_max       = 700000;
    int     lat         = 2;
    int     mark_a      = 0;
    int     mark_b      = 0;
    logic [23:0] mark_addr = 24'h082208;
    logic [15:0] mark_mask = 16'hFFFF;

    initial begin
        void'($value$plusargs("ROM=%s", rom_path));
        void'($value$plusargs("REPLAY=%s", replay_path));
        void'($value$plusargs("TRACE=%s", trace_path));
        void'($value$plusargs("N=%d", n_max));
        void'($value$plusargs("LAT=%d", lat));
        void'($value$plusargs("MARKADDR=%h", mark_addr));
        void'($value$plusargs("MARKMASK=%h", mark_mask));
        void'($value$plusargs("MARKA=%d", mark_a));
        void'($value$plusargs("MARKB=%d", mark_b));
    end

    // ---- ROM: MAME's decoded program image; 512 KB at 0, 512 KB at 100000 ----
    localparam int ROM_HALF = 262144;          // words in one 512 KB half
    logic [15:0] rom [0:2*ROM_HALF-1];

    // ---- replay of MAME's non-ROM reads, in MAME's order ----
    // One entry per non-ROM read in the MAME window, and the cischeat boot's
    // delay loop reads the watchdog register once per iteration, so a long
    // window needs room for tens of thousands of entries.
    localparam int MAX_REPLAY = 262144;
    logic [23:0] rp_addr [0:MAX_REPLAY-1];
    logic [15:0] rp_mask [0:MAX_REPLAY-1];
    logic [15:0] rp_data [0:MAX_REPLAY-1];
    int          rp_n = 0, rp_i = 0;

    // ---- trace and cycle accounting (declared before the model uses them) ----
    int     seq = 0;
    int     unmapped = 0, replay_miss = 0;
    int     mark_n = 0;
    logic   finished = 1'b0;
    logic   trace_open = 1'b0;
    longint cycles = 0, stalls = 0;
    longint cyc_at_a = 0, st_at_a = 0, acc_at_a = 0;
    longint bus_reqs = 0, bus_fills = 0;
    longint reqs_at_a = 0, fills_at_a = 0;
    int     fd_trace;

    // ---- the CPU and its bus ----
    logic        bus_req, bus_we, bus_uds, bus_lds, bus_is_fill;
    logic [23:1] bus_addr;
    logic [15:0] bus_wdata, bus_rdata;
    logic        bus_ready;
    logic [2:0]  bus_fc;
    logic        dbg_stb, dbg_we, dbg_uds, dbg_lds;
    logic [23:1] dbg_addr;
    logic [15:0] dbg_data;
    logic        cycle_tick, stall_tick;

    fx68k_bus #(.PHASE_NUM(PHASE_NUM), .PHASE_DEN(PHASE_DEN), .ICACHE(ICACHE)) u_cpu (.fast(1'b0),
        .clk         (clk),
        .reset       (reset),
        .cpu_run     (1'b1),
        .ipl_level   (3'd0),
        .bus_req     (bus_req),
        .bus_we      (bus_we),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_uds     (bus_uds),
        .bus_lds     (bus_lds),
        .bus_fc      (bus_fc),
        .bus_is_fill (bus_is_fill),
        .bus_rdata   (bus_rdata),
        .bus_ready   (bus_ready),
        .dbg_stb     (dbg_stb),
        .dbg_we      (dbg_we),
        .dbg_addr    (dbg_addr),
        .dbg_data    (dbg_data),
        .dbg_uds     (dbg_uds),
        .dbg_lds     (dbg_lds),
        .cycle_tick  (cycle_tick),
        .stall_tick  (stall_tick)
    );

    // ---- memory map, from jaleco/cischeat.cpp ----
    function automatic bit is_rom(input [23:0] a);
        is_rom = (a < 24'h080000) || (a >= 24'h100000 && a < 24'h180000);
    endfunction

    function automatic bit is_ram(input [23:0] a);
        // 084000-08ffff cabinet link, 090000-0bffff shared/scroll/palette,
        // 0f0000-0fffff work RAM. a[17:0] is unique across all three.
        is_ram = (a >= 24'h084000 && a < 24'h0c0000) ||
                 (a >= 24'h0f0000 && a < 24'h100000);
    endfunction

    logic [15:0] ram [0:262143];

    function automatic [15:0] rom_word(input [23:0] a);
        if (a < 24'h080000)
            rom_word = rom[a[18:1]];
        else
            rom_word = rom[ROM_HALF + a[18:1]];
    endfunction

    function automatic [15:0] lanes(input logic uds, lds);
        lanes = {uds ? 8'hFF : 8'h00, lds ? 8'hFF : 8'h00};
    endfunction

    // ---- memory model: one word request, held, ready after LAT clk ----
    logic        m_act, m_ready;
    logic [23:1] m_addr;
    logic [15:0] m_wdata, m_rdata;
    logic        m_we, m_uds, m_lds, m_fill;
    int          m_wait;

    assign bus_ready = m_ready;
    assign bus_rdata = m_rdata;

    always_ff @(posedge clk) begin
        if (reset) begin
            m_act   <= 1'b0;
            m_ready <= 1'b0;
            m_wait  <= 0;
            m_rdata <= 16'h0000;
        end else if (!bus_req) begin
            m_act   <= 1'b0;
            m_ready <= 1'b0;
            m_wait  <= 0;
        end else if (!m_act) begin
            m_act   <= 1'b1;
            m_ready <= 1'b0;
            m_wait  <= 0;
            m_addr  <= bus_addr;
            m_wdata <= bus_wdata;
            m_we    <= bus_we;
            m_uds   <= bus_uds;
            m_lds   <= bus_lds;
            m_fill  <= bus_is_fill;
        end else if (!m_ready) begin
            if (m_wait + 1 >= lat) begin
                m_ready <= 1'b1;
                if (m_we) begin
                    if (is_ram({m_addr, 1'b0})) begin
                        if (m_uds) ram[m_addr[17:1]][15:8] <= m_wdata[15:8];
                        if (m_lds) ram[m_addr[17:1]][7:0]  <= m_wdata[7:0];
                    end
                    // ROM and I/O writes are accepted and ignored, as MAME does.
                end else if (is_rom({m_addr, 1'b0})) begin
                    m_rdata <= rom_word({m_addr, 1'b0});
                end else if (is_ram({m_addr, 1'b0})) begin
                    m_rdata <= ram[m_addr[17:1]];
                end else if (m_fill) begin
                    // A line fill that runs off the end of a ROM range reads
                    // the hole. It never consumes an I/O replay slot.
                    m_rdata <= 16'hFFFF;
                end else if (rp_i < rp_n) begin
                    if (rp_addr[rp_i] == {m_addr, 1'b0} &&
                        rp_mask[rp_i] == lanes(m_uds, m_lds)) begin
                        m_rdata <= rp_data[rp_i];
                        rp_i    <= rp_i + 1;
                    end else begin
                        $display("REPLAY-MISS access %0d: RTL %06X %04X, replay %06X %04X",
                                 seq + 1, {m_addr, 1'b0}, lanes(m_uds, m_lds),
                                 rp_addr[rp_i], rp_mask[rp_i]);
                        replay_miss <= replay_miss + 1;
                        m_rdata <= 16'hFFFF;
                    end
                end else begin
                    $display("UNMAPPED read %06X at access %0d", {m_addr, 1'b0}, seq + 1);
                    unmapped <= unmapped + 1;
                    m_rdata <= 16'hFFFF;
                end
            end else begin
                m_wait <= m_wait + 1;
            end
        end
    end

    // ---- load the images and release reset ----
    // $fopen's (name, mode) form returns a multichannel descriptor. ModelSim's
    // PLI-3073 rejects SystemVerilog's three-argument $fopen(fd, name, mode).
    initial begin
        int fd, ra, rm, rd, got;
        fd_trace = $fopen(trace_path, "w");
        if (fd_trace == 0) begin
            $display("cannot open trace %s", trace_path);
            $fatal(1);
        end
        trace_open = 1'b1;
        fd = $fopen(rom_path, "r");
        if (fd == 0) begin
            $display("cannot open ROM %s -- run scripts/mame_rom_dump.py first", rom_path);
            $fatal(1);
        end
        $fclose(fd);
        $readmemh(rom_path, rom);

        fd = $fopen(replay_path, "r");
        if (fd == 0) begin
            $display("cannot open replay %s -- run compare_boot_trace.py replay first", replay_path);
            $fatal(1);
        end
        while (!$feof(fd)) begin
            got = $fscanf(fd, "%x %x %x\n", ra, rm, rd);
            if (got == 3 && rp_n < MAX_REPLAY) begin
                rp_addr[rp_n] = ra[23:0];
                rp_mask[rp_n] = rm[15:0];
                rp_data[rp_n] = rd[15:0];
                rp_n = rp_n + 1;
            end
        end
        $fclose(fd);

        $display("ROM    %s", rom_path);
        $display("REPLAY %s (%0d entries)", replay_path, rp_n);
        $display("TRACE  %s, ICACHE=%0d, %0d/%0d clk per CPU clock, LAT=%0d",
                 trace_path, ICACHE, PHASE_NUM, PHASE_DEN, lat);

        repeat (40) @(posedge clk);
        reset <= 1'b0;
    end

    // Clock accounting: cycle_tick is one per CPU clock (phi1), stall_tick is
    // one per clk a phi2 was held for memory. bus_reqs counts transactions on
    // the memory side, which is what the SDRAM arbiter will see; bus_fills is
    // how many of them the line cache issued. Their ratio is the cache's
    // granule, so a broken cache shows up here and not in the trace.
    logic reqs_prev;

    always_ff @(posedge clk) begin
        reqs_prev <= (reset ? 1'b0 : bus_req);
        if (!reset) begin
            if (cycle_tick) cycles <= cycles + 1;
            if (stall_tick) stalls <= stalls + 1;
            if (bus_req && !reqs_prev) begin
                bus_reqs <= bus_reqs + 1;
                if (bus_is_fill) bus_fills <= bus_fills + 1;
            end
        end
    end

    // ---- trace ----
    always_ff @(posedge clk) begin
        if (dbg_stb && !finished) begin
            seq <= seq + 1;
            $fdisplay(fd_trace, "%0d\t%s\t%06X\t%04X\t%04X",
                      seq + 1, dbg_we ? "w" : "r", {dbg_addr, 1'b0},
                      lanes(dbg_uds, dbg_lds), dbg_data & lanes(dbg_uds, dbg_lds));

            if (dbg_we && {dbg_addr, 1'b0} == mark_addr &&
                lanes(dbg_uds, dbg_lds) == mark_mask) begin
                mark_n <= mark_n + 1;
                if (mark_n + 1 == mark_a || mark_n + 1 == mark_b)
                    $display("MARK write=%0d access=%0d cycles=%0d stalls=%0d",
                             mark_n + 1, seq + 1, cycles, stalls);
                if (mark_n + 1 == mark_a) begin
                    cyc_at_a  <= cycles;
                    st_at_a   <= stalls;
                    acc_at_a  <= seq;
                    reqs_at_a <= bus_reqs;
                    fills_at_a <= bus_fills;
                end
            end

            if ((mark_b > 0 && mark_n + 1 == mark_b) ||
                (mark_b == 0 && seq + 1 >= n_max)) begin
                finished <= 1'b1;
                $fdisplay(fd_trace, "# %0d accesses, %0d unmapped, %0d replay misses",
                          seq + 1, unmapped, replay_miss);
                $fclose(fd_trace);
                trace_open <= 1'b0;
                $display("TRACE %0d accesses -> %s (unmapped %0d, replay misses %0d)",
                         seq + 1, trace_path, unmapped, replay_miss);
                $display("BUS   %0d memory transactions, %0d of them cache fill words (%.1f%% of CPU accesses)",
                         bus_reqs, bus_fills,
                         100.0 * real'(bus_reqs) / real'(seq + 1));
                if (mark_a > 0 && mark_b > 0) begin
                    $display("CPI   writes %0d..%0d: %0d CPU clocks, %0d stall clk, %0d accesses",
                             mark_a, mark_b, cycles - cyc_at_a, stalls - st_at_a,
                             seq - acc_at_a);
                    $display("CPI   %.3f CPU clocks per access, + %.3f stall clk per access",
                             real'(cycles - cyc_at_a) / real'(seq - acc_at_a),
                             real'(stalls - st_at_a) / real'(seq - acc_at_a));
                    $display("CPI   %.2f clk-of-48MHz per access (CPU %.3f x %0d/%0d + %.3f stall)",
                             real'(cycles - cyc_at_a) * real'(PHASE_NUM) / real'(PHASE_DEN)
                                 / real'(seq - acc_at_a)
                                 + real'(stalls - st_at_a) / real'(seq - acc_at_a),
                             real'(cycles - cyc_at_a) / real'(seq - acc_at_a),
                             PHASE_NUM, PHASE_DEN,
                             real'(stalls - st_at_a) / real'(seq - acc_at_a));
                    $display("CPI   %0d bus transactions, %0d fills over %0d accesses (%.1f%%)",
                             bus_reqs - reqs_at_a, bus_fills - fills_at_a, seq - acc_at_a,
                             100.0 * real'(bus_reqs - reqs_at_a) / real'(seq - acc_at_a));
                end
                $finish;
            end
        end
    end

    // Backstop: a CPU that stops making accesses still ends the run. A
    // 700,000-access window is about 0.34 s of 48 MHz time; leave an order of
    // magnitude, or the longest trace in this phase would trip it.
    initial begin
        #(5 * 1000 * 1000 * 1000);
        $display("TIMEOUT at %0d accesses (%0d unmapped, %0d replay misses)",
                 seq, unmapped, replay_miss);
        if (trace_open) begin
            $fdisplay(fd_trace, "# TIMEOUT at %0d accesses", seq);
            $fclose(fd_trace);
        end
        $finish;
    end

endmodule
