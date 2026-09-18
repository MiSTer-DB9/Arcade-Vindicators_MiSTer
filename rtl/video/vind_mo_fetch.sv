`timescale 1ns/1ps
//============================================================================
//  Vindicators — SP-317 sheet 8 (`MO-CTRL`): the PAL16R6A 7N slot sequencer,
//  the 4J LS139 word strobes, the four motion-object word latches, the X
//  adders, the two undumped bipolar PROMs, the graphics-address counters, the
//  MATCH flip-flops and the MO half of the sheet-9 SLAGS shifters.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later.
//
//  ---------------------------------------------------------------------------
//  1. PAL16R6A 7N = 136059-1153 -- a dumped PAL, implemented VERBATIM
//  ---------------------------------------------------------------------------
//  All six registered outputs clock on the rising edge of RCLKB; /OE (pin 11)
//  is grounded, so there is no "MO engine off" state.  jedutil prints the
//  sum-of-products that drives each pin LOW, so `pin = ~SOP` and, for the
//  registered pins, `Q = SOP` with the pin showing `~Q`.  The nets /END, /NXL,
//  /LMPD and /NEWMO are ACTIVE LOW, so the literals below are written
//  asserted-true (END, NXL, LMPD, NEWMO).
//
//      PVAS0 (12) = ~(  /1H & 2H
//                     +  1H & 2H & 4H & NXL )
//      pin13 (13) := ~(  1H & /2H & 4H & LMPD )
//      MC0   (14) := ~(  1H & 2H & /4H & MATCH & NEWMO
//                     + /1H & /2H & /MATCH
//                     + /1H & /2H & /4H & MATCH & MATCHD & NEWMO )
//      MC1   (15) := ~(  1H & 2H & /4H & MATCH & NEWMO
//                     + /1H & /2H & 4H & MATCH
//                     + /1H & /2H & /4H & MATCH & /MATCHD & NEWMO
//                     + /1H & /2H & /4H & MATCH & /NEWMO )
//      pin16 (16) := ~( /1H & /2H
//                     +  1H & 2H & /MATCH
//                     +  1H & 2H & /4H & MATCH & NEWMO
//                     +  1H & 2H & 4H & MATCH & MATCHD & NEWMO
//                     +  1H & 2H & 4H & NXL )
//      /LD01 (17) := ~(  1H & /2H & /4H & NEWMO )
//      /NEWMO(18) := ~( /1H & 2H & /4H & END
//                     +  1H & 2H & 4H & NXL
//                     + (/MATCHD + /MATCH + 4H + /2H + 1H) & NEWMO )
//      PVAS1 (19) = ~( /1H & /2H
//                     + /1H & 4H
//                     +  1H & 2H & /MATCH & /NXL
//                     +  1H & 2H & /4H & MATCH & NEWMO
//                     +  1H & 2H & 4H & MATCH & MATCHD & /NXL & NEWMO )
//
//  The five `... & NEWMO` terms inside /NEWMO's own equation are the classic
//  hold: NEWMO stays asserted until phase 2 (4H:2H:1H = 010) with MATCH and
//  MATCHD both true -- i.e. the sequencer LOCKS ON to an object that matched
//  this line -- and is re-asserted at phase 2 when the width counter finishes
//  (/END) or at phase 7 on a new line (NXL).
//
//  With MATCH low and nothing else asserted, PVAS1:PVAS0 over the eight phases
//  is 01, 11, 10, 01, 01, 11, 00, 01 = MO, CPU, alpha, MO, MO, CPU, PF, MO --
//  one playfield word, one alpha word, four MO words and two CPU cycles every
//  eight pixel clocks.  Sheet 6's 6F LS174C registers PVAS into VAS, so the
//  RAM cycle happens one RCLKA later than the code above names it.
//
//  ---------------------------------------------------------------------------
//  2. THE TWO UNDUMPED PROMs  (sheet 8, [inferred])
//  ---------------------------------------------------------------------------
//  11N 82S147 (512x8) and 9J 82S129 (256x4) are NOT in the MAME ROM set and
//  cannot be read off the drawing.  Their FUNCTION is fixed by their wiring
//  plus `atarimo.cpp`, and both are reconstructed here:
//
//    11N  A8..A0 = {/VMATCH, MFLP, HSIZ2, GND, HSIZ1, HSIZ0, tile_row[2:0]}
//         O8..O1 -> the preset of the 10N/9N LS169 offset counters.
//         The tiles of one object are consecutive and ROW-MAJOR (the counters
//         step by one per 8-pixel column and 6D LS04 makes them count DOWN when
//         MFLP is set), so the preset must be the offset of the FIRST tile of
//         the matched row:
//                 W = HSIZ + 1
//                 O = tile_row * W        (no flip -- count up from column 0)
//                 O = tile_row * W + W-1  (flip   -- count down from column W-1)
//         With /VMATCH inactive the value is a don't-care; 0 is used.
//
//    9J   A7..A0 = {HPOS8..HPOS4, HSIZ2..HSIZ0}
//         O4..O2 -> the 9K LS169 width counter's preset (down counter, D = GND)
//         O1     -> 21F LS74's D, the "this object is visible horizontally" bit
//         Reconstructed as the preset = HSIZ (i.e. width - 1, which is exactly
//         the three bits 9K's D = GND leaves room for; section 7 below has the
//         cycle count that makes HSIZ, and only HSIZ, draw HSIZ+1 columns) and
//         O1 = 1.  MAME wraps X with `xpos & 0x1ff` and never clips, so no
//         HPOS-dependent shortening is modelled; the HPOS inputs exist on the
//         board to stop an object that would run off the end of the 512-entry
//         line buffer, which cannot happen with a wrapping write pointer.
//
//  ---------------------------------------------------------------------------
//  3. STROBE PHASING IN THIS MODEL
//  ---------------------------------------------------------------------------
//  On the board the VRAM is asynchronous static RAM: during the cycle in which
//  MC1:MC0 selects a word, VRD already carries it, and the 4J LS139 strobe
//  latches it at the end of that same cycle.  `vind_vram.sv` reproduces that by
//  clocking its BRAM read at clk_sys (8x the pixel clock) instead of at ce_7m,
//  so `vrd` is the word of the CURRENT slot and the LS139 strobes here are used
//  undelayed -- exactly as drawn.
//
//  Sheet 8 routes PICTD/HORZD/VERTD through 7F LS175D first, so on the board
//  the word latches clock on the RCLKA edge that ENDS the LS139 strobe cell
//  (7F /Q = the active-high strobe, whose RISING edge is that boundary) and the
//  21F MATCH flip-flop, clocked by the complementary 7F Q, one cell later
//  again.  Both are modelled exactly that way below (`if (!vertd_n) w_vert <=`
//  at the end of the strobe cell, `vertd_n && !vertd_d` one cell after it).
//
//  ---------------------------------------------------------------------------
//  4. THE PIXEL PHASES THAT MATTER  (all named as {4H,2H,1H} = `hphase`)
//  ---------------------------------------------------------------------------
//      phase 0 : /GLD with MO//PF high -> the SLAGS load the MO column
//      phase 2 : /LD01 -> 8K/8J take MAT, 9K takes the width, and the 14D/14E
//                write pointers take HPOS (they present it from phase 3)
//      phase 3 : 4H's RISING edge -- 12M LS378C and the 10N/9N offset counters
//                clock here, and the MO column's FIRST pixel reaches MSD3..MSD0
//                (the SLAGS' own two-stage output delay line, section 10)
//      phase 7 : 4HD3's rising edge -- the 9K width counter steps and the
//                graphics-ROM row for the NEXT column is addressed
//
//  So the SLAGS column boundary and the /LD01 write-pointer reload coincide
//  exactly at phase 3, which is what makes the board's "a one-tile-wide object
//  never locks the sequencer and simply rewrites its single column every cell"
//  (section 7) come out as exactly eight pixels at HPOS.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_mo_fetch (
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	// ---- SYNGEN / sheet-6 taps ----
	input  logic  [2:0] hphase,      // {4H, 2H, 1H}
	input  logic        nxl,         // 11F /Q3 (active high)
	input  logic        lmpd_n,      // SYNGEN pin 25
	input  logic        gld_n,
	input  logic        mo_pf,       // MO//PF: 1 = the motion-object half
	input  logic        h4d3,
	input  logic        board_4h,
	input  logic        vblank_n,

	// ---- VRAM ----
	input  logic [15:0] vrd,

	// ---- sheet-7 inputs ----
	input  logic  [8:0] pf_v,
	input  logic  [8:0] mo_xscroll_n, // /PF256L../PF1L, ONE'S COMPLEMENT
	input  logic        matchd,       // 14M LS273K Q12

	// ---- graphics ROM client (see vind_pf.sv for the bit order) ----
	output logic        gfx_req,
	output logic [17:0] gfx_addr,
	input  logic [31:0] gfx_data,

	// ---- to sheet 6 ----
	output logic        pvas0,
	output logic        pvas1,
	output logic  [1:0] mc,
	output logic        link_n,

	// ---- to sheet 7 ----
	output logic        match,

	// ---- to sheet 10 ----
	output logic  [3:0] msd,          // MSD3..MSD0, the board's ACTIVE-LOW pen
	output logic  [6:0] mat,          // MAT6..MAT0, the board's ACTIVE-LOW
	                                  // priority(6:4) + colour(3:0)
	output logic  [8:0] hpos,
	output logic        rb0,
	output logic        rb1,
	output logic        ld01_n,
	output logic        gpen,
	// PAL 7N pin 13 IS the board's /BUFCLR (see section 3 below)
	output logic        bufclr_n,

	// ---- diagnostics ----
	output logic        newmo_n,
	output logic        end_n
);

	// =====================================================================
	// 1. PAL 7N -- state
	// =====================================================================
	wire h1 = hphase[0], h2 = hphase[1], h4 = hphase[2];

	logic q_mc0, q_mc1, q_p16, q_ld01, q_newmo, q_p13;
	// register value Q = SOP; the PIN is ~Q.
	wire newmo = q_newmo;                  // "/NEWMO asserted"
	assign newmo_n = ~q_newmo;
	assign mc      = {~q_mc1, ~q_mc0};     // the MC1:MC0 PINS
	wire   g139_n  = ~q_p16;               // 4J LS139 /G
	assign ld01_n  = ~q_ld01;
	wire   p13     = ~q_p13;

	wire nxl_a  = nxl;                     // asserted-true forms
	wire lmpd_a = ~lmpd_n;
	wire end_a  = ~end_n;

	// --- combinatorial outputs (pins 12 and 19) ---
	assign pvas0 = ~( (~h1 &  h2)
	                | ( h1 &  h2 &  h4 & nxl_a) );

	assign pvas1 = ~( (~h1 & ~h2)
	                | (~h1 &  h4)
	                | ( h1 &  h2 & ~match & ~nxl_a)
	                | ( h1 &  h2 & ~h4 &  match &  newmo)
	                | ( h1 &  h2 &  h4 &  match & matchd & ~nxl_a & newmo) );

	// --- registered outputs (pins 13..18), rising edge of RCLKB ---
	always_ff @(posedge clk) begin
		if (reset) begin
			q_mc0 <= 1'b0; q_mc1 <= 1'b0; q_p16 <= 1'b0;
			q_ld01 <= 1'b0; q_newmo <= 1'b1; q_p13 <= 1'b0;
		end else if (ce_7m) begin
			q_p13 <= ( h1 & ~h2 &  h4 & lmpd_a);

			q_mc0 <= ( h1 &  h2 & ~h4 &  match & newmo)
			       | (~h1 & ~h2 & ~match)
			       | (~h1 & ~h2 & ~h4 &  match &  matchd & newmo);

			q_mc1 <= ( h1 &  h2 & ~h4 &  match & newmo)
			       | (~h1 & ~h2 &  h4 &  match)
			       | (~h1 & ~h2 & ~h4 &  match & ~matchd & newmo)
			       | (~h1 & ~h2 & ~h4 &  match & ~newmo);

			q_p16 <= (~h1 & ~h2)
			       | ( h1 &  h2 & ~match)
			       | ( h1 &  h2 & ~h4 &  match & newmo)
			       | ( h1 &  h2 &  h4 &  match &  matchd & newmo)
			       | ( h1 &  h2 &  h4 & nxl_a);

			q_ld01 <= ( h1 & ~h2 & ~h4 & newmo);

			q_newmo <= (~h1 &  h2 & ~h4 & end_a)
			         | ( h1 &  h2 &  h4 & nxl_a)
			         | ((~matchd | ~match | h4 | ~h2 | h1) & newmo);
		end
	end

	// =====================================================================
	// 2. 4J LS139 -- the four MO word strobes (sheet 8)
	// =====================================================================
	logic [3:0] y139;
	always_comb begin
		y139 = 4'hF;
		if (!g139_n) y139[mc] = 1'b0;
	end
	wire pictd_n = y139[0];
	wire horzd_n = y139[1];
	wire vertd_n = y139[2];
	assign link_n = y139[3];

	// =====================================================================
	// 3. 7F LS175D -- the strobe pipeline and the line-buffer bank (sheet 8)
	// =====================================================================
	// 24E LS86 (4,5 -> 6): pin13 ^ RB0 -> 7F D4 -> Q2 = RB1, /Q3 = RB0.
	// pin13 is low only in phase 5 (4H & /2H & 1H) while LMPD is asserted, so
	// D4 = ~RB1 for exactly one clock per scanline and RB toggles once per
	// line: the ping-pong of the two MO line buffers.
	//
	// PIN 13 IS THE BOARD'S /BUFCLR.  Not settled by the schematic: sheet 8
	// also shows /BUFCLR on 7F's /CLR, and that cannot be taken literally -- an
	// asynchronous clear on THIS register would pin the bank at 0 and there
	// would be no ping-pong at all.  Gauntlet -- the same custom set -- builds
	// the net in discrete logic as `/BUFCLR = /LMPD + /4H + 2H + /1H`
	// (`Arcade-Gauntlet_MiSTer-main/rtl/gauntlet/VIDEO.vhd` line 693), which is
	// this exact term, and feeds it BOTH to the XOR that toggles the bank flag
	// (line 723, `sl_FLBBn <= sl_FLBAn xor sl_BUFCLRn`) and to the line
	// buffers' clear (`LINEBUF.vhd` line 57, `sl_CLRn <= I_FLBn or
	// I_BUFCLRn` = Vindicators' 14F LS32).  The 7F clear modelled here is
	// therefore the power-on reset only.
	assign bufclr_n = p13;

	logic q_rb;
	always_ff @(posedge clk) begin
		if (reset)          q_rb <= 1'b0;
		else if (ce_7m)     q_rb <= p13 ^ ~q_rb;
	end
	assign rb1 =  q_rb;
	assign rb0 = ~q_rb;

	// =====================================================================
	// 4. The four word latches (sheet 8)
	// =====================================================================
	logic [15:0] w_code;                    // word 0, PICTD  (4M + 7K)
	logic [15:0] w_horz;                    // word 1, HORZD  (8M + 8L)
	logic [15:0] w_vert;                    // word 2, VERTD  (9M + 9L)
	logic pictd_d, horzd_d, vertd_d;
	always_ff @(posedge clk) begin
		if (reset) begin
			w_code <= 16'd0; w_horz <= 16'd0; w_vert <= 16'd0;
			pictd_d <= 1'b1; horzd_d <= 1'b1; vertd_d <= 1'b1;
		end else if (ce_7m) begin
			pictd_d <= pictd_n; horzd_d <= horzd_n; vertd_d <= vertd_n;
			// the '273s clock on the RISING edge of the (active-low) strobe
			if (!pictd_n) w_code <= vrd;
			if (!horzd_n) w_horz <= vrd;
			if (!vertd_n) w_vert <= vrd;
		end
	end
	/* verilator lint_off UNUSEDSIGNAL */
	// GA15 (mo_tile[15]) is not decoded by the graphics ROM (sheet 9).
	wire unused_edges = &{1'b0, pictd_d, horzd_d, vertd_d, board_4h,
	                      mo_tile[15]};
	/* verilator lint_on UNUSEDSIGNAL */

	wire [8:0] mo_x    = w_horz[15:7];
	wire [6:0] mat_raw = w_horz[6:0];       // MAT6..MAT0 = priority + colour
	wire [8:0] mo_y    = w_vert[15:7];
	wire       mflp    = w_vert[6];
	wire [2:0] hsiz    = w_vert[5:3];
	wire [2:0] vsiz    = w_vert[2:0];

	// =====================================================================
	// 5. 10J / 10K / 4N -- HPOS = MO_X - MO_XSCROLL  (sheet 8)
	// =====================================================================
	assign hpos = mo_x + mo_xscroll_n + 9'd1;

	// ---- 12M LS378C -- the snapshot register (sheet 8) ---------------------
	//   12M : CK = 4H , /G = /NEWMO
	//         D4 = MFLP -> Q5 ; D13/D3/D6 = 12N S3/S2/S1 (= diff[2:0]) -> the
	//         GP4V/GP2V/GP1V side of 12L ; D14 = MATCH -> Q15 -> 20F = GPEN.
	//
	// 4H's rising edge is the ce_7m edge that ENDS phase 3 (see vind_alpha.sv),
	// and /NEWMO is still asserted at that edge in the cell BEFORE the lock-on
	// (the PAL clears it during phase 3, so 12M's last enabled edge is the one
	// that ends phase 3 of the previous cell).  At that point 9M/9L still hold
	// the MATCHED entry's word 2, whichever of the two VERTD slots produced the
	// match:
	//
	//   * VERTD in phase 1 of cell N  -> MATCH from phase 3 of N, lock during
	//     phase 3 of N+1; last 12M edge = end of phase 3 of N.
	//   * VERTD in phase 5 of cell N  -> MATCH from phase 7 of N, lock during
	//     phase 3 of N+2; last 12M edge = end of phase 3 of N+1, and cell N+1
	//     carries HORZD (not VERTD) in phase 1, so word 2 is untouched.
	//
	// The snapshot is what the fetch must use: taken LIVE from the vertical-
	// match adders, `pix_row`/`tile_row` would give every tile of a matched
	// object the row of the FOLLOWING list entry.
	wire h4_rise = ce_7m & (hphase == 3'd3);   // the RISING edge of 4H
	wire ld_12m  = h4_rise & ~newmo_n;         // 12M /G = /NEWMO
	logic [2:0] pix_row_l;
	logic       mflp_l2;
	// HSIZ/VSIZ have no drawn snapshot, but 9K is preset by /LD01 in phase 2 --
	// AFTER the phase-1 VERTD of the lock cell has already replaced word 2 --
	// so a live HSIZ would give every object its successor's width.  Snapshotted
	// alongside 12M's bits.  [inferred]
	logic [2:0] hsiz_l, vsiz_l;
	always_ff @(posedge clk) begin
		if (reset) begin
			hsiz_l <= 3'd0; vsiz_l <= 3'd0; mflp_l2 <= 1'b0;
			pix_row_l <= 3'd0;
		end else if (ld_12m) begin
			hsiz_l     <= hsiz;
			vsiz_l     <= vsiz;
			mflp_l2    <= mflp;
			pix_row_l  <= pix_row;
		end
	end
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_vsizl = &{1'b0, vsiz_l};
	/* verilator lint_on UNUSEDSIGNAL */

	// 8K / 8J LS175 -- MAT6..MAT0 latched on /LD01
	logic ld01_n_d;
	always_ff @(posedge clk) begin
		if (reset) begin mat <= 7'd0; ld01_n_d <= 1'b1; end
		else if (ce_7m) begin
			ld01_n_d <= ld01_n;
			// the LS175 /Q outputs are the MAT nets, so MAT is ACTIVE LOW --
			// which is what 17D's `/o19` and 17E's `PRI6 = /MAT6` require.
			if (!ld01_n) mat <= ~mat_raw;
		end
	end
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_ld = &{1'b0, ld01_n_d};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	// 6. Vertical match (sheet 8)
	// =====================================================================
	logic       vmatch_n;
	logic [2:0] tile_row, pix_row;
	vind_mo_vmatch u_vmatch (
		.pf_v(pf_v), .mo_y(mo_y), .vsiz(vsiz), .vblank_n(vblank_n),
		.vmatch_n(vmatch_n), .tile_row(tile_row), .pix_row(pix_row));

	// =====================================================================
	// 7. 9J 82S129 + 9K LS169 -- the width counter and /END (sheet 8)
	// =====================================================================
	// [inferred], header section 2.  The preset is **HSIZ** -- the object's
	// width minus one -- which is exactly the three bits sheet 8's "9K D
	// (pin 6) = GND" leaves room for, and it is the only value that draws
	// HSIZ + 1 columns:
	//
	//  * 9K is RELOADED at every /LD01 (phase 2) and DECREMENTED at every 4HD3
	//    (phase 7).  For a ONE-tile-wide object the preset is 0, so /END is
	//    already true at the phase-2 decision point; /NEWMO's set term
	//    (`/1H & 2H & /4H & END`) sits at the same phase as the lock-on
	//    condition and wins, so the sequencer never locks on.  The walk carries
	//    on, /LD01 keeps reloading the 14D write pointer with HPOS at the exact
	//    phase the SLAGS start a new column (header section 4), and the 8-pixel
	//    column is written over itself.  Exactly one column, list not stalled.
	//  * With preset P >= 1 the sequencer locks on during phase 3 of the lock
	//    cell, the reload stops, and the counter runs 4HD3 by 4HD3: P at the
	//    lock cell, P-1, ... 0, and /END is seen at phase 2 P+1 cells later.
	//    The columns start at phase 3 of the lock cell, one per cell, so the
	//    object is P + 1 = HSIZ + 1 columns wide -- MAME's `width`.
	//
	// A preset of `HSIZ + 1` instead draws ONE EXTRA column of the tile past the
	// object's right edge on every object wider than one tile, as a pixel
	// comparison against MAME shows.
	wire [3:0] prom9j_cnt = {1'b0, hsiz_l};
	wire       prom9j_vis = 1'b1;           // [inferred], header section 2

	// 4HD3's rising edge is phase 7 (its high window is phases 7,0,1,2).
	logic h4d3_q;
	always_ff @(posedge clk) if (ce_7m) h4d3_q <= h4d3;
	wire  ck_4hd3 = h4d3 & ~h4d3_q;

	// Not settled by the schematic: sheet 8 reads 9K's CK as 4HD3 and its /LD as
	// /LD01, but /LD01 is low only in phase 2 while 4HD3 rises in phase 7, so a
	// LITERAL LS169 -- synchronous load -- would never take the preset at all.
	// The counter is therefore modelled with a
	// TRANSPARENT /LD (the preset shows through while /LD01 is low, as an
	// LS193/LS191-class part or a '169 clocked inside phase 2 would behave) and
	// a 4HD3 count.  That is the only reconstruction in which the SAME
	// three-bit 82S129 output produces both required behaviours:
	//
	//   W = 1 (preset 0): /END is already true at every phase-2 decision point,
	//                     so the sequencer never locks on -- see above.
	//   W > 1 (preset P): /END is false at the lock, then the register counts
	//                     P-1, P-2, ... and reaches 0 at phase 2 of the
	//                     (P = W-1)-th cell after it, releasing /NEWMO one cell
	//                     BEFORE the offset counter would have addressed tile W.
	//
	// With a synchronous load the two cases would need preset = HSIZ+1 and HSIZ
	// respectively, which no single PROM value can satisfy -- and a preset of
	// HSIZ+1 is exactly what draws the extra column described above.
	logic [3:0] wcnt;
	wire  [3:0] wcnt_eff = ld01_n ? wcnt : prom9j_cnt;      // transparent /LD
	always_ff @(posedge clk) begin
		if (reset)                wcnt <= 4'd0;
		else if (ce_7m) begin
			if (!ld01_n)          wcnt <= prom9j_cnt;           // /LD
			else if (ck_4hd3)     wcnt <= wcnt - 4'd1;          // CK = 4HD3
		end
	end
	assign end_n = ~(wcnt_eff == 4'd0);     // RCO of a down counter

	// =====================================================================
	// 8. 21F LS74 + 21E LS08 -- MATCH  (sheet 8)
	// =====================================================================
	//   first half : D = /VMATCH, CK = /VERTD, /PRE = /NXL, /CLR = PR4
	//                /Q -> 21E pin 5
	//   second half: D = 9J O1,  CK = /HORZD, /PRE = /VERTD, /CLR = PR4
	//                Q  -> 21E pin 4
	logic ff_v, ff_h;
	always_ff @(posedge clk) begin
		if (reset) begin ff_v <= 1'b1; ff_h <= 1'b0; end
		else if (ce_7m) begin
			if (nxl)                          ff_v <= 1'b1;   // /PRE = /NXL
			else if (vertd_n && !vertd_d)     ff_v <= vmatch_n;
			if (!vertd_n)                     ff_h <= 1'b1;   // /PRE = /VERTD
			else if (horzd_n && !horzd_d)     ff_h <= prom9j_vis;
		end
	end
	assign match = ~ff_v & ff_h;            // 21E LS08 (/Q of the first half)

	// =====================================================================
	// 9. 11N 82S147 + 10N/9N LS169 + 8N/7M LS283 -- the graphics address
	// =====================================================================
	// Sheet 8 wires the 82S147's address from the LIVE nets -- A8 = /VMATCH,
	// A7 = MFLP (9L), A6/A4/A3 = HSIZ (9L), A2:A0 = 14N S4:S2 -- not from 12M,
	// and 10N/9N reload from it on EVERY 4H while /NEWMO is asserted.
	// The last of those edges is the one that ends phase 3 of the cell before
	// the lock-on, where word 2 is still the matched entry's (see the 12M note
	// in section 5), so the live inputs are the right ones and the value the
	// counters hold once /NEWMO deasserts is the matched object's first tile.
	wire [7:0] width8 = {5'd0, hsiz} + 8'd1;
	wire [7:0] base8  = {5'd0, tile_row} * width8;
	wire [7:0] prom11n = mflp ? (base8 + width8 - 8'd1) : base8;

	// 10N / 9N LS169: CK = 4H (sheet 8), /LD = /NEWMO, U//D = 6D LS04 from
	// the snapshotted MFLP (12M Q5) -- the direction has to survive the whole
	// locked-on fetch, so it cannot be the live 9L bit.
	logic [7:0] gaoff;
	always_ff @(posedge clk) begin
		if (reset)                gaoff <= 8'd0;
		else if (h4_rise) begin
			if (!newmo_n)         gaoff <= prom11n;              // /LD = /NEWMO
			else                  gaoff <= mflp_l2 ? (gaoff - 8'd1)
			                                       : (gaoff + 8'd1);
		end
	end

	// 4M drives GA15..GA8 from the code word's high byte; 8N/7M add the offset
	// into the LOW byte only, so the sum wraps at 256 -- a real hardware limit
	// MAME does not have, and a deliberate difference from it.
	wire [15:0] mo_tile = {w_code[15:8], w_code[7:0] + gaoff};

	// ---- when the SDRAM path is ASKED for a column -------------------------
	// The board's ROMs are asynchronous: the SLAGS simply take whatever the
	// address bus selects at the MO /GLD (phase 0).  The core fetches through
	// `vind_gfx_hold` / `vind_gfx_mem` / the SDRAM, ~12 clk_sys at best and up
	// to ~30 under a playfield or 68010 burst, so the request has to go out as
	// soon as the address is COMPLETE.  Waiting for 4HD3 (phase 7) leaves only
	// one pixel = 8 clk_sys before the load, and every column then arrives one
	// cell late:
	//   * the FIRST column of an object is complete at the PICTD edge, when 4M/7K
	//     take the code word: {code + 11N preset, row}.  That is 4 pixels before
	//     its /GLD in the phase-1 lock-on and 7 in the phase-5 one;
	//   * every FOLLOWING column is complete at the 4H edge that steps 10N/9N,
	//     4 pixels before its /GLD -- and so is the first column of a phase-5
	//     lock-on, whose code word is already latched when that edge loads the
	//     11N preset into the counters.
	// Both addresses are exactly the ones the asynchronous bus would carry at
	// the corresponding /GLD.
	logic        req_first_d;
	logic [17:0] addr_first;
	always_ff @(posedge clk) begin
		if (reset) begin req_first_d <= 1'b0; addr_first <= 18'd0; end
		else begin
			req_first_d <= ce_7m & ~pictd_n;
			if (ce_7m && !pictd_n)
				// The 12M row and the 10N/9N preset as loaded at the 4H edge
				// that ENDED the previous phase -- not the live adders, which
				// at the end of a line already show the next line's row (the
				// vertical counter steps on the same 4H edge, PFHST) and would
				// fetch the column with that wrong row.  For the phase-5
				// lock-on both are still the previous entry's here, and the 4H
				// request two pixels later overrides this one.
				addr_first <= {vrd[14:8], vrd[7:0] + gaoff, pix_row_l};
		end
	end
	assign gfx_addr = req_first_d ? addr_first : {mo_tile[14:0], pix_row_l};
	// Every 4H edge, locked or not: the address after that edge is what the
	// asynchronous bus carries at the next MO /GLD (the first column of a
	// phase-5 lock-on, and every column after the first, come from here; the
	// PICTD request only matters for the phase-1 lock-on, whose code word
	// arrives one pixel after that edge -- and then it simply repeats the same
	// address, which costs one spare SDRAM transaction per object per line).
	assign gfx_req  = (ce_7m & ~pictd_n) | h4_rise;

`ifdef VIND_MO_TRACE
	// simulation-only trace of the list walk and the tile fetches
	logic match_q;
	always_ff @(posedge clk) if (ce_7m) match_q <= match;
	always @(posedge clk) if (ce_7m) begin
		if (!vertd_n) $display("MOT VERTD pfv=%0d vrd=%04h vmatch_n=%b tile_row=%0d pix_row=%0d ph=%0d newmo_n=%b", pf_v, vrd, vmatch_n, tile_row, pix_row, hphase, newmo_n);
		if (match && !match_q) $display("MOT MATCH pfv=%0d w_code=%04h w_horz=%04h w_vert=%04h pix_row=%0d tile_row=%0d ph=%0d", pf_v, w_code, w_horz, w_vert, pix_row, tile_row, hphase);
		if (ld_12m) $display("MOT 12M pfv=%0d pix_row<=%0d hsiz<=%0d mflp<=%b gpen<=%b gaoff<=%0d ph=%0d", pf_v, pix_row, hsiz, mflp, match, prom11n, hphase);
		if (!ld01_n) $display("MOT LD01 pfv=%0d hpos=%0d w_horz=%04h wcnt<=%0d ph=%0d newmo_n=%b", pf_v, hpos, w_horz, prom9j_cnt, hphase, newmo_n);
		if (gfx_req) $display("MOT FETCH pfv=%0d addr=%05h tile=%04h gaoff=%0d pix_row_l=%0d newmo_n=%b wcnt=%0d gpen_l=%b match=%b ph=%0d", pf_v, gfx_addr, mo_tile, gaoff, pix_row_l, newmo_n, wcnt, gpen_l, match, hphase);
		if (nxl) $display("MOT NXL pfv=%0d ph=%0d", pf_v, hphase);
	end
`endif

	// =====================================================================
	// 10. 12M LS378C / 12L LS257C / 20F LS32 (sheet 8) and the MO SLAGS half
	// =====================================================================
	// 12M Q5 = MFLP -> 12L 4A -> HFLP, and 12M Q15 = MATCH -> 20F LS32 = GPEN.
	// Same register, same enable, as the row bits in section 5.
	logic gpen_l;
	always_ff @(posedge clk) begin
		if (reset)          gpen_l <= 1'b0;
		else if (ld_12m)    gpen_l <= match;    // CK = 4H, /G = /NEWMO
	end
	assign gpen = gpen_l;                       // 20F LS32 used as a buffer
	wire   mo_flip_l = mflp_l2;                 // 12M Q5 -> 12L 4A -> HFLP

	wire ld_mo = ce_7m & ~gld_n & mo_pf;

	logic [7:0] ml0, ml1, ml2, ml3;
	logic       mo_flip;
	always_ff @(posedge clk) begin
		if (reset) begin
			ml0 <= 8'hFF; ml1 <= 8'hFF; ml2 <= 8'hFF; ml3 <= 8'hFF;
			mo_flip <= 1'b0;
		end else if (ce_7m) begin
			if (ld_mo) begin
				// GPEN qualifies the 3N bank decode; with no ROM selected the
				// 4.7K packs (RP3..RP6) hold the bus at all-ones = pen 0.
				mo_flip <= mo_flip_l;
				ml0 <= gpen_l ? gfx_data[7:0]   : 8'hFF;
				ml1 <= gpen_l ? gfx_data[15:8]  : 8'hFF;
				ml2 <= gpen_l ? gfx_data[23:16] : 8'hFF;
				ml3 <= gpen_l ? gfx_data[31:24] : 8'hFF;
			end else if (mo_flip) begin
				ml0 <= {1'b1, ml0[7:1]};
				ml1 <= {1'b1, ml1[7:1]};
				ml2 <= {1'b1, ml2[7:1]};
				ml3 <= {1'b1, ml3[7:1]};
			end else begin
				ml0 <= {ml0[6:0], 1'b1};
				ml1 <= {ml1[6:0], 1'b1};
				ml2 <= {ml2[6:0], 1'b1};
				ml3 <= {ml3[6:0], 1'b1};
			end
		end
	end

	// MSD3..MSD0 leave the SLAGS in the board's ACTIVE-LOW pixel sense: the ROM
	// bytes arrive raw (the data lines carry 4.7K pull-ups, and MAME models the
	// same fact with ROMREGION_INVERT at load time), so no inversion is needed
	// here.  Every consumer -- the 17D/17E PAL equations, the 14D/14E line
	// buffers and the GPC's M bus -- wants exactly that sense.
	wire [3:0] msd_sr = mo_flip ? {ml3[0], ml2[0], ml1[0], ml0[0]}
	                            : {ml3[7], ml2[7], ml1[7], ml0[7]};

	// ---- the SLAGS' own output delay line ---------------------------------
	// The Atari 137415-101 does not present the LS299 tap directly on MODA/MODB:
	// latches 2A/2B (MO) and 3A/3B (PF) are a TWO-CLOCK delay line between the
	// shifter multiplexer and the output pins (Gauntlet's `SLAGS.vhd`, the same
	// custom, `p_2A_2B_3A_3B`; `Arcade-Gauntlet_MiSTer/
	// rtl/gauntlet/SLAGS.vhd`).  `vind_pf.sv` already carries the playfield half
	// of it as PFX_ALIGN = 2 on the pen nibble -- and only on the pen nibble,
	// because PS7..PS4 do not come through the SLAGS -- which is the same two
	// clocks seen from the other side.
	//
	// It is what puts the MO column's first pixel in phase 3, i.e. on the very
	// pixel at which /LD01 has just presented HPOS to the 14D write pointer
	// (header section 4).  Without it every motion object lands two pixels left
	// of MAME's `xpos = X - xscroll`; with it the layer is pixel-exact against
	// MAME frame captures.
	logic [3:0] msd_2b, msd_2a;
	always_ff @(posedge clk) begin
		if (reset) begin msd_2b <= 4'hF; msd_2a <= 4'hF; end
		else if (ce_7m) begin
			msd_2b <= msd_sr;
			msd_2a <= msd_2b;
		end
	end
	assign msd = msd_2a;

endmodule
