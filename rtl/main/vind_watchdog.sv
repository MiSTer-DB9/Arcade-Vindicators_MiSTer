`timescale 1ns/1ps
//============================================================================
//  Vindicators watchdog / reset counter — SP-317 sheet 4 (22M/N 74LS197,
//  18L LS08, the WDIS jumper) plus the sheet-2 power-on one-shot.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Shaped after the Xybots core's `xybots_watchdog.sv`
//  (GPL-3.0); the part, the load vector and the timing are Vindicators' own.
//
//  ---- the gates ----------------------------------------------------------
//      18L LS08 : 12 = /WDOG (4J Y2, write 0x2E0000)
//                 13 = VCC via R155 1 k, "WDIS" jumper pads to GND
//                 11 = LS197 C/L        -> C/L = /WDOG & WDIS_level
//
//      22M/N 74LS197 (dual counter: CK1 -> QA divide-by-2; CK2 -> QB,QC,QD /8)
//          pin 13 /CLR = POWER-ON (sheet 2)
//          pin 11 D    = PR1 = 1        pin 3 C = pin 10 B = pin 4 A = GND
//          pin  1 C/L  = 18L LS08 pin 11
//          pin  8 CK1  = /VBLANK        pin 6 CK2 = QA (pin 5, looped back)
//          pin 12 QD   = /SYSRES
//
//  ---- timing ------------------------------------------------------------
//  * POWER-ON low clears the counter -> QD = 0 -> /SYSRES asserted.  When it
//    releases, QD needs 4 CK2 edges = **8 /VBLANK periods ~ 133 ms** to rise.
//  * A write to 0x2E0000 pulses /WDOG -> C/L low -> {QD,QC,QB,QA} = 1000, so
//    /SYSRES is forced high and the count restarts at 8.
//  * From 8 the counter needs **8 /VBLANKs** to roll QD to 0 (~134 ms at
//    59.9 Hz).  Sheet 12 says "128 msec. timeout" — agreed within rounding.
//  * /SYSRES then stays low for another **8 /VBLANKs** before QD rises again,
//    i.e. the reset pulse is ~133 ms wide.
//  * WDIS installed grounds 18L pin 13, so C/L is permanently low, the counter
//    is permanently in load mode and /SYSRES = PR1 = 1 forever: watchdog off.
//
//  ---- one departure from the sheet --------------------------------------
//  Sheet 4 calls the C/L load "synchronous".  The real SN74197 loads
//  **asynchronously** (C/L low makes the part a transparent latch and inhibits
//  counting) — that is what is implemented here.  The difference is at most
//  one /VBLANK period of load latency and is invisible to the program, which
//  only ever pulses /WDOG far from a frame edge.
//
//  ---- the sheet-2 power-on one-shot -------------------------------------
//      VCC - R152 100 k -+- base of Q13 (2N5306) ;  C60 .1 uF to GND
//      emitter -> R151 240 -> GND, and that node IS `POWER-ON`
//  ~ R152*C60 = 10 ms, so POWER-ON is low for `POR_CYCLES` after power-up.
//  Shorting the RESET pads discharges C60 and re-asserts it (`por_req`).
//============================================================================

module vind_watchdog #(
	parameter int CLK_HZ     = 57_272_727,
	// sheet 2: R152 100 k x C60 0.1 uF ~ 10 ms (plus the Darlington Vbe)
	parameter int POR_CYCLES  = CLK_HZ / 100,
	// WDIS jumper pads (18L pin 13 to GND).  Normally OPEN on a shipped board.
	parameter bit WDIS        = 1'b0
)(
	input  logic clk,
	input  logic init_reset,    // FPGA init / ROM not loaded: restarts the one-shot
	input  logic por_req,       // the sheet-2 "RESET" pads, active high (optional)

	input  logic vblank_n,      // the /VBLANK net (LS197 CK1), active LOW
	input  logic wdog_n,        // 4J Y2, active LOW, level (not a pulse)

	output logic power_on,      // sheet-2 Q13 emitter, active HIGH once released
	output logic sysres_n,      // /SYSRES = QD
	output logic [3:0] count    // {QD,QC,QB,QA}, for observation in simulation
);

	// ---- sheet 2: the power-on one-shot ---------------------------------
	localparam int POR_W = (POR_CYCLES <= 1) ? 1 : $clog2(POR_CYCLES + 1);
	logic [POR_W-1:0] por_ctr;
	always_ff @(posedge clk) begin
		if (init_reset || por_req) por_ctr <= '0;
		else if (!power_on)        por_ctr <= por_ctr + 1'b1;
	end
	assign power_on = (por_ctr == POR_W'(POR_CYCLES));

	// ---- 18L LS08 -------------------------------------------------------
	wire cl_n = WDIS ? 1'b0 : wdog_n;

	// ---- 22M/N 74LS197 ---------------------------------------------------
	// CK1 and CK2 are NEGATIVE-edge triggered; /VBLANK falls at the START of
	// vertical blank, and QA's own falling edge clocks the divide-by-8 half.
	logic qa;
	logic [2:0] qbcd;                    // {QD,QC,QB}
	logic vbl_n_d;
	assign count = {qbcd[2], qbcd[1], qbcd[0], qa};

	always_ff @(posedge clk) begin
		vbl_n_d <= vblank_n;
		if (!power_on) begin             // /CLR, asynchronous on the part
			qa   <= 1'b0;
			qbcd <= 3'b000;
		end else if (!cl_n) begin        // C/L: ASYNCHRONOUS load of D:C:B:A = 1000
			qa   <= 1'b0;
			qbcd <= 3'b100;
		end else if (vbl_n_d & ~vblank_n) begin   // falling edge of /VBLANK
			qa <= ~qa;
			if (qa) qbcd <= qbcd + 3'd1;          // QA 1 -> 0 clocks CK2
		end
	end

	assign sysres_n = qbcd[2];           // QD

endmodule
