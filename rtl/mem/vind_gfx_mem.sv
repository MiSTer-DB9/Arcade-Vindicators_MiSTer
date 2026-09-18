`timescale 1ns/1ps
//============================================================================
//  Vindicators graphics-ROM fetch — the playfield and motion-object clients of
//  the SDRAM, presented to the video pipeline as "one 8-pixel row, four
//  planes, one 32-bit word".
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Derived from the Xybots MiSTer core's `xybots_gfx_mem.sv`
//  (GPL-3.0), whose arbitration half now lives in `vind_sdram_arb.sv` (this
//  core has a third, CPU, client) and whose 4-byte row assembly is what
//  remains here.
//
//  ---- what one request IS on the board (SP-317 sheet 9) -------------------
//  The sixteen graphics ROM sockets are wired as four quadrants, one per pixel
//  bit-plane, all sharing ONE address bus:
//
//      socket A2:A0 = GP4V, GP2V, GP1V   the pixel row inside an 8x8 cell
//      socket A16:A3 = GA13..GA0         the tile/sprite code, low bits
//      GA14 (and GA15, undecoded) select the socket through the 3N bank PAL
//
//  so one address presents FOUR bytes at once — one per plane — and each byte
//  is 8 horizontal pixels of that plane, loaded into the SLAGS shifters on
//  /GLD and shifted out MSB-first (bit 7 = the leftmost pixel when HFLP = 0;
//  the SLAGS' FLP input takes the other end of the shifter).  One request here
//  is therefore exactly one hardware graphics-ROM access.
//
//  The MRA emits MAME's `sprites_pf` region as a four-way byte interleave of
//  the planes, plane 0 first, so those four bytes are consecutive in SDRAM and
//  the fetch is one 2-word burst:
//
//      word0 = {plane1, plane0}     word1 = {plane3, plane2}
//      data  = {word1, word0} = {plane3, plane2, plane1, plane0}
//
//  ---- client contract ------------------------------------------------------
//      *_addr[17:0]  the GRAPHICS ROM ADDRESS = {GA14..GA0, GP4V, GP2V, GP1V}
//                    = code[14:0]*8 + row[2:0].  GA15 exists on the board but
//                    is not decoded by the fitted ROMs (sheet 8), so the
//                    caller drops it.
//      *_req         raise with the address and HOLD it
//      *_valid       one-cycle pulse; *_data is valid in that cycle and is held
//                    until this client's next transaction completes
//      *_data[31:0]  {plane3, plane2, plane1, plane0}, each byte MSB = leftmost
//                    pixel.  These are the RAW ROM bits, i.e. the board's own
//                    ACTIVE-LOW MSD/PSD nets: pen = ~data.  (MAME's
//                    ROMREGION_INVERT is the same fact applied at load time;
//                    this core keeps the board's polarity so sheet 10's PAL
//                    equations can be written verbatim.)
//      then          drop *_req; the arbiter waits for the drop, so one
//                    request = exactly one transaction.
//
//  Both addresses are 2-word aligned by construction, so a burst can never
//  cross an SDRAM row (512 words).
//
//  ---- budget ---------------------------------------------------------------
//  Sheet 6 alternates the graphics ROM between the playfield and the motion
//  object every 4 pixel clocks (MO//PF = 4HDL), and each layer's SLAGS pair is
//  reloaded once per 8 pixels (/GLD), so the steady-state load is exactly
//  ONE fetch per client per 8 pixel clocks = one per 64 clk_sys each, 114 of
//  each per 456-clock line.  That is a hard deadline, not an average: the
//  shifter must have the row before it starts shifting it out.
//============================================================================

module vind_gfx_mem #(
	parameter int AW = 24,
	parameter logic [AW-1:0] GFX_BASE = 24'h080000   // word address of the region
)(
	input  logic          clk,
	input  logic          reset,

	// ---- playfield row client ----
	input  logic          pf_req,
	input  logic [17:0]   pf_addr,
	output logic          pf_valid,
	output logic [31:0]   pf_data,

	// ---- motion-object row client ----
	input  logic          mo_req,
	input  logic [17:0]   mo_addr,
	output logic          mo_valid,
	output logic [31:0]   mo_data,

	// ---- arbiter read ports (0 = PF, 1 = MO) ----
	output logic          c0_req,
	output logic [AW-1:0] c0_addr,
	output logic  [1:0]   c0_blen,
	input  logic          c0_valid,
	input  logic          c0_last,
	output logic          c1_req,
	output logic [AW-1:0] c1_addr,
	output logic  [1:0]   c1_blen,
	input  logic          c1_valid,
	input  logic          c1_last,
	input  logic [15:0]   c_rdata
);

	// byte address {addr, 2'b00} -> word address {addr, 1'b0}
	assign c0_addr = GFX_BASE + {{(AW-19){1'b0}}, pf_addr, 1'b0};
	assign c1_addr = GFX_BASE + {{(AW-19){1'b0}}, mo_addr, 1'b0};
	assign c0_blen = 2'd1;                  // two words = the four plane bytes
	assign c1_blen = 2'd1;
	assign c0_req  = pf_req;
	assign c1_req  = mo_req;

	// Each client assembles its own two words.  `c_rdata` is shared and is only
	// meaningful in the cycle that client's `*_valid` is high, so the low word
	// is latched on the first pulse and the pair is emitted on `*_last`.
	logic [15:0] pf_lo, mo_lo;

	always_ff @(posedge clk) begin
		if (reset) begin
			pf_valid <= 1'b0; mo_valid <= 1'b0;
		end else begin
			pf_valid <= 1'b0; mo_valid <= 1'b0;
			if (c0_valid) begin
				if (!c0_last) pf_lo <= c_rdata;
				else begin pf_data <= {c_rdata, pf_lo}; pf_valid <= 1'b1; end
			end
			if (c1_valid) begin
				if (!c1_last) mo_lo <= c_rdata;
				else begin mo_data <= {c_rdata, mo_lo}; mo_valid <= 1'b1; end
			end
		end
	end

endmodule
