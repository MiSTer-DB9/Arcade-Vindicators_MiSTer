//============================================================================
//  Vindicators (Atari Games, 1988) — the complete JSA I "Stand-Alone Audio
//  PCB" A043713, SP-317 sheets 14-17.  6502 (T65) + vind_jsa_bus (decode /
//  memory / I/O / the 3F staging latch) + YM2151 (jt51) + POKEY + the /MIX
//  analogue mixer + the sheet-16 output low-pass + BOTH halves of the SCOM
//  link (vind_scom) and the four-wire cable to the game PCB.
//
//  Derived from `Arcade-Toobin_MiSTer/rtl/sound/toobin_jsa.sv` (Toobin'
//  MiSTer core, GPL-3.0; same A043713 audio PCB), rewired for Vindicators
//  against SP-317 sheets 14-17.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- clocking ------------------------------------------------------------
//  ONE clock domain, `clk` = clk_sys = 57.272727 MHz, integer enables:
//     ce_ym   = clk_sys/16 = 3.579545  MHz  -> the board's 3579K net
//                                              (YM2151 OM, the IRQ divider)
//     ce_6502 = clk_sys/32 = 1.7897725 MHz  -> the board's 1790K net
//                                              (6502 O0, POKEY O2, jt51 cen_p1)
//     ce_b4h  = /B4H       = 894.886   kHz  -> the SCOM shift clock, produced
//                                              on the GAME PCB (sheet 3, 17F
//                                              LS04 inverting 4H) and carried
//                                              over JSCM-7, so it is an INPUT
//                                              here — the video side drives it.
//  `ce_6502` must be a strict subset of `ce_ym` (both come from the same
//  clk_sys divider, so this holds by construction); jt51's cen/cen_p1 contract
//  and the board's own /2 relationship are then identical.  Toobin's
//  fractional `toobin_jsa_cen` is deliberately NOT ported.
//
//  ---- the sound CPU -------------------------------------------------------
//  1J is a 6502A: T65 in Mode "00".  RES = /SNDRES from the SCOM's RES pin;
//  /NMI = the SCOM's /FULL; /IRQ = the open-collector wired-OR of the periodic
//  timer (Q8) and the YM2151.  `Rdy` is tied high: the 2M-FPAL READY
//  wait-state stretcher for the slow YM2151 is cycle timing only and is not
//  modelled.
//
//  ---- self-test -----------------------------------------------------------
//  `self_test` is the CABINET service switch — the same line that appears at
//  $260010 D1 on the game PCB and reaches this board over JSCM-1/AUD-1 (SW1
//  on the audio PCB is the same node).  SP-317 sheet 2 puts the service switch
//  on D1; do NOT wire it from MAME's `260010` bit 12, which is a P2 stick bit
//  and a driver kludge.
//
//  ---- output routing (sheet 16 -> sheet 14) -------------------------------
//     aud_left  = LAUD = YM3012 CH2 + PS*CT1 -> TDA2030 Q2 -> SPKR1 -> JSPK-5
//     aud_right = RAUD = YM3012 CH1 + PS*CT2 -> TDA2030 Q1 -> SPKR2 -> JSPK-2
//============================================================================

module vind_jsa #(
	parameter bit LPF_BYPASS   = 1'b0,   // 1 = skip the sheet-16 output low-pass
	parameter bit MAME_FREERUN = 1'b0,   // 1 = MAME's free-running periodic IRQ
	parameter bit MAME_MAILBOX = 1'b0    // 1 = MAME's zero-latency SCOM mailbox
) (
	input  logic        clk,             // clk_sys 57.272727 MHz
	input  logic        reset,

	// clock enables
	input  logic        ce_6502,         // clk_sys/32, 1790K (also POKEY, jt51 cen_p1)
	input  logic        ce_ym,           // clk_sys/16, 3579K
	input  logic        ce_b4h,          // /B4H, ~894.886 kHz — the SCOM shift clock

	// sound ROM loader (2K, 64 KB)
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,

	// ---- main-board side of the SCOM link (game PCB 14/15B, sheet 2) ----
	input  logic        snd_cmd_wr,      // /SCOMWR pulse  ($360030 write)
	input  logic  [7:0] snd_cmd_data,
	input  logic        snd_resp_rd,     // /SCOMRD pulse  ($260030 read)
	output logic  [7:0] snd_resp_data,
	output logic        snd_full,        // /SINT  -> 68010 IPL 6, $260010 D2  (ACTIVE LOW)
	output logic        snd_busy,        // /SCBSY ->             $260010 D3  (ACTIVE LOW)
	input  logic        snd_reset,       // /SNDRES pulse  ($360020 write)

	// ---- board inputs / outputs ----
	input  logic        coin1,           // JCOIN-4 "Coin 1"
	input  logic        coin2,           // JCOIN-3 "Coin 2"
	input  logic        self_test,       // cabinet service switch (JSCM-1/AUD-1)
	output logic        coin_ctr1,       // CCTR1 -> Q9  -> CC1+/CC1-
	output logic        coin_ctr2,       // CCTR2 -> Q10 -> CC2+/CC2-

	// ---- audio ----
	output logic signed [15:0] aud_left,   // LAUD -> SPKR1
	output logic signed [15:0] aud_right   // RAUD -> SPKR2
);

	// ---- SCOM: both customs + the four-wire cable ----
	wire [7:0] scom_cmd_data, scom_wrp_data;
	wire       scom_rdp, scom_wrp, scom_nmi, scom_sfull, scom_res;
	vind_scom #(.MAME_MAILBOX(MAME_MAILBOX)) u_scom (
		.clk(clk), .reset(reset), .ce_b4h(ce_b4h),
		.snd_cmd_wr(snd_cmd_wr), .snd_cmd_data(snd_cmd_data),
		.snd_resp_rd(snd_resp_rd), .snd_resp_data(snd_resp_data),
		.snd_full(snd_full), .snd_busy(snd_busy), .snd_reset(snd_reset),
		.jsa_rdp(scom_rdp), .jsa_wrp(scom_wrp), .jsa_wrp_data(scom_wrp_data),
		.jsa_cmd_data(scom_cmd_data), .jsa_nmi(scom_nmi),
		.jsa_sfull(scom_sfull), .jsa_res(scom_res) );

	// ---- 1J 6502A ----
	wire [15:0] cpu_a; wire [7:0] cpu_do, cpu_di; wire cpu_rwn;
	wire cpu_irq;
	wire [7:0] dbgA_nc, dbgX_nc, dbgY_nc, dbgS_nc, dbgP_nc; wire cpu_sync_nc;
	T65_wrap u_cpu (
		.Mode(2'b00), .Res_n(~(reset | scom_res)), .Clk(clk), .Enable(ce_6502),
		.Rdy(1'b1),                       // 2M-FPAL READY stretcher not modelled
		.IRQ_n(~cpu_irq), .NMI_n(~scom_nmi), .DI(cpu_di),
		.A(cpu_a), .DO(cpu_do), .R_W_n(cpu_rwn), .Sync(cpu_sync_nc),
		.dbg_A(dbgA_nc), .dbg_X(dbgX_nc), .dbg_Y(dbgY_nc), .dbg_S(dbgS_nc), .dbg_P(dbgP_nc) );

	// ---- the board bus ----
	wire ym_reset_n; wire [1:0] cpu_bank_nc;
	wire ym_cs, ym_a0, ym_we, ym_rd; wire [7:0] ym_dout, ym_din;
	wire pk_cs; wire [3:0] pk_addr; wire pk_we, pk_rd; wire [7:0] pk_dout, pk_din;
	wire mix_wr; wire [7:0] mix_data;
	wire ym_irq_w;
	vind_jsa_bus #(.MAME_FREERUN(MAME_FREERUN)) u_bus (
		.clk(clk), .reset(reset), .ce(ce_6502), .ce_jsa(ce_ym),
		.cpu_addr(cpu_a), .cpu_dout(cpu_do), .cpu_rnw(cpu_rwn), .cpu_din(cpu_di),
		.cpu_irq(cpu_irq), .ym_irq(ym_irq_w),
		.rom_wr(rom_wr), .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data),
		.scom_rdp(scom_rdp), .scom_wrp(scom_wrp), .scom_wrp_data(scom_wrp_data),
		.scom_cmd_data(scom_cmd_data), .scom_sfull(scom_sfull), .scom_nmi(scom_nmi),
		.coin1(coin1), .coin2(coin2), .self_test(self_test),
		.ym_reset_n(ym_reset_n), .coin_ctr1(coin_ctr1), .coin_ctr2(coin_ctr2),
		.cpu_bank(cpu_bank_nc),
		.ym_cs(ym_cs), .ym_a0(ym_a0), .ym_we(ym_we), .ym_rd(ym_rd),
		.ym_dout(ym_dout), .ym_din(ym_din),
		.pk_cs(pk_cs), .pk_addr(pk_addr), .pk_we(pk_we), .pk_rd(pk_rd),
		.pk_dout(pk_dout), .pk_din(pk_din),
		.mix_wr(mix_wr), .mix_data(mix_data) );

	// ---- 2F YM2151 + 2D YM3012 (jt51) ----
	wire signed [15:0] ym_l, ym_r, ym_l_lo_nc, ym_r_lo_nc;
	wire ym_sample_nc, ym_ct1, ym_ct2;
	vind_ym u_ym (
		.clk(clk), .reset(reset), .cen(ce_ym), .cen_p1(ce_6502), .ym_reset_n(ym_reset_n),
		.ym_cs(ym_cs), .ym_a0(ym_a0), .ym_we(ym_we), .ym_dout(ym_dout), .ym_din(ym_din),
		.sample(ym_sample_nc), .aud_left(ym_l), .aud_right(ym_r),
		.aud_left_lo(ym_l_lo_nc), .aud_right_lo(ym_r_lo_nc),
		.ct1(ym_ct1), .ct2(ym_ct2), .ym_irq(ym_irq_w) );

	// ---- 3K POKEY ----
	wire signed [10:0] pk_audio;
	vind_pokey u_pokey (
		.clk(clk), .reset(reset), .ena(ce_6502),
		.pk_cs(pk_cs), .pk_addr(pk_addr), .pk_we(pk_we), .pk_rd(pk_rd),
		.pk_dout(pk_dout), .pk_din(pk_din), .audio_out(pk_audio) );

	// ---- POKEY analogue output stage: R34 470 || C37 .047 + the C47 block ----
	wire signed [15:0] pk_filt;
	vind_pokey_out u_pk_out (
		.clk(clk), .reset(reset), .ce(ce_6502), .bypass(LPF_BYPASS),
		.pk_dac(pk_audio), .pk_out(pk_filt) );

	// ---- the /MIX analogue mixer (5F LS273B + the 5C/5D/5E 4066 gates) ----
	wire signed [15:0] mix_l, mix_r; wire lpf_engage;
	vind_jsa_mix u_mix (
		.clk(clk), .reset(reset), .mix_wr(mix_wr), .mix_data(mix_data),
		.ym_ct1(ym_ct1), .ym_ct2(ym_ct2),
		.ym_left(ym_l), .ym_right(ym_r), .pk_audio(pk_filt),
		.out_left(mix_l), .out_right(mix_r), .lpf_engage(lpf_engage) );

	// ---- the sheet-16 output low-pass, one per channel ----
	vind_jsa_lpf u_lpf_l (
		.clk(clk), .reset(reset), .ce(ce_6502), .engage(lpf_engage),
		.bypass(LPF_BYPASS), .in(mix_l), .out(aud_left) );
	vind_jsa_lpf u_lpf_r (
		.clk(clk), .reset(reset), .ce(ce_6502), .engage(lpf_engage),
		.bypass(LPF_BYPASS), .in(mix_r), .out(aud_right) );

	// ym_rd (the YM2151 /RD pin: jt51 has no read strobe, dout is continuous),
	// the ROM bank (internal to vind_jsa_bus), the T65 debug taps and jt51's
	// low-resolution outputs are all unused at this level.
	wire _unused_jsa = &{1'b0, ym_rd, cpu_bank_nc, cpu_sync_nc,
		dbgA_nc, dbgX_nc, dbgY_nc, dbgS_nc, dbgP_nc, ym_sample_nc,
		ym_l_lo_nc, ym_r_lo_nc};

endmodule
