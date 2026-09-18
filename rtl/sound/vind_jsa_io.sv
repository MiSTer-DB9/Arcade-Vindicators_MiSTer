//============================================================================
//  Vindicators (Atari Games, 1988) — JSA I audio PCB I/O: the 5H /WRIO output
//  register, the 5J /RDIO input port, ROM banking, and the periodic sound IRQ.
//
//  Derived from `Arcade-Toobin_MiSTer/rtl/sound/toobin_jsa_io.sv`
//  (Toobin' MiSTer core, GPL-3.0; same A043713 audio PCB), with the Xybots
//  port's LS74-dominant /IRQACK ordering.  Re-derived against SP-317 sheets 15
//  and 17: the periodic-IRQ divider is rewritten and the coin lanes are
//  Vindicators'.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- /WRIO output register ($2A04 write; 5H 74LS273A, sheet 15) ----------
//  CK(11) = /WRIO (rising edge = end of the strobe), /CLR(1) = /POR
//  (R103 150K + C84 .1, tau ~15 ms), so all eight bits power up at 0 —
//  including /YAMRES, i.e. the YM2151 and the YM3012 are held in reset until
//  the 6502's first /WRIO write.
//
//    D7 -> BA13     ROM bank bit 1  -> 2L pin 4  -> 2K A13
//    D6 -> BA12     ROM bank bit 0  -> 2L pin 3  -> 2K A12
//    D5 -> CCTR2    coin counter 2  (sheet 17, R53 -> Q10 2N5306)
//    D4 -> CCTR1    coin counter 1  (sheet 17, R54 -> Q9  2N5306)
//    D3 -> SQUEAK   TMS5220 rate select (4D LS169 preset)  \  3D socket EMPTY
//    D2 -> /SPHRES  TMS5220 RS                              |  on Vindicators:
//    D1 -> /SPHWR   TMS5220 WS                             /   dead outputs
//    D0 -> /YAMRES  YM2151 IC(3) *and* YM3012 ICL(7), active low (1 = run)
//
//  [ROM] the reset routine at $4005 does
//      LDA #$01 / STA $2A04 / AND #$FE / STA $2A04 / ORA #$01 / STA $2A04
//  — a low pulse on D0, which is what confirms D0 = active-low YM reset.
//  D3:D1 are still LATCHED here (real flip-flops on the real 5H) and then
//  ignored: the 3D TMS5220 socket is empty on Vindicators, so nothing consumes
//  them and no speech device is modelled.
//
//  ---- /RDIO input port ($2804 read; 5J 74LS240A, sheet 17) ----------------
//  The LS240A is an INVERTING octal buffer with /1G and /2G both on /RDIO:
//
//    D7 = ~SELF-TEST  SW1 + JSCOM-1 (active low, R11 1K pull-up) -> 1 = test on
//    D6 = ~(/NMI)     SCOM 1M pin 4 /FULL                        -> 1 = cmd pending
//    D5 = ~SFULL      SCOM 1M pin 5 /BUSY                        -> 1 = resp full
//    D4 = ~(/SPHRDY)  TMS5220 RDY — socket empty, input floats high -> 0
//    D3 = ~COIN4      JCOIN-1 — not in the Vindicators harness       -> 0
//    D2 = ~COIN3      JCOIN-2 — not in the Vindicators harness       -> 0
//    D1 = ~COIN2      JCOIN-3 = "Coin 2"                          -> 1 = coin 2
//    D0 = ~COIN1      JCOIN-4 = "Coin 1"                          -> 1 = coin 1
//
//  **Coins are NOT swapped.**  MAME's `vindictr.cpp` never calls
//  set_swapped_coins(), and the Vindicators harness pinout gives JCOIN-4 =
//  Coin 1 -> D0, JCOIN-3 = Coin 2 -> D1.  MAME and the board agree here.
//  (Xybots DOES swap them — do not copy that.)
//
//  [ROM] evidence for the assembled byte:
//    $4016  LDA $280C / AND #$80 / BNE      — D7 self-test, active high
//    $5CB8  BIT $280C / BPL                 — D7 again, via the N flag
//    $5CBF  LDA $280C / LSR A ...           — coins shifted out of D0/D1
//    $414B  LDA #$20 / BIT $280C / BNE      — D5 = 1 means "response still
//                                              pending", skip the send path
//
//  **D6 disagrees with MAME.**  The LS240 inverts an active-low /NMI, so the
//  6502 reads 1 while a command is pending.  MAME (`atarijsa.cpp`) declares
//  that lane IP_ACTIVE_LOW on main_to_sound_ready, i.e. the opposite sense,
//  and MAME's own JSA I/II/III comments disagree with each other.  The
//  schematic is followed here, and the choice is unobservable: the Vindicators
//  sound ROM never tests D6 — there is no `AND #$40` / `BIT`+`BVx` at any
//  $280A/$280C site.
//
//  ---- periodic sound IRQ (sheet 17) --------------------------------------
//  The chain, all from the 3.579545 MHz master:
//
//    3579K --/4 (LS393)--> 894 886 Hz --/16 (6J.1)--> 55 930 Hz
//          --/16 (6J.2)--> 3 495.65 Hz --> the final LS393 half, /14
//
//  and the /14 terminator is an LS393 half plus the 5K LS74 pair:
//
//    LS393 pin 12 /CLR (active HIGH) <- 5K FF2 Q (pin 5)
//    FF1: D = QC, CK = QB            -> FF1.Q rises at counts 6 and 14
//    FF2: D = QD, CK = FF1.Q, CLR = /IRQACK, Q -> LS393 CLR *and* Q8 -> /IRQ
//
//  QD is 0 at count 6 (FF2 clears) and 1 at count 14 (FF2 SETS), so the
//  counter runs 0..13 and restarts: a divide by 14.  3 579 545/4/16/16/14 =
//  **249.6893 Hz**, matching MAME's `MASTER/4/16/16/14`.
//
//  **The behaviour MAME and the Toobin'/Xybots cores do NOT model:** FF2's Q
//  holds the last LS393 in CLR, so the /14 stage is *stopped* for as long as
//  the interrupt is pending.  The real interval is 14 upstream ticks measured
//  from the /IRQACK, not a free-running 249.6893 Hz grid.  The three upstream
//  stages have their CLRs at GND and free-run, so only the last /14 stops —
//  which is why the post-ack phase is quantised to the 3 495.65 Hz tick.
//  This is modelled exactly below.
//
//  `MAME_FREERUN = 1` restores the free-running 14336-tick counter for A/B
//  testing against MAME captures; the schematic behaviour is the default.
//
//  /IRQACK ($2806, decoded on READ or WRITE) is the LS74's ASYNCHRONOUS /CLR,
//  so it dominates a coincident divider edge — a divider tick that lands while
//  /IRQACK is asserted cannot set Q.  (The Toobin' port had the set win; the
//  Xybots port fixed it.  The two orderings differ on only ~0.014 % of
//  interrupts, but the clear is what the part does.)  [ROM] the handler acks
//  with a READ: `$41C2 LDA $280E`, having sampled the YM2151 status at $41BC
//  first.
//
//  6502 /IRQ is an open-collector wired-OR of Q8 (this timer) and the YM2151's
//  own /IRQ pin, with R28 10K pulling up — done in vind_jsa_bus.
//============================================================================

module vind_jsa_io #(
	// 3 579 545 / 4 / 16 / 16 = 3 495.65 Hz upstream tick, then /14.
	parameter int IRQ_PRE      = 1024,   // /4 /16 /16, free-running (CLRs at GND)
	parameter int IRQ_POST     = 14,     // the LS393+LS74 /14 that STOPS when pending
	parameter bit MAME_FREERUN = 1'b0    // 1 = MAME/Toobin' free-running divider
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_jsa,        // JSA master-clock enable (3.579545 MHz)

	// /WRIO write ($2A04)
	input  logic        wrio_wr,
	input  logic  [7:0] wrio_data,
	// /IRQACK strobe ($2806, read or write) — the LS74 asynchronous /CLR
	input  logic        irqack,

	// input-port sources (all logical "asserted" = 1)
	input  logic        self_test,     // SW1 on the audio PCB, shared over JSCOM-1
	input  logic        nmi_line_n,    // physical /NMI, BEFORE the LS240 inverts it
	input  logic        resp_full,     // SFULL: sound->main response pending
	input  logic        coin1,         // JCOIN-4 "Coin 1" -> D0
	input  logic        coin2,         // JCOIN-3 "Coin 2" -> D1

	// outputs
	output logic  [1:0] cpu_bank,      // {BA13, BA12} -> the $3000-$3FFF window
	output logic        coin_ctr1,     // CCTR1 -> Q9
	output logic        coin_ctr2,     // CCTR2 -> Q10
	output logic        ym_reset_n,    // /YAMRES (active low: 1 = run)
	output logic  [7:0] rdio_data,     // assembled /RDIO byte
	output logic        sound_irq      // level, into the 6502 /IRQ wired-OR
);

	// ---- 5H LS273A: the /WRIO output latch, /CLR = /POR --------------------
	// D3:D1 are real flip-flops on the board driving the empty TMS5220 socket.
	// They are latched here so the register file is the part's, then ignored.
	logic [2:0] tms_ctl;   // {SQUEAK, /SPHRES, /SPHWR} — dead on Vindicators
	always_ff @(posedge clk) begin
		if (reset) begin
			cpu_bank <= 2'd0; coin_ctr1 <= 1'b0; coin_ctr2 <= 1'b0;
			ym_reset_n <= 1'b0; tms_ctl <= 3'd0;
		end else if (wrio_wr) begin
			cpu_bank   <= wrio_data[7:6];
			coin_ctr2  <= wrio_data[5];
			coin_ctr1  <= wrio_data[4];
			tms_ctl    <= wrio_data[3:1];
			ym_reset_n <= wrio_data[0];
		end
	end
	wire unused_tms = &{1'b0, tms_ctl};   // 3D socket empty: latched, never read

	// ---- 5J LS240A: the /RDIO input port (inverting) -----------------------
	// D4 /SPHRDY floats high at the empty TMS socket -> 0 after the inverter.
	// D3/D2 COIN4/COIN3 are pulled up with JCOIN-1/-2 unpopulated -> 0.
	assign rdio_data = { self_test, ~nmi_line_n, resp_full, 1'b0,
	                     1'b0, 1'b0, coin2, coin1 };

	// ---- the periodic IRQ divider ------------------------------------------
	localparam int PREW  = $clog2(IRQ_PRE);
	localparam int POSTW = $clog2(IRQ_POST);

	logic [PREW-1:0]  pre_cnt;    // /4 /16 /16 — free-running, CLRs at GND
	logic [POSTW-1:0] post_cnt;   // the /14 LS393 half, CLR held by the LS74

	always_ff @(posedge clk) begin
		if (reset) begin
			pre_cnt <= '0; post_cnt <= '0; sound_irq <= 1'b0;
		end else begin
			if (ce_jsa) begin
				pre_cnt <= pre_cnt + PREW'(1);
				if (pre_cnt == PREW'(IRQ_PRE-1)) begin
					if (post_cnt == POSTW'(IRQ_POST-1)) begin
						post_cnt  <= '0;
						sound_irq <= 1'b1;         // 5K FF2 sets -> Q8 -> /IRQ low
					end else begin
						post_cnt <= post_cnt + POSTW'(1);
					end
				end
			end
			// FF2's Q holds the LS393's active-high CLR for as long as the
			// interrupt is pending, so the /14 stage cannot advance.
			if (!MAME_FREERUN && sound_irq) post_cnt <= '0;
			// /IRQACK is FF2's asynchronous /CLR: dominant over a coincident edge.
			if (irqack) sound_irq <= 1'b0;
		end
	end

endmodule
