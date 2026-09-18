`timescale 1ns/1ps
//============================================================================
//  Vindicators — SP-317 sheet 10: the PAL16L8A at 17D (136059-1151, MO-pen-1 /
//  SHADE / PF-M priority), the seven 13F/15F LS32 OR gates, the GPC custom
//  15J/K (Atari 137419-101), the 13J LS253C alpha/MO substitution, the 12F
//  LS174D one-pixel pipeline, the 19M/N STAIN latch and the 11-bit colour-RAM
//  address formation.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later.
//  The GPC's internals are derived from
//  `Arcade-Gauntlet_MiSTer/rtl/gauntlet/GPC.vhd`
//  (c) 2020 d18c7db, GPL-3.0 -- the SAME Atari custom (137419-101), whose
//  internals SP-317 draws as a black box.  Every wire around it is
//  Vindicators' own and cited to sheet 10.
//
//  ---------------------------------------------------------------------------
//  1. 17D = 136059-1151 -- a dumped PAL, implemented VERBATIM
//  ---------------------------------------------------------------------------
//      /o12 = /LB0 & LB1 & LB2 & LB3
//      /o18 = PF/M & [ PFX6 & PFX5 & /PFX3
//                    + MPR1 & PFX6 & /PFX3
//                    + MPR0 & PFX6 & /PFX3
//                    + MPR1 & PFX5 & /PFX3
//                    + MPR0 & MPR1 & /PFX6 & /PFX5 & /PFX3 ]
//      /o19 = LB0 + /LB1 + /LB2 + /LB3 + (LB4 & LB5 & LB6 & LB7) + /o18
//
//  A 16L8 pin is LOW when its sum-of-products is true, so as pin LEVELS:
//      pin12 (-> GPC M7) = ~(MO pen == 1)
//      PFWIN             = ~pin18 = PF/M & G
//      SHADE (pin19)     = (MO pen == 1) & (MO colour != 0) & ~PFWIN
//  The `MO pen == 1` test being `/LB0 & LB1 & LB2 & LB3` is what proves the
//  line-buffer data is carried ACTIVE LOW.  PFX2 (pin 17) is wired but appears
//  in no product term.  MPR1:MPR0 = MAT5:MAT4, also active low.
//
//  `PF/M` on pin 13 is the NET from sheet 7's PFHS custom (the per-playfield-
//  colour "playfield in front of the MO" bit selected out of the /PFSPC
//  register by PFX[2:0]); `PF/M` on GPC pin 18 is a PIN NAME inside the
//  custom's box.  There is no feedback loop.
//
//  ---------------------------------------------------------------------------
//  2. 13F / 15F -- the MO bus into the GPC (sheet 10)
//  ---------------------------------------------------------------------------
//      M7 = 17D pin 12                 M6..M0 = PFWIN + 14D DO6..DO0
//  With active-low MO data, PFWIN = 1 forces M6:M0 to all-ones = "pen 0,
//  colour 0" = transparent, so the GPC falls through to the playfield.
//
//  ---------------------------------------------------------------------------
//  3. THE GPC (sheet 10, internals from the Gauntlet model)
//  ---------------------------------------------------------------------------
//      3H latch (H03 & /4H)  : D3..D0 = VRD15, VRD10, VRD11, VRD12
//      3F latch              : 3F2 = D3 (alpha OPAQUE), ALC2..ALC0 = D2..D0
//      8C6   = ~(P7 | P6 | P5 | P4 | P3)
//      1C12  = ~(M3 & M2 & M1)
//      gate  = ~(3F2 | AL1 | AL0)               "the alpha pixel is transparent"
//      CRAS1 = gate & ( (8C6 & PF/M) | /M7 | (M0 & /1C12) )
//      CRAS0 = gate & ~( (8C6 & PF/M) | ((/M7 | M0) & /1C12) )
//      CRAS  9D output
//       00   {000, ALC2..ALC0, AL1, AL0}      alphanumerics
//       01   {0, ~M6..~M0}                     motion objects
//       10   P7..P0                            playfield
//       11   {P3..P0, ~M3..~M0}                UNREACHABLE on Vindicators
//
//  CRAS = 11 cannot occur here, and not merely for want of data to provoke it.
//  CRAS0 needs both `8C6 & PF/M` and `(/M7 + M0) & /1C12` false, while CRAS1
//  needs one of `8C6 & PF/M`, `/M7` or `M0 & /1C12` true.  `/M7` means the MO
//  pen IS 1, which makes M3 & M2 & M1 -- and so `/1C12` -- true as well, so
//  each of CRAS1's three terms forces one of CRAS0's two.
//
//  THIS CLOSES THE SHEET-7 OPEN ITEM.  Sheet 7 leaves the latched VRD15 as a
//  bare stub and never latches VRD12 at all, and asks where APAL2..APAL0 come
//  from.  They come from INSIDE the GPC: it has its own latch on the raw VRD
//  bus and produces the alpha attribute bits D12, D11, D10 as ALC0..ALC2 and
//  the opaque flag from D15.  APAL4 = D14 and APAL3 = D13 arrive separately
//  from 13M on sheet 7 and are substituted onto CRA8/CRA6 by 13J.
//
//  ---------------------------------------------------------------------------
//  4. THE COLOUR-RAM ADDRESS (sheet 10)
//  ---------------------------------------------------------------------------
//      A7..A0 = CRA8..CRA1, with
//         CRA1..CRA5 = GPC CA0..CA4     CRA7 = GPC CA6
//         CRA6 = 13J lower mux          CRA8 = 13J upper mux
//      13J (SB:SA = CA9:CA8, /G = /PRAM):
//         00 alpha : upper = APAL4, lower = APAL3
//         01 MO    : upper = /MPX7 delayed (= MO colour bit 3), lower = CL6
//         1x PF    : upper = CL8 (= CA7),                       lower = CL6
//      A8  = CA8 + (SHADE_delayed & CA9)     -- 18L LS08 + 13F LS32
//      A9  = CA9
//      A10 = STAIN                            -- 19M/N LS74 through 12F Q7
//      CPU (via 14K LS257B and 19K LS244N): A10 = MA11, A9 = MA10 (the GPC's
//      MA1/MA0 pins are BOTH tied to MA10), A8 = MA9, A7..A0 = MA8..MA1.
//
//  The resulting video addresses are
//      alpha  0x000 | D14<<7 | D13<<5 | D12<<4 | D11<<3 | D10<<2 | pen
//             (that is the ALPHA_D_MAME = 1 order, the default, and it is
//              IDENTICAL to MAME's; ALPHA_D_MAME = 0 reverses the D12/D10 run
//              to the literal sheet-10 pin order)
//      MO     0x100 | colour<<4 | pen
//      PF     0x200 | PFX[7:5]<<5 | pen        (PFX[4] grounded at the GPC)
//      + 0x100 when SHADE fires on a playfield pixel, + 0x400 while STAIN.
//  All three rows agree with MAME exactly once ALPHA_D_MAME is set -- which is
//  the default, and which is verified pixel-exact against MAME frame captures.
//  See the ALPHA_D_MAME parameter below.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_prio_gpc #(
	// Sheet 10 records the GPC's alpha attribute pins as
	//   D3 = VRD15, D2 = VRD10, D1 = VRD11, D0 = VRD12
	// -- a scrambled order (Xybots' GPC is scrambled too, differently).  Taken
	// literally the alpha colour address puts D10 in bit 4 and D12 in bit 2,
	// while MAME's `color = ((data >> 10) & 0x0f) | ((data >> 9) & 0x20)` puts
	// D12 in bit 4 and D10 in bit 2.  ALPHA_D_MAME = 1 selects the descending
	// order D3..D0 = VRD15, VRD12, VRD11, VRD10 that reproduces MAME.
	parameter bit ALPHA_D_MAME = 1'b1
)(
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	// ---- sheet-6 taps ----
	input  logic  [2:0] hphase,       // {4H, 2H, 1H} = h[2:0]
	input  logic        board_4h,
	input  logic        h03,
	input  logic        vblank_n,
	input  logic [15:0] vrd,

	// ---- layers ----
	input  logic  [1:0] apix,        // APIX1, APIX0
	input  logic        apal4,       // 13M Q5 = alpha D14
	input  logic        apal3,       // 13M Q7 = alpha D13
	input  logic  [7:0] pfx,         // PFX7..PFX0
	input  logic        pf_m,        // PFHS pin 37 -> 17D pin 13
	input  logic  [7:0] lb,          // 14D DO7..DO0, ACTIVE LOW
	input  logic        ston_n,
	input  logic        stoff_n,
	input  logic        mpr1,        // 18D Q6 = MAT5, ACTIVE LOW
	input  logic        mpr0,        // 18D Q9 = MAT4, ACTIVE LOW
	input  logic  [2:0] mog_data,    // 14E DO3..DO1

	// ---- CPU / colour-RAM select (sheet 6) ----
	input  logic        clram_n,
	input  logic        pram_n,
	input  logic [11:1] ma,

	// ---- outputs ----
	output logic [10:0] cram_a,      // CRAM A10..A0  (continuous, see below)
	output logic  [2:0] mog,         // MOG3..MOG1 into the 18M LS283
	output logic        shade,       // 17D pin 19, undelayed
	output logic        pfwin,       // ~17D pin 18
	output logic        stain,
	output logic        clrdl_n,     // 12F Q5
	output logic        h4df_n       // 12F Q15
);

	// =====================================================================
	// 1. 17D
	// =====================================================================
	wire mo_pen1 = ~lb[0] & lb[1] & lb[2] & lb[3];        // /o12
	wire mo_col0 =  lb[4] & lb[5] & lb[6] & lb[7];        // "MO colour == 0"

	wire g =  ( pfx[6] &  pfx[5] & ~pfx[3])
	        | ( mpr1   &  pfx[6] & ~pfx[3])
	        | ( mpr0   &  pfx[6] & ~pfx[3])
	        | ( mpr1   &  pfx[5] & ~pfx[3])
	        | ( mpr0   &  mpr1   & ~pfx[6] & ~pfx[5] & ~pfx[3]);

	assign pfwin = pf_m & g;                              // ~pin18
	assign shade = mo_pen1 & ~mo_col0 & ~pfwin;           // pin 19
	wire   m7    = ~mo_pen1;                              // pin 12

	// =====================================================================
	// 2. 13F / 15F -- seven OR gates onto the MO bus
	// =====================================================================
	wire [7:0] m_bus = {m7, lb[6:0] | {7{pfwin}}};

	// =====================================================================
	// 3. GPC 15J/K
	// =====================================================================
	// 3H: latch the raw VRD attribute nibble at the alpha slot (H03 & /4H).
	wire [3:0] gpc_d = ALPHA_D_MAME ? {vrd[15], vrd[12], vrd[11], vrd[10]}
	                                : {vrd[15], vrd[10], vrd[11], vrd[12]};

	// The GPC's own 3H latch takes the raw alpha attribute nibble off VRD on the
	// same edge as sheet 7's 14M/14L: the ce_7m edge that ENDS the alpha slot
	// (phase 3), which is 4H's rising edge.  See vind_alpha.sv.
	wire alpha_latch = ce_7m & (hphase == 3'd3);

	logic [3:0] l3h;
	logic       aopaque;
	logic [2:0] alc;
	always_ff @(posedge clk) begin
		if (reset) begin l3h <= 4'd0; aopaque <= 1'b0; alc <= 3'd0; end
		else begin
			if (alpha_latch) l3h <= gpc_d;
			if (ce_7m && h03) begin                        // 3F latch
				aopaque <= l3h[3];
				alc     <= l3h[2:0];
			end
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// only VRD15, VRD12..VRD10 reach the GPC's D pins (sheet 10).
	wire unused_vrd = &{1'b0, vrd[14:13], vrd[9:0]};
	/* verilator lint_on UNUSEDSIGNAL */

	wire g8c6  = ~(pfx[7] | pfx[6] | pfx[5] | pfx[4] | pfx[3]);
	wire g1c12 = ~(m_bus[3] & m_bus[2] & m_bus[1]);
	wire gate  = ~(aopaque | apix[1] | apix[0]);

	wire cras1 = gate &  ( (g8c6 & pfwin) | ~m_bus[7] | (m_bus[0] & ~g1c12) );
	wire cras0 = gate & ~( (g8c6 & pfwin) | ((~m_bus[7] | m_bus[0]) & ~g1c12) );

	wire [7:0] gpc9d = (!cras1 && !cras0) ? {3'b000, alc, apix}      // alpha
	                 : (!cras1 &&  cras0) ? {1'b0, ~m_bus[6:0]}      // MO
	                 : ( cras1 && !cras0) ? pfx                      // playfield
	                 :                      {pfx[3:0], ~m_bus[3:0]}; // unreachable

	// 9D + 1B/5B: the GPC's output register (falling MCKR), gated by SEL.
	logic [7:0] ca_lo;
	logic [1:0] cras_q;
	always_ff @(posedge clk) begin
		if (reset) begin ca_lo <= 8'd0; cras_q <= 2'd0; end
		else if (ce_7m && clram_n) begin      // SEL = /CLRAM; frozen in a CPU cycle
			ca_lo  <= gpc9d;
			cras_q <= {cras1, cras0};
		end
	end

	// =====================================================================
	// 4. 12F LS174D -- the one-pixel pipeline (CK = FCLOCK)
	// =====================================================================
	logic stoff_n_d, shade_d, mpx7_n_d;
	logic stain_q;
	always_ff @(posedge clk) begin
		if (reset) begin
			stoff_n_d <= 1'b1; shade_d <= 1'b0; mpx7_n_d <= 1'b1;
			clrdl_n <= 1'b1; h4df_n <= 1'b1;
		end else if (ce_7m) begin
			stoff_n_d <= stoff_n;
			shade_d   <= shade;
			mpx7_n_d  <= ~lb[7];              // 6D LS04: /MPX7
			clrdl_n   <= clram_n;
			h4df_n    <= ~board_4h;
		end
	end

	// 19M/N LS74: /PRE = /STON, D = GND, CK = /VBLANK, /CLR = 12F Q12.
	logic vblank_n_d;
	always_ff @(posedge clk) begin
		if (reset) begin stain_q <= 1'b0; vblank_n_d <= 1'b1; end
		else begin
			if (ce_7m) vblank_n_d <= vblank_n;
			if      (!ston_n)                        stain_q <= 1'b1;   // /PRE
			else if (!stoff_n_d)                     stain_q <= 1'b0;   // /CLR
			else if (ce_7m && vblank_n && !vblank_n_d) stain_q <= 1'b0; // CK, D=0
		end
	end
	// 12F Q7 is the pipelined STAIN that reaches CRAM A10.
	always_ff @(posedge clk) begin
		if (reset)          stain <= 1'b0;
		else if (ce_7m)     stain <= stain_q;
	end

	// =====================================================================
	// 5. 13J LS253C and the 11-bit CRAM address
	// =====================================================================
	wire       ca8 = cras_q[0];
	wire       ca9 = cras_q[1];
	wire       cl8 = ca_lo[7];
	wire       cl6 = ca_lo[5];

	// 13J's two /G pins are tied together to /PRAM, and a '253 is ENABLED while
	// /G is LOW.  /PRAM = ~/CLRAM, so /PRAM is low (13J driving) in every video
	// slot and high (13J tri-stated) in a CPU colour-RAM cycle -- where 19K
	// LS244N drives CRA8..CRA1 from MA8..MA1 instead.  That CPU case is the
	// `!clram_n` branch of `cram_a` below, so nothing here has to model the
	// float; `pram_n` is listed as an input only to make the dependency explicit.
	wire cra8 = (cras_q == 2'b00) ? apal4                // alpha
	          : (cras_q == 2'b01) ? mpx7_n_d             // motion objects
	          :                     cl8;                 // playfield
	wire cra6 = (cras_q == 2'b00) ? apal3 : cl6;

	wire [7:0] cra_video = {cra8, ca_lo[6], cra6, ca_lo[4:0]};
	wire       a8_video  = ca8 | (shade_d & ca9);

	assign cram_a = clram_n ? {stain, ca9, a8_video, cra_video}
	                        : {ma[11], ma[10], ma[9], ma[8:1]};   // 19K + 14K

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_pram = &{1'b0, pram_n, board_4h};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	// 6. 18F LS173 -- MOG3..MOG1, tri-stated (pulled to 1) unless CA9 = 1
	// =====================================================================
	// /CA10 = ~CA9 (17F LS04) is both output enables, so the register only
	// drives while the playfield/shadow bank is selected.
	logic [2:0] mog_q;
	always_ff @(posedge clk) begin
		if (reset)      mog_q <= 3'b111;
		else if (ce_7m) mog_q <= mog_data;         // CLK = VIDCLK
	end
	assign mog = ca9 ? mog_q : 3'b111;             // R88/R89/R90 pull-ups

endmodule
