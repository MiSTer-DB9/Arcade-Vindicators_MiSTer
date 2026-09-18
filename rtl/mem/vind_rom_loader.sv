`timescale 1ns/1ps
//============================================================================
//  Vindicators ROM download router — MiSTer index-0 ioctl stream -> region
//  writes.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.
//
//  Ported from the Xybots MiSTer core's `xybots_rom_loader.sv` (GPL-3.0),
//  itself Toobin's `toobin_rom_loader.sv`.  The structure (a pure registered
//  address decode into per-region byte strobes plus region-local offsets) is
//  carried over unchanged; the stream map, the region widths and which regions
//  go to SDRAM are Vindicators' own.
//
//  ---- the stream this decodes (as releases/Vindicators.mra assembles it) ---
//
//    stream base   size       MAME region  destination
//    0x000000      0x060000   maincpu      68010 program ROM   -> SDRAM (word)
//    0x060000      0x010000   jsa:cpu      6502 sound ROM      -> BRAM (byte)
//    0x070000      0x100000   sprites_pf   PF + MO graphics    -> SDRAM (word)
//    0x170000      0x004000   chars        alpha gfx (16N)     -> BRAM (byte)
//    0x174000      0x000200   —            2804A EEPROM image  -> BRAM (byte)
//    total         0x174200                (1 524 224 bytes)
//
//  The MRA has already done all of the assembly, so this module never has to
//  know about byte lanes, ROM_RELOAD mirrors or socket holes:
//
//    * maincpu is emitted as BIG-ENDIAN INTERLEAVED WORDS — the MAME even-offset
//      ROM (the `1x` sockets 1D/1F/1K, sheet 4, D15:8) is `map="01"`, the FIRST
//      byte of each output word.  So download byte 2N is the 68010 word's high
//      lane and 2N+1 the low lane; `vind_sdram_loader` packs them that way and
//      `vind_cpurom_sdram` reads them straight back out.  Getting this
//      backwards byte-swaps every opcode and the CPU fetches a garbage reset
//      vector with no error anywhere, so the assembled region is checked by
//      CRC against MAME's own :maincpu region, 04f2ff51.
//    * sprites_pf is emitted as a FOUR-WAY BYTE INTERLEAVE of the four bit
//      planes, plane 0 (MSD0/PSD0) first, so the four plane bytes of one
//      graphics address are consecutive and one 32-bit read returns the whole
//      8-pixel row the sheet 9 SLAGS pair loads on /GLD.  The 64 KB parts'
//      GA13 mirror is already materialised, so the region is flat here.
//    * the EEPROM image is 512 bytes of 0xFF (an erased 2804A).  MiSTer's NVRAM
//      channel (ioctl index 2) restores saved settings OVER it afterwards; that
//      channel is NOT handled here — `rtl/main/vind_nvram_io.sv` owns the
//      index-2 path and the save-back upload, together with `ioctl_din`.
//
//  Nothing else in the stream exists: bytes at or above 0x174200, and every
//  ioctl index other than 0, produce no strobe at all.
//
//  ---- back-pressure -------------------------------------------------------
//  The BRAM regions accept a byte per clock and never stall.  The two SDRAM
//  regions go through `vind_sdram_loader`, which packs byte pairs into words
//  and raises `wr_busy` while a word is outstanding.  The integrator wires
//    assign ioctl_wait = sdram_loader_wr_busy;
//  (`vind_mem` does exactly that).  This module deliberately does not consume
//  `ioctl_wait` itself: hps_io holds `ioctl_addr`/`ioctl_dout` and simply does
//  not issue the next `ioctl_wr`, so the decode is unaffected.
//
//  Outputs are REGISTERED (one clk_sys after the ioctl_wr), matching the
//  hardware-proven Toobin'/Xybots timing: the SDRAM loader's combinational
//  `wr_busy` is then derived from the registered strobes and asserts one cycle
//  after the byte.
//
//  `rom_loaded` is 0 from `reset` (~pll_locked), 0 while an INDEX-0 download
//  runs, and 1 from the first cycle after it ends.  An index-2 (NVRAM) restore
//  never touches it — a core that had never seen a ROM download must not
//  announce "the ROMs are loaded" because settings were restored.
//============================================================================

module vind_rom_loader
(
	input  logic        clk,
	input  logic        reset,          // ~pll_locked ONLY (see vind_mem)

	// ---- HPS ioctl download channel ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,     // byte offset into the index-0 stream
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,

	// ---- 68010 program ROM -> SDRAM (via vind_sdram_loader), byte port ----
	output logic        prog_wr,
	output logic [18:0] prog_addr,      // byte offset 0..0x5FFFF
	// ---- PF + MO graphics -> SDRAM (via vind_sdram_loader), byte port ----
	output logic        gfx_wr,
	output logic [19:0] gfx_addr,       // byte offset 0..0xFFFFF
	// shared byte for both SDRAM regions (they never strobe in the same cycle)
	output logic  [7:0] sdram_data,

	// ---- JSA I 6502 sound ROM (BRAM inside vind_jsa), byte port ----
	output logic        snd_rom_wr,
	output logic [15:0] snd_rom_addr,   // byte offset 0..0xFFFF
	output logic  [7:0] snd_rom_data,

	// ---- alphanumerics character ROM (16N, BRAM), byte port ----
	output logic        char_rom_wr,
	output logic [13:0] char_rom_addr,  // byte offset 0..0x3FFF
	output logic  [7:0] char_rom_data,

	// ---- 2804A EEPROM initial image (BRAM/NVRAM), byte port ----
	output logic        eeprom_wr,
	output logic  [8:0] eeprom_addr,    // byte offset 0..0x1FF
	output logic  [7:0] eeprom_data,

	// ---- high once the index-0 download has ended ----
	output logic        rom_loaded
);

	// region base offsets in the concatenated download stream
	localparam [26:0] BASE_PROG   = 27'h000000;
	localparam [26:0] BASE_SND    = 27'h060000;
	localparam [26:0] BASE_GFX    = 27'h070000;
	localparam [26:0] BASE_CHARS  = 27'h170000;
	localparam [26:0] BASE_EEPROM = 27'h174000;
	localparam [26:0] END_STREAM  = 27'h174200;

	wire is_idx0 = (ioctl_index == 16'd0);
	wire wr      = ioctl_download & ioctl_wr & is_idx0;

	wire in_prog   = wr && (ioctl_addr <  BASE_SND);        // BASE_PROG == 0
	wire in_snd    = wr && (ioctl_addr >= BASE_SND)    && (ioctl_addr < BASE_GFX);
	wire in_gfx    = wr && (ioctl_addr >= BASE_GFX)    && (ioctl_addr < BASE_CHARS);
	wire in_chars  = wr && (ioctl_addr >= BASE_CHARS)  && (ioctl_addr < BASE_EEPROM);
	wire in_eeprom = wr && (ioctl_addr >= BASE_EEPROM) && (ioctl_addr < END_STREAM);

	logic [7:0] data_r;

	always_ff @(posedge clk) begin
		data_r        <= ioctl_dout;
		prog_wr       <= in_prog   & ~reset;
		snd_rom_wr    <= in_snd    & ~reset;
		gfx_wr        <= in_gfx    & ~reset;
		char_rom_wr   <= in_chars  & ~reset;
		eeprom_wr     <= in_eeprom & ~reset;
		prog_addr     <= 19'(ioctl_addr - BASE_PROG);
		snd_rom_addr  <= 16'(ioctl_addr - BASE_SND);
		gfx_addr      <= 20'(ioctl_addr - BASE_GFX);
		char_rom_addr <= 14'(ioctl_addr - BASE_CHARS);
		eeprom_addr   <=  9'(ioctl_addr - BASE_EEPROM);
	end

	// one registered byte, fanned out to every destination port
	assign sdram_data    = data_r;
	assign snd_rom_data  = data_r;
	assign char_rom_data = data_r;
	assign eeprom_data   = data_r;

	// rom_loaded latches on the falling edge of the INDEX-0 download.  `reset`
	// (~pll_locked) gives it a defined value from power-up, so simulation and
	// hardware agree and no consumer ever samples an X.
	wire  dl0 = ioctl_download & is_idx0;
	logic dl0_d;
	always_ff @(posedge clk) begin
		if (reset) begin
			dl0_d      <= 1'b0;
			rom_loaded <= 1'b0;
		end else begin
			dl0_d <= dl0;
			if (dl0)        rom_loaded <= 1'b0;   // download in progress
			else if (dl0_d) rom_loaded <= 1'b1;   // first cycle after it ends
		end
	end

endmodule
