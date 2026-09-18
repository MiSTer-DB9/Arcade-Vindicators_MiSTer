`timescale 1ns/1ps
//============================================================================
//  Vindicators main CPU wrapper — MC68010 at 5D, SP-317 sheet 4.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  Derived from the
//  Toobin' MiSTer core's `toobin_cpu.sv` (GPL-3.0) — the same TG68K 68010
//  configuration, the same `cpu_cen` pacing and the same IPL synchroniser.
//  GPL-3.0-or-later; see LICENSE.
//
//  The part on the board is a **68010** (sheet 4, 64-pin DIP at 5D, CLK =
//  RCLKA = 7.15909 MHz).  The core uses TG68K in 68010 mode (`CPU = "01"`,
//  TG68K.vhd's own default) rather than fx68k: the program uses no 68010-only
//  instruction, but the board has a 68010, on which `CLR <mem>` is write-only,
//  and fx68k (a cycle-exact 68000) would get that wrong on the bus.
//
//  TG68K polarities (TG68K.vhd): AS/UDS/LDS active low, RW 1 = read,
//  IPL active low ("111" = none), DTACK active low, RESET/HALT active low.
//  This wrapper presents the sheet's own active-high `BAS` and an active-high
//  `dtack` to the rest of the main board, and A23..A1 with **no A0** — there
//  is no A0 pin on a 68010 and none anywhere on this board; the byte lane is
//  /UDS //LDS and nothing else (sheet 4).
//
//  ---- how the sheet-4 sequencer is honoured -----------------------------
//  TG68K's bus is NOT cycle-exact.  Its bus state machine advances one state
//  per `cpu_cen` tick through S_state 00 -> 01 -> 10 -> 11, i.e. a **4
//  RCLKA-clock** minimum bus cycle, which is the right shape for a 68000-family
//  read/write, but the internal S1..S7 phases do not line up with a real part.
//  What it DOES honour exactly is the wait-state count:
//
//    * `/AS`, `/UDS`, `/LDS` and `R//W` are driven from a `cpu_cen`-gated
//      state machine, so every strobe edge lands on an RCLKA boundary — the
//      same edges the 8D LS163A samples (`vind_dtack`, /CLR = BAS,
//      CK = RCLKA).
//    * TG68K samples `DTACK` on the FALLING clock edge while in S_state "10"
//      and stays there for as long as it reads inactive.  One extra RCLKA in
//      the LS163A therefore becomes exactly one extra RCLKA of bus cycle, so
//      the sheet's table maps one-for-one: 0 waits for ROM and the write
//      strobes, **1** for /EEPROM, **stall until PVCPU** for /VRAM, **stall
//      until EWAI** for /COM (released on a 2-RCLKA quantum by the QB
//      feedback), and DTACK suppressed for 8 RCLKA on a /VPA cycle.
//    * The wait states therefore appear where the board puts them and last as
//      long as the board makes them last; what is NOT reproduced is the
//      sub-cycle placement of the strobes inside those four clocks.  Nothing
//      on this board looks at that: every terminator is /DTACK off the LS163A,
//      /BERR is tied high (no timeout), and the video side re-times its own
//      accesses through PVCPU / EWAI.
//
//  ---- /VPA and autovectors ----------------------------------------------
//  Sheet 4: `/VPA = ~(BAS & FC0 & FC1 & FC2)`, so every interrupt
//  acknowledge is autovectored.  TG68K's kernel is instantiated with
//  `IPL_autovector => '1'` **unconditionally** (TG68K.vhd line 163), so it
//  always autovectors — which is the board's behaviour.  Its `VPA` input then
//  only decides when the acknowledge cycle TERMINATES.
//
//  **/VPA must be connected on this board.**  The sheet-4 counter loads
//  {D,C,B,A} = {/VPA, Cin, Bin, /EEPROM} = 0111 on an acknowledge cycle, and
//  because /LD = QC the count 0111 -> 1000 immediately drops QC and RELOADS
//  0111 — so RCO, and therefore /DTACK, **never asserts during a /VPA cycle**
//  (verified in simulation; the sheet's own wait-state table prints "8" there,
//  which is arithmetic that ignores the /LD = QC feedback, while its prose says
//  DTACK is suppressed for the whole VPA cycle).  With `USE_VPA` clear the CPU
//  would hang on the first interrupt, so the default is SET.
//
//  What is not exact: TG68K ends a VPA cycle at the next `sync9` of a divider
//  that is NOT `cpu_cen`-gated, i.e. within ~20 clk_sys ~ 2.5 RCLKA, where a
//  real 68010 takes 10-19 clocks synchronised to E.  The acknowledge cycle is
//  therefore SHORTER here than on the board.  Nothing observes it: the
//  autovector number, the stacked frame and the handler entry are unaffected.
//
//  ---- reset --------------------------------------------------------------
//  /SYSRES reaches both `HALT` (pin 17, via R71 1 k) and `RESET` (pin 18, via
//  R72 1 k), so they are one net here.  TG68K does not export `nResetOut`, so
//  a `RESET` *instruction* is invisible to this core; on the board it would
//  pull the same net low and re-lock the EEPROM.  The program image contains
//  no `RESET` instruction, so nothing observable is lost.
//============================================================================

module vind_cpu #(
	// 1 = route the decoded /VPA into TG68K's VPA pin.  MUST stay 1: the
	// sheet-4 counter never produces DTACK on an acknowledge cycle (header).
	parameter bit USE_VPA = 1'b1
)(
	input  logic        clk,        // clk_sys 57.272727 MHz
	input  logic        ce_7m,      // RCLKA enable, clk_sys / 8 = 7.15909 MHz
	input  logic        reset,      // active high: /SYSRES asserted, or init
	input  logic  [2:0] ipl,        // {IPL2,IPL1,IPL0}, ACTIVE LOW (111 = none)
	input  logic        vpa_n,      // 20E LS00 output

	// ---- the 68010 bus, sheet-4 polarity ----
	output logic [23:1] a,
	output logic [15:0] dout,
	input  logic [15:0] din,
	output logic        as,         // BAS: ACTIVE HIGH copy of /AS (6D LS04)
	output logic        as_n,
	output logic        uds_n,
	output logic        lds_n,
	output logic        rw,         // R//W, 1 = read
	input  logic        dtack,      // ACTIVE HIGH (= ~/DTACK)
	output logic  [2:0] fc,
	output logic        vma_n       // 68010 pin 19; unused on this board
);

	wire [31:0] tg_addr;
	wire        tg_as_n, tg_uds_n, tg_lds_n, tg_rw, tg_vma, tg_e;

	// ---- IPL synchronisation (carried over from toobin_cpu.sv) -----------
	// TG68K captures IPL into `cpuIPL` on the FALLING edge of CLK (gated by
	// cpu_cen).  Two flops, the second deliberately on the NEGEDGE, so the long
	// path into that capture is a full negedge->negedge period rather than a
	// posedge->negedge half period at 57 MHz.  The half cycle that remains is a
	// bare flop-to-flop hop with no logic in it.  The extra 1/2 clk_sys of
	// latency is invisible at the RCLKA/8 sampling rate.
	logic [2:0] ipl_r, ipl_rn;
	always_ff @(posedge clk) begin
		if (reset) ipl_r <= 3'b111;
		else       ipl_r <= ipl;
	end
	always_ff @(negedge clk) begin
		if (reset) ipl_rn <= 3'b111;
		else       ipl_rn <= ipl_r;
	end

	// The TG68K kernel's ADDR is a long combinational function of its register
	// file (the effective-address adder) and reached the decoders and the EEPROM
	// BRAM with ~20 ns of logic -- 3 ns over the 57 MHz period.  A 68000-family
	// address is stable for the whole bus cycle and the wrapper asserts /AS at
	// least 1.5 clk_sys after the kernel update (TG68K.vhd, cpu_cen_f), so a
	// one-clk_sys registered copy is still valid before /AS falls.  A timing
	// fix only: the bus behaviour is unchanged.
	logic [23:1] a_q;
	always_ff @(posedge clk) a_q <= tg_addr[23:1];
	assign a     = a_q;
	assign as_n  = tg_as_n;
	assign as    = ~tg_as_n;          // 6D LS04 (1 -> 2): BAS
	assign uds_n = tg_uds_n;
	assign lds_n = tg_lds_n;
	assign rw    = tg_rw;
	assign vma_n = tg_vma;

	// CPU generic defaults to "01" (68010) in TG68K.vhd; the ghdl-generated
	// netlist bakes it in, so it is not overridden here (works for both).
	TG68K u_tg68k (
		.CLK    (clk),
		.cpu_cen(ce_7m),
		.RESET  (~reset),             // 68010 pin 18, /SYSRES via R72
		.HALT   (~reset),             // 68010 pin 17, /SYSRES via R71
		.BERR   (1'b0),               // pin 22 tied to PR3: no bus-error timeout
		.IPL    (ipl_rn),
		.ADDR   (tg_addr),
		.FC     (fc),
		.DATAI  (din),
		.DATAO  (dout),
		.AS     (tg_as_n),
		.UDS    (tg_uds_n),
		.LDS    (tg_lds_n),
		.RW     (tg_rw),
		.DTACK  (~dtack),             // active low into TG68K
		.E      (tg_e),               // pin 20, unused output on this board
		.VPA    (USE_VPA ? vpa_n : 1'b1),
		.VMA    (tg_vma)
	);

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_cpu = &{1'b0, tg_addr[31:24], tg_addr[0], vpa_n, tg_e};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
