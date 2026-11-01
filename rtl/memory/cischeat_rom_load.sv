// SPDX-License-Identifier: GPL-3.0-or-later
//
// Load-time copy of the .mra image from the DDR3 window (0x30000000, where the
// HPS puts a download with address="0x30000000") into SDRAM: ddram_phy ->
// rom_loader -> cischeat_rom_transform (sound program bitswap, sprite
// untangle) -> cischeat_sdram's download port. All on clk_mem, the SDRAM
// controller's clock, so the download port needs no crossing; DDRAM_CLK is
// clk_mem at the top level. Hold the board in reset while busy.

module cischeat_rom_load (
	input  logic         clk,           // clk_mem
	input  logic         reset,
	input  logic         gatearray,     // sound program bitswap: Big Run and Cisco Heat only
	input  logic         gs88000,       // Cisco Heat's gate array, else D65006

	input  logic         start,         // pulse: copy length bytes
	input  logic [27:0]  length,
	output logic         busy,

	input  logic         DDRAM_BUSY,
	output logic [7:0]   DDRAM_BURSTCNT,
	output logic [28:0]  DDRAM_ADDR,
	input  logic [63:0]  DDRAM_DOUT,
	input  logic         DDRAM_DOUT_READY,
	output logic         DDRAM_RD,
	output logic [63:0]  DDRAM_DIN,
	output logic [7:0]   DDRAM_BE,
	output logic         DDRAM_WE,

	output logic         dl_req,
	output logic [25:0]  dl_addr,
	output logic [15:0]  dl_data,
	output logic         dl_we16,
	input  logic         dl_busy
);

	logic        ddr_req, ddr_busy, ddr_valid;
	logic [27:0] ddr_addr;
	logic [63:0] ddr_rdata;

	ddram_phy u_ddr (
		.clk, .reset,
		.DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,
		.DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
		.req(ddr_req), .we(1'b0), .addr(ddr_addr), .wdata(8'h00),
		.busy(ddr_busy), .valid(ddr_valid), .rdata(ddr_rdata)
	);

	logic [25:0] raw_addr, xf_addr;
	logic [15:0] raw_word, xf_data;

	rom_loader u_load (
		.clk, .reset, .length, .start, .busy,
		.ddr_req, .ddr_addr, .ddr_busy, .ddr_valid, .ddr_rdata,
		.raw_addr, .raw_word, .xf_addr, .xf_data,
		.dl_req, .dl_addr, .dl_data, .dl_we16, .dl_busy
	);

	cischeat_rom_transform u_xf (.gatearray, .gs88000, .raw_addr, .raw_word, .xf_addr, .xf_data);

endmodule
