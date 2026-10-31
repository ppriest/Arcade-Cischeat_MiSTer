`timescale 1ns/10ps
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// From Arcade-Seta_MiSTer, where outclk_0 is clk_sys. Here it is clk_mem,
	// the SDRAM controller's 96 MHz; outclk_2 is clk_sys, 48 MHz, half of it,
	// so the two are synchronous with every 48 MHz edge on a 96 MHz edge.
	output wire outclk_0,

	// SDRAM_CLK: outclk_0 shifted 180 degrees (5208 ps), the value Psikyo
	// proved on hardware with this controller and Seta carried at 96 MHz. A
	// chip model has no clock phase, so no simulation checks it.
	output wire outclk_1,

	output wire outclk_2,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("96.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("96.000000 MHz"),
		.phase_shift1("5208 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("48.000000 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		// THE BUS, NOT JUST THE PARAMETERS. number_of_clocks(3) and
		// output_clock_frequency2 are not enough on their own: this
		// concatenation is the actual wiring, and leaving it two wide left
		// outclk_2 dangling. clk_video was then undriven, every register in
		// arcade_video went "Stuck at GND due to stuck port clock", and the
		// whole video chain was optimised away -- 4,000 ALMs, 35 RAM blocks
		// and 9 DSPs lighter, reporting +0.238 ns and TIMING MET.
		.outclk	({outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

