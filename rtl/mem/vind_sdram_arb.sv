`timescale 1ns/1ps
//============================================================================
//  Vindicators SDRAM arbiter — three read clients plus the loader write port
//  onto the single-port `vind_sdram` controller.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.
//
//  Derived from the Xybots MiSTer core's `xybots_gfx_mem.sv` arbitration
//  (GPL-3.0), itself Toobin's `toobin_sdram_arb.sv`.  Two changes:
//
//    1. THREE readers, because Vindicators keeps its 384 KB 68010 program ROM
//       in SDRAM: playfield rows, motion-object rows and the CPU cache-line
//       fill.
//    2. The client port carries `blen`, so a client chooses its own burst
//       length (2 words for a graphics row, 4 for a CPU cache line), and the
//       arbiter returns the words as they arrive with `*_last` on the final
//       one.  Assembling them is the client's job, not the arbiter's.
//
//  ---- arbitration ---------------------------------------------------------
//  The loader write port has ABSOLUTE priority — it only runs while
//  `ioctl_download` is high, when no reader exists yet.  The three readers are
//  served ROUND-ROBIN: after serving client N the next grant starts looking at
//  N+1.  This is not a preference, it is a requirement: PF and MO each have a
//  hard per-8-pixel deadline (64 clk_sys) and the 68010 stalls on a cache
//  miss, so no client can be the absolute loser.  Strict priority was measured
//  on a sibling core at 601 clk_sys of playfield starvation against that
//  64-clock deadline.
//
//  One request = exactly one transaction: raise `*_req` with the address, hold
//  it until `*_last` pulses, then drop it.  The arbiter waits for the drop
//  (state A_HOLD) before granting anything else, so a client can never be
//  served twice for one request.
//
//  ---- controller contract --------------------------------------------------
//  When `sd_ready` is high, pulse `sd_req` for one cycle with addr/we/blen
//  (/wdata); read data returns on `sd_rdata` with one `sd_valid` pulse per
//  word, on consecutive cycles for a burst, in address order; `sd_ready`
//  returns high when the access completes.  A request coinciding with a due
//  refresh is latched inside the controller, so the single-cycle pulse is safe.
//============================================================================

module vind_sdram_arb #(
	parameter int AW = 24
)(
	input  logic          clk,
	input  logic          reset,

	// ---- client 0: playfield row fetch ----
	input  logic          c0_req,
	input  logic [AW-1:0] c0_addr,
	input  logic  [1:0]   c0_blen,
	output logic          c0_valid,
	output logic          c0_last,
	// ---- client 1: motion-object row fetch ----
	input  logic          c1_req,
	input  logic [AW-1:0] c1_addr,
	input  logic  [1:0]   c1_blen,
	output logic          c1_valid,
	output logic          c1_last,
	// ---- client 2: 68010 program-ROM cache line fill ----
	input  logic          c2_req,
	// From vind_core's arbitration-window logic: a CPU (client 2)
	// transaction may START now, i.e. it will be finished before the next
	// playfield or motion-object request is due.  The video clients are never
	// gated.  Tie high to get the plain round-robin.
	input  logic          cpu_ok,
	input  logic [AW-1:0] c2_addr,
	input  logic  [1:0]   c2_blen,
	output logic          c2_valid,
	output logic          c2_last,
	// read data, shared: valid only in the cycle the granted client's
	// `*_valid` pulses (one word per pulse, in address order)
	output logic [15:0]   c_rdata,

	// ---- loader write port (16-bit word, address already in SDRAM space) ----
	input  logic          dl_wr,
	input  logic [AW-1:0] dl_waddr,
	input  logic [15:0]   dl_wdata,
	output logic          dl_ack,

	// ---- SDRAM controller port ----
	output logic          sd_req,
	output logic [AW-1:0] sd_addr,
	output logic          sd_we,
	output logic  [1:0]   sd_blen,
	output logic [15:0]   sd_wdata,
	input  logic          sd_ready,
	input  logic          sd_valid,
	input  logic [15:0]   sd_rdata
);

	typedef enum logic [1:0] { A_IDLE, A_REQ, A_WAIT, A_HOLD } astate_t;
	astate_t st;

	logic       is_wr;          // this transaction is the loader write
	logic [1:0] gnt;            // granted reader, valid when !is_wr
	logic [1:0] last;           // round-robin pointer
	logic [1:0] wcnt;           // words returned so far
	logic [1:0] blen_l;

	// Starvation valve: if the CPU has been refused for 256 clk_sys (four
	// 64-clock video cells with no window at all, which the measured request
	// instants never produce) it goes regardless.
	logic [8:0] c2_wait;
	always_ff @(posedge clk) begin
		if (reset)                          c2_wait <= '0;
		else if (!c2_req || (st == A_REQ && gnt == 2'd2)) c2_wait <= '0;
		else if (st == A_IDLE && !c2_wait[8]) c2_wait <= c2_wait + 9'd1;
	end
	wire       c2_ok = c2_req & (cpu_ok | c2_wait[8]);   // the CPU only when it fits
	wire [2:0] req = {c2_ok, c1_req, c0_req};
	wire       any_req = |req;

	// Round-robin: after serving client `last`, start looking at last+1.
	// The three client requests are used BY NAME here, not as `req[n]`: a
	// constant bit-select of a vector inside an always_* block makes Icarus
	// print "sorry: constant selects in always_* processes are not currently
	// supported (all bits will be included)" and fall back to a whole-vector
	// sensitivity, and the same construct is worked around the same way in
	// vind_sdram.sv.  `req`/`any_req` remain for the whole-vector tests.
	logic [1:0] gsel;
	always_comb begin
		case (last)
			// the two video clients alternate; the CPU only when neither is
			// pending AND its window is open -- a video fetch never queues
			// behind a cache burst
			2'd0:    gsel = c1_req ? 2'd1 : c0_req ? 2'd0 : 2'd2;
			2'd1:    gsel = c0_req ? 2'd0 : c1_req ? 2'd1 : 2'd2;
			default: gsel = c0_req ? 2'd0 : c1_req ? 2'd1 : 2'd2;
		endcase
	end

	logic [AW-1:0] sel_addr;
	logic  [1:0]   sel_blen;
	always_comb begin
		case (gsel)
			2'd0:    begin sel_addr = c0_addr; sel_blen = c0_blen; end
			2'd1:    begin sel_addr = c1_addr; sel_blen = c1_blen; end
			default: begin sel_addr = c2_addr; sel_blen = c2_blen; end
		endcase
	end

	wire held_req = (gnt == 2'd0) ? c0_req : (gnt == 2'd1) ? c1_req : c2_req;
	wire is_last  = (wcnt == blen_l);

	// `c_rdata` is REGISTERED alongside the client valid pulses, not wired
	// straight through: the controller's `sd_valid`/`sd_rdata` pair is one
	// cycle earlier than the client pulse this module emits, and in a burst the
	// next word lands on `sd_rdata` in exactly that cycle.  Forwarding
	// combinationally would hand every client the FOLLOWING word.
	always_ff @(posedge clk) if (sd_valid) c_rdata <= sd_rdata;

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= A_IDLE; sd_req <= 1'b0; sd_we <= 1'b0; sd_blen <= 2'd0;
			c0_valid <= 1'b0; c1_valid <= 1'b0; c2_valid <= 1'b0;
			c0_last  <= 1'b0; c1_last  <= 1'b0; c2_last  <= 1'b0;
			dl_ack <= 1'b0; last <= 2'd0; is_wr <= 1'b0; gnt <= 2'd0;
			wcnt <= 2'd0; blen_l <= 2'd0;
		end else begin
			c0_valid <= 1'b0; c1_valid <= 1'b0; c2_valid <= 1'b0;
			c0_last  <= 1'b0; c1_last  <= 1'b0; c2_last  <= 1'b0;
			dl_ack   <= 1'b0; sd_req   <= 1'b0;
			case (st)
				// -------- pick a client (write first, then round-robin) --------
				A_IDLE: begin
					wcnt <= 2'd0;
					if (dl_wr) begin
						is_wr    <= 1'b1;
						sd_addr  <= dl_waddr;
						sd_we    <= 1'b1;
						sd_blen  <= 2'd0;
						sd_wdata <= dl_wdata;
						blen_l   <= 2'd0;
						if (sd_ready) begin sd_req <= 1'b1; st <= A_REQ; end
					end else if (any_req) begin
						is_wr   <= 1'b0;
						gnt     <= gsel;
						sd_addr <= sel_addr;
						sd_we   <= 1'b0;
						sd_blen <= sel_blen;
						blen_l  <= sel_blen;
						if (sd_ready) begin
							sd_req <= 1'b1;
							last   <= gsel;
							st     <= A_REQ;
						end
					end
				end
				// -------- req asserted for exactly the previous cycle --------
				A_REQ: begin
					sd_we <= 1'b0;
					st    <= A_WAIT;
				end
				// -------- await completion --------
				A_WAIT: begin
					if (is_wr) begin
						if (sd_ready) begin dl_ack <= 1'b1; st <= A_HOLD; end
					end else if (sd_valid) begin
						case (gnt)
							2'd0:    begin c0_valid <= 1'b1; c0_last <= is_last; end
							2'd1:    begin c1_valid <= 1'b1; c1_last <= is_last; end
							default: begin c2_valid <= 1'b1; c2_last <= is_last; end
						endcase
						if (is_last) st <= A_HOLD;
						else         wcnt <= wcnt + 2'd1;
					end
				end
				// -------- one transaction per request: wait for req to drop ----
				A_HOLD: begin
					if (is_wr) begin if (!dl_wr) st <= A_IDLE; end
					else       begin if (!held_req) st <= A_IDLE; end
				end
				default: st <= A_IDLE;
			endcase
		end
	end

endmodule
