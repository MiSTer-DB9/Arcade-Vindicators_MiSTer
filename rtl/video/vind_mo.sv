`timescale 1ns/1ps
//============================================================================
//  Vindicators — the motion-object engine: SP-317 sheet 8 (`MO-CTRL`) plus the
//  two line-buffer customs on sheet 10.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later.
//
//  This module is only the wiring between `vind_mo_fetch` (the PAL 7N
//  sequencer, the word latches, the adders, the two undumped PROMs and the MO
//  half of the SLAGS shifters) and `vind_mo_linebuf` (14D/14E and the PAL 17E
//  write sequencer).  Both carry the detail in their own headers.
//
//  ---- the list walk, in one paragraph ------------------------------------
//  Sheet 6's NXLDL cycle reads the SLIP word for band PFV >> 3 out of alpha row
//  31 and 7L/7J latch its D9:0 into LNK9..LNK0.  From then on the sequencer
//  addresses {LNK9..LNK0, MC1, MC0}: it reads word 2 (Y, size, flip) and
//  word 3 (the next link) for every entry, and only when the vertical match
//  fires does it go back for word 0 (the code) and word 1 (X, colour,
//  priority).  /NEWMO clears when an object matches, so the sequencer stops
//  advancing the list and spends its MO slots fetching that object's tiles
//  until the 9K width counter runs out (/END), which re-asserts /NEWMO.  NXL
//  restarts the whole thing once per scanline.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_mo (
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	// ---- SYNGEN / sheet-6 taps ----
	input  logic  [2:0] hphase,       // {4H, 2H, 1H}
	input  logic        nxl,
	input  logic        lmpd_n,
	input  logic        gld_n,
	input  logic        mo_pf,
	input  logic        h4d3,
	input  logic        board_4h,
	input  logic        vblank_n,

	// ---- VRAM ----
	input  logic [15:0] vrd,

	// ---- sheet-7 ----
	input  logic  [8:0] pf_v,
	input  logic  [8:0] mo_xscroll_n,
	input  logic        matchd,

	// ---- graphics ROM client ----
	output logic        gfx_req,
	output logic [17:0] gfx_addr,
	input  logic [31:0] gfx_data,

	// ---- back to sheet 6 / 7 ----
	output logic        pvas0,
	output logic        pvas1,
	output logic  [1:0] mc,
	output logic        link_n,
	output logic        match,

	// ---- to the priority / GPC block (sheet 10) ----
	output logic  [7:0] lb,           // 14D DO7..DO0, ACTIVE LOW
	output logic        ston_n,
	output logic        stoff_n,
	output logic        mpr1,
	output logic        mpr0,
	output logic  [2:0] mog_data,
	output logic  [8:0] rd_hpos,

	// ---- diagnostics ----
	output logic  [8:0] hpos,
	output logic        rb1,
	output logic        newmo_n,
	output logic        end_n,
	output logic        gpen,
	output logic        bufclr_n     // PAL 7N pin 13 (see vind_mo_fetch.sv)
);

	logic [3:0] msd;
	logic [6:0] mat;
	logic       rb0, ld01_n;

	vind_mo_fetch u_fetch (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.hphase(hphase), .nxl(nxl), .lmpd_n(lmpd_n), .bufclr_n(bufclr_n),
		.gld_n(gld_n), .mo_pf(mo_pf), .h4d3(h4d3), .board_4h(board_4h),
		.vblank_n(vblank_n),
		.vrd(vrd), .pf_v(pf_v), .mo_xscroll_n(mo_xscroll_n), .matchd(matchd),
		.gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_data(gfx_data),
		.pvas0(pvas0), .pvas1(pvas1), .mc(mc), .link_n(link_n), .match(match),
		.msd(msd), .mat(mat), .hpos(hpos), .rb0(rb0), .rb1(rb1),
		.ld01_n(ld01_n), .gpen(gpen),
		.newmo_n(newmo_n), .end_n(end_n));

	/* verilator lint_off UNUSEDSIGNAL */
	wire we14d_dbg, we14e_dbg;
	/* verilator lint_on UNUSEDSIGNAL */

	vind_mo_linebuf u_lb (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.msd(msd), .mat(mat), .lmpd_n(lmpd_n), .rb1(rb1), .rb0(rb0),
		.ld01_n(ld01_n), .bufclr_n(bufclr_n), .hpos(hpos),
		.lb(lb), .ston_n(ston_n), .stoff_n(stoff_n),
		.mpr1(mpr1), .mpr0(mpr0), .mog_data(mog_data), .rd_hpos(rd_hpos),
		.we14d(we14d_dbg), .we14e(we14e_dbg));

`ifdef VIND_MO_TRACE
	integer trline;
	initial if (!$value$plusargs("motrace_line=%d", trline)) trline = -1;
	always @(posedge clk) if (ce_7m && trline >= 0
	                          && $signed({1'b0, pf_v}) >= trline
	                          && $signed({1'b0, pf_v}) <= trline + 4) begin
		if (we14d_dbg)
			$display("MOT WR pfv=%0d ph=%0d wa=%0d pen=%0d col=%0d",
			         pf_v, hphase, u_lb.rb1 ? u_lb.wa0 : u_lb.wa1,
			         ~msd, ~mat[3:0]);
		if (u_fetch.ld_mo)
			$display("MOT LDMO pfv=%0d ph=%0d gpen=%b data=%08h wa=%0d",
			         pf_v, hphase, u_fetch.gpen_l, gfx_data,
			         u_lb.rb1 ? u_lb.wa0 : u_lb.wa1);
	end
`endif

endmodule
