`timescale 1ns/1ps
//============================================================================
//  Vindicators /DTACK and wait-state sequencer — SP-317 sheet 4, gate for
//  gate (8D 74LS163A + 22F 74S74 + 23E/7D LS02 + 5F S32 + 22D LS10 + 24E LS86).
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Modelled on the Xybots core's `xybots_dtack.sv` (GPL-3.0);
//  the counter, the load vector and the COM grant latch below are
//  Vindicators' own, read off SP-317 sheet 4.
//
//  ---- the COM grant latch -----------------------------------------------
//      23E LS02 (8,9->10)  ENOWAI = ~( /ECOM  + EWAI )
//      23E LS02 (5,6-> 4)  EWAI   = ~( ENOWAI + /COM )
//      24E LS86 (12,13->11) /ENOWAI = ENOWAI ^ PR4 = ~ENOWAI
//
//    /COM  /ECOM |  EWAI   ENOWAI
//      1     x   |   0     ~/ECOM
//      0     1   |   1        0
//      0     0   | hold     hold
//
//  So a common-bus (I/O) cycle is granted as soon as the video side is not
//  holding /ECOM low, and a cycle that starts while /ECOM is low waits for it
//  to release.  EWAI is the CPU->common-bus GRANT: on the board it enables the
//  7E/8E LS244 address buffers and the 8C/7C LS245 data transceivers, and it
//  is the `C` term of the counter for /COM cycles.
//
//  ---- the wait terms ----------------------------------------------------
//      23E LS02 (11,12->13) n1  = ~( EWAI  + /COM )
//      7D  LS02 ( 8, 9->10) n2  = ~( /VRAM + PVCPU )
//      7D  LS02 ( 2, 3-> 1) Cin = ~( n1 + n2 ) = (EWAI + /COM) & (/VRAM + PVCPU)
//      7D  LS02 ( 5, 6-> 4) n3  = ~QB               (both inputs tied to QB)
//      5F  S32  ( 9,10-> 8) Bin = /COM + ~QB
//      22D LS10 ( 3,4,5->6) sd  = ~( /UDS & /LDS & R//W )
//
//  ---- the sequencer -----------------------------------------------------
//      22F 74S74   D = sd,  CK = RCLKB,  /PRE = /CLR = PR4 (inactive)
//                  Q -> 8D ENT
//      8D LS163A   CK = RCLKA, /CLR = BAS (SYNCHRONOUS), /LD = QC (SYNCHRONOUS)
//                  ENT = 22F Q,  ENP = /DTACK
//                  {D,C,B,A} = {/VPA, Cin, Bin, /EEPROM}
//                  RCO = QA & QB & QC & QD & ENT   = DTACK
//      6D LS04     /DTACK = ~DTACK   -> 68010 pin 10
//
//  Behaviour:
//    * /AS inactive -> BAS = 0 holds the synchronous clear, count = 0, QC = 0
//      so /LD is asserted and RCO = 0.
//    * first RCLKA with BAS = 1 loads {/VPA, Cin, Bin, /EEPROM}; QB is 0 at
//      that instant so Bin = 1.
//    * loaded C = 0 keeps /LD asserted and the counter reloads every clock —
//      **that is the wait mechanism**, and while it waits QB toggles through
//      the Bin = /COM + ~QB feedback, so the eventual release is quantised to
//      2 RCLKA (0 or 2 extra clocks for a /COM cycle).
//    * loaded C = 1 releases /LD and the counter runs to 15; waits = 15 - load.
//
//    Region            | A=/EEPROM B=Bin C=Cin D=/VPA | load | RCLKA waits
//    ROM / undecoded   |    1        1     1     1    |  15  | 0
//    EEPROM 0E0000     |    0        1     1     1    |  14  | 1
//    /UNLOCK, /WDOG    |    1        1     1     1    |  15  | 0
//    VRAM/CRAM 3E0000  |    1        1   PVCPU   1    |  --  | stall until PVCPU
//    I/O (common bus)  |    1        1   EWAI    1    |  --  | stall until EWAI
//    IACK (/VPA low)   |    1        1     1     0    |   7  | 8 (DTACK suppressed)
//
//  ---- departures from the gates -----------------------------------------
//  * The 23E LS02 pair is a combinational NOR latch on the board.  It is
//    evaluated here once per `clk_sys` (17.5 ns) instead of at gate delay;
//    /COM and /ECOM both change on `clk_sys` edges in this core, so the
//    one-cycle settling is invisible at the RCLKA sample points.
//  * RCLKB comes from the SYNGEN circuit and is not drawn on sheets 2-4.  It
//    is taken here as the OPPOSITE PHASE of RCLKA (`ce_7m_b`, four clk_sys
//    after `ce_7m`) — (inferred).  Its only job is the "no DTACK before a
//    data strobe" qualification, so the exact phase shifts DTACK by at most
//    half an RCLKA.
//============================================================================

module vind_dtack
(
	input  logic clk,        // clk_sys
	input  logic ce_7m,      // RCLKA enable (clk_sys / 8)
	input  logic ce_7m_b,    // RCLKB enable (RCLKA's opposite phase)
	input  logic reset,      // active high; parks the counter and the latch

	input  logic as,         // BAS = ~/AS
	input  logic uds_n,
	input  logic lds_n,
	input  logic rw,         // R//W
	input  logic eeprom_n,   // 4J Y0 -> 8D A
	input  logic com_n,      // PAL 3C /COM
	input  logic vram_n,     // 4J Y3
	input  logic vpa_n,      // -> 8D D
	input  logic pvcpu,      // video side: the CPU's VRAM slot grant
	input  logic ecom_n,     // video side: /ECOM

	output logic dtack,      // active HIGH (= ~/DTACK)
	output logic ewai,       // CPU -> common-bus grant
	output logic ewai_n,     // = ~EWAI (24E LS86 path), the buffer enable
	output logic enowai,
	output logic rco,
	output logic sd_q,       // 22F Q, for observation in simulation
	output logic [3:0] wcnt  // 8D {QD,QC,QB,QA}, for observation in simulation
);

	// ---- 23E LS02 NOR latch + 24E LS86 ----------------------------------
	always_ff @(posedge clk) begin
		if (reset) begin
			ewai   <= 1'b0;
			enowai <= 1'b0;
		end else if (com_n) begin              // no common-bus cycle
			ewai   <= 1'b0;
			enowai <= ~ecom_n;
		end else if (ecom_n) begin             // request, video not holding
			ewai   <= 1'b1;
			enowai <= 1'b0;
		end
		// /COM = 0 and /ECOM = 0 -> the latch holds (the CPU waits)
	end
	assign ewai_n = ~ewai;

	// ---- the wait terms -------------------------------------------------
	wire cin = (ewai | com_n) & (vram_n | pvcpu);
	wire bin = com_n | ~wcnt[1];               // 5F S32 : /COM + ~QB
	wire sd  = ~(uds_n & lds_n & rw);          // 22D LS10

	// ---- 22F 74S74, clocked by RCLKB ------------------------------------
	always_ff @(posedge clk) begin
		if (reset)        sd_q <= 1'b0;
		else if (ce_7m_b) sd_q <= sd;
	end

	// ---- 8D 74LS163A, clocked by RCLKA ----------------------------------
	wire clr_n = as;                            // synchronous clear while /AS idle
	wire ld_n  = wcnt[2];                       // /LD = QC
	wire ent   = sd_q;
	wire enp   = ~dtack;                        // ENP = /DTACK

	assign rco   = (&wcnt) & ent;
	assign dtack = rco;

	always_ff @(posedge clk) begin
		if (reset) begin
			wcnt <= 4'd0;
		end else if (ce_7m) begin
			if (!clr_n)         wcnt <= 4'd0;
			else if (!ld_n)     wcnt <= {vpa_n, cin, bin, eeprom_n};
			else if (ent & enp) wcnt <= wcnt + 4'd1;
		end
	end

endmodule
