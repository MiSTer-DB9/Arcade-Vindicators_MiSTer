//============================================================================
//  Vindicators (Atari Games, 1988) — the SCOM inter-CPU sound link.
//  BOTH Atari SCOM customs and the four-wire cable between them:
//
//      game PCB 14/15B (MASTER, S/M- = GND)   audio PCB 1M (SLAVE, S/M- = PR1)
//        9  /WR  = /SCOMWR ($360030 write)      9  WR  = /WRP  ($2A02 write)
//       10  /RD  = /SCOMRD ($260030 read)      10  RD  = /RDP  ($2802 read)
//        7 /RESREQ = /SNDRES ($360020 write)    7 /RESREQ = PR1 (never asserted)
//       11  CK  = /B4H  (894.886 kHz)          11  CK  = /CLK  <- the master's
//        4  FULL  -> /SINT (68010 IPL 6)        4  /FULL -> 6502 /NMI, /RDIO D6
//        5  BUSY  -> /SCBSY ($260010 D3)        5  /BUSY -> SFULL, /RDIO D5
//       19  SD    -> /DATA  <------ one bidirectional wire ------>  SD  19
//       16  RES     not connected               16  RES  -> /SNDRES -> 6502 RES
//        6 /EFULL <- FIN (JSCM-6) <- the slave's pin 5
//                    the master's pin 4 -> FOUT (JSCM-4) -> FIN -> /EFULL  6
//
//  Derived from `Arcade-Toobin_MiSTer/rtl/sound/toobin_sound_comm.sv`
//  and `Arcade-Xybots_MiSTer/rtl/sound/xybots_sound_comm.sv` (both
//  GPL-3.0), which model the logical mailbox only (MAME `atari_sound_comm`).
//  The register-level set/clear semantics are theirs; the serial transport,
//  the /EFULL back-channel and the /SCBSY meaning are new here, read off
//  SP-317 sheets 2 and 17.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- the cable, and what each flag wire actually carries ------------------
//  Only four signals cross: /CLK, /DATA, "Full" and "Aud Flag" (each 470 R
//  series + 100 pF at both connectors).  /DATA is driven by BOTH SD pins, so
//  it is a half-duplex wire and the master's /CLK arbitrates it.  The two flag
//  wires are cross-connected:
//
//      "Full"     JSCM-4  master pin 4 FULL   -> JSCOM-4 slave  /EFULL pin 6
//      "Aud Flag" JSCOM-6 slave  pin 5 /BUSY  -> JSCM-6  master /EFULL pin 6
//
//  Reading those two wires is what makes the whole handshake close, and it is
//  what explains the one sentence on sheet 17 that a plain mailbox cannot:
//  *"Nothing on the sound side can clear the sound->main flag — only the main
//  board's read (or the sound-reset strobe) does."*  The slave's /BUSY (SFULL,
//  /RDIO D5) is released when the MASTER's FULL flag falls, and that fall
//  reaches the slave over the "Full" wire.  Modelled exactly below.
//
//  ---- the two directions ---------------------------------------------------
//  main -> sound
//    1. 68010 writes $360030.  /SCOMWR loads the master's transmit latch and
//       asserts master BUSY  -> /SCBSY -> $260010 D3 reads "busy".
//    2. The master clocks a frame out on /DATA with /CLK.
//    3. On the last bit the slave's receive latch loads and its /FULL asserts:
//       6502 /NMI, and /RDIO D6 = 1 through the inverting LS240.
//    4. The master's BUSY releases: the byte is delivered.  Note there is NO
//       wire from the slave's /FULL back to the master, so /SCBSY cannot mean
//       "the 6502 has read it" — it means "the transfer has completed".
//       **This is where the hardware and MAME differ** (see MAME_MAILBOX).
//    5. 6502 reads $2802 (/RDP): the slave's /FULL releases, NMI and D6 clear.
//
//  sound -> main
//    1. 6502 writes $2A02 (/WRP).  The slave's transmit latch loads and its
//       /BUSY asserts: SFULL -> /RDIO D5 = 1, and out on "Aud Flag" to the
//       master's /EFULL, which is how the master learns there is a byte.
//    2. The master clocks a frame IN on /DATA (it owns /CLK in both directions).
//    3. On the last bit the master's receive latch loads and FULL asserts:
//       /SINT -> 68010 IPL 6, and $260010 D2.  FULL also goes out on the
//       "Full" wire to the slave's /EFULL.
//    4. 68010 reads $260030 (/SCOMRD): FULL falls -> /SINT clears -> the "Full"
//       wire falls -> the slave releases /BUSY -> /RDIO D5 reads 0.
//       [ROM] the sound ROM's main loop at $4149 is
//         `LDA #$20 / BIT $280C / BNE $4168` — it refuses to queue another
//       response while D5 is set, so this is the loop that closes the link.
//    5. A /SNDRES ($360020) also clears the response side.
//
//  ---- frame length: the one inferred number -------------------------------
//  The SCOM is an undumped Atari custom.  The drawing gives the wires, the
//  clock (/B4H = 4H inverted = 7.15909 MHz / 8 = 894 886 Hz, 1.1175 us/bit)
//  and the direction of every pin — it does NOT give the framing.  This model
//  uses a **10-/B4H-clock frame: 1 start bit + 8 data bits (LSB first) +
//  1 stop/turnaround bit = 11.18 us per byte** (`FRAME_BITS`), which is the
//  minimum self-framing shape for a single half-duplex data wire.  A write is
//  asynchronous to the master's /CLK, so the observed end-to-end latency is
//  FRAME_BITS or FRAME_BITS+1 /B4H clocks (11.2-12.3 us) depending on where
//  the strobe falls in the bit period.  Everything CPU-visible is independent
//  of the number; only the latency moves, so FRAME_BITS is a parameter.  Not
//  settled by the schematic: the framing is inferred, not transcribed.
//
//  Direction arbitration: the master owns /CLK, so its own transmit wins a tie
//  and a pending slave byte goes next.  (Also inferred; unobservable because
//  the two directions are never both pending in these ROMs for more than one
//  frame time.)
//
//  ---- MAME_MAILBOX = 1 (A/B only) -----------------------------------------
//  Collapses the link to MAME's zero-latency parallel mailbox with MAME's flag
//  semantics: `snd_busy` (= main_to_sound_ready) is set by /SCOMWR and cleared
//  by the 6502's /RDP read, and `jsa_sfull` (= sound_to_main_ready) is set by
//  /WRP and cleared by /SCOMRD directly.  Default is the schematic.
//============================================================================

module vind_scom #(
	parameter int  FRAME_BITS   = 10,     // start + 8 data + stop, in /B4H clocks
	parameter int  RESET_BITS   = 10,     // /RESREQ -> RES propagation, /B4H clocks
	parameter bit  MAME_MAILBOX = 1'b0    // 1 = MAME's zero-latency mailbox
) (
	input  logic       clk,
	input  logic       reset,          // power-on reset (both boards)
	input  logic       ce_b4h,         // /B4H = 4H inverted, ~894.886 kHz

	// ---- main board (SCOM 14/15B, sheet 2) ----
	input  logic       snd_cmd_wr,     // /SCOMWR pulse  ($360030 write)
	input  logic [7:0] snd_cmd_data,
	input  logic       snd_resp_rd,    // /SCOMRD pulse  ($260030 read)
	output logic [7:0] snd_resp_data,  // byte returned by that read
	// **ACTIVE LOW**, as the physical nets are and as vind_main_bus expects
	// (these are wired straight to `sint_n` / `scbsy_n`).
	output logic       snd_full,       // pin 4 FULL -> /SINT (IPL 6), $260010 D2
	                                   //   0 = a sound->main byte is waiting
	output logic       snd_busy,       // pin 5 BUSY -> /SCBSY,        $260010 D3
	                                   //   0 = a main->sound transfer is in flight
	input  logic       snd_reset,      // /SNDRES pulse ($360020 write) -> /RESREQ

	// ---- audio board (SCOM 1M, sheet 17) ----
	input  logic       jsa_rdp,        // /RDP pulse: 6502 read  $2802
	input  logic       jsa_wrp,        // /WRP pulse: 6502 write $2A02
	input  logic [7:0] jsa_wrp_data,
	output logic [7:0] jsa_cmd_data,   // byte the 6502 sees at /RDP
	output logic       jsa_nmi,        // pin 4 /FULL -> 6502 /NMI (1 = asserted)
	output logic       jsa_sfull,      // pin 5 /BUSY -> SFULL -> /RDIO D5
	output logic       jsa_res         // pin 16 RES -> /SNDRES -> 6502 RES (1 = held)
);

	// ------------------------------------------------------------------
	//  Master-side registers (game PCB 14/15B)
	// ------------------------------------------------------------------
	logic [7:0] m_tx_data;    // transmit holding latch  (loaded by /SCOMWR)
	logic       m_tx_pend;    // -> pin 5 BUSY / /SCBSY
	logic [7:0] m_rx_data;    // receive holding latch   (read by /SCOMRD)
	logic       m_rx_full;    // -> pin 4 FULL  / /SINT

	// ------------------------------------------------------------------
	//  Slave-side registers (audio PCB 1M)
	// ------------------------------------------------------------------
	logic [7:0] s_tx_data;    // transmit holding latch  (loaded by /WRP)
	logic       s_tx_pend;    // -> pin 5 /BUSY / SFULL / "Aud Flag"
	logic       s_tx_sent;    // the byte has been shifted out; /BUSY now waits
	                          // for the master's FULL to fall (sheet-17 rule)
	logic [7:0] s_rx_data;    // receive holding latch   (read by /RDP)
	logic       s_rx_full;    // -> pin 4 /FULL / 6502 /NMI / /RDIO D6

	// ------------------------------------------------------------------
	//  The cable
	// ------------------------------------------------------------------
	//  `audat`     JSCM-3 / JSCOM-3, driven by whichever SD pin owns the frame
	//  `cable_full` JSCM-4 -> JSCOM-4 ("Full"),     master pin 4 -> slave /EFULL
	//  `aud_flag`   JSCOM-6 -> JSCM-6 ("Aud Flag"), slave pin 5  -> master /EFULL
	//  (/CLK is `ce_b4h` itself.)
	logic       audat;
	wire        cable_full = m_rx_full;   // master FULL out on "Full"
	wire        aud_flag   = s_tx_pend;   // slave /BUSY out on "Aud Flag"
	wire        m_efull    = aud_flag;    // master pin 6 /EFULL
	wire        s_efull    = cable_full;  // slave  pin 6 /EFULL

	// ------------------------------------------------------------------
	//  Frame sequencer — the master owns /CLK, so one counter steps BOTH
	//  shift registers.  DIR: 0 = master -> slave, 1 = slave -> master.
	// ------------------------------------------------------------------
	localparam int FCW = $clog2(FRAME_BITS + 1);
	logic            frame_act;
	logic            frame_dir;
	logic [FCW-1:0]  frame_bit;
	logic [7:0]      shifter;

	// ------------------------------------------------------------------
	//  /RESREQ -> RES.  The reset request travels the same link, so it is
	//  held for RESET_BITS /B4H clocks (~11 us, ~20 6502 cycles) rather than
	//  the single fabric cycle the mailbox ports used.
	// ------------------------------------------------------------------
	localparam int RCW = $clog2(RESET_BITS + 1);
	logic [RCW-1:0] res_cnt;

	assign snd_resp_data = m_rx_data;
	assign snd_full      = ~m_rx_full;   // /SINT  is active low
	assign snd_busy      = ~m_tx_pend;   // /SCBSY is active low
	assign jsa_cmd_data  = s_rx_data;
	assign jsa_nmi       = s_rx_full;
	assign jsa_sfull     = s_tx_pend;
	assign jsa_res       = (res_cnt != '0);

	// The master's FULL falling is what releases the slave's /BUSY (sheet 17).
	logic m_rx_full_d;

	always_ff @(posedge clk) begin
		if (reset) begin
			m_tx_data <= 8'h00; m_tx_pend <= 1'b0;
			m_rx_data <= 8'h00; m_rx_full <= 1'b0;
			s_tx_data <= 8'h00; s_tx_pend <= 1'b0; s_tx_sent <= 1'b0;
			s_rx_data <= 8'h00; s_rx_full <= 1'b0;
			frame_act <= 1'b0;  frame_dir <= 1'b0; frame_bit <= '0;
			shifter   <= 8'h00; audat     <= 1'b1;
			res_cnt   <= '0;    m_rx_full_d <= 1'b0;
		end else begin
			m_rx_full_d <= m_rx_full;

			// ---------------- CPU-side accesses (fabric rate) ----------------
			// /SCOMWR: load the master transmit latch, raise BUSY (/SCBSY).
			if (snd_cmd_wr) begin
				m_tx_data <= snd_cmd_data;
				m_tx_pend <= 1'b1;
			end
			// /WRP: load the slave transmit latch, raise /BUSY (SFULL, D5).
			if (jsa_wrp) begin
				s_tx_data <= jsa_wrp_data;
				s_tx_pend <= 1'b1;
				s_tx_sent <= 1'b0;
			end
			// /RDP: the 6502 takes the command -> slave /FULL releases (NMI, D6).
			if (jsa_rdp) s_rx_full <= 1'b0;
			// /SCOMRD: the 68010 takes the response -> master FULL releases.
			if (snd_resp_rd) m_rx_full <= 1'b0;

			// ---------------- the serial link (on /B4H) ----------------------
			if (MAME_MAILBOX) begin
				// A/B mode: zero-latency mailbox with MAME's flag semantics.
				if (snd_cmd_wr) begin s_rx_data <= snd_cmd_data; s_rx_full <= 1'b1; end
				else if (jsa_rdp) m_tx_pend <= 1'b0;          // /SCBSY clears on /RDP
				if (jsa_wrp) begin m_rx_data <= jsa_wrp_data; m_rx_full <= 1'b1; end
				else if (snd_resp_rd || snd_reset) s_tx_pend <= 1'b0;
			end else if (ce_b4h) begin
				if (!frame_act) begin
					// Idle: the master's own transmit wins the wire, then the
					// slave's (announced over "Aud Flag" -> the master's /EFULL).
					if (m_tx_pend) begin
						frame_act <= 1'b1; frame_dir <= 1'b0;
						frame_bit <= '0;   shifter   <= m_tx_data;
						audat     <= 1'b0;                     // start bit
					end else if (m_efull && !s_tx_sent && !m_rx_full) begin
						frame_act <= 1'b1; frame_dir <= 1'b1;
						frame_bit <= '0;   shifter   <= s_tx_data;
						audat     <= 1'b0;                     // start bit
					end else begin
						audat <= 1'b1;                         // idle high
					end
				end else begin
					frame_bit <= frame_bit + FCW'(1);
					if (frame_bit < FCW'(8)) begin
						audat   <= shifter[0];                 // LSB first
						shifter <= {1'b1, shifter[7:1]};
					end else begin
						audat <= 1'b1;                         // stop / turnaround
					end
					if (frame_bit == FCW'(FRAME_BITS-1)) begin
						frame_act <= 1'b0;
						if (frame_dir == 1'b0) begin
							// master -> slave: the command lands, /FULL sets,
							// and the master's BUSY (/SCBSY) releases.
							s_rx_data <= m_tx_data;
							s_rx_full <= 1'b1;
							m_tx_pend <= 1'b0;
						end else begin
							// slave -> master: the response lands, FULL sets
							// (/SINT).  The slave's /BUSY stays set until the
							// master's FULL falls, over the "Full" wire.
							m_rx_data <= s_tx_data;
							m_rx_full <= 1'b1;
							s_tx_sent <= 1'b1;
						end
					end
				end
			end

			// ---- "Full" wire -> slave /EFULL: releases SFULL on the fall ----
			// Only the master's read (or /SNDRES) can make this edge happen,
			// which is exactly the sheet-17 sentence.
			if (!MAME_MAILBOX && m_rx_full_d && !m_rx_full) s_tx_pend <= 1'b0;

			// ---------------- /RESREQ -> RES over the link -------------------
			if (snd_reset) begin
				res_cnt   <= RCW'(RESET_BITS);
				s_tx_pend <= 1'b0;      // the response side is cleared with it
				m_rx_full <= 1'b0;
			end else if (ce_b4h && res_cnt != '0) begin
				res_cnt <= res_cnt - RCW'(1);
			end
		end
	end

	// `audat` and the cable levels exist so a simulation can watch the real wire;
	// nothing downstream consumes them (the receive latches are loaded from the
	// transmit latches at end-of-frame, which is what the shift register would
	// have reassembled bit for bit).
	wire _unused_cable = &{1'b0, audat, s_efull, shifter[7]};

endmodule
