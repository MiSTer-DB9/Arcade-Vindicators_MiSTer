`timescale 1ns/1ps
//============================================================================
//  Vindicators — SP-317 sheet 7 (`ALPHA`): the AP pipeline latch, the alpha
//  control-word decoder, the VIRQ latch, the character ROM and its shifters,
//  the playfield vertical counter and the motion-object X-scroll latch.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.
//
//  ---------------------------------------------------------------------------
//  1. THE AP LATCH
//  ---------------------------------------------------------------------------
//      14M LS273K (CK = 4H) : MATCH->MATCHD, VRD14->AP14, VRD13->AP13,
//                             VRD11..VRD8 -> AP11..AP8, VRD15 -> BARE STUB
//      14L LS273A (CK = 4H) : VRD7..VRD0  -> AP7..AP0
//  VRD12 is latched NOWHERE on sheet 7 and there is no AP12 net.  That is not a
//  missing bit: the alpha attribute bits D15, D12, D11 and D10 are latched
//  INSIDE the GPC custom (15J/K pins 22..25, sheet 10) straight off the raw
//  VRD bus, and D14/D13 come back as APAL4/APAL3 from 13M here.  That is also
//  where APAL2..APAL0 come from; see vind_prio_gpc.sv.
//
//  ---------------------------------------------------------------------------
//  2. THE CONTROL WORDS
//  ---------------------------------------------------------------------------
//      11M LS138 : G1 = 256H, /G2A = /HBLANK, /G2B = ~(MO//PF & 1V & 2V & 4V)
//                  SELC:SELB:SELA = AP11:AP10:AP9
//      Y2 /PFB    playfield bank latch (AP3..AP0 -> GA15..GA12)
//      Y3 /PFHSLD PFHS HS   -- playfield X scroll, AP8..AP0
//      Y4 /MOHS   MO X-scroll latch (19M/N + 10L + 10M)
//      Y5 /PFSPC  PFHS SPC  -- the per-colour PF/M priority register
//      Y6 /VIRQ   18E LS74 CK -> /VINT
//      Y7 -> 13M D14 -> /PFVS  -- synchronous load of the PF vertical counter
//      Y0, Y1     bare stubs (MAME's `default:` no-op is right)
//  The enable needs V[2:0] == 7 -- the LAST line of each eight-line band -- so
//  the words in alpha row r execute in the HBLANK at the end of scanline 8r+7
//  and take effect from 8r+8.  MAME's `configure_scanline(..., 0, 8)` with
//  `offset = ((scanline - 8) / 8) * 64 + 42` is the same thing said one line
//  later.  The column window is set by where HBLANK falls with 256H high, NOT
//  by the constant 42.
//
//  ---------------------------------------------------------------------------
//  3. THE CHARACTER ROM AND SHIFTERS
//  ---------------------------------------------------------------------------
//  15/16N is a 16 Kx8 EPROM with CE and OE tied to GND -- free-running, no
//  per-slot enable.  A13..A4 = AP9..AP0 (the 1024-character code), A3..A1 =
//  4V,2V,1V (the pixel row) and A0 = /4H (which half of the row).  One byte is
//  four pixels of two bit planes; 19N/18N LS194A parallel-load on H03 and shift
//  right for the other three FCLOCKs, so QD emits O7,O6,O5,O4 (APIX1, the pen
//  MSB) and O3,O2,O1,O0 (APIX0).  That is exactly MAME's `anlayout`
//  (planeoffset {0,4}, xoffset {0,1,2,3,8,9,10,11}) with planeoffset[0] the
//  pen MSB.
//
//  ---------------------------------------------------------------------------
//  4. THE PLAYFIELD VERTICAL COUNTER
//  ---------------------------------------------------------------------------
//  19K/11L/13L LS163A, CK = 4H, /LD = /PFVS (AP8..AP0), ENT = PFHST (one pulse
//  per line), ENP = /VBLANK (FROZEN during vertical blanking), /CLR = PR2.
//  Its outputs are the playfield tilemap row, the SLIP band index (PFV >> 3)
//  and the MO vertical-match operand -- so the motion objects share the
//  playfield's vertical scroll, exactly as MAME's `set_yscroll()` does.
//
//  ---------------------------------------------------------------------------
//  5. THE MO X-SCROLL LATCH
//  ---------------------------------------------------------------------------
//  19M/N LS74 + 10L/10M LS175, CK = /MOHS, /CLR = /SYSRES, taking the /Q
//  outputs, so `/PF256L../PF1L` is the ONE'S COMPLEMENT of the 9-bit MO X
//  scroll -- which is what sheet 8's LS283 chain wants (subtract by add of
//  complement).  Reset leaves scroll = 0.  Despite the `PF` prefix these are
//  the MOTION-OBJECT scroll bits.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_alpha (
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,        // /SYSRES asserted
	input  logic        sysres,       // sheet 4 22M/N LS197, active high here

	// ---- SYNGEN / sheet-6 taps ----
	input  logic  [8:0] h,
	input  logic  [7:0] v,
	input  logic        hblank,       // active high (SYNGEN pin 26 inverted)
	input  logic        vblank_n,
	input  logic        pfhst,        // SYNGEN pin 28 inverted (once per line)
	input  logic        mo_pf,        // MO//PF  (23F S04 from SYNGEN pin 35)
	input  logic        board_4h,     // 11F /Q1
	input  logic        h4d3,         // 11F /Q2 -- also the 13M/12F clock phase
	input  logic        h03,          // 6F Q2 -- the LS194A parallel-load window

	// ---- VRAM ----
	input  logic [15:0] vrd,

	// ---- character ROM (served from rtl/mem) ----
	output logic [13:0] char_addr,
	input  logic  [7:0] char_data,

	// ---- sheet-8 feedback ----
	input  logic        match,        // 21E LS08 on sheet 8
	output logic        matchd,       // 14M LS273K Q12

	// ---- the AP bus ----
	output logic [14:0] ap,           // AP14, AP13, (no AP12), AP11..AP0

	// ---- control-word strobes (all active low) ----
	output logic        pfb_n,
	output logic        pfhsld_n,
	output logic        mohs_n,
	output logic        pfspc_n,
	output logic        virq_n,
	output logic        pfvs_n,       // 13M Q15 (registered)

	// ---- VIRQ latch ----
	input  logic        vack_n,       // sheet 3, write 0x360000
	output logic        vint_n,       // 18E LS74 /Q -> sheet 4's IPL network

	// ---- alpha pixel and the two attribute bits this sheet produces ----
	output logic  [1:0] apix,         // {APIX1, APIX0}
	output logic        apal4,        // 13M Q5  = AP14 = alpha word D14
	output logic        apal3,        // 13M Q7  = AP13 = alpha word D13

	// ---- playfield vertical counter ----
	output logic  [8:0] pf_v,         // PF256V..PF1V

	// ---- motion-object X scroll, ONE'S COMPLEMENT (see header) ----
	output logic  [8:0] mo_xscroll_n  // /PF256L../PF1L
);

	// =====================================================================
	// 1. 14M / 14L -- the AP latch, CK = 4H
	// =====================================================================
	// 4H is h[2] (see vind_vram.sv's 11F chain), so its RISING edge is the
	// ce_7m edge that ends the pixel with h[2:0] == 3 -- the pixel in which the
	// alpha VRAM slot (VAS = 10, phase 3) presents its word.  On the board the
	// VRAM is asynchronous, so VRD still carries that word at the edge and the
	// 14M/14L '273s take it.  Detecting the edge one pixel LATER (`board_4h &
	// ~board_4h_d`) would latch the NEXT slot's word instead, which is the
	// motion-object word -- and the control-word decoder would never see an
	// opcode.  Every latch in the video block is phased this way.
	wire ap_clk = ce_7m & (h[2:0] == 3'd3);            // rising edge of 4H

	always_ff @(posedge clk) begin
		if (reset) begin
			ap     <= 15'd0;
			matchd <= 1'b0;
		end else if (ap_clk) begin
			// ap[14] = AP14, ap[13] = AP13, ap[11:0] = AP11..AP0.
			// ap[12] has NO board net (VRD12 is latched nowhere on sheet 7) and
			// is held at 0 so nothing can accidentally consume it.
			ap     <= {vrd[14], vrd[13], 1'b0, vrd[11:0]};
			matchd <= match;
		end
	end

	// =====================================================================
	// 2. 11M LS138 -- the control-word decoder
	// =====================================================================
	wire cw_en = h[8] & hblank & mo_pf & (v[2:0] == 3'b111);
	wire [2:0] cw_op = ap[11:9];

	logic [7:0] y;
	always_comb begin
		y = 8'hFF;
		if (cw_en) y[cw_op] = 1'b0;
	end

	assign pfb_n    = y[2];
	assign pfhsld_n = y[3];
	assign mohs_n   = y[4];
	assign pfspc_n  = y[5];
	assign virq_n   = y[6];
	wire   pfvs_raw = y[7];

	// =====================================================================
	// 3. 13M LS174A -- CK = /4HDF [inferred]
	// =====================================================================
	// WHICH NET IS `/4HDF`?  Sheet 7 gives 13M's clock as `/4HDF`, a name that
	// appears nowhere else in SP-317; the obvious reading is a drawing typo for
	// `/4HDD` (SYNGEN pin 36).  The timing settles it, and against that reading:
	// the 11M LS138 is enabled by `256H & /HBLANK & MO//PF & (V[2:0] == 7)`, and
	// MO//PF (= 4HDL inverted) is high over phases 5, 6, 7 and 0 -- so Y7's pulse
	// ENDS at the ce_7m edge that ends phase 0.  A '174 clocked by /4HDD would
	// sample at the end of phase 1, one pixel after the pulse is over, and the
	// /PFVS load would never happen at all.  The net whose RISING edge lands
	// exactly on the end of the window is PF//MO itself (SYNGEN pin 35, the
	// complement of MO//PF), so `/4HDF` is read here as that edge: 13M registers
	// the LS138's Y7 at the trailing edge of its own enable window.  [inferred]
	wire c13m = ce_7m & (h[2:0] == 3'd0);

	always_ff @(posedge clk) begin
		if (reset) begin
			pfvs_n <= 1'b1;
			apal4  <= 1'b0;
			apal3  <= 1'b0;
		end else if (c13m) begin
			pfvs_n <= pfvs_raw;
			apal4  <= ap[14];
			apal3  <= ap[13];
		end
	end

	// =====================================================================
	// 4. 18E LS74 -- the VIRQ latch
	// =====================================================================
	// D = PR4 = 1, CK = /VIRQ (the RISING edge = end of the LS138 pulse),
	// /CLR = /VACK.  Q is a bare stub; /Q is /VINT.  This is a plain totem-pole
	// output, NOT open collector, so /VINT drives the IPL network directly.
	logic virq_n_d, virq_q;
	always_ff @(posedge clk) begin
		if (reset) begin
			virq_n_d <= 1'b1;
			virq_q   <= 1'b0;
		end else begin
			if (ce_7m) virq_n_d <= virq_n;
			if (!vack_n)                          virq_q <= 1'b0;
			else if (ce_7m && virq_n && !virq_n_d) virq_q <= 1'b1;
		end
	end
	assign vint_n = ~virq_q;

	// =====================================================================
	// 5. Character ROM and the 19N / 18N LS194A shifters
	// =====================================================================
	assign char_addr = {ap[9:0], v[2:0], ~board_4h};

	logic [3:0] sr1, sr0;
	always_ff @(posedge clk) begin
		if (reset) begin
			sr1 <= 4'd0; sr0 <= 4'd0;
		end else if (ce_7m) begin
			if (h03) begin
				// S1:S0 = 1:1 -> parallel load.  D,C,B,A = O7,O6,O5,O4 for 19N
				// and O3,O2,O1,O0 for 18N; QD then emits them in that order.
				sr1 <= char_data[7:4];
				sr0 <= char_data[3:0];
			end else begin
				// S1:S0 = 0:1 -> shift right, SR = GND
				sr1 <= {sr1[2:0], 1'b0};
				sr0 <= {sr0[2:0], 1'b0};
			end
		end
	end
	assign apix = {sr1[3], sr0[3]};

	/* verilator lint_off UNUSEDSIGNAL */
	// h[7:0]: only 256H reaches 11M's G1.  v[7:3]: the alpha ROW index is
	// formed on sheet 6, not here.  vrd[15]/vrd[12]: latched inside the GPC
	// (sheet 10), never on this sheet.  y[1:0]: LS138 Y0/Y1 are bare stubs.
	wire unused = &{1'b0, h[7:3], v[7:3], vrd[15], vrd[12], y[1:0], h4d3};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	// 6. 19K / 11L / 13L LS163A -- the playfield vertical counter
	// =====================================================================
	always_ff @(posedge clk) begin
		if (reset)          pf_v <= 9'd0;   // /CLR = PR2: never cleared on the
		                                    // board; this is only a sim seed
		else if (ap_clk) begin              // CK = 4H
			if (!pfvs_n)         pf_v <= ap[8:0];              // /LD, synchronous
			else if (pfhst & vblank_n) pf_v <= pf_v + 9'd1;    // ENT & ENP
		end
	end

	// =====================================================================
	// 7. 19M/N + 10L + 10M -- the MO X-scroll latch
	// =====================================================================
	logic mohs_n_d;
	always_ff @(posedge clk) begin
		if (sysres) begin
			mo_xscroll_n <= 9'h1FF;         // /CLR -> Q = 0 -> /Q = 1 -> scroll 0
			mohs_n_d     <= 1'b1;
		end else if (ce_7m) begin
			mohs_n_d <= mohs_n;
			if (mohs_n && !mohs_n_d) mo_xscroll_n <= ~ap[8:0];
		end
	end

endmodule
