`timescale 1ns/1ps
//============================================================================
//  Vindicators memory subsystem — the single module `vind_core` instantiates
//  for the ROM download, the SDRAM and every ROM that is not owned by another
//  board block.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Structure follows the Xybots MiSTer core's `xybots_mem.sv`
//  (GPL-3.0); the client mix, the stream map and the CPU-ROM path are this
//  core's own.
//
//  It wires up, and hides, seven modules:
//
//    vind_rom_loader      index-0 download stream -> per-region byte strobes
//    vind_sdram_loader    byte pairs -> the ONE SDRAM write path
//    vind_cpurom_sdram    384 KB 68010 program ROM + its prefetching cache
//    vind_gfx_mem         PF + MO row fetch, 4 planes per 32-bit word
//    vind_sdram_arb       three read clients + the loader write port
//    vind_sdram           the MT48LC16M16-class controller itself
//    vind_char_rom        the 16 KB 15/16N alphanumeric character ROM
//
//  What it deliberately does NOT contain: the 64 KB JSA sound ROM (that BRAM
//  is inside `vind_jsa_mem`, so this module only forwards `sndrom_*` write
//  strobes), the 2804A EEPROM and the whole ioctl index-2 NVRAM channel
//  (`rtl/main/vind_nvram_io.sv` + `vind_eeprom_2804.sv` own the device, the
//  restore, the save-back and `ioctl_din`; this module only offers the erased
//  factory image the MRA ships at stream 0x174000), and VRAM and CRAM
//  (dual-port BRAM next to the CPU and video sides that use them).
//
//  ---- reset: ONE reset, and it MUST be ~pll_locked -------------------------
//  `init_reset` reaches the SDRAM controller (where it drives SDRAM_CKE), the
//  loader, the arbiter and the CPU cache.  It must be `~pll_locked` and
//  NOTHING else.  A game or download reset pulsing here drops CKE, restarts
//  the 200 us init in the middle of the download and silently loses every
//  write already made — the confirmed root cause of a black screen on a
//  sibling Atari core.  There is intentionally no second reset input: nothing
//  in the memory path needs resetting when the game resets, and offering the
//  port would be offering the trap.
//
//  The ONE exception, and it is not a reset input: the 68010 program-ROM CACHE
//  is additionally invalidated while `rom_loaded` is low.  PAL 3C decodes
//  /ROM0..2 from the address alone, so `prog_rd` is asserted throughout the
//  download even though the CPU is in reset, and a cache that fills from a
//  not-yet-written SDRAM would hold zeros for ever.  See the `u_cpurom`
//  instantiation below.
//
//  ---- read-port contracts (what the rest of the core codes against) -------
//
//  68010 program ROM (SDRAM + cache; the board's ROM port plus two flags):
//      prog_a[17:0]   the word address vind_main_bus forms,
//                     {bank[1:0], A16, A15, MA14', MA13', A12..A1}
//      prog_rd        /ROM0..2 & W//R
//      prog_data      valid 1 clk_sys after prog_a **on a cache hit**
//      rom_ready      level: an image has been downloaded (holds the CPU in
//                     reset until then) — the same signal as `rom_loaded`
//      prog_ready     per-access: `prog_data` belongs to the address on prog_a
//      prog_stall     prog_rd & ~prog_ready — see the WARNING below
//
//  **WARNING**: sheet 4 gives ROM cycles zero wait states and `vind_main_bus`
//  implements that literally, so on a cache miss the CPU would latch stale
//  data.  The integrator must use `prog_stall`, either as
//  `cpu_cen = ce_7m & ~prog_stall` or as an extra term in the /ROM DTACK path.
//  `vind_core` does the former.
//
//  Character ROM (BRAM, 15/16N, 16 KB):
//      char_addr[13:0] = code*16 + row*2 + half -> char_data[7:0], LATENCY 1.
//
//  Playfield / motion-object graphics rows (SDRAM, arbitrated):
//      *_addr[17:0] is the GRAPHICS ROM ADDRESS {GA14..GA0, GP4V,GP2V,GP1V};
//      one request returns the four plane bytes of that 8-pixel row as
//      {plane3, plane2, plane1, plane0}, RAW (active low) — see
//      `vind_gfx_mem.sv`.  Raise `*_req` and hold it; `*_valid` pulses once;
//      then drop `*_req`.
//
//  ---- download and NVRAM -------------------------------------------------
//  `ioctl_wait` is driven from the SDRAM loader's back-pressure and is the only
//  thing that stops the byte stream outrunning the SDRAM; `vind_core` must wire
//  it straight to hps_io.  Index 0 is the MRA ROM stream and this module owns
//  it in full.  Index 2 (NVRAM) is passed through untouched: no strobe here
//  ever fires for it and no upload path is driven, so `vind_nvram_io` can own
//  `ioctl_din` without a fight.
//
//  ---- SDRAM map (word addresses, 32 MB module, 1.375 MB used) ------------
//    0x000000..0x02FFFF  68010 program ROM  0x60000 bytes
//    0x080000..0x0FFFFF  PF + MO graphics  0x100000 bytes
//  Everything is in bank 0, rows of 512 words, so neither the 2-word graphics
//  burst nor the 4-word CPU line can cross a row.  SDRAM_CLK is NOT driven
//  here — `Arcade-Vindicators.sv` drives that pin from the PLL's second,
//  phase-shifted output, so the read-capture phase is a constant fixed in
//  rtl/pll/pll_0002.v.
//============================================================================

module vind_mem #(
	parameter int AW = 24,
	parameter logic [AW-1:0] PROG_BASE = 24'h000000,
	parameter logic [AW-1:0] GFX_BASE  = 24'h080000
)(
	input  logic        clk,
	// arbitration windows from vind_core: high while a CPU burst / a refresh
	// can still finish before the next playfield or motion-object fetch is due
	input  logic        cpu_ok,
	input  logic        rfsh_ok,
	input  logic        init_reset,      // ~pll_locked ONLY — see header

	// ---- HPS ioctl download ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	output logic        ioctl_wait,
	output logic        rom_loaded,

	// ---- 68010 program ROM read port ----
	input  logic [17:0] prog_a,
	input  logic        prog_rd,
	output logic [15:0] prog_data,
	output logic        rom_ready,
	output logic        prog_ready,
	output logic        prog_stall,

	// ---- alphanumeric character ROM (15/16N, BRAM, latency 1) ----
	input  logic [13:0] char_addr,
	output logic  [7:0] char_data,

	// ---- graphics row fetch (SDRAM) ----
	input  logic        pf_req,
	input  logic [17:0] pf_addr,
	output logic        pf_valid,
	output logic [31:0] pf_data,
	input  logic        mo_req,
	input  logic [17:0] mo_addr,
	output logic        mo_valid,
	output logic [31:0] mo_data,

	// ---- JSA I sound ROM write stream (the BRAM lives in vind_jsa_mem) ----
	output logic        sndrom_wr,
	output logic [15:0] sndrom_addr,
	output logic  [7:0] sndrom_data,

	// ---- 2804A EEPROM erased factory image (index 0, stream 0x174000) ----
	// Optional: vind_nvram_io decodes the same bytes and also owns index 2.
	output logic        eeprom_img_wr,
	output logic  [8:0] eeprom_img_addr,
	output logic  [7:0] eeprom_img_data,

	// ---- SDRAM chip pins (SDRAM_CLK is driven in Arcade-Vindicators.sv) ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

	// ================= index-0 download router =================
	logic        ld_prog_wr, ld_gfx_wr;
	logic [18:0] ld_prog_addr;
	logic [19:0] ld_gfx_addr;
	logic  [7:0] ld_data;
	logic        char_wr;
	logic [13:0] char_wr_addr;
	logic  [7:0] char_wr_data;

	vind_rom_loader u_loader (
		.clk            (clk),
		.reset          (init_reset),
		.ioctl_download (ioctl_download),
		.ioctl_wr       (ioctl_wr),
		.ioctl_addr     (ioctl_addr),
		.ioctl_dout     (ioctl_dout),
		.ioctl_index    (ioctl_index),
		.prog_wr        (ld_prog_wr),
		.prog_addr      (ld_prog_addr),
		.gfx_wr         (ld_gfx_wr),
		.gfx_addr       (ld_gfx_addr),
		.sdram_data     (ld_data),
		.snd_rom_wr     (sndrom_wr),
		.snd_rom_addr   (sndrom_addr),
		.snd_rom_data   (sndrom_data),
		.char_rom_wr    (char_wr),
		.char_rom_addr  (char_wr_addr),
		.char_rom_data  (char_wr_data),
		.eeprom_wr      (eeprom_img_wr),
		.eeprom_addr    (eeprom_img_addr),
		.eeprom_data    (eeprom_img_data),
		.rom_loaded     (rom_loaded)
	);

	assign rom_ready = rom_loaded;

	// ================= alphanumeric character ROM (BRAM, 15/16N) =============
	vind_char_rom u_char (
		.clk     (clk),
		.wr      (char_wr),
		.wr_addr (char_wr_addr),
		.wr_data (char_wr_data),
		.addr    (char_addr),
		.data    (char_data)
	);

	// ================= SDRAM: one write path, three read clients =============
	logic          dl_wr, dl_ack;
	logic [AW-1:0] dl_waddr;
	logic [15:0]   dl_wdata;

	vind_sdram_loader #(
		.AW (AW), .PROG_BASE (PROG_BASE), .GFX_BASE (GFX_BASE)
	) u_sdram_loader (
		.clk       (clk),
		.reset     (init_reset),
		.prog_wr   (ld_prog_wr),
		.prog_addr (ld_prog_addr),
		.gfx_wr    (ld_gfx_wr),
		.gfx_addr  (ld_gfx_addr),
		.ld_data   (ld_data),
		.wr_busy   (ioctl_wait),
		.dl_wr     (dl_wr),
		.dl_waddr  (dl_waddr),
		.dl_wdata  (dl_wdata),
		.dl_ack    (dl_ack)
	);

	logic          c0_req, c1_req, c2_req;
	logic [AW-1:0] c0_addr, c1_addr, c2_addr;
	logic  [1:0]   c0_blen, c1_blen, c2_blen;
	logic          c0_valid, c1_valid, c2_valid;
	logic          c0_last, c1_last, c2_last;
	logic [15:0]   c_rdata;

	vind_gfx_mem #(
		.AW (AW), .GFX_BASE (GFX_BASE)
	) u_gfx (
		.clk      (clk),
		.reset    (init_reset),
		.pf_req   (pf_req),   .pf_addr (pf_addr),
		.pf_valid (pf_valid), .pf_data (pf_data),
		.mo_req   (mo_req),   .mo_addr (mo_addr),
		.mo_valid (mo_valid), .mo_data (mo_data),
		.c0_req   (c0_req),   .c0_addr (c0_addr), .c0_blen (c0_blen),
		.c0_valid (c0_valid), .c0_last (c0_last),
		.c1_req   (c1_req),   .c1_addr (c1_addr), .c1_blen (c1_blen),
		.c1_valid (c1_valid), .c1_last (c1_last),
		.c_rdata  (c_rdata)
	);

	vind_cpurom_sdram #(
		.AW (AW), .PROG_BASE (PROG_BASE)
	) u_cpurom (
		.clk     (clk),
		// init_reset OR "no image loaded".  PAL 3C decodes /ROM0..2 from the
		// address alone (sheet 4: there is no BAS term on those outputs),
		// so `prog_rd` is HIGH at prog_a = 0 for the whole download, while the
		// 68010 is still held in reset — and without this term the cache fills
		// line 0 (and prefetches line 1) out of an SDRAM that has not been
		// written yet, latches those zeros as VALID, and never invalidates them.
		// The 68010 then reads 0x00000000 as its reset SSP and PC and runs off
		// into the vector table.  `rom_loaded` clears at the start of every
		// index-0 download and sets on its last cycle, so it is exactly "the
		// cached image is stale".  This is a CACHE-COHERENCE term only: it does
		// NOT reach the SDRAM controller, the loader or the arbiter, so the
		// one-reset rule in this file's header still holds.
		// The cache's valid bits live in M10K, so this term starts an
		// invalidate WALK (one set per clk_sys) rather than a one-cycle clear;
		// it finishes long inside the download.
		.reset   (init_reset | ~rom_loaded),
		.rd      (prog_rd),
		.addr    (prog_a),
		.data    (prog_data),
		.ready   (prog_ready),
		.stall   (prog_stall),
		.c_req   (c2_req),
		.c_addr  (c2_addr),
		.c_blen  (c2_blen),
		.c_valid (c2_valid),
		.c_last  (c2_last),
		.c_rdata (c_rdata)
	);

	logic          sd_req, sd_we, sd_ready, sd_valid;
	logic [AW-1:0] sd_addr;
	logic  [1:0]   sd_blen;
	logic [15:0]   sd_wdata, sd_rdata;
	logic          rfsh_pending;

	vind_sdram_arb #(.AW (AW)) u_arb (
		.clk      (clk),
		.reset    (init_reset),
		.c0_req   (c0_req), .c0_addr (c0_addr), .c0_blen (c0_blen),
		.c0_valid (c0_valid), .c0_last (c0_last),
		.c1_req   (c1_req), .c1_addr (c1_addr), .c1_blen (c1_blen),
		.c1_valid (c1_valid), .c1_last (c1_last),
		.c2_req   (c2_req), .c2_addr (c2_addr), .c2_blen (c2_blen),
		.c2_valid (c2_valid), .c2_last (c2_last),
		.c_rdata  (c_rdata),
		// a due refresh takes precedence over the CPU for the next window,
		// otherwise a cache-miss burst in every cell starves it until it is
		// forced late -- in front of a video fetch
		.cpu_ok   (cpu_ok & ~rfsh_pending),
		.dl_wr    (dl_wr),  .dl_waddr (dl_waddr),
		.dl_wdata (dl_wdata), .dl_ack (dl_ack),
		.sd_req   (sd_req), .sd_addr (sd_addr), .sd_we (sd_we),
		.sd_blen  (sd_blen), .sd_wdata (sd_wdata),
		.sd_ready (sd_ready), .sd_valid (sd_valid), .sd_rdata (sd_rdata)
	);

	vind_sdram #(
		.CLK_KHZ (57273), .ROW_BITS (13), .COL_BITS (9)
	) u_sdram (
		.clk        (clk),
		.reset      (init_reset),
		.addr       (sd_addr),
		.wdata      (sd_wdata),
		.we         (sd_we),
		.blen       (sd_blen),
		.req        (sd_req),
		// a refresh may not start while a video request is already waiting for
		// the bus either (the request that arrived during the previous fetch)
		.rfsh_ok    (rfsh_ok & ~c0_req & ~c1_req),
		.rfsh_pending (rfsh_pending),
		.rdata      (sd_rdata),
		.valid      (sd_valid),
		.ready      (sd_ready),
		.SDRAM_DQ   (SDRAM_DQ),
		.SDRAM_A    (SDRAM_A),
		.SDRAM_BA   (SDRAM_BA),
		.SDRAM_DQML (SDRAM_DQML),
		.SDRAM_DQMH (SDRAM_DQMH),
		.SDRAM_CKE  (SDRAM_CKE),
		.SDRAM_nCS  (SDRAM_nCS),
		.SDRAM_nRAS (SDRAM_nRAS),
		.SDRAM_nCAS (SDRAM_nCAS),
		.SDRAM_nWE  (SDRAM_nWE)
	);

endmodule
