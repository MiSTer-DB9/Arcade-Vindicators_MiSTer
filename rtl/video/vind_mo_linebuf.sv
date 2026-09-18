`timescale 1ns/1ps
//============================================================================
//  Vindicators — SP-317 sheet 10: the two Atari "LB" line-buffer customs 14D
//  (pixel/colour plane) and 14E (attribute plane), the 14F LS32 bank strobes,
//  the 16F LS32 intensity-kludge gates and the PAL16L8A at 17E (136059-1152)
//  that sequences them.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later.
//  Structure follows the Xybots core's `xybots_mo_linebuf.sv` (GPL-3.0).
//
//  ---------------------------------------------------------------------------
//  1. 17E = 136059-1152 -- a dumped PAL, implemented VERBATIM
//  ---------------------------------------------------------------------------
//  In the board's ACTIVE-LOW motion-object data convention:
//
//      PEN0    = MSD0 & MSD1 & MSD2 & MSD3          "pen == 0" (transparent)
//      NOTPEN0 = /MSD0 + /MSD1 + /MSD2 + /MSD3      "pen != 0"
//      PEN1    = /MSD0 & MSD1 & MSD2 & MSD3         "pen == 1" (the SHADE pen)
//      BIT1    = MSD0 & /MSD1 & MSD3                "pen bit1 set, bit0 and
//                                                    bit3 clear" (pen 2 or 6)
//      PRI6    = /MAT6                              "MO priority bit 6 set"
//
//      RSEL   (12) = RB1 XOR MCKR
//      RAMCLK (13) = /( [ PEN0 + LMPD + /P1 + RB1&/o15 + /RB1&/o14 ]
//                       & /RCLKA & /MCKR )
//      14E WE1(14) = /( P1 & /LMPD & /MCKR & /o15 & /o17 & NOTPEN0
//                     + PEN1 & PRI6 & /MCKR
//                     + BIT1 & PRI6 & /MCKR
//                     + RB1 & /MCKR )
//      14E WE0(15) = same with (/o14 & /o16) and  /RB1 & /MCKR
//      /WE1   (16) = /( P1 & PRI6' & /LMPD & /MCKR & /o15 & /o17 & NOTPEN0
//                     + PEN1 & PRI6 & /MCKR
//                     + RB1 & /MCKR )         [PRI6' = the MAT6 net HIGH]
//      /WE0   (17) = same with (/o14 & /o16) and  /RB1 & /MCKR
//      14E DI7(18) = MSD1 + MAT6      -> 18D LS373 Q2 = /STON
//      14E DI6(19) = MSD2 + MAT6      -> 18D LS373 Q5 = /STOFF
//
//  ---------------------------------------------------------------------------
//  2. THE ONE PLACE THE FUSE MAP CANNOT BE TAKEN LITERALLY
//  ---------------------------------------------------------------------------
//  Sheet 10 records 17E pin 1 as `21E LS08 (9,10 -> 8) = MCKR & FCLOCK`.
//  Every product term that uses pin 1 also contains `/MCKR`, so `P1 & /MCKR`
//  would be identically false and FOUR of the eight outputs would have no
//  pixel-dependent term at all.  The equations are therefore only consistent if
//  pin 1 is high during part of the /MCKR half of the pixel; the reading
//  adopted here is
//
//      P1 = /MCKR & FCLOCK
//
//  i.e. 21E is fed from the complementary MCKR buffer (an LS08 output with a
//  1 K pull-up is itself odd -- an open-collector LS09 would explain both).
//  Not settled by the schematic; it is the only reading under which the fuse
//  map is self-consistent.
//
//  With that reading the write conditions reduce to, in logical terms
//  (pen = ~MSD, pri6 = ~MAT6):
//
//      14D (pixel/colour plane) : (pen != 0 && !pri6 && !LMPD) || (pen == 1 && pri6)
//      14E (attribute plane)    : (pen != 0 && !LMPD)
//                                 || (pen == 1 && pri6) || (pen in {2,6} && pri6)
//
//  -- so a "special" object (priority bit 6) leaves the PIXEL plane untouched
//  ("no draw", MAME's `if (mopriority & 4) continue;`) but still deposits its
//  stain markers in the ATTRIBUTE plane.  /STON is exactly MAME's
//  `START_MARKER = (4 << PRIORITY_SHIFT) | 2` and /STOFF its `END_MARKER
//  = (4 << PRIORITY_SHIFT) | 4`.
//
//  The `RB1 & /MCKR` / `/RB1 & /MCKR` terms are the ping-pong bank steering:
//  they force the strobe pair of the bank currently being READ, which leaves
//  only the bank being WRITTEN gated by the pixel conditions.  RB1 = 1 means
//  bank 1 is displayed and bank 0 is filled.
//
//  ---------------------------------------------------------------------------
//  3. THE CUSTOM ITSELF
//  ---------------------------------------------------------------------------
//  A8..A0 = HPOS8..HPOS0, MDL_n loads bank n's WRITE pointer, MDR_n clears its
//  READ pointer (14F LS32: /MOL = /LD01 + RB, /MOR = /BUFCLR + RB), DOE = GND.
//  Reading clears -- there is no other clear anywhere and a buffer written on
//  line N and displayed on line N+1 must be empty for line N+2.  A location
//  that was never written reads all-ones = pen 0, colour 0 in the active-low
//  convention, which is the correct "no object here" idle value for 17D.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_mo_linebuf #(
	// ---- the LB custom's own output stage --------------------------------
	// The 40-pin Atari LB does not present the addressed cell straight on
	// DO7..DO0: Gauntlet builds the same buffer out of discrete counters and
	// '189s and still ends it in the "4W, 5W latches"
	// (`Arcade-Gauntlet_MiSTer/rtl/gauntlet/LINEBUF.vhd`,
	// `O_MPX <= RAM(slv_LB)`), and the SLAGS on sheet 9 carry a two-stage
	// output delay line of exactly the same kind (see vind_mo_fetch.sv).  How
	// many pixel clocks the custom's stage costs is not on the drawing, and it
	// is the ONE constant that sets where a line-buffer address lands on the
	// raster -- nothing else in the core reads these two buffers.  It is
	// measured the same way `vind_pf.sv`'s PFX_ALIGN is: at 1 the motion
	// objects land on MAME's `xpos = X - xscroll` in every frame capture, at 0
	// they are one pixel to the left.  Changing it moves the motion-object
	// layer alone.
	parameter int RD_OUT_DLY = 1
) (
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	// ---- 17E inputs ----
	input  logic  [3:0] msd,        // ACTIVE LOW
	input  logic  [6:0] mat,        // ACTIVE LOW
	input  logic        lmpd_n,
	input  logic        rb1,
	input  logic        rb0,
	input  logic        ld01_n,
	input  logic        bufclr_n,

	// ---- write address ----
	input  logic  [8:0] hpos,

	// ---- 14D read side, straight into 17D and the 13F/15F OR gates ----
	output logic  [7:0] lb,         // DO7..DO0, ACTIVE LOW
	// ---- 14E read side, latched by 18D LS373 on sheet 10 ----
	output logic        ston_n,
	output logic        stoff_n,
	output logic        mpr1,       // MAT5
	output logic        mpr0,       // MAT4
	output logic  [2:0] mog_data,   // 14E DO3..DO1 -> 18F LS173 -> MOG3..MOG1

	// ---- the column the read side is presenting ----
	output logic  [8:0] rd_hpos,

	// ---- 17E outputs, exported for inspection ----
	output logic        we14d,      // "the 14D write is happening this pixel"
	output logic        we14e
);

	localparam logic [7:0]  LB_EMPTY_D = 8'hFF;
	localparam logic [7:0]  LB_EMPTY_E = 8'hFF;

	// =====================================================================
	// 1. 17E, in the reduced logical form derived in the header
	// =====================================================================
	wire pen0    = &msd;                       // MSD0 & MSD1 & MSD2 & MSD3
	wire notpen0 = ~pen0;
	wire pen1    = ~msd[0] &  msd[1] &  msd[2] & msd[3];
	wire bit1    =  msd[0] & ~msd[1] &  msd[3];
	wire pri6    = ~mat[6];
	wire lmpd    = ~lmpd_n;

	assign we14d = (notpen0 & ~pri6 & ~lmpd) | (pen1 & pri6);
	assign we14e = (notpen0 & ~lmpd) | (pen1 & pri6) | (bit1 & pri6);

	// 17E pins 18 and 19 -- the stain markers, latched later by 18D.
	wire di7_14e = msd[1] | mat[6];            // -> /STON
	wire di6_14e = msd[2] | mat[6];            // -> /STOFF

	// 16F LS32: n = MAT6 + MSD3; DI3..DI1 = MAT3..MAT1 + n; DI0 = GND.
	wire n16f = mat[6] | msd[3];
	wire [2:0] di_lo_14e = {mat[3] | n16f, mat[2] | n16f, mat[1] | n16f};

	// =====================================================================
	// 2. Bank strobes (14F LS32) and the two pointers per bank
	// =====================================================================
	wire mol0_n = ld01_n   | rb0;
	wire mol1_n = ld01_n   | rb1;
	wire mor0_n = bufclr_n | rb0;
	wire mor1_n = bufclr_n | rb1;

	logic [8:0] wa0, wa1, ra0, ra1;

	// RB1 = 1 -> bank 1 is DISPLAYED, bank 0 is FILLED.
	wire rd0 = ~rb1;
	wire rd1 =  rb1;

	wire [8:0] ra0_nxt = !mor0_n ? 9'd0 : (rd0 ? (ra0 + 9'd1) : ra0);
	wire [8:0] ra1_nxt = !mor1_n ? 9'd0 : (rd1 ? (ra1 + 9'd1) : ra1);

	always_ff @(posedge clk) begin
		if (reset) begin
			wa0 <= '0; wa1 <= '0; ra0 <= '0; ra1 <= '0;
		end else if (ce_7m) begin
			wa0 <= mol0_n ? (wa0 + 9'd1) : hpos;
			wa1 <= mol1_n ? (wa1 + 9'd1) : hpos;
			ra0 <= ra0_nxt;
			ra1 <= ra1_nxt;
		end
	end

	// =====================================================================
	// 3. The stores -- 14D and 14E, two banks each
	// =====================================================================
	logic [7:0] d0 [0:511], d1 [0:511];
	logic [7:0] e0 [0:511], e1 [0:511];
	logic [7:0] qd0, qd1, qe0, qe1;

	wire [7:0] di_d = {mat[3:0], msd};                        // 14D DI7..DI0
	wire [7:0] di_e = {di7_14e, di6_14e, mat[5], mat[4], di_lo_14e, 1'b0};

`ifndef ALTERA_RESERVED_QIS
	initial begin
		for (int i = 0; i < 512; i++) begin
			d0[i] = LB_EMPTY_D; d1[i] = LB_EMPTY_D;
			e0[i] = LB_EMPTY_E; e1[i] = LB_EMPTY_E;
		end
	end
`endif

	wire       wr0   = rd0 ? (ra0_nxt != ra0) : we14d;
	wire       wr0e  = rd0 ? (ra0_nxt != ra0) : we14e;
	wire [8:0] aw0   = rd0 ? ra0 : wa0;
	wire       wr1   = rd1 ? (ra1_nxt != ra1) : we14d;
	wire       wr1e  = rd1 ? (ra1_nxt != ra1) : we14e;
	wire [8:0] aw1   = rd1 ? ra1 : wa1;

	always_ff @(posedge clk) if (ce_7m) begin
		if (wr0)  d0[aw0] <= rd0 ? LB_EMPTY_D : di_d;
		if (wr0e) e0[aw0] <= rd0 ? LB_EMPTY_E : di_e;
		qd0 <= d0[ra0_nxt];
		qe0 <= e0[ra0_nxt];
	end

	always_ff @(posedge clk) if (ce_7m) begin
		if (wr1)  d1[aw1] <= rd1 ? LB_EMPTY_D : di_d;
		if (wr1e) e1[aw1] <= rd1 ? LB_EMPTY_E : di_e;
		qd1 <= d1[ra1_nxt];
		qe1 <= e1[ra1_nxt];
	end

	// =====================================================================
	// 4. Output mux -- the LB customs' RSEL
	// =====================================================================
	wire [7:0] mux_d = rd1 ? qd1 : qd0;
	wire [7:0] mux_e = rd1 ? qe1 : qe0;
	wire [8:0] mux_a = rd1 ? ra1 : ra0;

	// The custom's output stage (see the RD_OUT_DLY note at the top).
	localparam int RD_N = (RD_OUT_DLY == 0) ? 1 : RD_OUT_DLY;
	logic [7:0] pd [RD_N];
	logic [7:0] pe [RD_N];
	logic [8:0] pa [RD_N];
	always_ff @(posedge clk) begin
		if (reset) begin
			for (int k = 0; k < RD_N; k++) begin
				pd[k] <= LB_EMPTY_D; pe[k] <= LB_EMPTY_E; pa[k] <= 9'd0;
			end
		end else if (ce_7m) begin
			pd[0] <= mux_d; pe[0] <= mux_e; pa[0] <= mux_a;
			for (int k = 1; k < RD_N; k++) begin
				pd[k] <= pd[k-1]; pe[k] <= pe[k-1]; pa[k] <= pa[k-1];
			end
		end
	end
	wire [7:0] dout_d = (RD_OUT_DLY == 0) ? mux_d : pd[RD_N-1];
	wire [7:0] dout_e = (RD_OUT_DLY == 0) ? mux_e : pe[RD_N-1];

	assign lb       = dout_d;
	assign ston_n   = dout_e[7];
	assign stoff_n  = dout_e[6];
	assign mpr1     = dout_e[5];
	assign mpr0     = dout_e[4];
	assign mog_data = dout_e[3:1];
	assign rd_hpos  = (RD_OUT_DLY == 0) ? mux_a : pa[RD_N-1];

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused = &{1'b0, dout_e[0], mat[6]};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
