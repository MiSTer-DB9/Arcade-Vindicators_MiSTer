`timescale 1ns/1ps
//============================================================================
//  Vindicators graphics-ROM request holder — the adapter between the video
//  pipeline's ASYNCHRONOUS view of the graphics ROMs and the SDRAM client
//  protocol `vind_gfx_mem`/`vind_sdram_arb` actually implement.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.
//
//  ---- what the board does --------------------------------------------------
//  SP-317 sheet 9: the sixteen graphics EPROMs are asynchronous and permanently
//  enabled.  The address {bank/code, row} comes off the playfield word register
//  (11K/11J, clocked by /4H) or the motion-object code adder, and the SLAGS
//  shift registers latch whatever the ROMs are presenting at the /GLD in which
//  MO//PF selects that layer.  There is no request and no handshake: the row is
//  simply THERE.  `vind_pf` and `vind_mo_fetch` model exactly that — their
//  `gfx_addr` is combinational and their `gfx_req` is a ONE-clk_sys marker of
//  the instant the address became the next row's.
//
//  ---- what the SDRAM path needs --------------------------------------------
//  `vind_sdram_arb` only samples a client while it is in A_IDLE, and its
//  contract is "raise *_req with the address and HOLD it until *_last, then
//  drop it".  A one-clk_sys pulse raised while the arbiter is serving one of
//  the other two clients would be LOST OUTRIGHT — the row would never be
//  fetched and the SLAGS would latch whatever the previous transaction left in
//  `gfx_data`.  Over one frame the playfield asks for 13 680 rows, and roughly
//  half of them fall in that window.
//
//  The address a request must carry is the one present ONE clk_sys AFTER the
//  pulse, not during it.  Both pulses ride the very clock edge that loads the
//  register they address (`pfword <= vrd` on /4H is the same edge as
//  `h4_fall`), so during the pulse cycle the combinational address still shows
//  the PREVIOUS row.
//
//  So this module: delay the pulse by one clk_sys, latch the address then, hold
//  the request until `valid`, and guarantee the one-cycle drop the arbiter's
//  A_HOLD state waits for.  A pulse that arrives while a transaction is still in
//  flight is QUEUED (one deep) rather than lost; two pulses in flight would be a
//  genuine deadline miss.
//
//  Latency added: the request reaches the arbiter 2 clk_sys after the pulse.
//  The playfield has 5 pixel clocks = 40 clk_sys between its pulse (h[2:0] = 7)
//  and its /GLD (h[2:0] = 4), so 38 remain against a worst-case fetch of well
//  under that.
//============================================================================

module vind_gfx_hold (
	input  logic        clk,
	input  logic        reset,

	// ---- the video pipeline side (asynchronous-ROM semantics) ----
	input  logic        req_pulse,    // one clk_sys marker: a new row is addressed
	input  logic [17:0] addr_in,      // combinational; belongs to the NEXT cycle

	// ---- the vind_gfx_mem side (held request, latched address) ----
	output logic        req,
	output logic [17:0] addr,
	input  logic        valid         // one-cycle completion pulse
);

	logic        pulse_d, pend;
	logic [17:0] pend_addr;

	always_ff @(posedge clk) begin
		if (reset) begin
			pulse_d   <= 1'b0;
			pend      <= 1'b0;
			req       <= 1'b0;
			addr      <= 18'd0;
			pend_addr <= 18'd0;
		end else begin
			pulse_d <= req_pulse;
			if (valid) begin
				// The transaction completed.  Dropping `req` here gives the
				// arbiter the one idle cycle its A_HOLD state waits for before
				// it will look at any client again.
				req <= 1'b0;
				if (pulse_d) begin pend <= 1'b1; pend_addr <= addr_in; end
			end else if (pulse_d && !req) begin
				req  <= 1'b1;
				addr <= addr_in;             // the cycle AFTER the pulse
			end else if (pulse_d) begin
				pend      <= 1'b1;           // busy: queue this one
				pend_addr <= addr_in;
			end else if (pend && !req) begin
				req  <= 1'b1;
				addr <= pend_addr;
				pend <= 1'b0;
			end
		end
	end

endmodule
