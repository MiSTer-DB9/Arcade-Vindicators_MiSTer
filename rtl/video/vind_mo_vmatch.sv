`timescale 1ns/1ps
//============================================================================
//  Vindicators — SP-317 sheet 8: the motion-object VERTICAL MATCH.
//  12N + 13N + 4N LS86 (the 9-bit difference), 14N (the height compare) and
//  14J LS20 (/VMATCH).
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later.
//
//      12N LS283 : {word2 D10..D7} + {PF8V,PF4V,PF2V,PF1V} + C0(= /VBLANK)
//      13N LS283 : {word2 D14..D11} + {PF128V,PF64V,PF32V,PF16V} + carry
//      4N  LS86  : diff8 = PF256V ^ word2 D15 ^ 13N C4
//      14N LS283 : {diff5,diff4,diff3, 1} + {VSIZ2,VSIZ1,VSIZ0, 1} + 1
//      14J LS20  : /VMATCH = ~( diff8 & diff7 & diff6 & 14N C4 )
//
//  With `diff = PFV[8:0] + Y[8:0] + /VBLANK` taken as an unsigned 9-bit sum:
//
//      diff8 & diff7 & diff6 == 1     <=>  diff in [-64, -1]  (signed)
//      14N C4 == 1                    <=>  diff[5:3] + VSIZ + 1 >= 8
//                                     <=>  diff >= -8*(VSIZ+1)
//
//  so /VMATCH is asserted exactly for  -8*(VSIZ+1) <= diff <= -1: the object
//  covers the 8*(VSIZ+1) scanlines ABOVE the row where PFV == ~Y.  That is the
//  same "negate Y, subtract the height" rule MAME uses
//  (`ypos = -ypos; ypos -= yscroll; ypos -= height << 3`); the residual
//  one-line offset is the line-buffer pipeline (the engine fills the buffer on
//  line n for display on line n+1).
//
//  `/VBLANK` as the adder's CARRY-IN is deliberate: during vertical blanking
//  the +1 disappears and every match shifts by one line, which together with
//  the frozen PF*V counter guarantees no match in VBLANK.  MAME simply does not
//  render outside the visible area -- a different mechanism, same result.
//
//  14N S4:S2 is `(diff[5:3] + VSIZ + 1) mod 8` = the TILE ROW within the object
//  counted from the top; it addresses the 82S147 at 11N.  12N S3:S1 = diff[2:0]
//  is the PIXEL ROW within that tile and becomes GP4V/GP2V/GP1V.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_mo_vmatch (
	input  logic  [8:0] pf_v,        // PF256V..PF1V
	input  logic  [8:0] mo_y,        // word 2 D15:D7
	input  logic  [2:0] vsiz,        // word 2 D2:D0  (height - 1)
	input  logic        vblank_n,    // 12N C0

	output logic        vmatch_n,
	output logic  [2:0] tile_row,    // 14N S4:S2 -> 11N A2:A0
	output logic  [2:0] pix_row      // 12N S3:S1 -> GP4V/GP2V/GP1V
);

	wire [8:0] diff = pf_v + mo_y + {8'd0, vblank_n};

	// 14N: {diff[5:3], 1} + {VSIZ, 1} + 1.  The forced LSBs and the carry-in
	// make this a 3-bit add with a +1, shifted up one place.
	wire [4:0] n14 = {1'b0, diff[5:3], 1'b1} + {1'b0, vsiz, 1'b1} + 5'd1;

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused = &{1'b0, n14[0]};   // the forced LSB of the 14N add
	/* verilator lint_on UNUSEDSIGNAL */

	assign vmatch_n = ~(diff[8] & diff[7] & diff[6] & n14[4]);
	assign tile_row = n14[3:1];
	assign pix_row  = diff[2:0];

endmodule
