//============================================================================
//  Vindicators (Atari Games, 1988) — JSA I audio PCB: the /MIX analog mixer.
//
//  Derived from `Arcade-Toobin_MiSTer/rtl/sound/toobin_jsa_mix.sv`
//  (Toobin' MiSTer core, GPL-3.0; same A043713 audio PCB).  The CT1/CT2 stereo
//  gating and the reciprocal-multiply arithmetic are Toobin's; the GAIN LAW and
//  the `lpf_engage` term are re-derived from SP-317 sheet 16 and differ from
//  both Toobin' and MAME (see below).
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- the register: 5F 74LS273B, clocked by /MIX ($2A06) ------------------
//    D7 SM2   speech volume bit 1  \  3D TMS5220C socket EMPTY on Vindicators:
//    D6 SM1   speech volume bit 0  /  latched, switches nothing
//    D5 PM2   POKEY  volume bit 1
//    D4 PM1   POKEY  volume bit 0
//    D3 YM2   YM2151 volume bit 2
//    D2 YM1   YM2151 volume bit 1
//    D1 YM0   YM2151 volume bit 0
//    D0 LPF   output low-pass enable
//  /CLR(1) = /POR, so every bit powers up at 0: muted, filter disengaged.
//
//  **The /MIX data does not come from the $2A06 write.**  5F's D inputs are
//  VO7..VO0, the outputs of the 3F LS374A /VOICE staging latch — /MIX only
//  clocks the transfer.  That staging register lives in vind_jsa_bus, which
//  feeds `mix_data` from it.  MAME (`atarijsa.cpp`) and the Toobin' RTL both
//  use the $2A06 write data instead; identical for this ROM because every
//  `STA $2A06` is immediately preceded by `STA $2A00` with the same A
//  ($42F2, $59D0, $5AC9 — the only three sites).
//
//  [ROM] the only two values this board ever writes are
//    $3C  SM=0 PM=3 YM=6 LPF=0     (from $42F2 and $5AC9)
//    $3F  SM=0 PM=3 YM=7 LPF=1     (from $59D0)
//  i.e. the POKEY volume is always maximum, and D0 (LPF) and D1 (YM0) are
//  always equal — which is why the R57/R58 "OR" question below is unobservable.
//
//  ---- gain law, from the resistors (SP-317 sheet 16) ----------------------
//  Left channel, virtual-earth sum into LM324 4B with feedback R43 12K:
//     YM CH2 through R62 7.5K (YM2), R64 15K (YM1), R63 30K (YM0)
//        -> gain = -12K*(YM2/7.5K + YM1/15K + YM0/30K)
//                = -0.4 * V_ym,   V_ym = 4*YM2 + 2*YM1 + YM0 = 0..7
//        -> full scale 2.8, exactly linear in the register field
//     PS through R65 12K gated by CT1 -> gain = -1.0 * CT1
//  Right channel: R69/R67/R68 + R66 gated by CT2 into R48 12K — identical.
//
//  PS itself (LM324 4A, feedback R38 47K):
//     POKEY through R70 75K (PM2) and R71 150K (PM1)
//        -> gain = -47K*(PM2/75K + PM1/150K) = -0.3133 * V_pk,  V_pk = 0..3
//        -> full scale 0.94.  (Speech uses R72/R73, the same law — dead here.)
//  The two inversions cancel, so both sources reach LAUD/RAUD in phase.
//
//  **Full-scale ratio YM : POKEY = 2.8 : 0.94 = 2.98 : 1** for equal chip
//  output amplitude.  MAME routes 0.60 : 0.40 = 1.5 : 1; the Toobin' and
//  Xybots cores normalise both to 1.0 = 1 : 1.  **This core implements the
//  resistors' 2.98 : 1** — the single biggest audible modelling gap in the
//  other two.
//
//  Scaling: the coefficients below are normalised so that YM at V_ym = 7 is
//  digital unity (divide the whole network by 2.8), which is the loudest
//  setting the ROM uses and keeps the YM path bit-identical to MAME's V/7.
//  POKEY then contributes 0.3133*V_pk/2.8 = 0.1119 per step, 0.3357 at V_pk=3.
//
//  ---- the one assumption: equal chip full scale ---------------------------
//  "2.98 : 1 for equal chip output amplitude" is a statement about VOLTS at
//  the YM3012 CH1/CH2 outputs and at the POKEY transimpedance output.  Neither
//  the YM3012's nor POKEY's absolute full-scale swing is given anywhere in
//  SP-317, so the two chips' analogue full scales are ASSUMED EQUAL and the
//  ratio is applied to equal DIGITAL full scales.  jt51's xleft/xright span
//  the full 16-bit signed range; POKEY.vhd's AUDIO_OUT is 11-bit signed
//  (0..2044 with the MSB inverted) which vind_pokey_out carries at <<4, i.e.
//  +/-16384 = HALF of 16-bit full scale.  `PK_FS_X2` therefore doubles the
//  POKEY path so the resistor ratio is applied to comparable amplitudes.
//  Set PK_FS_X2 = 0 to apply the ratio to the raw DAC scale instead (which
//  halves POKEY, giving an effective 5.96 : 1).  Not settled by the schematic:
//  which of the two the real board sounds like needs a hardware A/B.
//
//  ---- CT1 / CT2 -----------------------------------------------------------
//  Two INDEPENDENT gates: PS enters the left sum through R65 gated by CT1 and
//  the right sum through R66 gated by CT2 (YM2151 pins 8 and 9).  MAME's
//  update_all_volumes() multiplies both POKEY outputs by ct1 and ignores ct2,
//  which its own source flags as a known shortcut.  The Toobin' RTL models the
//  two gates correctly and is kept.
//
//  ---- lpf_engage ----------------------------------------------------------
//  `lpf` (D0) ALONE, not `lpf | ym_vol[0]`.  Sheet 16 draws the left Q5 base
//  as R58 1K from LPF "OR" R57 1K from YM0 while the right channel has only
//  R60 from LPF; this core reads "OR" as Atari's stuff-one-part-or-the-other
//  note (as on sheets 14 and 17), so R58 is stuffed and the channels stay
//  symmetric.  Not settled by the schematic, but unobservable on this ROM
//  (D0 == D1 in both values it writes).  See vind_jsa_lpf.
//============================================================================

module vind_jsa_mix #(
	parameter bit PK_FS_X2 = 1'b1   // 1 = equalise POKEY's 11-bit DAC full scale
	                                //     against jt51's 16-bit (see above)
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        mix_wr,        // /MIX strobe ($2A06)
	input  logic  [7:0] mix_data,      // VO7..VO0 from the 3F staging latch
	input  logic        ym_ct1,        // YM2151 CT1: PS -> LEFT  gate
	input  logic        ym_ct2,        // YM2151 CT2: PS -> RIGHT gate
	input  logic signed [15:0] ym_left,    // YM3012 CH2 -> LAUD
	input  logic signed [15:0] ym_right,   // YM3012 CH1 -> RAUD
	input  logic signed [15:0] pk_audio,   // from vind_pokey_out (filtered, DC-blocked)
	output logic signed [15:0] out_left,   // -> LAUD  (sheet 14 Q2, SPKR1, JSPK-5)
	output logic signed [15:0] out_right,  // -> RAUD  (sheet 14 Q1, SPKR2, JSPK-2)
	output logic               lpf_engage  // -> vind_jsa_lpf (both channels)
);

	logic [2:0] ym_vol; logic [1:0] pk_vol; logic [1:0] sp_vol; logic lpf;
	always_ff @(posedge clk) begin
		if (reset) begin
			ym_vol <= 3'd0; pk_vol <= 2'd0; sp_vol <= 2'd0; lpf <= 1'b0;
		end else if (mix_wr) begin
			sp_vol <= mix_data[7:6];   // SM2/SM1 — 3D socket empty, latched only
			pk_vol <= mix_data[5:4];
			ym_vol <= mix_data[3:1];
			lpf    <= mix_data[0];
		end
	end
	wire unused_speech = &{1'b0, sp_vol};   // the 5E legs exist; the TMS does not

	assign lpf_engage = lpf;

	// ---- gain coefficients, Q16 --------------------------------------------
	// YM  : (0.4 * V) / 2.8 = V/7          -> V * 9363   (Toobin's reciprocal)
	// POKEY: (0.3133 * V) / 2.8 * (1 or 2) -> V * 7334 or V * 14668
	//        0.3133/2.8 = 0.111905 -> Q16 7334.1;  x2 -> 14668.2
	// Precomputing volume*reciprocal keeps this to one multiply per source per
	// channel instead of a cascaded sample*volume then *reciprocal DSP chain.
	localparam signed [17:0] PK_STEP = PK_FS_X2 ? 18'sd14668 : 18'sd7334;

	logic signed [17:0] ym_gain;
	logic signed [17:0] pk_gain;
	always_comb begin
		case (ym_vol)
			3'd0: ym_gain = 18'sd0;
			3'd1: ym_gain = 18'sd9363;
			3'd2: ym_gain = 18'sd18726;
			3'd3: ym_gain = 18'sd28089;
			3'd4: ym_gain = 18'sd37452;
			3'd5: ym_gain = 18'sd46815;
			3'd6: ym_gain = 18'sd56178;
			default: ym_gain = 18'sd65541;      // 7*9363, i.e. digital unity
		endcase
		case (pk_vol)
			2'd0: pk_gain = 18'sd0;
			2'd1: pk_gain = PK_STEP;
			2'd2: pk_gain = PK_STEP <<< 1;
			default: pk_gain = (PK_STEP <<< 1) + PK_STEP;
		endcase
	end

	// YM channel: signed sample * the precombined coefficient.
	wire signed [33:0] ym_l_m = $signed(ym_left)  * $signed(ym_gain);
	wire signed [33:0] ym_r_m = $signed(ym_right) * $signed(ym_gain);
	wire signed [17:0] ym_l_s = 18'(ym_l_m >>> 16);
	wire signed [17:0] ym_r_s = 18'(ym_r_m >>> 16);

	// POKEY channel, gated INDEPENDENTLY into the two analogue sums by CT1/CT2.
	// The DAC scaling, the 7.2 kHz transimpedance pole and the C47 DC block all
	// happen upstream in vind_pokey_out, which is what stops these gates from
	// switching POKEY's silence offset in and out of the digital sum.
	wire signed [33:0] pk_l_m = ym_ct1 ? ($signed(pk_audio) * $signed(pk_gain)) : 34'sd0;
	wire signed [33:0] pk_r_m = ym_ct2 ? ($signed(pk_audio) * $signed(pk_gain)) : 34'sd0;
	wire signed [17:0] pk_l_s = 18'(pk_l_m >>> 16);
	wire signed [17:0] pk_r_s = 18'(pk_r_m >>> 16);

	// sum + saturate to 16-bit signed
	wire signed [18:0] sum_l = {ym_l_s[17], ym_l_s} + {pk_l_s[17], pk_l_s};
	wire signed [18:0] sum_r = {ym_r_s[17], ym_r_s} + {pk_r_s[17], pk_r_s};
	function automatic signed [15:0] sat16(input signed [18:0] v);
		if      (v >  19'sd32767)  sat16 =  16'sd32767;
		else if (v < -19'sd32768)  sat16 =  16'sh8000;
		else                       sat16 = v[15:0];
	endfunction

	always_ff @(posedge clk) begin
		out_left  <= sat16(sum_l);
		out_right <= sat16(sum_r);
	end

endmodule
