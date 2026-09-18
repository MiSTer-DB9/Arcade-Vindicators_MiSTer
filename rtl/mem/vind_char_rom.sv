`timescale 1ns/1ps
//============================================================================
//  Vindicators alphanumeric character ROM — the 27128 at 15/16N (SP-317
//  sheet 7), 16 K x 8 in one M10K-backed BRAM.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.
//
//  ---- the board (sheet 7) -------------------------------------------------
//      A13..A4 = AP9..AP0     the character code, alpha word D9:0
//      A3..A1  = 4V, 2V, 1V   the pixel row inside the 8x8 cell
//      A0      = /4H          which half of the row: 0 = pixels 0..3
//      OE, CE  = GND          the part is permanently enabled and free-running
//
//  so  addr = code*16 + row*2 + half  and one byte is FOUR pixels of two bits:
//  O7..O4 go to the 19N shifter (APIX1, the pen's MSB) and O3..O0 to 18N
//  (APIX0).  Pixel p of a half therefore has pen {O[7-p], O[3-p]}.  That is
//  MAME's `anlayout` exactly: 2 planes at bit offsets {0, 4}, xoffsets
//  {0,1,2,3, 8,9,10,11}, 8*16 bits per character.
//
//  Unlike the graphics ROMs this data is NOT inverted anywhere: MAME applies
//  ROMREGION_INVERT to `sprites_pf` only, and sheet 7's shifters take the ROM
//  bits straight.
//
//  Read port: `addr` -> `data` one clk_sys later (registered BRAM output, so
//  the array infers as M10K).  The write port is the ROM download and is only
//  strobed while `ioctl_download` is high, long before the video side reads.
//============================================================================

module vind_char_rom
(
	input  logic        clk,
	// loader (byte writes over the whole 16 KB image)
	input  logic        wr,
	input  logic [13:0] wr_addr,
	input  logic  [7:0] wr_data,
	// video read port
	input  logic [13:0] addr,
	output logic  [7:0] data
);

	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] rom [0:16383];
`ifndef ALTERA_RESERVED_QIS
	initial begin for (int i = 0; i < 16384; i++) rom[i] = 8'h00; end   // sim only
`endif

	always_ff @(posedge clk) begin
		if (wr) rom[wr_addr] <= wr_data;
		data <= rom[addr];
	end

endmodule
