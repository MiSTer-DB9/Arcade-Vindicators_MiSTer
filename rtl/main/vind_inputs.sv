`timescale 1ns/1ps
//============================================================================
//  Vindicators player / status input ports — SP-317 sheet 3 (1/2B, 3B, 6B
//  LS244 and 9B LS367A).
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Shaped after the Xybots core's `xybots_inputs.sv` (GPL-3.0);
//  the bit map is Vindicators' own, read off SP-317 sheet 3.
//
//  ---- the three switch buffers ------------------------------------------
//  1/2B LS244A (/PL1, 0x260000), 3B LS244B (/PL2, 0x260010) and 6B LS244C
//  (/PL3, 0x260020) each drive the HIGH byte only, with BOTH enables tied to
//  their strobe.  The pin pairs (2->18, 4->16, 6->14, 8->12, 11->9, 13->7,
//  15->5, 17->3) give
//
//      Pn-S1 -> CD8   Pn-S2 -> CD9   Pn-S3 -> CD10  Pn-S4 -> CD11
//      Pn-S5 -> CD12  Pn-S6 -> CD13  Pn-S7 -> CD14  Pn-S8 -> CD15
//
//  Every switch has a 470 R pull-up (R1/R18/R34), a .1 uF cap and a 1 k series
//  resistor, so every bit is **active low** (closed = 0).
//
//  **Sheet 12's legend numbers the bits the other way round** ("D15 (Switch 1)
//  ... D8 (Switch 8)").  Sheet 3 is the wiring and wins; sheet 12 is just
//  numbering bits top-down.  MAME's `0x0100 = Left Stick Fire` therefore
//  corresponds to Pn-S1, which is the mapping used here.
//
//  ---- the status byte (9B LS367A, enabled by /PL2) ----------------------
//      CD0 = /VBLANK   (video sheets)
//      CD1 = S-TEST    (self-test switch, pulled up by R68 -> 1 = not pressed)
//      CD2 = /SINT     (SCOM FULL, sheet 2 — sound -> main byte waiting)
//      CD3 = /SCBSY    (SCOM BUSY, sheet 2 — main -> sound still busy)
//      CD4 = ADEOC     (ADC0809 pin 7) — the ADC is NOT POPULATED, so this
//                        LS367 input floats and reads **1**
//      CD5 = LS367A pin 2 is a bare stub, no connect -> reads **1**
//      CD6, CD7 are not driven at 0x260010 -> read **1**
//
//  ---- the unpopulated LETA / ADC0809 low byte (sheet 3) ----------------
//  13B (LETA quadrature) would drive CD0-CD7 during /PL1 and 11B (ADC0809)
//  during /PL3.  Neither is populated on Vindicators (sheet 12 lists no analog
//  entry, MAME declares the low bytes IPT_UNUSED, and the cabinet has only
//  twin digital sticks), so those lanes read the floating/pulled-up bus =
//  **0xFF**.  The sockets and their full wiring exist on the board, but with
//  nothing fitted there is nothing to model.
//
//  Pure combinational packing: no clock, no state.
//============================================================================

module vind_inputs
(
	// Player switches, ACTIVE-HIGH "pressed"; [0] = Pn-S1 ... [7] = Pn-S8.
	input  logic [7:0] p1_sw,
	input  logic [7:0] p2_sw,
	input  logic [7:0] p3_sw,     // the start panel, PL3

	// Status bits
	input  logic       vblank,    // active HIGH  -> CD0 = /VBLANK = ~vblank
	input  logic       self_test, // 1 = switch pressed -> CD1 = 0
	input  logic       sint_n,    // /SINT  from the SCOM
	input  logic       scbsy_n,   // /SCBSY from the SCOM

	output logic [15:0] pl1,      // 0x260000 read
	output logic [15:0] pl2,      // 0x260010 read
	output logic [15:0] pl3,      // 0x260020 read
	output logic  [7:0] status    // the 9B LS367A byte, for observation in simulation
);

	// CD15..CD8 = Pn-S8..Pn-S1, active low.
	function automatic [7:0] sw_hi(input [7:0] s);
		sw_hi = ~{s[7], s[6], s[5], s[4], s[3], s[2], s[1], s[0]};
	endfunction

	assign status = { 2'b11,        // CD7, CD6 — not driven at 0x260010
	                  1'b1,         // CD5 — LS367A pin 2 is a bare stub
	                  1'b1,         // CD4 — ADEOC, ADC0809 not populated
	                  scbsy_n,      // CD3
	                  sint_n,       // CD2
	                  ~self_test,   // CD1 — S-TEST, active low
	                  ~vblank };    // CD0 — /VBLANK

	assign pl1 = { sw_hi(p1_sw), 8'hFF };   // low byte = unpopulated LETA
	assign pl2 = { sw_hi(p2_sw), status };
	assign pl3 = { sw_hi(p3_sw), 8'hFF };   // low byte = unpopulated ADC0809

endmodule
