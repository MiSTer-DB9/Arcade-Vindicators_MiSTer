`timescale 1ns/1ps
//============================================================================
//  Vindicators — SP-317 sheet 10: the 2048 x 16 colour RAM (16K + 18K,
//  2K8-45A) and its CPU port.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later.
//
//      16K  D7..D0 = GRN3..GRN0, BLU3..BLU0     /WE = 20F = /CLRAM + /VLWE
//      18K  D7..D0 = INT3..INT0, RED3..RED0     /WE = 20F = /CLRAM + /VUWE
//      both /CS = GND, /OE = 18L LS08 = /PRAM & VW//R
//      16M/16L LS245: /G = /CLRAM, DIR = VW//R  (VRD15..0 <-> the colour nets)
//
//  So the CRAM word is INT3-0 : RED3-0 : GRN3-0 : BLU3-0 = D15..D0, matching
//  MAME's `paletteram_w`, and the two byte lanes are written INDEPENDENTLY
//  through their own /WE terms (which is how /UDS and /LDS are honoured).
//
//  The array is always selected and /OE is only high during a CPU colour-RAM
//  WRITE, so the video reads it continuously and a CPU access takes the
//  address of one pixel.  During a write the '245s drive the CPU's word onto
//  the colour nets the 17M/17L output registers read, and that is what `cint`
//  .. `cblu` carry here.  The registers never load it: VIDCLK is gated off by
//  /CLRAM and /CLRDL (vind_video), and the one VIDCLK edge the gate lets
//  through, at the start of the slot, comes from the same /CLRAM fall that
//  turns the '245s on -- it samples the nets before the written word arrives.
//  The picture effect (a held pixel, no new colour) matches that.  MAME does
//  not model any of this.
//
//  The array answers on MA11:MA1 only; MA12 and above are not decoded on this
//  sheet, so 0x3E0000-0x3E0FFF repeats through the whole /CLRAM window.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_cram (
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	input  logic [10:0] cram_a,       // already muxed CPU/video (vind_prio_gpc)
	input  logic        clram_n,
	input  logic        pram_n,
	input  logic        vw_r,
	input  logic        vuwe_n,
	input  logic        vlwe_n,
	input  logic [15:0] cpu_dout,

	output logic [15:0] cpu_cram_din,
	output logic  [3:0] cint,
	output logic  [3:0] cred,
	output logic  [3:0] cgrn,
	output logic  [3:0] cblu
);

	logic [7:0] cram_hi [0:2047];     // 18K: INT3-0 : RED3-0
	logic [7:0] cram_lo [0:2047];     // 16K: GRN3-0 : BLU3-0
	logic [15:0] q;

`ifndef ALTERA_RESERVED_QIS
	initial begin
		for (int i = 0; i < 2048; i++) begin
			cram_hi[i] = 8'h00;
			cram_lo[i] = 8'h00;
		end
	end
`endif

	wire cs_hi_n = clram_n | vuwe_n;   // 20F LS32 ( 9,10 -> 8) -> 18K /CS
	wire cs_lo_n = clram_n | vlwe_n;   // 20F LS32 (12,13 -> 11) -> 16K /CS
	wire oe_n    = pram_n & vw_r;      // 18L LS08 (1,2 -> 3)

	always_ff @(posedge clk) begin
		if (ce_7m) begin
			if (!cs_hi_n) cram_hi[cram_a] <= cpu_dout[15:8];
			if (!cs_lo_n) cram_lo[cram_a] <= cpu_dout[7:0];
			q <= {cram_hi[cram_a], cram_lo[cram_a]};
		end
	end

	// ---- the CPU's own read port ------------------------------------------
	// Clocked at clk_sys, NOT at ce_7m, for exactly the reason `vind_vram`'s
	// read is: the board's 16K/18K are ASYNCHRONOUS 2K8-45A static
	// RAMs, so during the CPU's one RCLKA slot the word is already on D15:0, and
	// the sheet-4 LS163A asserts /DTACK **inside that slot**.  `q` above is
	// registered on ce_7m -- the right model for the VIDEO tap, whose whole
	// pipeline phase (`PIPE_DLY`) was measured around it -- but it presents the
	// CPU's word one PIXEL after the slot, by which time /CLRAM is high again,
	// the array is being read for the next pixel and the bus cycle is over.  The
	// CPU therefore gets its own registered read of the same address, which
	// `cram_a` holds for all eight clk_sys of the slot.  Without it the game's
	// own power-on self test reads back zero from the colour RAM it has just
	// written and stops at its COLOR RAM BAD display.
	logic [15:0] cpu_q;
	always_ff @(posedge clk) cpu_q <= {cram_hi[cram_a], cram_lo[cram_a]};

	// 3L/3K LS373 (sheet 6): transparent while the CPU owns the array,
	// latched on the falling edge of that slot, driven onto D15:0 while /VRAMRD
	// is low.  The 68010's bus cycle outlives the slot, so the latch is what
	// holds the word until the CPU takes it.
	logic [15:0] cpu_hold;
	always_ff @(posedge clk) begin
		if (reset)                       cpu_hold <= 16'h0000;
		else if (ce_7m && !clram_n)      cpu_hold <= cpu_q;
	end
	assign cpu_cram_din = clram_n ? cpu_hold : cpu_q;

	// The colour nets: the array while /OE is low; the CPU's word through
	// 16M/16L (DIR = VW//R = A -> B) while /OE is high, i.e. in a CPU write.
	wire [15:0] vdata = oe_n ? cpu_dout : q;

	assign cint = vdata[15:12];
	assign cred = vdata[11:8];
	assign cgrn = vdata[7:4];
	assign cblu = vdata[3:0];


endmodule
