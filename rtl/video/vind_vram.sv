`timescale 1ns/1ps
//============================================================================
//  Vindicators — SP-317 sheet 6 (`VRAM`): the four 8Kx8 static RAMs, the six
//  74LS253 + 3J LS257A address multiplexers, the CPU read/write path, the
//  6F LS174C / 11F LS175A pipeline registers and the 7L/7J LS378 MO link
//  register.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Structure follows the Xybots MiSTer core's video blocks
//  (GPL-3.0); every equation here is Vindicators' own and cited to sheet 6.
//
//  ---------------------------------------------------------------------------
//  1. THE ARRAY
//  ---------------------------------------------------------------------------
//  1M/2M carry VRD15..VRD8, 2N/1N carry VRD7..VRD0; `VRA14` and `/VRA14` are
//  the two banks' CS2 and `VRA13..VRA1` are A12..A0, so the store is
//  16384 x 16 addressed by VRA14:VRA1 and VRAn == 68010 byte-address bit n.
//  `VRA15` lands on pin 1, a NO-CONNECT on the fitted 8Kx8 parts -- that is the
//  hardware origin of MAME's `.mirror(0x8000)`, and it also makes `PRBK`
//  (sheet 3's 0x360010 bit CD3) functionally dead.  Both facts are modelled by
//  simply not decoding VRA15.
//
//      VRA14 VRA13   region                       byte range
//        0     0     playfield  64x64 words       0x3F0000-0x3F1FFF
//        0     1     motion objects 1024x4 words  0x3F2000-0x3F3FFF
//        1     0     alphanumerics 64x32 words    0x3F4000-0x3F4FFF
//        1     1     CPU work RAM                 0x3F6000-0x3F7FFF
//
//  ---------------------------------------------------------------------------
//  2. THE FOUR CLIENTS
//  ---------------------------------------------------------------------------
//  VAS1:VAS0 = 00 playfield, 01 motion object, 10 alpha, 11 CPU.  The video
//  side drives VRA14:VRA13 = VAS1B:VAS0 (3J LS257A section 3/4), so each client
//  lands in its own 8 KB quadrant, and the six LS253s pick VRA12..VRA1:
//
//    PF     {PF256H..PF8H, PF256V..PF8V}   column-major 64x64  (TILEMAP_SCAN_COLS)
//    MO     {LNK9..LNK0, MC1, MC0}          4 CONSECUTIVE words per entry
//    alpha  {0, 128V..8V, 256H..8H}         row-major 64 x 32
//    CPU    MA12..MA1
//
//  ---------------------------------------------------------------------------
//  3. NXLDL -- THE SLIP FETCH
//  ---------------------------------------------------------------------------
//  NXLDL tri-states VRA11..VRA7 (the 6L/5L/6J chain's /G) and RP2 pulls them to
//  1, i.e. the alpha ROW index is forced to 31.  In the same cycle VAS1A goes
//  low (18L LS08 = /NXL & PVAS1), so the LOW mux selects C0 = PF256V..PF8V.
//  The address is therefore 0x3F4F80 + 2*(PFV >> 3): one SLIP entry per eight
//  scanlines, following the PLAYFIELD's vertical scroll.
//
//  ---------------------------------------------------------------------------
//  4. THE CPU SLOT
//  ---------------------------------------------------------------------------
//      7D LS02 : n     = ~(DTACK + /VRAM)
//      9F LS11 : PVCPU = PVAS0 & PVAS1 & n          -> sheet 4's wait counter
//      6F      : VCPU  = registered PVCPU
//      20F LS32: /VRAMRD = /VRAM + W//R
//      20E LS00: VR//W   = ~(W//R & VCPU)
//      17F LS04: VW//R   = ~VR//W
//      5F  S32 : /VUWE   = RCLKA + VR//W + /UDS
//                /VLWE   = RCLKA + VR//W + /LDS
//  The '373s (3L/3K) are transparent while VCPU is high and latch on its
//  falling edge; the '244s (4L/4K) drive VRD for the whole write slot and the
//  RAM WE pulse is the low half of RCLKA.  In this single-clock model the whole
//  CPU access is performed in the ce_7m cycle in which VCPU is high.
//
//  ---------------------------------------------------------------------------
//  5. /CLRAM
//  ---------------------------------------------------------------------------
//      VCPU = 1 : /CLRAM = MA16      -> CRAM at A16 == 0, VRAM at A16 == 1
//      VCPU = 0 : /CLRAM = PR3 = 1   -> VRAM permanently enabled for the video
//  and /PRAM = ~/CLRAM (17F LS04).
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_vram (
	input  logic        clk,          // clk_sys 57.272727 MHz
	input  logic        ce_7m,        // RCLKA / RCLKB / FCLOCK rate
	input  logic        reset,

	// ---- SYNGEN taps (sheet 6) ----
	input  logic  [8:0] h,            // 1H..256H
	input  logic  [7:0] v,            // 1V..128V
	input  logic        vrac2,        // SYNGEN pin 22 "C2"  -> 6F D3
	input  logic        pnxl_n,       // SYNGEN pin 21 "/PNXL" -> 11F D3
	input  logic        h_4hd2h_n,    // SYNGEN pin 36 "/4HDD" -> 11F D2

	// ---- slot selector from the sheet-8 PAL 7N (one RCLKA ahead) ----
	input  logic        pvas0,
	input  logic        pvas1,
	input  logic  [1:0] mc,           // MC1:MC0, the MO word counter
	input  logic        link_n,       // 4J LS139 Y3 -> 7L/7J LS378 /E

	// ---- playfield / alpha address sources (sheets 7) ----
	input  logic  [5:0] pf_h,         // PF256H..PF8H  (PFHS custom)
	input  logic  [8:0] pf_v,         // PF256V..PF1V  (19K/11L/13L counters)

	// ---- CPU side (the raw 68010 bus, NOT the common bus -- sheet 6) ----
	input  logic [16:1] ma,           // MA1..MA16, buffered by 3D/3E LS244
	input  logic [15:0] cpu_dout,
	input  logic        vram_n,       // sheet 4 4J LS139 Y3   (0x3E0000-0x3FFFFF)
	input  logic        w_r,          // sheet 4 24D LS04 pin 4 (1 = write)
	input  logic        uds_n,
	input  logic        lds_n,
	input  logic        dtack,
	output logic        pvcpu,        // -> sheet 4's DTACK wait term
	output logic [15:0] cpu_vram_din, // the 3L/3K LS373 latch, gated by /VRAMRD
	output logic        vramrd_n,

	// ---- colour-RAM select, exported to sheet 10 ----
	output logic        clram_n,
	output logic        pram_n,
	output logic        vuwe_n,       // CRAM/VRAM upper byte write strobe
	output logic        vlwe_n,       // ... lower byte
	output logic        vw_r,         // RAM /OE: 1 during the CPU write slot

	// ---- the sheet-6 pipeline nets everything else consumes ----
	output logic  [1:0] vas,          // {VAS1B, VAS0}
	output logic        vas1a,
	output logic        vcpu,
	output logic        nxldl,
	output logic        h03,          // 6F Q2
	output logic        gld_n,        // 11F /Q4
	output logic        nxl,          // 11F /Q3
	output logic        nxl_n,        // 11F  Q3
	output logic        board_4h,     // 11F /Q1  (== h[2], see the header note)
	output logic        board_4h_n,   // 11F  Q1
	output logic        h4d3,         // 11F /Q2

	// ---- VRAM read data and the MO link register ----
	output logic [15:0] vrd,
	output logic  [9:0] lnk
);

	// =====================================================================
	// 1. 11F 74LS175A -- CK = RCLKA, /CLR = PR3 (never cleared)
	// =====================================================================
	//   D1 = 4HD3   -> Q1 = /4H , /Q1 = 4H
	//   D2 = /4HDD  -> /Q2 = 4HD3
	//   D3 = /PNXL  -> Q3 = /NXL , /Q3 = NXL
	//   D4 = H03    -> /Q4 = /GLD
	logic q1_11f, q2_11f, q3_11f, q4_11f;
	always_ff @(posedge clk) begin
		if (reset) begin
			q1_11f <= 1'b1; q2_11f <= 1'b1; q3_11f <= 1'b1; q4_11f <= 1'b0;
		end else if (ce_7m) begin
			q1_11f <= h4d3;
			q2_11f <= h_4hd2h_n;
			q3_11f <= pnxl_n;
			q4_11f <= h03;
		end
	end
	assign board_4h_n =  q1_11f;
	assign board_4h   = ~q1_11f;
	assign h4d3       = ~q2_11f;
	assign nxl_n      =  q3_11f;
	assign nxl        = ~q3_11f;
	assign gld_n      = ~q4_11f;

	// =====================================================================
	// 2. 7D LS02 + 9F LS11 -- the CPU's grant
	// =====================================================================
	wire cpu_wants = ~(dtack | vram_n);        // 7D LS02 (11,12 -> 13)
	assign pvcpu = pvas0 & pvas1 & cpu_wants;  // 9F LS11 (1,2,13 -> 12)

	// =====================================================================
	// 3. 6F 74LS174C -- CK = RCLKA, /CLR = PR3
	// =====================================================================
	wire d_vas1a = nxl_n & pvas1;              // 18L LS08 (4,5 -> 6)

	logic vas1b, vas0;
	always_ff @(posedge clk) begin
		if (reset) begin
			h03 <= 1'b0; nxldl <= 1'b0; vas1a <= 1'b0;
			vas1b <= 1'b0; vas0 <= 1'b0; vcpu <= 1'b0;
		end else if (ce_7m) begin
			h03   <= vrac2;
			nxldl <= nxl;
			vas1a <= d_vas1a;
			vas1b <= pvas1;
			vas0  <= pvas0;
			vcpu  <= pvcpu;
		end
	end
	assign vas = {vas1b, vas0};

	// =====================================================================
	// 4. Address multiplexers
	// =====================================================================
	// The LOW group (VRA6..VRA1, "select A") uses VAS1A as SB; the HIGH group
	// (VRA12..VRA7, "select B") uses VAS1B.  They differ only during the NXLDL
	// cycle, where VAS1A is forced low so the low mux reads the C0 (playfield)
	// column while the high mux is tri-stated to all-ones by RP2.
	wire [1:0] sel_lo = {vas1a, vas0};
	wire [1:0] sel_hi = {vas1b, vas0};

	// VRA6..VRA1 -- 5K/6K/5J, /G tied to GND (never tri-stated)
	wire [5:0] vra_lo = (sel_lo == 2'b00) ? pf_v[8:3]        // PF256V..PF8V
	                  : (sel_lo == 2'b01) ? {lnk[3:0], mc}   // LNK3..0, MC1, MC0
	                  : (sel_lo == 2'b10) ? h[8:3]           // 256H..8H
	                  :                     ma[6:1];
	// VRA12..VRA7 -- 6J/5L/6L (6L's C2 input is tied to GND)
	wire [5:0] vra_hi = (sel_hi == 2'b00) ? pf_h             // PF256H..PF8H
	                  : (sel_hi == 2'b01) ? lnk[9:4]
	                  : (sel_hi == 2'b10) ? {1'b0, v[7:3]}   // 128V..8V
	                  :                     ma[12:7];

	// 6L LS253F's /2G is tied to GND, so VRA12 is never tri-stated by NXLDL;
	// VRA11..VRA7 are, and RP2 then pulls them to 1 (alpha row 31).
	wire       vra12  = vra_hi[5];
	wire [4:0] vra_11_7 = nxldl ? 5'b11111 : vra_hi[4:0];

	// 3J LS257A -- SEL = VCPU selects the B (CPU) inputs
	wire       vra14 = vcpu ? ma[14] : vas1b;
	wire       vra13 = vcpu ? ma[13] : vas0;
	assign     clram_n = vcpu ? ma[16] : 1'b1;      // PR3 = 1 in a video slot
	assign     pram_n  = ~clram_n;                  // 17F LS04 (3->4)

	wire [13:0] vaddr = {vra14, vra13, vra12, vra_11_7, vra_lo};

	// =====================================================================
	// 5. CPU data path and byte-write strobes
	// =====================================================================
	assign vramrd_n = vram_n | w_r;                 // 20F LS32 (1,2 -> 3)
	wire   vr_w_n   = ~(w_r & vcpu);                // 20E LS00 (9,10 -> 8)
	assign vw_r     = ~vr_w_n;                      // 17F LS04 (9 -> 8)

	// 5F S32: /VUWE = RCLKA + VR//W + /UDS.  The RCLKA term only shapes the
	// pulse INSIDE the slot, so in this model the strobe is the whole ce_7m
	// cycle of the CPU slot.
	assign vuwe_n = vr_w_n | uds_n;
	assign vlwe_n = vr_w_n | lds_n;

	// A CPU VRAM write lands only when /PRAM is low (A16 == 1); with A16 == 0
	// the same strobes drive the colour RAM on sheet 10.
	wire cpu_vram_cycle = vcpu & ~pram_n;
	wire we_hi = cpu_vram_cycle & ~vuwe_n & ce_7m;
	wire we_lo = cpu_vram_cycle & ~vlwe_n & ce_7m;

	// =====================================================================
	// 6. The store -- one synchronous 16384 x 16 block with byte lanes
	// =====================================================================
	logic [7:0] ram_hi [0:16383];
	logic [7:0] ram_lo [0:16383];
	logic [15:0] q;

`ifndef ALTERA_RESERVED_QIS
	initial begin
		for (int i = 0; i < 16384; i++) begin
			ram_hi[i] = 8'h00;
			ram_lo[i] = 8'h00;
		end
	end
`endif

	// THE READ IS CLOCKED AT clk_sys, NOT AT ce_7m, AND THAT IS THE WHOLE POINT.
	// On the board this is ASYNCHRONOUS static RAM (four 8Kx8/70): during the
	// pixel in which VAS/MC/LNK select a word, VRD already carries it, and every
	// consumer latches it on the RCLK edge that ENDS that pixel.  A read
	// registered on ce_7m would make `vrd` one pixel late, which is survivable
	// for the alpha and playfield latches but NOT for the motion-object list
	// walk: LNK is both a consumer of VRD and a producer of the next address,
	// so a late LNK pairs each entry's vertical match with the NEXT entry's
	// link and the engine fetches the wrong object's words 0 and 1.
	//
	// clk_sys is 8x the pixel clock, so the address (registered on ce_7m) is
	// stable for eight clk_sys cycles and a plain registered-read BRAM delivers
	// the word within the same pixel, with seven cycles to spare.  Consumers
	// still latch on ce_7m, so they see exactly what the board's '273s see.
	always_ff @(posedge clk) begin
		if (we_hi) ram_hi[vaddr] <= cpu_dout[15:8];
		if (we_lo) ram_lo[vaddr] <= cpu_dout[7:0];
		q <= {ram_hi[vaddr], ram_lo[vaddr]};
	end

	assign vrd = q;

	// 3L/3K LS373: TRANSPARENT while VCPU is high, latched on its falling edge,
	// driven onto D15:0 while /VRAMRD is low.  Transparent is the operative
	// word: `q` is clk_sys-registered (section 6) so it already carries the CPU
	// slot's word within that slot, and the sheet-4 LS163A asserts /DTACK
	// **inside the slot** -- a latch that only captured after it would deliver
	// the word after the bus cycle had ended.  The registered half is what HOLDS
	// it for the rest of the cycle.
	logic [15:0] cpu_hold;
	always_ff @(posedge clk) begin
		if (reset)                cpu_hold <= 16'h0000;
		else if (ce_7m && vcpu)   cpu_hold <= q;
	end
	assign cpu_vram_din = vcpu ? q : cpu_hold;

	// =====================================================================
	// 7. 7L / 7J 74LS378 -- the MO link register
	// =====================================================================
	// CK = RCLKB, /E = /LINK.  LNK9..LNK0 = VRD9..VRD0; VRD10/VRD11 are latched
	// by 7L but their outputs are bare stubs, so they are simply not modelled.
	//
	// `q` is valid within the same pixel as the address (see section 6), so the
	// strobe needs no compensation: LNK takes the word on the RCLKB edge that
	// ends the slot, exactly as 7L/7J do.
	always_ff @(posedge clk) begin
		if (reset)                     lnk <= 10'd0;
		else if (ce_7m && !link_n)     lnk <= q[9:0];
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// MA15 reaches VRA15 -> RAM pin 1, a no-connect on the fitted 8Kx8 parts.
	// h[2:0], v[2:0] and pf_v[2:0] are below the word address this sheet forms.
	wire unused = &{1'b0, ma[15], h[2:0], v[2:0], pf_v[2:0]};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
