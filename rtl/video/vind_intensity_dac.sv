`timescale 1ns/1ps
//============================================================================
//  Vindicators — SP-317 sheet 10 (the 18M LS283 intensity adder, the 18D / 18F
//  registers and the 17M/17L output registers) and sheet 11 (the RGBI current
//  DACs, the ZREF reference and the all-zero clamps).
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later.
//
//  ---------------------------------------------------------------------------
//  1. THE INTENSITY ADDER  (sheet 10)
//  ---------------------------------------------------------------------------
//      18M LS283 : A = INT3..INT0, B = MOG3, MOG2, MOG1, PR1(=1), C0 = PR1(=1)
//      =>  IOUT[3:0] = INT + 2*MOG[3:1] + 2   (mod 16, a WRAPPING 4-bit adder)
//  With the idle value MOG = 111 that is INT + 14 + 2 = INT: the intensity
//  passes through untouched.  The kludge only fires when MAT6 and MSD3 are both
//  set, where 16F LS32 lets MAT3..MAT1 through (the ACTIVE-LOW nets, i.e. the
//  complement of the logical colour bits) -- exactly MAME's
//  `if (mo[x] & 8) pf[x] |= (~mo[x] & 0xe0) << 6;`.
//
//  ---------------------------------------------------------------------------
//  2. BLANKING  (sheet 10, sheet 11)
//  ---------------------------------------------------------------------------
//  17M/17L LS273 are cleared ASYNCHRONOUSLY by /VIDBL, so blanking forces
//  I = R = G = B = 0 and the sheet-11 all-zero clamps drive each channel hard
//  to black.  There is no separate blanking pedestal: the blanking level IS
//  colour code 0.  VIDCLK = ~(RCLKA & /CLRAM & /CLRDL), so the pixel is only
//  clocked out on cycles that are not CPU colour-RAM cycles.
//
//  ---------------------------------------------------------------------------
//  3. THE LADDER  (sheet 11)
//  ---------------------------------------------------------------------------
//  Intensity ladder into node Z (all through open-collector 7406 inverters):
//      R119 120R = bit3   R118 240R = bit2   R117 470R = bit1   R116 1K = bit0
//      R120 1K   driven by 19M LS260 = NOR(IOUT3..IOUT0), i.e. it sinks one
//                extra LSB whenever IOUT != 0 -- a fixed pedestal;
//      R121 240R to GND  sets Q12's idle so Q11 is JUST cut off at IOUT == 0,
//                i.e. ZREF == 0 (hard black) at intensity code 0.
//  Colour ladder (identical in all three channels):
//      R111/R103/R95  620R  = bit3      R110/R102/R94  1.2K = bit2
//      R109/R101/R93  2.4K  = bit1      R108/R100/R92  4.7K = bit0
//  and a 470R all-zero clamp (19M/19L LS260 + one more 7406) that pulls the
//  gain stage's bias down when the whole nibble is 0.
//
//  In conductance units normalised to the LSB resistor, the E24 values give
//      intensity   8.333 : 4.167 : 2.128 : 1.000   (ideal 8 : 4 : 2 : 1)
//      colour      7.581 : 3.917 : 1.958 : 1.000   (ideal 8 : 4 : 2 : 1)
//  so the real ladders are ~3 % non-linear.  MAME uses an exact `*15` multiply
//  and the 17-step table
//      ztable[] = { 0, 3, 4, 5, 6, 7, 8, 9, a, b, c, d, e, f, 10, 11 }
//  whose shape (0 at code 0, n+2 for n >= 1) reproduces R121's threshold and
//  R120's pedestal but not the ladder's curvature.  `DAC_MAME_COMPAT = 1`
//  selects MAME's table and its exact multiply, for bit-exact comparison
//  against MAME's rendering; the release build uses the resistor-ladder
//  transfer, which is the default.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_intensity_dac #(
	// 1 = MAME's ztable and its exact multiply, for bit-exact comparison
	// against MAME's rendering.  0 = the resistor-ladder transfer derived in
	// the header, which is what the release build uses.
	parameter bit DAC_MAME_COMPAT = 1'b0
)(
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	input  logic  [3:0] cint,
	input  logic  [3:0] cred,
	input  logic  [3:0] cgrn,
	input  logic  [3:0] cblu,
	input  logic  [2:0] mog,
	input  logic        vidbl_n,      // SYNGEN pin 16, asynchronous clear
	input  logic        vidclk_en,    // 9F LS11 + 17F LS04: the VIDCLK enable

	output logic  [3:0] iout,       // the blanked value, i.e. what the DAC sees
	output logic  [7:0] red,
	output logic  [7:0] green,
	output logic  [7:0] blue
);

	// =====================================================================
	// 1. 18M LS283
	// =====================================================================
	wire [4:0] sum = {1'b0, cint} + {1'b0, mog, 1'b1} + 5'd1;

	// MAME does NOT compute this sum.  `paletteram_w` indexes ztable with
	// `((data >> 12) + (c * 2)) & 15`, where `c` is 0 for an ordinary pixel and
	// `~MAT3-1` (= MOG) only on a kludge pixel (`screen_update`'s second MO
	// pass, `pf[x] |= (~mo[x] & 0xe0) << 6`).  Hardware's idle MOG is 111, so
	// `INT + 2*7 + 2 = INT + 16 = INT` and the two agree for ordinary pixels --
	// but on a kludge pixel hardware gives `INT + 2*MOG + 2` where MAME gives
	// `INT + 2*MOG`, i.e. the hardware is TWO ztable steps higher.  That is a
	// real difference between the two, so DAC_MAME_COMPAT reproduces MAME's
	// arithmetic as well as its table.
	wire [4:0] sum_mame = {1'b0, cint} + {1'b0, (&mog) ? 3'd0 : mog, 1'b0};
	wire [3:0] iout_c = DAC_MAME_COMPAT ? sum_mame[3:0] : sum[3:0];
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused = &{1'b0, sum[4], sum_mame[4]};   // the LS283's C4 goes nowhere
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	// 2. 17M / 17L LS273 -- the output registers
	// =====================================================================
	// /VIDBL is an ASYNCHRONOUS clear on these two '273s, and their clock is
	// VIDCLK = ~(RCLKA & /CLRAM & /CLRDL) -- so they load on RCLKA's FALLING
	// edge, HALF a pixel out of phase with the SYNGEN grid /VIDBL itself is
	// aligned to.  On the board the clear therefore costs nothing: /VIDBL
	// releases at a pixel boundary and the very next VIDCLK edge, half a pixel
	// later, already loads the first visible pixel.
	//
	// Written literally as a synchronous clear in a pixel-quantised core it
	// costs a WHOLE pixel -- the register is still holding zero throughout the
	// first pixel after /VIDBL releases -- and the picture loses its leftmost
	// column: one mismatching pixel per row, all at x = 0, against MAME frame
	// captures.  Blanking is therefore modelled as what it observably is on
	// the board: a LEVEL that forces the DAC inputs to zero for exactly the
	// counts /VIDBL is low, with the register itself free-running.  The
	// blanking level is still colour code 0 -- there is no separate pedestal
	// (sheet 11), which is the only thing the clear was there to say.
	logic [3:0] rout, gout, bout;
	logic [3:0] iout_q;
	always_ff @(posedge clk) begin
		if (reset) begin
			iout_q <= 4'd0; rout <= 4'd0; gout <= 4'd0; bout <= 4'd0;
		end else if (ce_7m && vidclk_en) begin
			iout_q <= iout_c;
			rout   <= cred;
			gout   <= cgrn;
			bout   <= cblu;
		end
	end
	assign iout = vidbl_n ? iout_q : 4'd0;

	// =====================================================================
	// 3. The transfer tables
	// =====================================================================
	// MAME's ztable, and the resistor-derived intensity curve.  Both are given
	// on a 0..17 scale so the two paths share the final multiply.
	// Hardware: z(0) = 0; z(n) = w(n) + 2 where w is the conductance sum
	// normalised to the 1K LSB (1000/1000, 1000/470, 1000/240, 1000/120).
	// Rounded to 1/16 LSB and stored x16 to keep the arithmetic integral.
	// Icarus does not accept unpacked localparam arrays, so both tables are
	// case statements.  Values are stored x16 to keep the arithmetic integral.
	//
	// z16_mame(n) = ztable[n] * 16.
	// z16_hw(n)   = (w(n) + 2) * 16, w = the conductance sum normalised to the
	//               1K LSB (1000/1000, 1000/470, 1000/240, 1000/120):
	//    n : w      z=w+2    x16      n : w      z=w+2    x16
	//    0 : -      0          0      8 : 8.333 10.333   165
	//    1 : 1.000  3.000     48      9 : 9.333 11.333   181
	//    2 : 2.128  4.128     66     10 :10.461 12.461   199
	//    3 : 3.128  5.128     82     11 :11.461 13.461   215
	//    4 : 4.167  6.167     99     12 :12.500 14.500   232
	//    5 : 5.167  7.167    115     13 :13.500 15.500   248
	//    6 : 6.294  8.294    133     14 :14.628 16.628   266
	//    7 : 7.294  9.294    149     15 :15.628 17.628   282
	function automatic int z16(input [3:0] n);
		case (n)
			4'd0: z16 = DAC_MAME_COMPAT ?   0 :   0;
			4'd1: z16 = DAC_MAME_COMPAT ?  48 :  48;
			4'd2: z16 = DAC_MAME_COMPAT ?  64 :  66;
			4'd3: z16 = DAC_MAME_COMPAT ?  80 :  82;
			4'd4: z16 = DAC_MAME_COMPAT ?  96 :  99;
			4'd5: z16 = DAC_MAME_COMPAT ? 112 : 115;
			4'd6: z16 = DAC_MAME_COMPAT ? 128 : 133;
			4'd7: z16 = DAC_MAME_COMPAT ? 144 : 149;
			4'd8: z16 = DAC_MAME_COMPAT ? 160 : 165;
			4'd9: z16 = DAC_MAME_COMPAT ? 176 : 181;
			4'd10: z16 = DAC_MAME_COMPAT ? 192 : 199;
			4'd11: z16 = DAC_MAME_COMPAT ? 208 : 215;
			4'd12: z16 = DAC_MAME_COMPAT ? 224 : 232;
			4'd13: z16 = DAC_MAME_COMPAT ? 240 : 248;
			4'd14: z16 = DAC_MAME_COMPAT ? 256 : 266;
			default: z16 = DAC_MAME_COMPAT ? 272 : 282;
		endcase
	endfunction

	// Colour ladder, x16.  MAME multiplies exactly; the hardware weights are
	// 1.000 / 1.958 / 3.917 / 7.581, summing to 14.456, scaled by 15/14.456.
	function automatic int c16(input [3:0] n);
		case (n)
			4'd0: c16 = DAC_MAME_COMPAT ?   0 :   0;
			4'd1: c16 = DAC_MAME_COMPAT ?  16 :  17;
			4'd2: c16 = DAC_MAME_COMPAT ?  32 :  33;
			4'd3: c16 = DAC_MAME_COMPAT ?  48 :  49;
			4'd4: c16 = DAC_MAME_COMPAT ?  64 :  65;
			4'd5: c16 = DAC_MAME_COMPAT ?  80 :  81;
			4'd6: c16 = DAC_MAME_COMPAT ?  96 :  98;
			4'd7: c16 = DAC_MAME_COMPAT ? 112 : 114;
			4'd8: c16 = DAC_MAME_COMPAT ? 128 : 126;
			4'd9: c16 = DAC_MAME_COMPAT ? 144 : 142;
			4'd10: c16 = DAC_MAME_COMPAT ? 160 : 158;
			4'd11: c16 = DAC_MAME_COMPAT ? 176 : 175;
			4'd12: c16 = DAC_MAME_COMPAT ? 192 : 191;
			4'd13: c16 = DAC_MAME_COMPAT ? 208 : 207;
			4'd14: c16 = DAC_MAME_COMPAT ? 224 : 223;
			default: c16 = DAC_MAME_COMPAT ? 240 : 240;
		endcase
	endfunction

	// The divisor puts the full-scale product (colour 15 x intensity 15) at 255
	// on both paths: MAME 240*272/256 = 255, hardware 240*282/265 = 255.
	//   DIV = DAC_MAME_COMPAT ? 256 : 265
	// It is written as a comment rather than a localparam because the runtime
	// divide is gone (see chan_lut below) and Verilator rightly warns about a
	// parameter nothing reads.

	// chan(c, z) = clamp((c16(c) * z16(z)) / DIV), with the all-zero clamp
	// (19M/19L LS260 + R115/R107/R99: a zero nibble is hard black whatever ZREF
	// is doing).  Evaluated ahead of time into a 256-entry table: the same
	// arithmetic done at runtime is a deep multiply-and-divide chain that does
	// not come close to meeting the clk_sys period.  Every entry is the integer
	// result of that arithmetic (DIV = 256 for MAME's ztable, 265 for the
	// resistor ladder) applied to the c16/z16 functions above.
	function automatic [7:0] chan_lut(input [7:0] cz);
		case (cz)
			8'h00: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h01: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h02: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h03: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h04: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h05: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h06: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h07: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h08: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h09: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h0A: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h0B: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h0C: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h0D: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h0E: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h0F: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h10: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h11: chan_lut = DAC_MAME_COMPAT ? 8'd3 : 8'd3;
			8'h12: chan_lut = DAC_MAME_COMPAT ? 8'd4 : 8'd4;
			8'h13: chan_lut = DAC_MAME_COMPAT ? 8'd5 : 8'd5;
			8'h14: chan_lut = DAC_MAME_COMPAT ? 8'd6 : 8'd6;
			8'h15: chan_lut = DAC_MAME_COMPAT ? 8'd7 : 8'd7;
			8'h16: chan_lut = DAC_MAME_COMPAT ? 8'd8 : 8'd8;
			8'h17: chan_lut = DAC_MAME_COMPAT ? 8'd9 : 8'd9;
			8'h18: chan_lut = DAC_MAME_COMPAT ? 8'd10 : 8'd10;
			8'h19: chan_lut = DAC_MAME_COMPAT ? 8'd11 : 8'd11;
			8'h1A: chan_lut = DAC_MAME_COMPAT ? 8'd12 : 8'd12;
			8'h1B: chan_lut = DAC_MAME_COMPAT ? 8'd13 : 8'd13;
			8'h1C: chan_lut = DAC_MAME_COMPAT ? 8'd14 : 8'd14;
			8'h1D: chan_lut = DAC_MAME_COMPAT ? 8'd15 : 8'd15;
			8'h1E: chan_lut = DAC_MAME_COMPAT ? 8'd16 : 8'd17;
			8'h1F: chan_lut = DAC_MAME_COMPAT ? 8'd17 : 8'd18;
			8'h20: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h21: chan_lut = DAC_MAME_COMPAT ? 8'd6 : 8'd5;
			8'h22: chan_lut = DAC_MAME_COMPAT ? 8'd8 : 8'd8;
			8'h23: chan_lut = DAC_MAME_COMPAT ? 8'd10 : 8'd10;
			8'h24: chan_lut = DAC_MAME_COMPAT ? 8'd12 : 8'd12;
			8'h25: chan_lut = DAC_MAME_COMPAT ? 8'd14 : 8'd14;
			8'h26: chan_lut = DAC_MAME_COMPAT ? 8'd16 : 8'd16;
			8'h27: chan_lut = DAC_MAME_COMPAT ? 8'd18 : 8'd18;
			8'h28: chan_lut = DAC_MAME_COMPAT ? 8'd20 : 8'd20;
			8'h29: chan_lut = DAC_MAME_COMPAT ? 8'd22 : 8'd22;
			8'h2A: chan_lut = DAC_MAME_COMPAT ? 8'd24 : 8'd24;
			8'h2B: chan_lut = DAC_MAME_COMPAT ? 8'd26 : 8'd26;
			8'h2C: chan_lut = DAC_MAME_COMPAT ? 8'd28 : 8'd28;
			8'h2D: chan_lut = DAC_MAME_COMPAT ? 8'd30 : 8'd30;
			8'h2E: chan_lut = DAC_MAME_COMPAT ? 8'd32 : 8'd33;
			8'h2F: chan_lut = DAC_MAME_COMPAT ? 8'd34 : 8'd35;
			8'h30: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h31: chan_lut = DAC_MAME_COMPAT ? 8'd9 : 8'd8;
			8'h32: chan_lut = DAC_MAME_COMPAT ? 8'd12 : 8'd12;
			8'h33: chan_lut = DAC_MAME_COMPAT ? 8'd15 : 8'd15;
			8'h34: chan_lut = DAC_MAME_COMPAT ? 8'd18 : 8'd18;
			8'h35: chan_lut = DAC_MAME_COMPAT ? 8'd21 : 8'd21;
			8'h36: chan_lut = DAC_MAME_COMPAT ? 8'd24 : 8'd24;
			8'h37: chan_lut = DAC_MAME_COMPAT ? 8'd27 : 8'd27;
			8'h38: chan_lut = DAC_MAME_COMPAT ? 8'd30 : 8'd30;
			8'h39: chan_lut = DAC_MAME_COMPAT ? 8'd33 : 8'd33;
			8'h3A: chan_lut = DAC_MAME_COMPAT ? 8'd36 : 8'd36;
			8'h3B: chan_lut = DAC_MAME_COMPAT ? 8'd39 : 8'd39;
			8'h3C: chan_lut = DAC_MAME_COMPAT ? 8'd42 : 8'd42;
			8'h3D: chan_lut = DAC_MAME_COMPAT ? 8'd45 : 8'd45;
			8'h3E: chan_lut = DAC_MAME_COMPAT ? 8'd48 : 8'd49;
			8'h3F: chan_lut = DAC_MAME_COMPAT ? 8'd51 : 8'd52;
			8'h40: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h41: chan_lut = DAC_MAME_COMPAT ? 8'd12 : 8'd11;
			8'h42: chan_lut = DAC_MAME_COMPAT ? 8'd16 : 8'd16;
			8'h43: chan_lut = DAC_MAME_COMPAT ? 8'd20 : 8'd20;
			8'h44: chan_lut = DAC_MAME_COMPAT ? 8'd24 : 8'd24;
			8'h45: chan_lut = DAC_MAME_COMPAT ? 8'd28 : 8'd28;
			8'h46: chan_lut = DAC_MAME_COMPAT ? 8'd32 : 8'd32;
			8'h47: chan_lut = DAC_MAME_COMPAT ? 8'd36 : 8'd36;
			8'h48: chan_lut = DAC_MAME_COMPAT ? 8'd40 : 8'd40;
			8'h49: chan_lut = DAC_MAME_COMPAT ? 8'd44 : 8'd44;
			8'h4A: chan_lut = DAC_MAME_COMPAT ? 8'd48 : 8'd48;
			8'h4B: chan_lut = DAC_MAME_COMPAT ? 8'd52 : 8'd52;
			8'h4C: chan_lut = DAC_MAME_COMPAT ? 8'd56 : 8'd56;
			8'h4D: chan_lut = DAC_MAME_COMPAT ? 8'd60 : 8'd60;
			8'h4E: chan_lut = DAC_MAME_COMPAT ? 8'd64 : 8'd65;
			8'h4F: chan_lut = DAC_MAME_COMPAT ? 8'd68 : 8'd69;
			8'h50: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h51: chan_lut = DAC_MAME_COMPAT ? 8'd15 : 8'd14;
			8'h52: chan_lut = DAC_MAME_COMPAT ? 8'd20 : 8'd20;
			8'h53: chan_lut = DAC_MAME_COMPAT ? 8'd25 : 8'd25;
			8'h54: chan_lut = DAC_MAME_COMPAT ? 8'd30 : 8'd30;
			8'h55: chan_lut = DAC_MAME_COMPAT ? 8'd35 : 8'd35;
			8'h56: chan_lut = DAC_MAME_COMPAT ? 8'd40 : 8'd40;
			8'h57: chan_lut = DAC_MAME_COMPAT ? 8'd45 : 8'd45;
			8'h58: chan_lut = DAC_MAME_COMPAT ? 8'd50 : 8'd50;
			8'h59: chan_lut = DAC_MAME_COMPAT ? 8'd55 : 8'd55;
			8'h5A: chan_lut = DAC_MAME_COMPAT ? 8'd60 : 8'd60;
			8'h5B: chan_lut = DAC_MAME_COMPAT ? 8'd65 : 8'd65;
			8'h5C: chan_lut = DAC_MAME_COMPAT ? 8'd70 : 8'd70;
			8'h5D: chan_lut = DAC_MAME_COMPAT ? 8'd75 : 8'd75;
			8'h5E: chan_lut = DAC_MAME_COMPAT ? 8'd80 : 8'd81;
			8'h5F: chan_lut = DAC_MAME_COMPAT ? 8'd85 : 8'd86;
			8'h60: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h61: chan_lut = DAC_MAME_COMPAT ? 8'd18 : 8'd17;
			8'h62: chan_lut = DAC_MAME_COMPAT ? 8'd24 : 8'd24;
			8'h63: chan_lut = DAC_MAME_COMPAT ? 8'd30 : 8'd30;
			8'h64: chan_lut = DAC_MAME_COMPAT ? 8'd36 : 8'd36;
			8'h65: chan_lut = DAC_MAME_COMPAT ? 8'd42 : 8'd42;
			8'h66: chan_lut = DAC_MAME_COMPAT ? 8'd48 : 8'd49;
			8'h67: chan_lut = DAC_MAME_COMPAT ? 8'd54 : 8'd55;
			8'h68: chan_lut = DAC_MAME_COMPAT ? 8'd60 : 8'd61;
			8'h69: chan_lut = DAC_MAME_COMPAT ? 8'd66 : 8'd66;
			8'h6A: chan_lut = DAC_MAME_COMPAT ? 8'd72 : 8'd73;
			8'h6B: chan_lut = DAC_MAME_COMPAT ? 8'd78 : 8'd79;
			8'h6C: chan_lut = DAC_MAME_COMPAT ? 8'd84 : 8'd85;
			8'h6D: chan_lut = DAC_MAME_COMPAT ? 8'd90 : 8'd91;
			8'h6E: chan_lut = DAC_MAME_COMPAT ? 8'd96 : 8'd98;
			8'h6F: chan_lut = DAC_MAME_COMPAT ? 8'd102 : 8'd104;
			8'h70: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h71: chan_lut = DAC_MAME_COMPAT ? 8'd21 : 8'd20;
			8'h72: chan_lut = DAC_MAME_COMPAT ? 8'd28 : 8'd28;
			8'h73: chan_lut = DAC_MAME_COMPAT ? 8'd35 : 8'd35;
			8'h74: chan_lut = DAC_MAME_COMPAT ? 8'd42 : 8'd42;
			8'h75: chan_lut = DAC_MAME_COMPAT ? 8'd49 : 8'd49;
			8'h76: chan_lut = DAC_MAME_COMPAT ? 8'd56 : 8'd57;
			8'h77: chan_lut = DAC_MAME_COMPAT ? 8'd63 : 8'd64;
			8'h78: chan_lut = DAC_MAME_COMPAT ? 8'd70 : 8'd70;
			8'h79: chan_lut = DAC_MAME_COMPAT ? 8'd77 : 8'd77;
			8'h7A: chan_lut = DAC_MAME_COMPAT ? 8'd84 : 8'd85;
			8'h7B: chan_lut = DAC_MAME_COMPAT ? 8'd91 : 8'd92;
			8'h7C: chan_lut = DAC_MAME_COMPAT ? 8'd98 : 8'd99;
			8'h7D: chan_lut = DAC_MAME_COMPAT ? 8'd105 : 8'd106;
			8'h7E: chan_lut = DAC_MAME_COMPAT ? 8'd112 : 8'd114;
			8'h7F: chan_lut = DAC_MAME_COMPAT ? 8'd119 : 8'd121;
			8'h80: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h81: chan_lut = DAC_MAME_COMPAT ? 8'd24 : 8'd22;
			8'h82: chan_lut = DAC_MAME_COMPAT ? 8'd32 : 8'd31;
			8'h83: chan_lut = DAC_MAME_COMPAT ? 8'd40 : 8'd38;
			8'h84: chan_lut = DAC_MAME_COMPAT ? 8'd48 : 8'd47;
			8'h85: chan_lut = DAC_MAME_COMPAT ? 8'd56 : 8'd54;
			8'h86: chan_lut = DAC_MAME_COMPAT ? 8'd64 : 8'd63;
			8'h87: chan_lut = DAC_MAME_COMPAT ? 8'd72 : 8'd70;
			8'h88: chan_lut = DAC_MAME_COMPAT ? 8'd80 : 8'd78;
			8'h89: chan_lut = DAC_MAME_COMPAT ? 8'd88 : 8'd86;
			8'h8A: chan_lut = DAC_MAME_COMPAT ? 8'd96 : 8'd94;
			8'h8B: chan_lut = DAC_MAME_COMPAT ? 8'd104 : 8'd102;
			8'h8C: chan_lut = DAC_MAME_COMPAT ? 8'd112 : 8'd110;
			8'h8D: chan_lut = DAC_MAME_COMPAT ? 8'd120 : 8'd117;
			8'h8E: chan_lut = DAC_MAME_COMPAT ? 8'd128 : 8'd126;
			8'h8F: chan_lut = DAC_MAME_COMPAT ? 8'd136 : 8'd134;
			8'h90: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'h91: chan_lut = DAC_MAME_COMPAT ? 8'd27 : 8'd25;
			8'h92: chan_lut = DAC_MAME_COMPAT ? 8'd36 : 8'd35;
			8'h93: chan_lut = DAC_MAME_COMPAT ? 8'd45 : 8'd43;
			8'h94: chan_lut = DAC_MAME_COMPAT ? 8'd54 : 8'd53;
			8'h95: chan_lut = DAC_MAME_COMPAT ? 8'd63 : 8'd61;
			8'h96: chan_lut = DAC_MAME_COMPAT ? 8'd72 : 8'd71;
			8'h97: chan_lut = DAC_MAME_COMPAT ? 8'd81 : 8'd79;
			8'h98: chan_lut = DAC_MAME_COMPAT ? 8'd90 : 8'd88;
			8'h99: chan_lut = DAC_MAME_COMPAT ? 8'd99 : 8'd96;
			8'h9A: chan_lut = DAC_MAME_COMPAT ? 8'd108 : 8'd106;
			8'h9B: chan_lut = DAC_MAME_COMPAT ? 8'd117 : 8'd115;
			8'h9C: chan_lut = DAC_MAME_COMPAT ? 8'd126 : 8'd124;
			8'h9D: chan_lut = DAC_MAME_COMPAT ? 8'd135 : 8'd132;
			8'h9E: chan_lut = DAC_MAME_COMPAT ? 8'd144 : 8'd142;
			8'h9F: chan_lut = DAC_MAME_COMPAT ? 8'd153 : 8'd151;
			8'hA0: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'hA1: chan_lut = DAC_MAME_COMPAT ? 8'd30 : 8'd28;
			8'hA2: chan_lut = DAC_MAME_COMPAT ? 8'd40 : 8'd39;
			8'hA3: chan_lut = DAC_MAME_COMPAT ? 8'd50 : 8'd48;
			8'hA4: chan_lut = DAC_MAME_COMPAT ? 8'd60 : 8'd59;
			8'hA5: chan_lut = DAC_MAME_COMPAT ? 8'd70 : 8'd68;
			8'hA6: chan_lut = DAC_MAME_COMPAT ? 8'd80 : 8'd79;
			8'hA7: chan_lut = DAC_MAME_COMPAT ? 8'd90 : 8'd88;
			8'hA8: chan_lut = DAC_MAME_COMPAT ? 8'd100 : 8'd98;
			8'hA9: chan_lut = DAC_MAME_COMPAT ? 8'd110 : 8'd107;
			8'hAA: chan_lut = DAC_MAME_COMPAT ? 8'd120 : 8'd118;
			8'hAB: chan_lut = DAC_MAME_COMPAT ? 8'd130 : 8'd128;
			8'hAC: chan_lut = DAC_MAME_COMPAT ? 8'd140 : 8'd138;
			8'hAD: chan_lut = DAC_MAME_COMPAT ? 8'd150 : 8'd147;
			8'hAE: chan_lut = DAC_MAME_COMPAT ? 8'd160 : 8'd158;
			8'hAF: chan_lut = DAC_MAME_COMPAT ? 8'd170 : 8'd168;
			8'hB0: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'hB1: chan_lut = DAC_MAME_COMPAT ? 8'd33 : 8'd31;
			8'hB2: chan_lut = DAC_MAME_COMPAT ? 8'd44 : 8'd43;
			8'hB3: chan_lut = DAC_MAME_COMPAT ? 8'd55 : 8'd54;
			8'hB4: chan_lut = DAC_MAME_COMPAT ? 8'd66 : 8'd65;
			8'hB5: chan_lut = DAC_MAME_COMPAT ? 8'd77 : 8'd75;
			8'hB6: chan_lut = DAC_MAME_COMPAT ? 8'd88 : 8'd87;
			8'hB7: chan_lut = DAC_MAME_COMPAT ? 8'd99 : 8'd98;
			8'hB8: chan_lut = DAC_MAME_COMPAT ? 8'd110 : 8'd108;
			8'hB9: chan_lut = DAC_MAME_COMPAT ? 8'd121 : 8'd119;
			8'hBA: chan_lut = DAC_MAME_COMPAT ? 8'd132 : 8'd131;
			8'hBB: chan_lut = DAC_MAME_COMPAT ? 8'd143 : 8'd141;
			8'hBC: chan_lut = DAC_MAME_COMPAT ? 8'd154 : 8'd153;
			8'hBD: chan_lut = DAC_MAME_COMPAT ? 8'd165 : 8'd163;
			8'hBE: chan_lut = DAC_MAME_COMPAT ? 8'd176 : 8'd175;
			8'hBF: chan_lut = DAC_MAME_COMPAT ? 8'd187 : 8'd186;
			8'hC0: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'hC1: chan_lut = DAC_MAME_COMPAT ? 8'd36 : 8'd34;
			8'hC2: chan_lut = DAC_MAME_COMPAT ? 8'd48 : 8'd47;
			8'hC3: chan_lut = DAC_MAME_COMPAT ? 8'd60 : 8'd59;
			8'hC4: chan_lut = DAC_MAME_COMPAT ? 8'd72 : 8'd71;
			8'hC5: chan_lut = DAC_MAME_COMPAT ? 8'd84 : 8'd82;
			8'hC6: chan_lut = DAC_MAME_COMPAT ? 8'd96 : 8'd95;
			8'hC7: chan_lut = DAC_MAME_COMPAT ? 8'd108 : 8'd107;
			8'hC8: chan_lut = DAC_MAME_COMPAT ? 8'd120 : 8'd118;
			8'hC9: chan_lut = DAC_MAME_COMPAT ? 8'd132 : 8'd130;
			8'hCA: chan_lut = DAC_MAME_COMPAT ? 8'd144 : 8'd143;
			8'hCB: chan_lut = DAC_MAME_COMPAT ? 8'd156 : 8'd154;
			8'hCC: chan_lut = DAC_MAME_COMPAT ? 8'd168 : 8'd167;
			8'hCD: chan_lut = DAC_MAME_COMPAT ? 8'd180 : 8'd178;
			8'hCE: chan_lut = DAC_MAME_COMPAT ? 8'd192 : 8'd191;
			8'hCF: chan_lut = DAC_MAME_COMPAT ? 8'd204 : 8'd203;
			8'hD0: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'hD1: chan_lut = DAC_MAME_COMPAT ? 8'd39 : 8'd37;
			8'hD2: chan_lut = DAC_MAME_COMPAT ? 8'd52 : 8'd51;
			8'hD3: chan_lut = DAC_MAME_COMPAT ? 8'd65 : 8'd64;
			8'hD4: chan_lut = DAC_MAME_COMPAT ? 8'd78 : 8'd77;
			8'hD5: chan_lut = DAC_MAME_COMPAT ? 8'd91 : 8'd89;
			8'hD6: chan_lut = DAC_MAME_COMPAT ? 8'd104 : 8'd103;
			8'hD7: chan_lut = DAC_MAME_COMPAT ? 8'd117 : 8'd116;
			8'hD8: chan_lut = DAC_MAME_COMPAT ? 8'd130 : 8'd128;
			8'hD9: chan_lut = DAC_MAME_COMPAT ? 8'd143 : 8'd141;
			8'hDA: chan_lut = DAC_MAME_COMPAT ? 8'd156 : 8'd155;
			8'hDB: chan_lut = DAC_MAME_COMPAT ? 8'd169 : 8'd167;
			8'hDC: chan_lut = DAC_MAME_COMPAT ? 8'd182 : 8'd181;
			8'hDD: chan_lut = DAC_MAME_COMPAT ? 8'd195 : 8'd193;
			8'hDE: chan_lut = DAC_MAME_COMPAT ? 8'd208 : 8'd207;
			8'hDF: chan_lut = DAC_MAME_COMPAT ? 8'd221 : 8'd220;
			8'hE0: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'hE1: chan_lut = DAC_MAME_COMPAT ? 8'd42 : 8'd40;
			8'hE2: chan_lut = DAC_MAME_COMPAT ? 8'd56 : 8'd55;
			8'hE3: chan_lut = DAC_MAME_COMPAT ? 8'd70 : 8'd69;
			8'hE4: chan_lut = DAC_MAME_COMPAT ? 8'd84 : 8'd83;
			8'hE5: chan_lut = DAC_MAME_COMPAT ? 8'd98 : 8'd96;
			8'hE6: chan_lut = DAC_MAME_COMPAT ? 8'd112 : 8'd111;
			8'hE7: chan_lut = DAC_MAME_COMPAT ? 8'd126 : 8'd125;
			8'hE8: chan_lut = DAC_MAME_COMPAT ? 8'd140 : 8'd138;
			8'hE9: chan_lut = DAC_MAME_COMPAT ? 8'd154 : 8'd152;
			8'hEA: chan_lut = DAC_MAME_COMPAT ? 8'd168 : 8'd167;
			8'hEB: chan_lut = DAC_MAME_COMPAT ? 8'd182 : 8'd180;
			8'hEC: chan_lut = DAC_MAME_COMPAT ? 8'd196 : 8'd195;
			8'hED: chan_lut = DAC_MAME_COMPAT ? 8'd210 : 8'd208;
			8'hEE: chan_lut = DAC_MAME_COMPAT ? 8'd224 : 8'd223;
			8'hEF: chan_lut = DAC_MAME_COMPAT ? 8'd238 : 8'd237;
			8'hF0: chan_lut = DAC_MAME_COMPAT ? 8'd0 : 8'd0;
			8'hF1: chan_lut = DAC_MAME_COMPAT ? 8'd45 : 8'd43;
			8'hF2: chan_lut = DAC_MAME_COMPAT ? 8'd60 : 8'd59;
			8'hF3: chan_lut = DAC_MAME_COMPAT ? 8'd75 : 8'd74;
			8'hF4: chan_lut = DAC_MAME_COMPAT ? 8'd90 : 8'd89;
			8'hF5: chan_lut = DAC_MAME_COMPAT ? 8'd105 : 8'd104;
			8'hF6: chan_lut = DAC_MAME_COMPAT ? 8'd120 : 8'd120;
			8'hF7: chan_lut = DAC_MAME_COMPAT ? 8'd135 : 8'd134;
			8'hF8: chan_lut = DAC_MAME_COMPAT ? 8'd150 : 8'd149;
			8'hF9: chan_lut = DAC_MAME_COMPAT ? 8'd165 : 8'd163;
			8'hFA: chan_lut = DAC_MAME_COMPAT ? 8'd180 : 8'd180;
			8'hFB: chan_lut = DAC_MAME_COMPAT ? 8'd195 : 8'd194;
			8'hFC: chan_lut = DAC_MAME_COMPAT ? 8'd210 : 8'd210;
			8'hFD: chan_lut = DAC_MAME_COMPAT ? 8'd225 : 8'd224;
			8'hFE: chan_lut = DAC_MAME_COMPAT ? 8'd240 : 8'd240;
			8'hFF: chan_lut = DAC_MAME_COMPAT ? 8'd255 : 8'd255;
		endcase
	endfunction

	function automatic [7:0] chan(input [3:0] c, input [3:0] z);
		chan = chan_lut({c, z});
	endfunction

	assign red   = vidbl_n ? chan(rout, iout_q) : 8'd0;
	assign green = vidbl_n ? chan(gout, iout_q) : 8'd0;
	assign blue  = vidbl_n ? chan(bout, iout_q) : 8'd0;

endmodule
