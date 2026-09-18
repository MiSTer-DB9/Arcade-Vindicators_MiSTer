//============================================================================
//  Vindicators (Atari Games, 1988) - JSA I audio PCB: the POKEY output stage.
//
//  Ported from `Arcade-Toobin_MiSTer/rtl/sound/toobin_pokey_out.sv`
//  (Toobin' MiSTer core, GPL-3.0; same A043713 audio PCB) - the same parts
//  (R34 470, C37 .047, C47 .22) appear on SP-317 sheet 16 here.  The
//  arithmetic and the polarity argument below are Toobin's, verbatim.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- the hardware (SP-317 sheet 16, POKEY output stage) ------------------
//  POKEY (3K) pin 37 AUD is a current output and LM324 2B is wired as a
//  transimpedance stage around it - NOT as a voltage amplifier:
//
//                     R34 470  ||  C37 .047
//                  +---/\/\/\-----||------+
//                  |                      |
//   AUD (pin 37) --+---- pin 13 (-)       |
//                  |            \         |
//                C40 .001        >--------+---- pin 14 --[C47 .22]--> mixer
//                  |            /
//                 AGND    pin 12 (+)
//                              |
//                    VCC --[R36 10K]--+-- C39 .1 -- AGND
//
//  R36/C39 are the pin-12 DC reference and its AC bypass; they are NOT in the
//  signal path, so there is no 1/(2*pi*10K*0.1u) = 158 Hz pole and R36 is not
//  an input resistor setting a 470/10K voltage gain.  The one signal-path pole
//  is the feedback impedance:
//
//    Vout(s) = Vref - I_AUD(s) * 470 / (1 + s*470*47nF)
//    tau = 470 * 47nF = 22.09 us  ->  fc = 7204 Hz
//
//  C40 .001 shunts the AUD node and adds a little ultrasonic loading against
//  POKEY's output impedance; it is not what shapes the audible response, so
//  the defensible first-order model is the R34/C37 pole alone.
//
//  C47 .22 AC-couples the stage into the volume DAC (R70 75K / R71 150K into
//  the PS summing node), i.e. roughly a 5-15 Hz high-pass.  Modelling it
//  matters beyond tone: the POKEY DAC reads -1024 at silence (POKEY.vhd
//  converts the unsigned channel sum to signed by inverting the MSB), so
//  without the DC block every CT1/CT2 transition in the mixer would step a
//  large offset in and out of the digital sum.  On the board C47 removes that
//  before the 5C/5D gates ever see it.
//
//  POLARITY: not inverted here, and the schematics say that is correct.
//  Counting inverting stages from each chip to LAUD (sheets 16 and 14):
//
//    POKEY : 2B transimpedance (inv) -> PS amp 4A (inv) -> main sum 4B (inv)
//            -> 4A Sallen-Key (non-inv)                          = 3, inverted
//    YM2151: YM3012 CH2 -> LM324 4B unity follower (non-inv)
//            -> main sum 4B (inv) -> 4A Sallen-Key (non-inv)     = 1, inverted
//
//  Two inversions apart, i.e. even, so the two sources arrive in phase.  In
//  this mixer a rising POKEY sum and a positive YM sample both push the sum
//  up, which is the same relationship.  Inverting this module would break it.
//
//  Runs on ce (= ce_6502 = ce_pokey = 1.7897725 MHz).
//============================================================================

module vind_pokey_out
(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,                    // ce_pokey
	input  logic        bypass,                // 1 = raw DAC <<9, no filtering
	input  logic signed [10:0] pk_dac,         // POKEY AUDIO_OUT
	output logic signed [15:0] pk_out          // -> vind_jsa_mix
);

	localparam int SW = 34;                    // Q16, 18 integer bits

	// 11-bit DAC into the 16-bit mix range, then Q16 for the filter state.  The
	// shift is 4 rather than the 9 the old 6-bit DAC used, which keeps silence at
	// -16384 and full scale unchanged -- only the volume-step spacing changed.
	wire signed [15:0] x       = {{1{pk_dac[10]}}, pk_dac, 4'd0};
	wire signed [SW-1:0] x_q16 = {{(SW-32){x[15]}}, x, 16'd0};

	// ---- transimpedance pole: one-pole low-pass at 7204 Hz ----
	// a = exp(-2*pi*fc/fs) = 0.9750214 at fs = 1789772.5 Hz, so K = 1-a in Q16.
	// K = 1637 gives fc = 7204.4 Hz, within 0.01% of the target.
	// The product is registered for the same reason as in vind_jsa_lpf: ce is
	// one clock in 32 (ce_6502 = clk_sys/32), so the multiply gets its own cycle
	// rather than sharing one with the adds either side of it.
	localparam signed [11:0] K_LP = 12'sd1637;
	logic signed [SW-1:0]    lp;
	wire signed [SW-1:0]     lp_err = x_q16 - lp;
	wire signed [SW+11:0]    lp_inc = K_LP * lp_err;
	logic signed [SW-1:0]    lp_inc_r;
	always_ff @(posedge clk) lp_inc_r <= SW'(lp_inc >>> 16);
	wire signed [SW-1:0]     lp_nxt = lp + lp_inc_r;

	// ---- C47 DC block ----
	// The DC estimate is a very slow one-pole; a shift of 15 puts its corner at
	// 2^-15 * fs / (2*pi) = 8.69 Hz, inside the 4.8-14.5 Hz the analog network
	// spans as the PM1/PM2 switches change the load, and it needs no multiplier.
	wire signed [SW-1:0]  dc_nxt = dc + ((lp_nxt - dc) >>> 15);
	logic signed [SW-1:0] dc;

	always_ff @(posedge clk) begin
		if (reset) begin
			lp <= '0;
			dc <= '0;
		end else if (ce) begin
			lp <= lp_nxt;
			dc <= dc_nxt;
		end
	end

	wire signed [SW-1:0] acf = lp - dc;
	wire signed [17:0]   acf_int = acf[SW-1:16];
	wire _unused_acf = &{1'b0, acf[15:0]};   // Q16 fraction, deliberately dropped

	function automatic signed [15:0] sat16(input signed [17:0] v);
		if      (v >  18'sd32767) sat16 =  16'sd32767;
		else if (v < -18'sd32768) sat16 =  16'sh8000;
		else                      sat16 =  v[15:0];
	endfunction

	assign pk_out = bypass ? x : sat16(acf_int);

endmodule
