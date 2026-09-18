//============================================================================
//  Vindicators (Atari Games, 1988) - JSA I audio PCB: the output low-pass.
//  One per channel: the unity-gain Sallen-Key around LM324 4A on SP-317
//  sheet 16, with Q5/Q6 switching C54/C56 in.
//
//  Ported from `Arcade-Toobin_MiSTer/rtl/sound/toobin_jsa_lpf.sv`
//  (Toobin' MiSTer core, GPL-3.0; same A043713 audio PCB): the topology, the
//  R/C values and the derived (f, Q) for both states match SP-317 sheet 16
//  here as well.  The one change is the `engage` term - on Vindicators it is
//  /MIX D0 (LPF) ALONE.  That expression lives in vind_jsa_mix, not here.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- the hardware (SP-317 sheet 16, output low-pass filters) --------------
//
//   in --[R44 12K]--+--[R45 12K]--+-- (+) 4A >--+-- LAUD
//                   |             |             |
//                 C53 .0022 ------+             |   (feedback to the R44/R45 node)
//                                 |             |
//                          C55 .001 to AGND     +-- (-) 4A   (follower)
//                                 |
//                          C54 .0027 to AGND via Q5
//
//  Right channel, same parts: R47/R46, C58, C57, C56, Q6, R59, R60.
//  Q5/Q6 (2N3904) shunt C54/C56 to AGND, adding them in parallel with C55/C57
//  and dropping the corner.  With Q off, C54 sees R56 150K to AGND, which is
//  high against its own reactance in band, so it is effectively out of circuit.
//
//  For R1 = R2 = R:  w0 = 1/(R*sqrt(C1*C2)),  Q = 0.5*sqrt(C1/C2)
//
//    disengaged  C2 = C55        = 1.0 nF -> fc = 8941.9 Hz, Q = 0.7416
//    engaged     C2 = C55 + C54  = 3.7 nF -> fc = 4648.6 Hz, Q = 0.3855
//
//  w0/Q = 2/(R*C1) is independent of C2, so f*q is the same in both states
//  (0.0423) and only the frequency coefficient switches.
//
//  **Base drive - the one deviation from the Toobin' core.**  The left
//  channel's Q5 base is drawn as `R58 1K from LPF` "OR" `R57 1K from YM0`;
//  the right channel has only `R60 1K from LPF`.  Toobin' read "OR" as a logic
//  OR and used `engage = lpf | ym_vol[0]`.  This core reads it as Atari's
//  stuff-one-part-or-the-other note (the same annotation appears between the
//  ALTCLK/6K LS393 packages on sheet 17 and between R25/R26 on sheet 14), which
//  makes R58 the stuffed one and `engage = LPF` alone - otherwise the two
//  channels would be asymmetric.  Not settled by the schematic: which reading
//  is right needs a real-board A/B.  It is unobservable on this ROM, though:
//  the only /MIX values the Vindicators sound ROM ever writes are $3C (LPF=0,
//  YM0=0) and $3F (LPF=1, YM0=1), so D0 and D1 are always equal.
//
//  ---- realisation ---------------------------------------------------------
//  A Chamberlin state-variable filter clocked by ce (= ce_6502 = ce_pokey =
//  1.7897725 MHz).  An SVF rather than a direct-form biquad because fc/fs here
//  is 0.0026-0.0050: direct-form poles that close to z = 1 need far more
//  coefficient precision to stay accurate, while the SVF is parameterised
//  directly by the (f, Q) the schematic gives.
//
//    f = 2*sin(pi*fc/fs)   q = 1/Q   both Q16
//
//  Stability needs f*q < 2 and f < 2; both states sit at f*q = 0.0423.
//
//  bypass = 1 passes the input through untouched, for A/B against an
//  unfiltered mix (the always-on 8.9 kHz corner is audible, so it wants to be
//  verifiable).
//============================================================================

module vind_jsa_lpf
(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,             // ce_pokey: 1.7897725 MHz
	input  logic        engage,         // /MIX D0 (LPF) -- see vind_jsa_mix
	input  logic        bypass,
	input  logic signed [15:0] in,
	output logic signed [15:0] out
);

	// Q16 coefficients; see the derivation above.
	localparam signed [18:0] F_OPEN  = 19'sd2057;    // fc 8941.9 Hz
	localparam signed [18:0] Q_OPEN  = 19'sd88369;   // Q 0.7416
	localparam signed [18:0] F_SHUT  = 19'sd1070;    // fc 4648.6 Hz
	localparam signed [18:0] Q_SHUT  = 19'sd169981;  // Q 0.3855

	wire signed [18:0] f_c = engage ? F_SHUT : F_OPEN;
	wire signed [18:0] q_c = engage ? Q_SHUT : Q_OPEN;

	// State is Q16 with 18 integer bits: 2 bits of headroom over the 16-bit
	// sample so the (mild) resonant overshoot cannot wrap.
	localparam int SW = 34;
	logic signed [SW-1:0] lp, bp;

	wire signed [SW-1:0] in_q16 = {{(SW-32){in[15]}}, in, 16'sd0};

	// low  = low + f*band
	// high = in - low - q*band
	// band = band + f*high
	//
	// Evaluated across several clk_sys cycles rather than one.  ce fires once per
	// 32 clocks (ce_6502 = clk_sys/32 against the 57.272727 MHz fabric), so there
	// is no need to chain two 34-bit multiplies and three adds into a single
	// cycle -- doing so missed setup by 11.7 ns in Quartus on the Toobin' core,
	// on this module's own bp register.
	//
	// Pipelining rather than an SDC multicycle exception is deliberate: these
	// pipeline registers update on EVERY clock, so a blanket "this module only
	// moves on ce" exception would be false about precisely the registers it
	// would cover.  Everything settles within 3 clocks of a ce, against 32
	// available, and the values latched at ce are the same ones the single-cycle
	// form produced -- so the response is unchanged.
	logic signed [SW-1:0] f_bp_r, q_bp_r, hp_r, f_hp_r;

	wire signed [SW+18:0] f_bp = f_c * bp;
	wire signed [SW+18:0] q_bp = q_c * bp;
	always_ff @(posedge clk) begin
		f_bp_r <= SW'(f_bp >>> 16);
		q_bp_r <= SW'(q_bp >>> 16);
	end

	wire signed [SW-1:0] lp_nxt = lp + f_bp_r;
	wire signed [SW-1:0] hp     = in_q16 - lp_nxt - q_bp_r;
	always_ff @(posedge clk) hp_r <= hp;

	wire signed [SW+18:0] f_hp = f_c * hp_r;
	always_ff @(posedge clk) f_hp_r <= SW'(f_hp >>> 16);

	wire signed [SW-1:0] bp_nxt = bp + f_hp_r;

	always_ff @(posedge clk) begin
		if (reset) begin
			lp <= '0;
			bp <= '0;
		end else if (ce) begin
			lp <= lp_nxt;
			bp <= bp_nxt;
		end
	end

	// Saturate back to 16-bit; the headroom bits should never be in use, but a
	// wrap here would be a loud click rather than a quiet inaccuracy.
	wire signed [17:0] lp_int = lp[SW-1:16];
	function automatic signed [15:0] sat16(input signed [17:0] v);
		if      (v >  18'sd32767) sat16 =  16'sd32767;
		else if (v < -18'sd32768) sat16 =  16'sh8000;
		else                      sat16 =  v[15:0];
	endfunction

	assign out = bypass ? in : sat16(lp_int);

endmodule
