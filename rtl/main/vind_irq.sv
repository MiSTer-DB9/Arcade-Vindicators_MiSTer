`timescale 1ns/1ps
//============================================================================
//  Vindicators interrupt encoding — SP-317 sheet 4 (21E LS08, R79/R80,
//  9F LS11, 20E LS00).
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Shaped after the Xybots core's `xybots_irq.sv` (GPL-3.0); the
//  encoding is Vindicators' own, read off SP-317 sheet 4.
//
//  ---- the "encoder" is two resistors ------------------------------------
//      IPL0 (pin 25) = PR3                     ; 1 k pull-up, always HIGH
//      IPL2 (pin 23) = 21E LS08: /VINT & /SINT ; also labelled /SRVI
//      IPL1 (pin 24) = the midpoint of R79 1 k -> /VINT and R80 1 k -> /SINT
//
//    /VINT /SINT | IPL2 IPL1 IPL0 | level
//      1     1   |  1    1     1  |  0  none
//      0     1   |  0    1*    1  |  4  video   (* ~1.8 V, read HIGH)
//      1     0   |  0    0     1  |  6  sound
//      0     0   |  0    0     1  |  6  sound wins
//
//  ---- not settled by the schematic: the IPL1 asymmetry -------------------
//  There is NO GATE on IPL1.  For the "video only" row to read HIGH while the
//  "sound only" row reads LOW, the /VINT driver must be open-collector (or at
//  least weaker) and the /SINT driver push-pull.  /SINT is the SCOM's `FULL`
//  pin, a push-pull output (sheet 2), so that half is settled; /VINT comes
//  from the VIRQ latch on the video sheets, so the asymmetry is **(inferred)**.
//
//  The program ROM corroborates it and is decisive at the level of observable
//  behaviour: vector 28 (autovector 4) is the VIRQ handler at 0x000482 (it
//  writes /VACK 0x360000 and the watchdog) and vector 30 (autovector 6) is the
//  sound handler at 0x001042 (it reads 0x260031); every other vector is the
//  STOP #$2700 stub.  A board that gave level 4 for a lone /SINT would run the
//  display handler on a sound interrupt and never drain the SCOM.  This module
//  therefore implements the table above; `IPL1_OPEN_COLLECTOR = 0` builds the
//  pessimistic alternative (IPL1 = /VINT & /SINT, i.e. both sources read as
//  level 6 individually) so it can be compared in simulation.
//
//  ---- autovector ---------------------------------------------------------
//      9F  LS11 (9,10,11->8) IACK = FC0 & FC1 & FC2
//      20E LS00 (12,13->11)  /VPA = ~( BAS & IACK )
//  Every interrupt on this board is autovectored.  /VPA also drives the DTACK
//  counter's D input (vind_dtack), which is how DTACK is held off for the
//  whole acknowledge cycle.
//
//  ---- acknowledge --------------------------------------------------------
//  /VACK (sheet 3 LS138 Y0, write 0x360000) clears the VIRQ latch, which lives
//  on the VIDEO sheets — so this module takes /VINT as an input and exports
//  the /VACK strobe for the video side to consume.  /SINT clears when the CPU
//  reads 0x260030 (/SCOMRD), inside the SCOM.
//============================================================================

module vind_irq #(
	// See the IPL1 note above.  1 = the sheet's table (video = 4, sound = 6).
	parameter bit IPL1_OPEN_COLLECTOR = 1'b1
)(
	input  logic vint_n,     // /VINT  — VIRQ latch, video sheets
	input  logic sint_n,     // /SINT  — SCOM FULL, sheet 2
	input  logic as,         // BAS
	input  logic [2:0] fc,

	output logic [2:0] ipl,  // {IPL2,IPL1,IPL0}, ACTIVE LOW, 111 = none
	output logic srvi_n,     // 21E LS08 output = IPL2, Atari's net name /SRVI
	output logic vpa_n
);

	wire ipl2 = vint_n & sint_n;                       // 21E LS08
	wire ipl1 = IPL1_OPEN_COLLECTOR ? sint_n : ipl2;   // R79/R80 junction
	wire ipl0 = 1'b1;                                  // PR3

	assign ipl    = {ipl2, ipl1, ipl0};
	assign srvi_n = ipl2;
	assign vpa_n  = ~(as & fc[0] & fc[1] & fc[2]);

endmodule
