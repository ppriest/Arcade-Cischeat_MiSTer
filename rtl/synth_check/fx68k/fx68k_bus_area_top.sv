// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the bus wrapper and the line cache add: area and Fmax for one and five
// FX68Ks behind fx68k_bus, each with a synchronous ROM on its memory side.
//
// The bare-CPU harness (fx68k_area_top.sv) answers what a 68000 costs. This
// one answers what the core will actually instantiate costs, and it is the
// number the roadmap's Phase 0 criterion 4 asks for: five CPUs, one bus
// wrapper, the line cache and memory behind the program ROM.
//
// Each instance gets its own PHASE_NUM/PHASE_DEN so both patterns the core uses
// are in the same fit (10 MHz = 24/5, 12 MHz = 4/1) and so no two instances can
// be merged. The memory is a 2K x 16 simple dual-port RAM with a registered
// read: enough to be a real M10K, small enough not to distort the comparison
// with the one-instance revision, and it puts a RAM block at the end of the
// bus so the reported path is CPU -> wrapper -> RAM -> wrapper -> CPU, which is
// the loop the core runs in. Its write port is driven so the contents are not
// a synthesis constant (see the note at the RAM).
//
// Pins are VIRTUAL (see the .qsf) and every input comes from a register, so the
// report is the kernel's own register-to-register limit.

module fx68k_bus_bank #(
    parameter int N = 1
) (
    input  logic       clk,
    input  logic       reset,
    output logic [7:0] sig
);
    logic [1:0]  phase;
    logic        r_reset;
    logic [2:0]  r_ipl;

    always_ff @(posedge clk) begin
        phase   <= phase + 2'd1;
        r_reset <= reset;
        r_ipl   <= r_ipl + 3'd1;
    end

    logic [N-1:0] acc;
    logic [7:0]   acc8;
    genvar g;

    // Quartus 17.0: genvar declared outside the generate, and no size casts.
    always_comb acc8 = {{(8-N){1'b0}}, acc};

    generate
        for (g = 0; g < N; g++) begin : g_cpu
            localparam int PN = (g % 2 == 0) ? 24 : 4;
            localparam int PD = (g % 2 == 0) ? 5  : 1;

            logic        bus_req, bus_we, bus_uds, bus_lds, bus_is_fill;
            logic [23:1] bus_addr;
            logic [15:0] bus_wdata, bus_rdata;
            logic        bus_ready;
            logic [2:0]  bus_fc;
            logic        dbg_stb, dbg_we, dbg_uds, dbg_lds;
            logic [23:1] dbg_addr;
            logic [15:0] dbg_data;
            logic        cycle_tick, stall_tick;

            logic [15:0] rom [0:2047];
            logic [15:0] rom_q;
            logic        ready_q;

            // The loader's write port is not decoration: a ROM whose contents
            // are never written and never initialised is a constant zero to
            // Quartus, which then prunes half the CPU's datapath (measured:
            // 1,040 ALMs for a CPU that costs 2,061). A write port makes the
            // contents unknown, which is also what the real SDRAM backend is
            // doing while the game loads.
            logic [10:0] wr_addr;
            logic [15:0] wr_data;

            fx68k_bus #(.PHASE_NUM(PN), .PHASE_DEN(PD), .ICACHE(1'b1)) u_bus (.fast(1'b0),
                .clk         (clk),
                .reset       (r_reset),
                .cpu_run     (1'b1),
                .ipl_level   (r_ipl),
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

            // One clk from request to ready, and ready stays up while the
            // request is held, which is the contract fx68k_bus requires.
            always_ff @(posedge clk) begin
                ready_q <= bus_req;
                if (bus_req)
                    rom_q <= rom[bus_addr[11:1]];
                rom[wr_addr] <= wr_data;
                wr_addr      <= wr_addr + 11'd1;
                wr_data      <= wr_data + 16'd7;
            end

            assign bus_ready = ready_q;
            assign bus_rdata = rom_q;

            always_ff @(posedge clk)
                acc[g] <= ^{cycle_tick, stall_tick, dbg_stb, dbg_we, dbg_uds,
                            dbg_lds, dbg_addr, dbg_data, bus_we, bus_uds,
                            bus_lds, bus_is_fill, bus_addr, bus_wdata, bus_fc};
        end
    endgenerate

    always_ff @(posedge clk)
        sig <= {8{^acc}} ^ acc8;

endmodule

module fx68k_bus_area_top1 (
    input  logic       clk,
    input  logic       reset,
    output logic [7:0] sig
);
    fx68k_bus_bank #(.N(1)) u_bank (.clk(clk), .reset(reset), .sig(sig));
endmodule

module fx68k_bus_area_top5 (
    input  logic       clk,
    input  logic       reset,
    output logic [7:0] sig
);
    fx68k_bus_bank #(.N(5)) u_bank (.clk(clk), .reset(reset), .sig(sig));
endmodule
