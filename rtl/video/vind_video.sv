`timescale 1ns/1ps
//============================================================================
//  Vindicators video top — SP-317 sheets 6 (VRAM/SYNGEN), 7 (ALPHA), 8
//  (MO-CTRL), 9 (GR-MEM), 10 (line buffers / priority / GPC / CRAM) and 11
//  (RGBI DAC), plus the sheet-5 common-bus signals that terminate here.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Structure follows the Xybots MiSTer core's `xybots_video.sv`
//  (GPL-3.0); every equation is Vindicators' own.
//
//  ---- the sheet-5 question this module answers ---------------------------
//  Sheet 5's ECPU half is not populated, so /ECOM is never asserted, the 23D
//  LS158A mux is held permanently on the main CPU's side and the main CPU is
//  granted the common bus with no arbitration delay.  This module therefore
//  drives `ecom_n` high, constantly, and everything the video side needs from
//  the common bus (CDS, /CIO, CW//R, /CWH, /CA20) is a pure function of the
//  main CPU's own strobes -- which is exactly what vind_main_bus already
//  synthesises.
//
//  ---- PIPE_DLY ------------------------------------------------------------
//  The board's own pipeline (VRAM slot -> latch -> shifter -> GPC register ->
//  CRAM -> output register) puts the pixel for screen column x on the DAC a
//  fixed number of counts after SYNGEN count x.  PIPE_DLY delays the raster
//  markers (HBLANK, VBLANK, HSYNC, VSYNC and -- see the generate block at the
//  bottom -- /VIDBL) by that many pixel clocks so the picture and the blanking
//  window line up again.  With PIPE_DLY = 2 the rendered frame sits at offset
//  (0, 0) against MAME frame captures.  Changing it moves the whole picture,
//  never one layer against another -- the layer-to-layer alignment lives in
//  vind_pf.sv's PFX_ALIGN and PSHI_STAGES.
//============================================================================

module vind_video #(
	parameter bit DAC_MAME_COMPAT = 1'b0,
	parameter bit ALPHA_D_MAME    = 1'b1,
	parameter bit PFX_LITERAL     = 1'b0,
	parameter int PIPE_DLY        = 2
)(
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        ce_14m,
	input  logic        reset,
	input  logic        sysres,       // /SYSRES asserted (active high here)

	// ================= common bus toward vind_main_bus =======================
	input  logic [16:1] ma,
	input  logic [15:0] cpu_dout,
	output logic [15:0] cpu_din,
	input  logic        vram_n,
	input  logic        cw_r,         // CW//R: 1 = the CPU is writing
	input  logic        uds_n,
	input  logic        lds_n,
	input  logic        dtack,
	input  logic        vack_n,
	output logic        pvcpu,
	output logic        ecom_n,
	output logic        vint_n,
	output logic        vblank_n_out,

	// ================= graphics ROM clients (rtl/mem) ========================
	output logic [13:0] char_addr,
	input  logic  [7:0] char_data,
	// The two row clients are presented to `rtl/mem` through
	// `vind_gfx_hold`, which turns the pipeline's asynchronous-ROM view (a
	// one-clk_sys pulse plus a combinational address) into the HELD request the
	// SDRAM arbiter documents.  See vind_gfx_hold.sv for why a pulse is not
	// enough and why the address belongs to the cycle after it.
	output logic        pf_gfx_req,
	output logic [17:0] pf_gfx_addr,
	input  logic [31:0] pf_gfx_data,
	input  logic        pf_gfx_valid,
	output logic        mo_gfx_req,
	output logic [17:0] mo_gfx_addr,
	input  logic [31:0] mo_gfx_data,
	input  logic        mo_gfx_valid,

	// ================= video output =========================================
	output logic        ce_pix,
	output logic  [7:0] red,
	output logic  [7:0] green,
	output logic  [7:0] blue,
	output logic        hsync,
	output logic        vsync,
	output logic        hblank,
	output logic        vblank,

	// ================= observation ==========================================
	output logic  [8:0] h,
	output logic  [7:0] v,
	output logic  [8:0] hpos_out,
	output logic [10:0] cram_a_out,
	output logic  [1:0] vas_out,
	output logic  [3:0] layer_out     // {stain, cras1, cras0, shade}
);

	// =====================================================================
	//  SYNGEN 11/12 J/K and the sheet-6 clock tree
	// =====================================================================
	logic       v256, hblank_n, vblank_n, hsync_n, vsync_n, vidbl_n;
	logic [8:0] hpos;
	logic       vrac2, pnxl_n, h_4hd1h_n, h_4hd2h_n, mohr_n;
	logic       pfhst_n, pfhst;
	logic       syn_hblank;

	// The SYNGEN model is shared with the Xybots core, so it carries the union
	// of the two boards' pin sets; the six pins Vindicators leaves as bare
	// stubs on SP-317 sheet 6 are tied off here.
	/* verilator lint_off PINCONNECTEMPTY */
	vind_syngen u_syngen (
		.clk(clk), .reset(reset), .ce_14m(ce_14m), .ce_7m(ce_7m),
		.m14(), .m14p_n(), .m7(), .m7_n(), .dclk(), .rclk(),
		.vidclk(), .vidclk_n(),
		.h(h), .v(v), .v256(v256), .hpos(hpos), .h256(),
		.hblank(syn_hblank), .hblank_n(hblank_n),
		.vblank(), .vblank_n(vblank_n),
		.hsync_n(hsync_n), .vsync_n(vsync_n), .blank_n(vidbl_n),
		.h1_n(), .h2_n(), .h4_n(), .h1h2(), .h1h2h4h_n(),
		.h_2hd1h(), .h_2hd1h_n(),
		.h_4hd1h(), .h_4hd1h_n(h_4hd1h_n),
		.h_4hd2h(), .h_4hd2h_n(h_4hd2h_n),
		.v1_n(), .v1d8h(), .v1d8h_n(),
		.vrac0(), .vrac1(), .vrac2(vrac2), .vram_phase(),
		.mohr_n(mohr_n), .mohld0_n(), .mohld1_n(), .mohr0_n(), .mohr1_n(),
		.virq_gate(),
		.pfhst_n(pfhst_n), .pfhst(pfhst),
		.nxl_n(pnxl_n),
		.line_start(), .frame_start(), .vblank_start());
	/* verilator lint_on PINCONNECTEMPTY */

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_syn = |{v256, hpos, hblank_n, pf_mo};
	/* verilator lint_on UNUSEDSIGNAL */

	// 23F S04 (9->8): MO//PF = ~PF//MO, and PF//MO is SYNGEN pin 35 itself.
	wire pf_mo = h_4hd1h_n;
	wire mo_pf = ~h_4hd1h_n;

	assign vblank_n_out = vblank_n;
	assign ecom_n       = 1'b1;         // the ECPU half is not populated

	// =====================================================================
	//  Sheet 6 -- VRAM, the address multiplexers and the CPU slot
	// =====================================================================
	logic  [1:0] vas;
	logic        vas1a, vcpu, nxldl, h03, gld_n, nxl, nxl_n;
	logic        board_4h, board_4h_n, h4d3;
	logic        clram_n, pram_n, vuwe_n, vlwe_n, vw_r, vramrd_n;
	logic [15:0] vrd;
	logic  [9:0] lnk;
	logic        pvas0, pvas1, link_n;
	logic  [1:0] mc;
	logic  [5:0] pf_h;
	logic  [8:0] pf_v;
	logic [15:0] cpu_vram_din;

	vind_vram u_vram (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.h(h), .v(v), .vrac2(vrac2), .pnxl_n(pnxl_n), .h_4hd2h_n(h_4hd2h_n),
		.pvas0(pvas0), .pvas1(pvas1), .mc(mc), .link_n(link_n),
		.pf_h(pf_h), .pf_v(pf_v),
		.ma(ma), .cpu_dout(cpu_dout), .vram_n(vram_n), .w_r(cw_r),
		.uds_n(uds_n), .lds_n(lds_n), .dtack(dtack), .pvcpu(pvcpu),
		.cpu_vram_din(cpu_vram_din), .vramrd_n(vramrd_n),
		.clram_n(clram_n), .pram_n(pram_n),
		.vuwe_n(vuwe_n), .vlwe_n(vlwe_n), .vw_r(vw_r),
		.vas(vas), .vas1a(vas1a), .vcpu(vcpu), .nxldl(nxldl), .h03(h03),
		.gld_n(gld_n), .nxl(nxl), .nxl_n(nxl_n),
		.board_4h(board_4h), .board_4h_n(board_4h_n), .h4d3(h4d3),
		.vrd(vrd), .lnk(lnk));

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_vram = |{vas1a, vcpu, nxldl, lnk, board_4h_n, nxl_n};
	/* verilator lint_on UNUSEDSIGNAL */

	assign vas_out = vas;

	// =====================================================================
	//  Sheet 7 -- alphanumerics, control words, PF vertical counter
	// =====================================================================
	logic [14:0] ap;
	logic        pfb_n, pfhsld_n, mohs_n, pfspc_n, virq_n, pfvs_n;
	logic  [1:0] apix;
	logic        apal4, apal3;
	logic  [8:0] mo_xscroll_n;
	logic        match, matchd;

	vind_alpha u_alpha (
		.clk(clk), .ce_7m(ce_7m), .reset(reset), .sysres(sysres),
		.h(h), .v(v), .hblank(syn_hblank), .vblank_n(vblank_n),
		.pfhst(pfhst), .mo_pf(mo_pf),
		.board_4h(board_4h), .h4d3(h4d3), .h03(h03),
		.vrd(vrd), .char_addr(char_addr), .char_data(char_data),
		.match(match), .matchd(matchd), .ap(ap),
		.pfb_n(pfb_n), .pfhsld_n(pfhsld_n), .mohs_n(mohs_n), .pfspc_n(pfspc_n),
		.virq_n(virq_n), .pfvs_n(pfvs_n),
		.vack_n(vack_n), .vint_n(vint_n),
		.apix(apix), .apal4(apal4), .apal3(apal3),
		.pf_v(pf_v), .mo_xscroll_n(mo_xscroll_n));

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_alpha = |{virq_n, pfvs_n, ap[14:9]};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  Playfield (sheets 7, 8 and 9)
	// =====================================================================
	logic [7:0] pfx;
	logic       pf_m, pfhf;
	logic [3:0] psd;
	logic        pf_req_pulse, mo_req_pulse;
	logic [17:0] pf_addr_comb, mo_addr_comb;

	vind_pf #(.PFX_LITERAL(PFX_LITERAL)) u_pf (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.pfhst_n(pfhst_n), .hphase(h[2:0]), .board_4h(board_4h), .h4d3(h4d3),
		.gld_n(gld_n), .mo_pf(mo_pf),
		.vrd(vrd), .ap(ap[8:0]), .ap_bank(ap[3:0]),
		.pfb_n(pfb_n), .pfhsld_n(pfhsld_n), .pfspc_n(pfspc_n),
		.pf_v(pf_v),
		.gfx_req(pf_req_pulse), .gfx_addr(pf_addr_comb), .gfx_data(pf_gfx_data),
		.pf_h(pf_h), .pfx(pfx), .pf_m(pf_m), .pfhf(pfhf), .psd(psd));

	vind_gfx_hold u_pf_gfx (
		.clk(clk), .reset(reset),
		.req_pulse(pf_req_pulse), .addr_in(pf_addr_comb),
		.req(pf_gfx_req), .addr(pf_gfx_addr), .valid(pf_gfx_valid));

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_pf = |{pfhf, psd};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  Motion objects (sheets 8, 9 and 10)
	// =====================================================================
	logic [7:0] lb;
	logic       ston_n, stoff_n, mpr1, mpr0;
	logic [2:0] mog_data;
	logic [8:0] rd_hpos, mo_hpos;
	logic       rb1, newmo_n, end_n, gpen, bufclr_n;

	vind_mo u_mo (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.hphase({board_4h, h[1], h[0]}), .nxl(nxl), .lmpd_n(mohr_n),
		.gld_n(gld_n), .mo_pf(mo_pf),
		.h4d3(h4d3), .board_4h(board_4h), .vblank_n(vblank_n),
		.vrd(vrd), .pf_v(pf_v), .mo_xscroll_n(mo_xscroll_n), .matchd(matchd),
		.gfx_req(mo_req_pulse), .gfx_addr(mo_addr_comb), .gfx_data(mo_gfx_data),
		.pvas0(pvas0), .pvas1(pvas1), .mc(mc), .link_n(link_n), .match(match),
		.lb(lb), .ston_n(ston_n), .stoff_n(stoff_n),
		.mpr1(mpr1), .mpr0(mpr0), .mog_data(mog_data), .rd_hpos(rd_hpos),
		.hpos(mo_hpos), .rb1(rb1), .newmo_n(newmo_n), .end_n(end_n),
		.gpen(gpen), .bufclr_n(bufclr_n));

	vind_gfx_hold u_mo_gfx (
		.clk(clk), .reset(reset),
		.req_pulse(mo_req_pulse), .addr_in(mo_addr_comb),
		.req(mo_gfx_req), .addr(mo_gfx_addr), .valid(mo_gfx_valid));

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_mo = |{rd_hpos, mo_hpos, rb1, newmo_n, end_n, gpen, mohs_n,
	                   bufclr_n};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  Priority, GPC and the colour-RAM address (sheet 10)
	// =====================================================================
	logic [10:0] cram_a;
	logic  [2:0] mog;
	logic        shade, pfwin, stain, clrdl_n, h4df_n;

	vind_prio_gpc #(.ALPHA_D_MAME(ALPHA_D_MAME)) u_prio (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.hphase(h[2:0]), .board_4h(board_4h), .h03(h03), .vblank_n(vblank_n),
		.vrd(vrd),
		.apix(apix), .apal4(apal4), .apal3(apal3),
		.pfx(pfx), .pf_m(pf_m),
		.lb(lb), .ston_n(ston_n), .stoff_n(stoff_n),
		.mpr1(mpr1), .mpr0(mpr0), .mog_data(mog_data),
		.clram_n(clram_n), .pram_n(pram_n), .ma(ma[11:1]),
		.cram_a(cram_a), .mog(mog), .shade(shade), .pfwin(pfwin),
		.stain(stain), .clrdl_n(clrdl_n), .h4df_n(h4df_n));

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_prio = |{pfwin, h4df_n};
	/* verilator lint_on UNUSEDSIGNAL */

	assign cram_a_out = cram_a;
	assign layer_out  = {stain, cram_a[9], cram_a[8], shade};

	// =====================================================================
	//  Colour RAM (sheet 10)
	// =====================================================================
	logic [3:0] cint, cred, cgrn, cblu;
	logic [15:0] cpu_cram_din;

	vind_cram u_cram (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.cram_a(cram_a), .clram_n(clram_n), .pram_n(pram_n), .vw_r(vw_r),
		.vuwe_n(vuwe_n), .vlwe_n(vlwe_n), .cpu_dout(cpu_dout),
		.cpu_cram_din(cpu_cram_din),
		.cint(cint), .cred(cred), .cgrn(cgrn), .cblu(cblu));

	// The CPU reads whichever of the two arrays /CLRAM selected -- but the
	// SELECT here must be the STABLE one.  /CLRAM (`vcpu ? ma[16] : 1`) is only
	// low during the CPU's one RCLKA slot, while the 68010's bus cycle outlives
	// it and both arrays present their word through their LS373 one ce_7m later,
	// with /CLRAM already back high.  /CLRAM is decoded from MA16 alone
	// (sheet 6) and MA16 holds for the whole cycle, so it is what the mux takes.
	// (A continuous assignment, not a bit-select inside the always_comb: Icarus
	// 12 answers a constant select in an always_* process with "sorry ... all
	// bits will be included" and gives up on the block.)
	wire cpu_reads_vram = ma[16];
	always_comb begin
		if (!vramrd_n) cpu_din = cpu_reads_vram ? cpu_vram_din : cpu_cram_din;
		else           cpu_din = 16'hFFFF;
	end

	// =====================================================================
	//  Intensity adder, output registers and the sheet-11 ladder
	// =====================================================================
	// 9F LS11 (3,4,5 -> 6) + 17F LS04 (13 -> 12): VIDCLK is suppressed on a CPU
	// colour-RAM cycle and on the one after it.
	wire vidclk_en = clram_n & clrdl_n;

	/* verilator lint_off UNUSEDSIGNAL */
	wire [3:0] iout_dbg;
	/* verilator lint_on UNUSEDSIGNAL */

	// /VIDBL, delayed with every other raster marker -- see the generate block
	// at the bottom of this file for why it must be.
	logic vidbl_n_dly;

	vind_intensity_dac #(.DAC_MAME_COMPAT(DAC_MAME_COMPAT)) u_dac (
		.clk(clk), .ce_7m(ce_7m), .reset(reset),
		.cint(cint), .cred(cred), .cgrn(cgrn), .cblu(cblu), .mog(mog),
		.vidbl_n(vidbl_n_dly), .vidclk_en(vidclk_en),
		.iout(iout_dbg), .red(red), .green(green), .blue(blue));

	// =====================================================================
	//  Raster markers, delayed by PIPE_DLY together with the picture
	// =====================================================================
	// EVERY SYNGEN-derived marker gets the same delay, and that includes
	// /VIDBL.  The DAC's blanking is not a decoration: on sheet 10 /VIDBL
	// ASYNCHRONOUSLY CLEARS the 17M/17L output registers, i.e. it acts on the
	// pixel that is in those registers at that instant.  On the board that pixel
	// is already PIPE_DLY counts behind the SYNGEN count, because the path from
	// the VRAM slot to the output register is a chain of transparent latches and
	// asynchronous RAM that this core has to model with edge-triggered
	// registers.  Leaving /VIDBL undelayed therefore blanks the LAST PIPE_DLY
	// VISIBLE COLUMNS of every line -- columns 334 and 335 come out black where
	// the playfield should be.  Delayed, the picture is pixel-exact against MAME
	// frame captures.

	generate
	if (PIPE_DLY == 0) begin : g_nodly
		assign hblank      = syn_hblank;
		assign vblank      = ~vblank_n;
		assign hsync       = ~hsync_n;
		assign vsync       = ~vsync_n;
		assign vidbl_n_dly = vidbl_n;
	end else begin : g_dly
		logic [4:0] r_sr [PIPE_DLY];
		always_ff @(posedge clk) begin
			if (reset) begin
				for (int i = 0; i < PIPE_DLY; i++) r_sr[i] <= 5'b00111;
			end else if (ce_7m) begin
				r_sr[0] <= {syn_hblank, ~vblank_n, hsync_n, vsync_n, vidbl_n};
				for (int i = 1; i < PIPE_DLY; i++) r_sr[i] <= r_sr[i-1];
			end
		end
		assign hblank      = r_sr[PIPE_DLY-1][4];
		assign vblank      = r_sr[PIPE_DLY-1][3];
		assign hsync       = ~r_sr[PIPE_DLY-1][2];
		assign vsync       = ~r_sr[PIPE_DLY-1][1];
		assign vidbl_n_dly = r_sr[PIPE_DLY-1][0];
	end
	endgenerate

	assign ce_pix   = ce_7m;
	assign hpos_out = h - 9'd9 - 9'(PIPE_DLY);

endmodule
