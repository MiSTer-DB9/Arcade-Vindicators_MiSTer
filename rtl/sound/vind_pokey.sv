//============================================================================
//  Vindicators (Atari Games, 1988) — JSA I audio PCB: POKEY (3K).
//
//  Ported from `Arcade-Toobin_MiSTer/rtl/sound/toobin_pokey.sv`
//  (Toobin' MiSTer core, GPL-3.0; same A043713 audio PCB) and re-checked
//  against SP-317 sheet 16.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- the hardware (SP-317 sheet 16) --------------------------------------
//    A3..A0(33-36) = SA3..SA0        D7..D0 = SD7..SD0
//    O2(7)  = 1790K (1.7897725 MHz — the same net as the 6502's O0)
//    CS0(30, active low) = /REST     CS1(31, active high) = SA10
//    R/W(32) = SR//W                 AUD(37) = the open-drain current output
//    IRQ(29) = **no connection** — the POKEY interrupt is NOT wired to the
//              6502 on this board, so nothing here drives cpu_irq.
//    P7..P0, K5..K0, KR1/KR2, BCK, OCK = unused; SID is only tied to SOD
//              through the normally-open solder pad SIOD.
//
//  Select = /REST low AND SA10 high -> $2C00-$2FFF, registers on SA3..SA0, so
//  $2C00-$2C0F mirrored every 16 bytes ($03F0 mirror).  That is exactly
//  complementary to the LS138's `!SA10` enable, so POKEY and the I/O strobes
//  can never collide.  Decoded in vind_jsa_decode.
//
//  ---- the wrapper ---------------------------------------------------------
//  Wiring mirrors the Atari System-1 AUDIO.vhd instantiation of this core
//  (CS = '1', CS_L = select, RW_L = r/w, ENA = clock enable, PIN = 0).  The
//  6502 runs at bus speed while POKEY consumes on ENA, so writes are latched
//  and held (CS_L = 0, RW_L = 0) until an ENA pulse takes them; reads present
//  the address directly (DOUT is the register file's own output).
//
//  `ena` is ce_6502 = clk_sys/32 = 1.7897725 MHz — the 1790K net, i.e. the
//  same enable the 6502 uses, exactly as the board wires it.
//============================================================================

module vind_pokey
(
	input  logic        clk,
	input  logic        reset,        // physical pin 30 path: /REST-driven RESET_L
	input  logic        ena,          // ce_6502 / ce_pokey = 1790K
	// bus side (from vind_jsa_bus)
	input  logic        pk_cs,
	input  logic  [3:0] pk_addr,
	input  logic        pk_we,
	input  logic        pk_rd,
	input  logic  [7:0] pk_dout,      // 6502 -> POKEY
	output logic  [7:0] pk_din,       // POKEY -> 6502
	// audio
	output logic signed [10:0] audio_out   // 4 channels x the 0..511 volume DAC
);

	// ---- write-pending bridge ----
	logic       wr_pend;
	logic [3:0] wr_a;
	logic [7:0] wr_d;
	always_ff @(posedge clk) begin
		if (reset) wr_pend <= 1'b0;
		else if (pk_cs & pk_we) begin wr_pend <= 1'b1; wr_a <= pk_addr; wr_d <= pk_dout; end
		else if (wr_pend & ena)  wr_pend <= 1'b0;
	end

	wire        rd_active = pk_cs & pk_rd;
	wire        cs_l = ~(wr_pend | rd_active);   // active-low select
	wire        rw_l = wr_pend ? 1'b0 : 1'b1;    // write while pending, else read
	wire  [3:0] addr = wr_pend ? wr_a : pk_addr;

	// DOUT_OE_L is the core's data-bus output enable; the 6502 read mux in
	// vind_jsa_bus already qualifies the POKEY lane with sel_pokey, so it is
	// deliberately left unconnected.
	/* verilator lint_off PINCONNECTEMPTY */
	POKEY u_pokey (
		.ADDR      (addr),
		.DIN       (wr_d),
		.DOUT      (pk_din),
		.DOUT_OE_L (),
		.RW_L      (rw_l),
		.CS        (1'b1),
		.CS_L      (cs_l),
		.AUDIO_OUT (audio_out),
		.PIN       (8'h00),
		.ENA       (ena),
		.RESET_L   (~reset),
		.CLK       (clk)
	);
	/* verilator lint_on PINCONNECTEMPTY */

endmodule
