`timescale 1ns/1ps
//============================================================================
//  Vindicators output latch 10B 74LS174B — SP-317 sheet 3.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.
//
//      CK   (9) = /LATCH   (LS138 7/8B Y1, write 0x360010-0x36001F, mirrored
//                           every 0x40 through 0x?60000-0x?6FFFF)
//      /CLR (1) = /SYSRES
//
//    D pin | Q pin | bit | net       | destination
//      3       2     CD5   (unlabelled, no connect)
//     14      15     CD4   (unlabelled, no connect)
//      4       5     CD3   PRBK        video sheets
//     13      12     CD2   LRESL       LETA 13B pin 14 RESOL (unpopulated)
//      6       7     CD1   LTEST       LETA 13B pin  9 TEST  (unpopulated)
//     11      10     CD0   /ERESET     video sheets
//
//  An LS174 clocks on the RISING edge of CK, i.e. at the END of the write
//  cycle when /LATCH releases — the address and data are still valid then.
//
//  ---- what the program does ---------------------------------------------
//  Exactly one site writes it: 0x00346A `move.b D0,$360011`, a BYTE write to
//  the ODD address, so the data arrives on D0-D7 -> CD0-CD7.  The helper at
//  0x003448 maintains a **6-bit** software shadow at 0x3F7F9D and uses bit 6
//  of its argument as set/clear — only CD0-CD5 exist, which is exactly what
//  the LS174 latches.  Boot calls it once with 0x0042 = "set bit 1" (LTEST).
//
//  MAME `nopw()`s this address.  Two of the six outputs (`/ERESET`, `PRBK`)
//  leave sheet 3 for the video sheets and are exported here; `LTEST`/`LRESL`
//  reach only the unpopulated LETA and are therefore genuinely inert on this
//  board.
//
//  Note the LS138 that makes /LATCH has NO /UDS or /LDS qualifier, so a
//  high-byte-only write to 0x360010 strobes the latch too; a 68010 byte write
//  drives the byte on BOTH halves of the data bus, so CD0-CD5 carry the same
//  value either way.
//============================================================================

module vind_out_latch
(
	input  logic       clk,
	input  logic       sysres,     // the /SYSRES net, ACTIVE HIGH here (/CLR)
	input  logic       latch_stb,  // 1-clk pulse at the RISING edge of /LATCH
	input  logic [5:0] cd,         // CD5..CD0 at that instant

	output logic       ereset_n,   // Q pin 10, CD0  -> video sheets
	output logic       ltest,      // Q pin  7, CD1  -> LETA (unpopulated)
	output logic       lresl,      // Q pin 12, CD2  -> LETA (unpopulated)
	output logic       prbk,       // Q pin  5, CD3  -> video sheets
	output logic [5:0] q           // the whole latch, for observation in simulation
);

	always_ff @(posedge clk) begin
		if (sysres)         q <= 6'd0;
		else if (latch_stb) q <= cd;
	end

	assign ereset_n = q[0];
	assign ltest    = q[1];
	assign lresl    = q[2];
	assign prbk     = q[3];

	// q[5:4] are the two unlabelled, unconnected outputs (pins 2 and 15).

endmodule
