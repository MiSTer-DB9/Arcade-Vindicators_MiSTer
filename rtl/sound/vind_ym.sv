//============================================================================
//  Vindicators (Atari Games, 1988) — JSA I audio PCB: YM2151 (2F) + YM3012 (2D).
//
//  Ported from `Arcade-Toobin_MiSTer/rtl/sound/toobin_ym.sv` (Toobin'
//  MiSTer core, GPL-3.0; same A043713 audio PCB) and re-checked against SP-317
//  sheet 16; `cen_p1` is re-documented for the Vindicators integer-enable
//  clocking.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- the hardware (SP-317 sheet 16) --------------------------------------
//    2F YM2151: OM(24) = 3579K, A0(4) = SA0, D7:0 = SD7:0, CS(7) = /YAM,
//               WR(5) = /SWR, RD(6) = /SRD, IC(3) = /YAMRES (5H D0),
//               IRQ(2) = /IRQ (open drain, wired-OR with Q8 on sheet 17),
//               CT1(8) / CT2(9) -> the 5C / 5D analog gates.
//    2D YM3012: ICL(7) = /YAMRES as well — resetting only jt51 covers both,
//               since jt51 models the YM3012's output path internally.
//
//  **Channel mapping.**  Sheet 16 puts YM3012 CH2(9) on the LEFT chain (LAUD ->
//  TDA2030 Q2 -> SPKR1 -> JSPK-5) and CH1(10) on the RIGHT (RAUD -> Q1 ->
//  SPKR2 -> JSPK-2).  jt51 emits `xleft`/`xright`; CH1 is the channel latched
//  by SH1, i.e. jt51's right, so CH2 = jt51 left.  The mapping is therefore the
//  identity: `aud_left` -> LAUD, `aud_right` -> RAUD.  Not settled by the
//  schematic: the CH1/CH2 <-> xleft/xright correspondence is inferred from
//  jt51's sample-and-hold order, not transcribed.
//
//  ---- clocking ------------------------------------------------------------
//  `cen` is ce_ym = clk_sys/16 = 3.579545 MHz (the 3579K net).  `cen_p1` must
//  be a strict half-rate SUBSET of `cen`; on this board that is exactly the
//  1790K net, i.e. ce_6502 = clk_sys/32, which is what vind_jsa passes.  Both
//  come from the same clk_sys divider, so the subset property holds by
//  construction — the Toobin' core's fractional `toobin_jsa_cen` is not used
//  here.
//
//  ---- the write bridge ----------------------------------------------------
//  The 6502 writes the YM at bus speed but jt51 captures `write = !cs_n & !wr_n`
//  on cen_p1, so each 6502 YM write (a0 + data) is latched into a pending
//  register and cs_n/wr_n are held asserted until a cen_p1 pulse consumes it.
//  Reads return jt51's status directly.  (The real 2M-FPAL stretches the 6502
//  instead, with READY: cycle timing only, and not modelled.)
//============================================================================

module vind_ym
(
	input  logic        clk,
	input  logic        reset,
	input  logic        cen,        // ce_ym  = 3.579545 MHz  (3579K, YM2151 OM)
	input  logic        cen_p1,     // ce_6502 = 1.7897725 MHz (1790K); subset of cen
	input  logic        ym_reset_n, // /YAMRES from the 5H /WRIO latch (1 = run)

	// bus side (from vind_jsa_bus)
	input  logic        ym_cs,      // /YAM this cycle
	input  logic        ym_a0,      // SA0
	input  logic        ym_we,      // /SWR strobe (one bus cycle)
	input  logic  [7:0] ym_dout,    // 6502 -> YM data
	output logic  [7:0] ym_din,     // YM status -> 6502

	// audio + peripheral
	output logic        sample,
	output logic signed [15:0] aud_left,     // YM3012 CH2 -> LAUD
	output logic signed [15:0] aud_right,    // YM3012 CH1 -> RAUD
	output logic signed [15:0] aud_left_lo,
	output logic signed [15:0] aud_right_lo,
	output logic        ct1,        // pin 8  -> 5C gate: PS into the LEFT sum
	output logic        ct2,        // pin 9  -> 5D gate: PS into the RIGHT sum
	output logic        ym_irq      // active high; pin 2 is open drain and is
	                                // wired-OR with Q8 onto /IRQ (sheet 17)
);

	// ---- write-pending bridge ----
	logic       wr_pend, wr_a0;
	logic [7:0] wr_d;
	always_ff @(posedge clk) begin
		if (reset) wr_pend <= 1'b0;
		else if (ym_cs & ym_we) begin
			wr_pend <= 1'b1; wr_a0 <= ym_a0; wr_d <= ym_dout;
		end else if (wr_pend & cen_p1) begin
			wr_pend <= 1'b0;
		end
	end

	wire irq_n;
	assign ym_irq = ~irq_n;

	jt51 u_jt51 (
		.rst    (reset | ~ym_reset_n),   // IC(3) = /YAMRES, and YM3012 ICL(7)
		.clk    (clk),
		.cen    (cen),
		.cen_p1 (cen_p1),
		.cs_n   (~wr_pend),
		.wr_n   (~wr_pend),
		.a0     (wr_a0),
		.din    (wr_d),
		.dout   (ym_din),
		.ct1    (ct1),
		.ct2    (ct2),
		.irq_n  (irq_n),
		.sample (sample),
		.left   (aud_left_lo),
		.right  (aud_right_lo),
		.xleft  (aud_left),
		.xright (aud_right)
	);

endmodule
