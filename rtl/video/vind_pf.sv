`timescale 1ns/1ps
//============================================================================
//  Vindicators — the playfield layer: the PFHS custom (15L/M, Atari 137419-104,
//  SP-317 sheet 7), the playfield word decode and bank latch (sheet 8), the
//  graphics-ROM fetch and the PF half of the SLAGS shifters (sheet 9).
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  The PFHS and SLAGS behaviour is derived from
//  `Arcade-Gauntlet_MiSTer/rtl/gauntlet/PFHS.vhd` and
//  `SLAGS.vhd` (c) 2020 d18c7db, GPL-3.0 -- the SAME two Atari customs, whose
//  internals SP-317 does not draw.  Every wire around them is Vindicators' own.
//
//  ---------------------------------------------------------------------------
//  1. THE PLAYFIELD WORD  (sheet 8)
//  ---------------------------------------------------------------------------
//      5M LS374A (CK = /4H, /OC = MO//PF) : VRD15..VRD8
//          Q19 = PFHF (= VRD15, the tile's HORIZONTAL FLIP) and -> 5N D13
//          Q16,Q15,Q12 -> 5N (VRD14..VRD12)      Q9..Q2 = GA11..GA8
//      3M LS374B (same clocks)             : VRD7..VRD0 -> GA7..GA0
//      5N LS175B (CK = 4HD3)               : /Q = PSD7..PSD4 = ~VRD15..~VRD12
//      20N LS173  (CLK = /PFB)             : AP3..AP0 -> GA15..GA12
//  The graphics ROM decodes GA14..GA0 (32768 tiles), so GA15 -- control-word
//  bit D3 of /PFB -- is unconnected, which is why MAME's `data & 7` bank is
//  right.  Tile code = {bank[2:0], VRD[11:0]}.
//
//  ---------------------------------------------------------------------------
//  2. PFHS  (sheet 7)
//  ---------------------------------------------------------------------------
//    * a 9-bit latch on HS  (/PFHSLD) -- the playfield X scroll;
//    * a 9-bit latch on SPC (/PFSPC)  -- the "special" register;
//    * a 6-bit counter loaded with scroll[8:3] at every ST (/PFHST, once per
//      line) and incremented on 4H  -> PF8H..PF256H, the tilemap COLUMN that
//      sheet 6's VRAM mux uses;
//    * an 8 x 8 RAM (two 74LS189, INVERTING data outputs) whose 3-bit address
//      counter is reloaded with scroll[2:0] at ST and at every wrap, giving a
//      variable-length delay line: XP = ~PS delayed by the fine scroll.  That
//      is the whole fine-horizontal-scroll mechanism.
//    * PF/M = SPC[ XP[2:0] ] -- an 8:1 mux, i.e. a PER-PLAYFIELD-COLOUR
//      "playfield in front of the motion objects" bit.  MAME treats /PFSPC as a
//      no-op (`case 5: break;`), so this whole input to the priority decision
//      is absent from MAME; the core implements it.
//
//  ---------------------------------------------------------------------------
//  3. PFX AND THE COLOUR ADDRESS  (sheet 10, and the ambiguity it raises)
//  ---------------------------------------------------------------------------
//  PFX7..PFX0 = ~PS7..~PS0 delayed, i.e. {VRD15, VRD14, VRD13, VRD12, pen[3:0]}
//  read literally off sheets 7/8.  Sheet 10 then holds GPC pin 32 (`P4`) at
//  logic 0 through R87 1K / R86 10R, so ONE of the eight PFX bits never
//  reaches the colour address.
//
//  Taken literally that would ground PFX4 = VRD12 = the LOW bit of the
//  playfield colour, and the colour address would become
//  0x200 | VRD15<<7 | VRD14<<6 | VRD13<<5 | pen -- i.e. the tile's FLIP bit
//  would be a palette bit and one colour bit would be lost.  MAME (whose
//  picture is known good) computes 0x200 + 32*((data>>12)&7) + pen, i.e.
//  colour = VRD14:VRD12 in bits 7:5 with bit 4 always zero.
//
//  The two readings differ by exactly one position, and only the MAME one is
//  physically sensible (a flip bit is not a palette bit).  The reading adopted
//  here is that the grounded GPC pin is the one carrying the FLIP bit, so
//
//      PFX[7:5] = VRD[14:12]  (playfield colour)
//      PFX[4]   = 0           (the grounded pin, where PFHF lands)
//      PFX[3:0] = playfield pen
//
//  `PFX_LITERAL = 1` selects the as-drawn alternative for experiments.
//  Note 17D's priority terms use PFX6, PFX5, PFX3 and PFX2, so the choice also
//  moves the priority comparison by one colour bit.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_pf #(
	parameter bit PFX_LITERAL = 1'b0,
	// extra pixels of PFHS delay-line latency (see section 5 below)
	parameter int PFX_ALIGN   = 2,
	// once-per-cell stages in the PS7..PS4 colour path (see section 3 below)
	parameter int PSHI_STAGES = 1
)(
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	// ---- SYNGEN / sheet-6 taps ----
	input  logic        pfhst_n,      // SYNGEN pin 28, once per line
	input  logic  [2:0] hphase,       // {4H, 2H, 1H} = h[2:0]
	input  logic        board_4h,     // 11F /Q1
	input  logic        h4d3,         // 11F /Q2
	input  logic        gld_n,        // 11F /Q4 -- SLAGS load, every four pixels
	input  logic        mo_pf,        // MO//PF  (1 = the MO half of the phase)

	// ---- VRAM + control words ----
	input  logic [15:0] vrd,
	input  logic  [8:0] ap,           // AP8..AP0, the control-word operand
	input  logic  [3:0] ap_bank,      // AP3..AP0 for the /PFB latch
	input  logic        pfb_n,
	input  logic        pfhsld_n,
	input  logic        pfspc_n,

	// ---- playfield vertical counter (vind_alpha) ----
	input  logic  [8:0] pf_v,

	// ---- graphics ROM client (served from rtl/mem) --------------------------
	// One request per eight pixels returns the FOUR bit planes of one 8-pixel
	// tile row as 32 bits, in the bit order `rtl/mem/vind_gfx_mem.sv` fixes:
	//     data[7:0] = plane 0 (pen bit 0), [15:8] = plane 1, [23:16] = plane 2,
	//     [31:24] = plane 3;  within a plane byte bit 7 is the LEFTMOST pixel;
	//     and the bytes are the RAW ROM bytes, i.e. the board's own ACTIVE-LOW
	//     PSD/MSD sense (pen = ~data).  MAME's ROMREGION_INVERT is the same fact
	//     applied at load time; this core keeps the board's polarity so sheets
	//     7/10's PAL equations can be written verbatim.
	output logic        gfx_req,
	output logic [17:0] gfx_addr,     // {code[14:0], row[2:0]}
	input  logic [31:0] gfx_data,

	// ---- outputs ----
	output logic  [5:0] pf_h,         // PF256H..PF8H -> sheet 6's VRAM mux
	output logic  [7:0] pfx,          // PFX7..PFX0   -> 17D and the GPC
	output logic        pf_m,         // PFHS pin 37  -> 17D pin 13
	output logic        pfhf,         // 5M Q19       -> 12L LS257C 4B
	output logic  [3:0] psd           // PSD3..PSD0, the SLAGS playfield pixel
	                                  // bits as the board carries them: ACTIVE
	                                  // LOW (pen = ~psd)
);

	// =====================================================================
	// 1. Edges of 4H and 4HD3
	// =====================================================================
	// 4H is h[2] and 4HD3 is h[2] delayed three pixels (vind_vram.sv's 11F
	// chain), so their edges are the ce_7m edges that END a particular phase.
	// The board's VRAM is asynchronous, so the '374s clocked by /4H take the
	// word of the slot that is STILL on VRD at that edge -- the playfield slot
	// is phase 7, and /4H rises at the edge ending phase 7.  Detecting the edge
	// one pixel later would latch the next slot's word.
	logic pfhst_n_d;
	always_ff @(posedge clk) if (ce_7m) pfhst_n_d <= pfhst_n;
	wire h4_rise    = ce_7m & (hphase == 3'd3);       // CK of 20N/counters
	wire h4_fall    = ce_7m & (hphase == 3'd7);       // CK of 5M/3M (= /4H rise)
	wire h4d3_rise  = ce_7m & (hphase == 3'd6);       // CK of 5N/6N
	wire st         = ~pfhst_n;                       // PFHS ST, active high
	wire st_edge    = ce_7m & ~pfhst_n & pfhst_n_d;

	// =====================================================================
	// 2. 20N LS173 -- the playfield bank latch, CLK = /PFB
	// =====================================================================
	logic [3:0] bank;
	logic       pfb_n_d;
	always_ff @(posedge clk) begin
		if (reset) begin bank <= 4'd0; pfb_n_d <= 1'b1; end
		else if (ce_7m) begin
			pfb_n_d <= pfb_n;
			if (pfb_n && !pfb_n_d) bank <= ap_bank;   // rising edge of /PFB
		end
	end

	// =====================================================================
	// 3. 5M / 3M LS374 and 5N LS175B / 6N LS174
	// =====================================================================
	logic [15:0] pfword;
	always_ff @(posedge clk) begin
		if (reset)        pfword <= 16'd0;
		else if (h4_fall) pfword <= vrd;              // CK = /4H
	end
	assign pfhf = pfword[15];

	// 5N inverts (its /Q outputs are the PSD nets); 6N delays them one 4HD3.
	//
	// PSHI_STAGES is the number of those once-per-cell stages the colour byte
	// passes through before it enters the PFHS delay line.  Sheets 7 and 8 draw
	// two (5N then 6N), but the pen bits reach PFHS straight off the SLAGS, and
	// the two paths only line up if the colour is one stage shorter than the
	// drawing reads; with one stage the playfield is pixel-exact against MAME
	// frame captures.  Either 5N's clock is not the same edge as the 5M/3M word
	// latch (sheet 8 draws it as "[4HD3]", in brackets, i.e. uncertain), or 6N's
	// stage is in the PS0..PS3 path rather than PS4..PS7.
	logic [3:0] pshi [PSHI_STAGES];
	always_ff @(posedge clk) begin
		if (reset) begin
			for (int k = 0; k < PSHI_STAGES; k++) pshi[k] <= 4'hF;
		end else if (h4d3_rise) begin
			pshi[0] <= ~pfword[15:12];
			for (int k = 1; k < PSHI_STAGES; k++) pshi[k] <= pshi[k-1];
		end
	end
	wire [3:0] ps_hi = pshi[PSHI_STAGES-1];    // PS7..PS4

	// =====================================================================
	// 4. Graphics fetch (sheet 9) and the PF half of the SLAGS
	// =====================================================================
	// Tile code = {bank[2:0], VRD[11:0]}; GA15 (bank bit 3) is not decoded by
	// the ROM.  Row = PF4V/PF2V/PF1V through 12L LS257C's B side.
	assign gfx_addr = {bank[2:0], pfword[11:0], pf_v[2:0]};
	assign gfx_req  = h4_fall;

	// /GLD fires every four pixels; the SLAGS latches the PF byte only on the
	// pulse in which MO//PF selects the playfield (SLAGS.vhd `sl_LDPFn`).
	wire ld_pf = ce_7m & ~gld_n & ~mo_pf;

	logic [7:0] pl0, pl1, pl2, pl3;   // the four plane shift registers
	logic       pf_flip;

	always_ff @(posedge clk) begin
		if (reset) begin
			pl0 <= 8'hFF; pl1 <= 8'hFF; pl2 <= 8'hFF; pl3 <= 8'hFF;
			pf_flip <= 1'b0;
		end else if (ce_7m) begin
			if (ld_pf) begin
				pf_flip <= pfhf;                       // latch 8B in SLAGS.vhd
				pl0 <= gfx_data[7:0];
				pl1 <= gfx_data[15:8];
				pl2 <= gfx_data[23:16];
				pl3 <= gfx_data[31:24];
			end else if (pf_flip) begin
				// the shifted-in bit is never tapped (8 shifts between loads);
				// 1 is the idle level of the pulled-up ROM bus.
				pl0 <= {1'b1, pl0[7:1]};               // shift LEFT-end out
				pl1 <= {1'b1, pl1[7:1]};
				pl2 <= {1'b1, pl2[7:1]};
				pl3 <= {1'b1, pl3[7:1]};
			end else begin
				pl0 <= {pl0[6:0], 1'b1};
				pl1 <= {pl1[6:0], 1'b1};
				pl2 <= {pl2[6:0], 1'b1};
				pl3 <= {pl3[6:0], 1'b1};
			end
		end
	end

	// FLP picks which end of the LS299 pair is tapped (SLAGS.vhd 1B/4B mux).
	assign psd = pf_flip ? {pl3[0], pl2[0], pl1[0], pl0[0]}
	                     : {pl3[7], pl2[7], pl1[7], pl0[7]};

	// =====================================================================
	// 5. PFHS -- the scroll latches, the column counter and the delay RAM
	// =====================================================================
	logic [8:0] hscroll, spc;
	logic       pfhsld_n_d, pfspc_n_d;
	always_ff @(posedge clk) begin
		if (reset) begin
			hscroll <= 9'd0; spc <= 9'd0;
			pfhsld_n_d <= 1'b1; pfspc_n_d <= 1'b1;
		end else if (ce_7m) begin
			pfhsld_n_d <= pfhsld_n;
			pfspc_n_d  <= pfspc_n;
			if (!pfhsld_n) hscroll <= ap;
			if (!pfspc_n)  spc     <= ap;
		end
	end
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_edges = &{1'b0, pfhsld_n_d, pfspc_n_d, st_edge,
	                      pf_v[8:3], bank[3], board_4h, h4d3};
	/* verilator lint_on UNUSEDSIGNAL */

	// 8E/9B: the six-bit column counter, loaded at ST and stepped on 4H.
	always_ff @(posedge clk) begin
		if (reset)         pf_h <= 6'd0;
		else if (h4_rise)  pf_h <= st ? hscroll[8:3] : (pf_h + 6'd1);
	end

	// 4M/5M: the 8 x 8 INVERTING delay RAM and its 6D address counter.
	logic [2:0] dly_a;
	logic [7:0] dly_ram [0:7];
	logic [7:0] xp;

	// PFHS pins 25..17 take PS7..PS4 from 6N and PSD3..PSD0 STRAIGHT from the
	// SLAGS (sheet 7), so the low nibble enters the delay RAM in the board's
	// active-low sense and the RAM's inverting outputs turn it back into the
	// active-high pen on PFX3..PFX0.
	wire [7:0] ps_bus = {ps_hi, psd};     // PS7..PS4 (6N), PSD3..PSD0 (SLAGS)

`ifndef ALTERA_RESERVED_QIS
	initial for (int i = 0; i < 8; i++) dly_ram[i] = 8'hFF;
`endif

	always_ff @(posedge clk) begin
		if (reset) begin
			dly_a <= 3'd0;
			xp    <= 8'h00;
		end else if (ce_7m) begin
			xp             <= ~dly_ram[dly_a];        // 4D latch, inverted data
			dly_ram[dly_a] <= ps_bus;
			dly_a          <= (st || (dly_a == 3'd7)) ? hscroll[2:0]
			                                          : (dly_a + 3'd1);
		end
	end

	// PFX ALIGNMENT.  The PFHS delay line is an 8 x 8 RAM whose address counter
	// is reloaded with scroll[2:0] at every ST and at every wrap, so its latency
	// is "eight pixels, minus the fine scroll" -- but the phase of that counter
	// relative to the SLAGS load, and the '189 pair's own registered output, are
	// not drawn at a resolution that fixes the constant part.  With
	// PFX_ALIGN = 2 the playfield and the alphanumerics land on the same raster
	// phase and the picture is pixel-exact against MAME frame captures.
	// Changing it moves the playfield alone, which is exactly the degree of
	// freedom it represents.
	// The alignment applies to the PEN half only.  The two halves of the PS bus
	// reach PFHS by different routes -- PS7..PS4 once per 8-pixel cell through
	// 5N/6N, PSD3..PSD0 serially out of the SLAGS -- and the residual latency is
	// in the SERIAL one: delaying both halves leaves every tile's first two
	// pixels carrying the LEFT neighbour's colour, while delaying the pen alone
	// is exact.
	logic [3:0] pen_dly [PFX_ALIGN == 0 ? 1 : PFX_ALIGN];
	always_ff @(posedge clk) if (ce_7m) begin
		pen_dly[0] <= xp[3:0];
		for (int k = 1; k < PFX_ALIGN; k++) pen_dly[k] <= pen_dly[k-1];
	end
	wire [3:0] xpen = (PFX_ALIGN == 0) ? xp[3:0]
	                                   : pen_dly[(PFX_ALIGN == 0) ? 0
	                                             : PFX_ALIGN - 1];

	// Section 3 of the header explains this one-position ambiguity.
	assign pfx = PFX_LITERAL ? {xp[7:5], 1'b0, xpen}    // as drawn
	                         : {xp[6:4], 1'b0, xpen};   // resolved

	// 12E: PF/M = SPC[ XP[2:0] ]
	assign pf_m = spc[{1'b0, xpen[2:0]}];

endmodule
