`timescale 1ns/1ps
//============================================================================
//  Vindicators X2804A (512 x 8) EEPROM at 1C + the 18E LS74 unlock latch —
//  SP-317 sheet 4.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  Ported from the
//  Xybots MiSTer core's `xybots_eeprom_2804.sv` (itself from Toobin's
//  `toobin_eeprom_2804.sv`), GPL-3.0, and re-derived against the SP-317
//  sheet-4 wiring.  GPL-3.0-or-later; see LICENSE.
//
//  ---- wiring ------------------------------------------------------------
//      A0..A10 (8,7,6,5,4,3,2,1,23,22,19) <- MA1 .. MA11
//      D0..D7  (9,10,11,13,14,15,16,17)  <-> D0..D7  — the **LOW byte only**
//      /CE (18) <- /EEPROM   (4J Y0)
//      /OE (20) <- 18E LS74 Q (pin 5)      — the unlock latch
//      /WE (21) <- /WL = R//W + /LDS       (20D LS32)
//
//  The socket is wired for a 2 K x 8 part but the fitted 2804A is 512 x 8
//  (A0..A8 only), so MA10/MA11 are don't-care and the 512 bytes repeat
//  **every 0x400** through the whole /EEPROM window 0x0E0000-0x0FFFFF.  Nine
//  address bits reach the array: MA1..MA9 = the CPU's A1..A9.  The part sits
//  on the ODD byte lane, so the program reads and writes 0x0E0001 + 2n.
//
//  ---- the unlock latch (18E LS74) ---------------------------------------
//      D (2) = GND     CK (3) = /WL     /PRE (4) = /UNLOCK    /CLR (1) = /SYSRES
//      Q (5) -> the 2804's /OE          /Q (6) unused
//
//  /UNLOCK (any write to 0x1E0000-0x1FFFFF) asynchronously SETS Q, driving
//  /OE high, which takes the 2804 out of read mode so the next /WE pulse is a
//  real write.  The RISING edge of that /WL — the end of ANY low-byte write on
//  the board, not just an EEPROM one — clocks D = 0 back in and re-locks the
//  part.  /SYSRES clears it.  Exactly one write per unlock: this is the
//  hardware behind MAME's `EEPROM_2804 ... lock_after_write(true)`.
//
//  Two orderings that matter, both reproduced below:
//   * The unlock write is itself a WORD write (`move.w d0,$1F0000`, pc
//     0x00358A), so /WL rises at the end of that very cycle.  /UNLOCK (PAL +
//     LS139, two gate delays behind /AS) is still low when /WL (one LS32 delay)
//     rises, so the PRESET wins.  Modelled by taking /UNLOCK as a LEVEL with
//     priority over the /WL edge.
//   * `write_accepted` samples `unlocked` BEFORE the same cycle's /WL edge can
//     re-lock the part, so the byte the game unlocked for really is stored.
//
//  ---- /OE and reads ------------------------------------------------------
//  While the part is unlocked (Q = 1) /OE is HIGH and the outputs are OFF: a
//  read in that window returns the floating bus, not the cell.  The program
//  masks interrupts around unlock+write (pc 0x003584-0x003592) so it never
//  reads there, but the behaviour is modelled rather than assumed away.
//
//  ---- programming time ---------------------------------------------------
//  The X2804A data sheet gives a self-timed byte write of typically 5 ms, at
//  most 10 ms, with the I/O pins high-Z throughout.  `WRITE_CYCLES` defaults
//  to the 10 ms bound and is a parameter so focused benches need not simulate
//  half a million clocks.
//============================================================================

module vind_eeprom_2804 #(
	parameter int CLK_HZ       = 57_272_727,
	parameter int WRITE_CYCLES = CLK_HZ / 100      // 10 ms
)(
	input  logic       clk,
	input  logic       init_reset,   // FPGA / PLL init: clears the busy state
	input  logic       sysres,       // the /SYSRES net, ACTIVE HIGH here

	input  logic       unlock,       // LEVEL: /UNLOCK asserted (18E /PRE)
	input  logic       wl_rise,      // 1-clk pulse: RISING /WL, anywhere on the board
	input  logic       cpu_we,       // 1-clk pulse: /EEPROM write with /WL low
	input  logic [8:0] cpu_addr,     // MA9..MA1
	input  logic [7:0] cpu_wdata,
	output logic [7:0] cpu_rdata,
	output logic       busy,
	output logic       oe_n,         // 18E Q -> 1C pin 20 (1 = outputs OFF)
	output logic       unlocked,
	output logic       write_accepted,

	// MiSTer NVRAM restore / save-back (vind_nvram_io)
	input  logic       load_we,
	input  logic [8:0] load_addr,
	input  logic [7:0] load_data,
	input  logic [8:0] dump_addr,
	output logic [7:0] dump_data
);

	localparam int BUSY_W = (WRITE_CYCLES <= 1) ? 1 : $clog2(WRITE_CYCLES + 1);
	logic [BUSY_W-1:0] busy_ctr;
	logic [7:0] mem [0:511];

`ifndef ALTERA_RESERVED_QIS
	// Sim-only: an unprogrammed 2804A reads 0xFF, which is also what the MRA
	// ships as the factory image.  On hardware vind_nvram_io writes the real
	// image in before the CPU runs.
	initial for (int i = 0; i < 512; i++) mem[i] = 8'hFF;
`endif

	assign busy           = |busy_ctr;
	assign write_accepted = cpu_we & unlocked & ~busy;
	assign dump_data      = mem[dump_addr];
	assign oe_n           = unlocked;          // 18E Q straight to /OE

	// 18E LS74.  /CLR = /SYSRES is asynchronous on the part; /UNLOCK (/PRE) is
	// a level and so beats the /WL rising edge of its own cycle — see header.
	always_ff @(posedge clk) begin
		if (init_reset || sysres) unlocked <= 1'b0;
		else if (unlock)          unlocked <= 1'b1;
		else if (wl_rise)         unlocked <= 1'b0;
	end

	// The cell array has no reset pin, so programming continues across a board
	// reset, and an out-of-band loader write is the power-up restore and wins.
	// The loader write deliberately sits OUTSIDE the init_reset arm: MiSTer's
	// index-2 NVRAM restore (and the MRA's image tail) can arrive while the core
	// still holds its game reset, and a load folded into the else-arm would be
	// dropped whenever init_reset happened to be high.
	always_ff @(posedge clk) begin
		if (load_we) begin
			mem[load_addr] <= load_data;
			busy_ctr <= '0;
		end else if (init_reset) busy_ctr <= '0;
		else begin
			if (busy) busy_ctr <= busy_ctr - 1'b1;
			if (write_accepted) begin
				mem[cpu_addr] <= cpu_wdata;
				busy_ctr <= BUSY_W'(WRITE_CYCLES);
			end
		end

		// During programming the I/O pins float; so do they while /OE is high
		// (the unlocked window).  Nothing pulls D0-D7 down, so the modelled
		// float value is 0xFF — also MAME's unmapped read.
		if (busy || oe_n) cpu_rdata <= 8'hFF;
		else              cpu_rdata <= mem[cpu_addr];
	end

endmodule
