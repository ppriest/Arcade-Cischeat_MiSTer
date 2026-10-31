// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone area and Fmax for FX68K (ijor/fx68k), one and four instances, on
// the DE10-nano's Cyclone V 5CSEBA6U23I7, speed grade 7, Quartus 17.0 - the
// same device, effort and seed KonamiGX used for TG68K.C (2,926 ALMs), so the
// two numbers are comparable.
//
// Not part of the core. It answers one question before the roadmap commits:
// what does a microcoded 68000 cost, and what do four or five of them leave for
// tilemaps, roads and sprites. Cischeat needs three at 10-12 MHz plus a sound
// CPU, and f1gpstr2/wildplt add an I/O CPU.
//
// Every input is driven from a register and every output lands in one, so each
// timing path is register-to-register and the pad ring stays out of the report
// (pins are VIRTUAL, see the .qsf). Instances get slightly different data so
// they cannot be merged; their outputs are XOR-reduced into sig.

module fx68k_bank #(
    parameter int N = 1
) (
    input  logic       clk,
    input  logic       reset,
    output logic [7:0] sig
);
    logic [1:0]  phase;
    logic        r_reset, r_dtack;
    logic [15:0] r_edb;
    logic [2:0]  r_ipl;

    always_ff @(posedge clk) begin
        phase   <= phase + 2'd1;
        r_reset <= reset;
        r_dtack <= 1'b0;
        r_edb   <= r_edb + 16'd1;
        r_ipl   <= r_ipl + 3'd1;
    end

    logic [N-1:0] acc;
    logic [7:0]   acc8;
    genvar g;

    // Quartus 17.0: genvar declared outside the generate, and no size casts.
    always_comb acc8 = {{(8-N){1'b0}}, acc};

    generate
        for (g = 0; g < N; g++) begin : g_cpu
            localparam logic [15:0] PERTURB = g;
            logic [23:1] eab;
            logic [15:0] oedb;
            logic [2:0]  fc;
            logic        halted, stop;

            fx68k u_cpu (
                .clk(clk), .HALTn(1'b1), .extReset(r_reset), .pwrUp(r_reset),
                .enPhi1(phase[0]), .enPhi2(phase[1]),
                .eRWn(), .ASn(), .LDSn(), .UDSn(), .E(), .VMAn(),
                .E_PosClkEn(), .E_NegClkEn(),
                .FC0(fc[0]), .FC1(fc[1]), .FC2(fc[2]),
                .BGn(), .oRESETn(), .oHALTEDn(halted),
                .DTACKn(r_dtack), .VPAn(1'b1), .BERRn(1'b1),
                .BRn(1'b1), .BGACKn(1'b1),
                .IPL0n(r_ipl[0]), .IPL1n(r_ipl[1]), .IPL2n(r_ipl[2]),
                .iEdb(r_edb ^ PERTURB),
                .oEdb(oedb), .eab(eab), .stop_out(stop)
            );

            always_ff @(posedge clk)
                acc[g] <= (^eab) ^ (^oedb) ^ (^fc) ^ halted ^ stop;
        end
    endgenerate

    always_ff @(posedge clk)
        sig <= {8{^acc}} ^ acc8;

endmodule

module fx68k_area_top1 (
    input  logic       clk,
    input  logic       reset,
    output logic [7:0] sig
);
    fx68k_bank #(.N(1)) u_bank (.clk(clk), .reset(reset), .sig(sig));
endmodule

module fx68k_area_top4 (
    input  logic       clk,
    input  logic       reset,
    output logic [7:0] sig
);
    fx68k_bank #(.N(4)) u_bank (.clk(clk), .reset(reset), .sig(sig));
endmodule

module fx68k_area_top5 (
    input  logic       clk,
    input  logic       reset,
    output logic [7:0] sig
);
    fx68k_bank #(.N(5)) u_bank (.clk(clk), .reset(reset), .sig(sig));
endmodule
