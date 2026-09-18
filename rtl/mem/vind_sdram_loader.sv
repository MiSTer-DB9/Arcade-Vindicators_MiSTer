`timescale 1ns/1ps
//============================================================================
//  Vindicators SDRAM loader-writer — packs the download byte stream into
//  16-bit words and writes the TWO SDRAM regions through the single arbiter
//  write port.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.
//
//  Ported from the Xybots MiSTer core's `xybots_sdram_loader.sv` (GPL-3.0),
//  itself Toobin's.  Two Vindicators changes, both because this core keeps its
//  384 KB 68010 program ROM in SDRAM instead of BRAM:
//
//    1. There are two source regions, not two graphics regions: `prog` (the
//       68010 program) and `gfx` (the shared PF/MO graphics).
//    2. They have OPPOSITE byte orders, and that is not a style choice:
//
//         prog : the MRA interleaves the six 27512s into BIG-ENDIAN 68010
//                words, so the EVEN download byte is D15:8 (the `1x` sockets
//                at 1D/1F/1K, sheet 4) and the ODD byte is D7:0.  The
//                word stored is therefore {even, odd} and `vind_cpurom_sdram`
//                hands it to the CPU unchanged.
//         gfx  : the graphics ROMs are byte-addressed devices with no word
//                order of their own; the stream is a four-way plane
//                interleave, so the natural little-endian packing is used —
//                EVEN byte -> D7:0, ODD byte -> D15:8.  A 4-byte group
//                (planes 0,1,2,3) then reads back as the two words
//                {plane1,plane0} and {plane3,plane2}, i.e. the 32-bit fetch
//                {word1, word0} = {plane3, plane2, plane1, plane0}.
//
//       Both sides of each datapath agree on its own convention, and both are
//       verified in simulation by CRCing the regions as they read back out of
//       the SDRAM, rather than off a write-strobe latch.
//
//  ---- SDRAM word map (word addresses; 32 MB module, 1.375 MB used) --------
//    PROG_BASE 0x000000 .. 0x02FFFF   68010 program ROM   0x60000 bytes
//    GFX_BASE  0x080000 .. 0x0FFFFF   PF + MO graphics   0x100000 bytes
//
//    prog : word = PROG_BASE + prog_addr[18:1]
//    gfx  : word = GFX_BASE  + gfx_addr[19:1]
//
//  Even and odd bytes of a word are always consecutive in the download stream,
//  so the even byte is latched and the word is emitted on the odd byte.
//  `wr_busy` is combinational and is asserted while a word is outstanding (and
//  in the cycle a word completes); drive `ioctl_wait` with it so the byte
//  stream can never outrun the SDRAM.
//
//  ---- the write-path rule -------------------------------------------------
//  This is a SINGLE write path through the shared `vind_sdram_arb` controller
//  port — NOT a fourth client behind the read arbitration.  A write client
//  placed behind a read arbiter has been seen to get pruned by Quartus, so
//  after any arbiter change, grep output_files/*.map.rpt for "Lost fanout" on
//  the request/we nets.
//
//  The even byte is latched in ANY state, not only when idle.  Latching only
//  when idle drops an even byte that arrives while a word is outstanding, and
//  the NEXT odd byte then pairs with a stale low byte — a silently corrupted
//  word rather than a lost one.  `wr_busy` makes that unreachable as long as
//  the integrator wires it to `ioctl_wait`, and this costs nothing.
//============================================================================

module vind_sdram_loader #(
	parameter int AW = 24,
	parameter logic [AW-1:0] PROG_BASE = 24'h000000,
	parameter logic [AW-1:0] GFX_BASE  = 24'h080000
)(
	input  logic          clk,
	input  logic          reset,

	// ---- byte strobes from vind_rom_loader (the SDRAM regions only) ----
	input  logic          prog_wr,
	input  logic [18:0]   prog_addr,
	input  logic          gfx_wr,
	input  logic [19:0]   gfx_addr,
	input  logic  [7:0]   ld_data,
	output logic          wr_busy,      // -> ioctl_wait (back-pressure)

	// ---- arbiter write port ----
	output logic          dl_wr,
	output logic [AW-1:0] dl_waddr,
	output logic [15:0]   dl_wdata,
	input  logic          dl_ack
);

	// ---- is this byte the even (first) or the word-completing (odd) one? ----
	wire prog_ev = prog_wr && !prog_addr[0];
	wire prog_od = prog_wr &&  prog_addr[0];
	wire gfx_ev  = gfx_wr  && !gfx_addr[0];
	wire gfx_od  = gfx_wr  &&  gfx_addr[0];

	wire any_ev = prog_ev | gfx_ev;
	wire any_od = prog_od | gfx_od;     // word-completing

	logic [7:0] ev_buf;                 // the latched even byte

	wire [AW-1:0] word_addr = prog_od
		? (PROG_BASE + {{(AW-18){1'b0}}, prog_addr[18:1]})
		: (GFX_BASE  + {{(AW-19){1'b0}}, gfx_addr[19:1]});

	// prog: even byte = D15:8 (68010 big-endian).  gfx: even byte = D7:0.
	wire [15:0] word_data = prog_od ? {ev_buf, ld_data} : {ld_data, ev_buf};

	typedef enum logic [0:0] { L_IDLE, L_WR } lstate_t;
	lstate_t st;

	// combinational back-pressure: busy while writing, or the cycle a word completes
	assign wr_busy = (st == L_WR) || (st == L_IDLE && any_od);

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= L_IDLE; dl_wr <= 1'b0;
		end else begin
			if (any_ev) ev_buf <= ld_data;      // latched whatever the state
			case (st)
				L_IDLE: begin
					dl_wr <= 1'b0;
					if (any_od) begin
						dl_waddr <= word_addr;
						dl_wdata <= word_data;
						dl_wr    <= 1'b1;
						st       <= L_WR;
					end
				end
				L_WR: begin
					if (dl_ack) begin dl_wr <= 1'b0; st <= L_IDLE; end
				end
				default: st <= L_IDLE;
			endcase
		end
	end

	// Simulation-only overrun check, in its own process so no synthesisable
	// always_ff contains a system task.  A word-completing (odd) byte arriving
	// while the previous word is still outstanding cannot be recovered — it
	// means `ioctl_wait` is not wired to `wr_busy`.  The whole 1 524 224-byte
	// download streams through here in simulation without it firing.
`ifndef ALTERA_RESERVED_QIS
	always @(posedge clk)
		if (!reset && st == L_WR && any_od)
			$display("ERROR: vind_sdram_loader overrun - a word-completing byte arrived while a write was outstanding; ioctl_wait is not wired to wr_busy");
`endif

endmodule
