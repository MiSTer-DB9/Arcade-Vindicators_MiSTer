`timescale 1ns/1ps
//============================================================================
//  Vindicators (Atari Games, 1988) — game logic top, below the MiSTer `emu` glue.
//
//  The four blocks below together model the SP-317 game board and the JSA I
//  audio board:
//
//    vind_mem       program EPROMs (sheet 4) and graphics ROMs (sheet 9), both
//                   held in SDRAM; the 15/16N character ROM; the MiSTer ROM
//                   download path and the sound-ROM write stream
//    vind_main_bus  sheets 2/3/4 — 68010 (TG68K), PAL 3C decode, LS163 DTACK
//                   sequencer, IPL, LS197 watchdog, 2804A EEPROM + NVRAM, the
//                   sheet-3 I/O block
//    vind_video     sheets 5-11 — SYNGEN, VRAM multiplex, alpha control words,
//                   playfield, motion objects, PALs 17D/17E/7N, GPC, CRAM, DAC
//    vind_jsa       sheets 14-17 — the whole JSA I audio PCB, both SCOM
//                   halves and the 4-wire cable between the boards
//
//  ---- clocking -------------------------------------------------------------
//
//  ONE clock domain, clk_sys = 57.272727 MHz = 4 x the 14.318181 MHz crystal
//  (sheet 6), with integer clock enables and no fractional enables anywhere.
//  The JSA I sound crystal (3.579545 MHz) is EXACTLY the video crystal / 4:
//
//     ce_14m  = clk_sys / 4   = 14.318181 MHz   SYNGEN master
//     ce_7m   = clk_sys / 8   =  7.159091 MHz   VIDCLK pixel AND RCLKA (68010)
//     ce_7m_b = clk_sys / 8   =  RCLKB, the opposite phase of RCLKA
//     ce_ym   = clk_sys / 16  =  3.579545 MHz   YM2151 (JSA I)
//     ce_6502 = clk_sys / 32  =  1.789772 MHz   JSA I 6502
//     ce_b4h  = /B4H, the SCOM shift clock = 4H inverted (sheet 3, 17F), one
//               pulse per rising edge of /B4H = falling edge of the SYNGEN 4H
//               tap, 894.886 kHz
//
//  All the /2^n enables are decodes of ONE free-running 5-bit counter, so each
//  slower enable is a strict subset of every faster one.  The ce_7m phase
//  convention (inherited from the Xybots core): the clk_sys cycle in which
//  `ce_7m` is high is the LAST cycle of SYNGEN count `h`.
//
//  ---- the one deliberate departure from the sheets: `prog_stall` ------------
//  Sheet 4 gives program-ROM cycles ZERO wait states and vind_main_bus
//  implements that literally.  The 384 KB of EPROM lives in SDRAM behind a
//  cache; a cache miss cannot be served in time, so on a miss the WHOLE main
//  board's RCLKA/RCLKB enables are withheld (`main_ce_7m` below) until
//  `prog_ready`.  That is equivalent to stretching the 68010's clock: every
//  bus-relative timing inside the board is preserved, and the video side
//  (which runs on the ungated ce_7m) never sees the stretch, because the CPU is
//  in a ROM cycle, not a VRAM/CRAM/I/O cycle, while stalled.  Sequential
//  fetches hit the cache, so stalls are rare.
//
//  ---- reset structure (as in the Toobin'/Xybots cores) ---------------------
//    init_reset   ~pll_locked ONLY -> vind_mem (SDRAM init + loader).
//    sys_reset    reset | ~rom_loaded -> video, sound, and the main bus's own
//                 init/por.  Holds the game off until the ROMs are in place.
//    cpu_reset    formed INSIDE vind_main_bus from /SYSRES (LS197 watchdog +
//                 sheet-2 power-on) — the watchdog does not reset the video
//                 or sound boards; the sound board has /SNDRES.
//
//  This program is free software under the GNU GPL v3 or later.
//============================================================================

module vind_core #(
	// 1 selects MAME's ztable transfer instead of the sheet-11 resistor ladder,
	// for bit-exact comparison against MAME; the release build uses the ladder.
	parameter bit DAC_MAME_COMPAT = 1'b0,
	// SDRAM arbitration windows (see "SDRAM arbitration windows" below).  The
	// instants are clk_sys counts inside the 64-clock, 8-pixel cell; the
	// transaction lengths were measured in simulation.
	parameter int ARB_T_PF    = 1,    // playfield request at cell clock 1 (pixel 0, 2nd clk)
	parameter int ARB_T_MO    = 33,   // motion-object request at 33 (pixel 4, 2nd clk), every cell
	parameter int ARB_T_MO2   = 47,   // the lock-on's PICTD repeat request at 47 (pixel 5, last clk)
	parameter int ARB_CPU_TXN = 16,   // a 4-word CPU burst holds the arbiter 14 clocks, plus controller recovery
	parameter int ARB_REF_TXN = 7     // AUTO_REFRESH: 5 clocks plus start and recovery
)(
	input  logic        clk_sys,        // 57.272727 MHz
	input  logic        reset,          // active-high system reset
	input  logic        init_reset,     // ~pll_locked ONLY (SDRAM/loader)

	// ---- HPS ioctl ROM download (index 0) ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	output logic        ioctl_wait,

	// ---- NVRAM (2804 EEPROM) save-back to HPS (index 2) ----
	input  logic        ioctl_upload,
	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din,

	// ---- controls (ACTIVE-HIGH "pressed"; the sheet-3 LS244 inversion is in
	//      vind_inputs).  [0] = Pn-S1 ... [7] = Pn-S8, which sheet 13 wires as
	//      Left Trigger, Right Trigger, Left Thumb, Right Thumb, Left Forward,
	//      Right Forward, Left Back, Right Back (= MAME 0x260000 D8..D15).
	input  logic  [7:0] p1_sw,
	input  logic  [7:0] p2_sw,
	input  logic  [1:0] start_sw,       // PL3: [0] = 1P start (S1), [1] = 2P start (S2)
	input  logic        self_test,      // the JSA board's SW1, shared over AUD-1
	input  logic        coin1,
	input  logic        coin2,

	// ---- video out (single clk_sys domain, qualified by ce_pix) ----
	output logic        ce_pix,
	output logic  [7:0] vga_r, vga_g, vga_b,
	output logic        hsync, vsync, hblank, vblank,

	// ---- audio ----
	output logic signed [15:0] aud_l, aud_r,

	// ---- SDRAM chip ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

	// ===================== clock enables =====================
	// One free-running /32 counter; every enable is a decode of it.  Not reset
	// and no initialiser: Quartus powers registers up at 0, and simulation is
	// run with X initialised to 0, so the enable phase is identical in both.
	logic [4:0] ce_cnt;
	always_ff @(posedge clk_sys) ce_cnt <= ce_cnt + 5'd1;

	wire ce_14m  = (ce_cnt[1:0] == 2'd0);   // 14.318181 MHz
	wire ce_7m   = (ce_cnt[2:0] == 3'd0);   //  7.159091 MHz  RCLKA / VIDCLK
	wire ce_7m_b = (ce_cnt[2:0] == 3'd4);   //  RCLKB: RCLKA's opposite phase
	wire ce_ym   = (ce_cnt[3:0] == 4'd0);   //  3.579545 MHz
	wire ce_6502 = (ce_cnt      == 5'd0);   //  1.789772 MHz

	// ===================== resets =====================
	logic rom_loaded;
	wire  sys_reset = reset | ~rom_loaded;

	// =====================================================================
	//  Memory subsystem
	// =====================================================================
	logic [17:0] prog_a;
	logic        prog_rd, prog_ready, prog_stall, rom_ready;
	logic [15:0] prog_data;

	logic [13:0] char_addr;
	logic  [7:0] char_data;

	logic        pf_gfx_req, mo_gfx_req, pf_gfx_valid, mo_gfx_valid;
	logic [17:0] pf_gfx_addr, mo_gfx_addr;
	logic [31:0] pf_gfx_data, mo_gfx_data;

	logic        sndrom_wr;
	logic [15:0] sndrom_addr;
	logic  [7:0] sndrom_data;

	logic        eeprom_img_wr;
	logic  [8:0] eeprom_img_addr;
	logic  [7:0] eeprom_img_data;

	vind_mem u_mem (
		.clk            (clk_sys),
		.cpu_ok         (cpu_ok),
		.rfsh_ok        (rfsh_ok),
		.init_reset     (init_reset),      // ~pll_locked ONLY

		.ioctl_download (ioctl_download),
		.ioctl_wr       (ioctl_wr),
		.ioctl_addr     (ioctl_addr),
		.ioctl_dout     (ioctl_dout),
		.ioctl_index    (ioctl_index),
		.ioctl_wait     (ioctl_wait),
		.rom_loaded     (rom_loaded),

		.prog_a         (prog_a),
		.prog_rd        (prog_rd),
		.prog_data      (prog_data),
		.rom_ready      (rom_ready),
		.prog_ready     (prog_ready),
		.prog_stall     (prog_stall),

		.char_addr      (char_addr),
		.char_data      (char_data),

		.pf_req         (pf_gfx_req),  .pf_addr (pf_gfx_addr),
		.pf_valid       (pf_gfx_valid), .pf_data (pf_gfx_data),
		.mo_req         (mo_gfx_req),  .mo_addr (mo_gfx_addr),
		.mo_valid       (mo_gfx_valid), .mo_data (mo_gfx_data),

		.sndrom_wr      (sndrom_wr),
		.sndrom_addr    (sndrom_addr),
		.sndrom_data    (sndrom_data),

		// The 2804A restore arrives over ioctl (index 2 + the index-0 tail)
		// through vind_nvram_io INSIDE vind_main_bus; this hook is the
		// alternative path and is deliberately left unused (wire ONE, never both).
		.eeprom_img_wr  (eeprom_img_wr),
		.eeprom_img_addr(eeprom_img_addr),
		.eeprom_img_data(eeprom_img_data),

		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_CKE(SDRAM_CKE),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_nWE(SDRAM_nWE)
	);

	// =====================================================================
	//  Main board — sheets 2, 3, 4
	// =====================================================================
	// RCLKA/RCLKB to the main board, withheld while a program-ROM cache miss
	// is outstanding (header, "prog_stall").
	wire main_ce_7m   = ce_7m   & ~prog_stall;
	wire main_ce_7m_b = ce_7m_b & ~prog_stall;

	logic [16:1] ma;
	logic [15:0] cpu_dout, cpu_din_video;
	logic        vram_n, cw_r, cpu_uds_n, cpu_lds_n, cpu_dtack;
	logic        pvcpu, ecom_n, vack_n, vint_n, vblank_n;
	logic        sysres_n;

	logic        snd_cmd_wr, snd_resp_rd, snd_reset, snd_full, snd_busy;
	logic  [7:0] snd_cmd_data, snd_resp_data;

	// Common-bus signals whose only consumer, the sheet-3 I/O block, is INSIDE
	// vind_main_bus (the ECPU that would also sit on that bus is unpopulated).
	/* verilator lint_off UNUSEDSIGNAL */
	logic [16:1] ca;
	logic        ca20, ca21, cbus_oe, cds, cio_n, com_n, ewai, vack_stb;
	logic [15:0] cd_out;
	logic        ereset_n, ltest, lresl, prbk, power_on;
	logic [23:1] cpu_a;
	logic [15:0] cpu_din;
	logic        cpu_as, cpu_rw;
	logic  [2:0] cpu_fc, ipl;
	logic [15:0] pl1, pl2, pl3;
	/* verilator lint_on UNUSEDSIGNAL */

	vind_main_bus #(.CLK_HZ(57_272_727)) u_main (
		.clk(clk_sys), .ce_7m(main_ce_7m), .ce_7m_b(main_ce_7m_b),
		// sys_reset, NOT init_reset: the 68010 must be held while the ROMs
		// stream in, and the watchdog must be parked at POR until then.
		.init_reset(sys_reset), .por_req(1'b0),

		.prog_a(prog_a), .prog_rd(prog_rd), .prog_data(prog_data), .rom_ready(rom_ready),

		.ma(ma), .cd_in(cpu_din_video),
		.ca(ca), .ca20(ca20), .ca21(ca21), .cd_out(cd_out), .cbus_oe(cbus_oe),
		.cw_r(cw_r), .cds(cds), .cio_n(cio_n), .com_n(com_n), .vram_n(vram_n), .ewai(ewai),
		.pvcpu(pvcpu), .ecom_n(ecom_n),
		.vack_n(vack_n), .vack_stb(vack_stb), .vint_n(vint_n), .vblank_n(vblank_n),

		.snd_cmd_wr(snd_cmd_wr), .snd_cmd_data(snd_cmd_data),
		.snd_resp_rd(snd_resp_rd), .snd_resp_data(snd_resp_data),
		.snd_reset(snd_reset), .snd_full(snd_full), .snd_busy(snd_busy),

		.p1_sw(p1_sw), .p2_sw(p2_sw), .p3_sw({6'b000000, start_sw[1], start_sw[0]}),
		.self_test(self_test),

		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_index(ioctl_index), .ioctl_upload(ioctl_upload),
		.ioctl_upload_req(ioctl_upload_req),
		.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din),

		.ereset_n(ereset_n), .ltest(ltest), .lresl(lresl), .prbk(prbk),

		.cpu_a(cpu_a), .cpu_dout(cpu_dout), .cpu_din(cpu_din), .cpu_as(cpu_as),
		.cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n), .cpu_rw(cpu_rw),
		.cpu_dtack(cpu_dtack), .cpu_fc(cpu_fc), .ipl(ipl),
		.sysres_n(sysres_n), .power_on(power_on),
		.pl1(pl1), .pl2(pl2), .pl3(pl3)
	);

	// =====================================================================
	//  Video — sheets 5-11
	// =====================================================================
	logic [7:0] vid_r, vid_g, vid_b;
	/* verilator lint_off UNUSEDSIGNAL */
	logic  [8:0] h;                  // only h[2:0] is used (ce_b4h)
	logic  [7:0] v;
	logic  [8:0] hpos_out;
	logic [10:0] cram_a_out;
	logic  [1:0] vas_out;
	logic  [3:0] layer_out;
	/* verilator lint_on UNUSEDSIGNAL */

	vind_video #(.DAC_MAME_COMPAT(DAC_MAME_COMPAT)) u_video (
		.clk(clk_sys), .ce_7m(ce_7m), .ce_14m(ce_14m),
		.reset(sys_reset), .sysres(~sysres_n),

		.ma(ma), .cpu_dout(cpu_dout), .cpu_din(cpu_din_video),
		.vram_n(vram_n), .cw_r(cw_r), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n),
		.dtack(cpu_dtack), .vack_n(vack_n),
		.pvcpu(pvcpu), .ecom_n(ecom_n), .vint_n(vint_n), .vblank_n_out(vblank_n),

		.char_addr(char_addr), .char_data(char_data),
		.pf_gfx_req(pf_gfx_req), .pf_gfx_addr(pf_gfx_addr), .pf_gfx_data(pf_gfx_data),
		.pf_gfx_valid(pf_gfx_valid),
		.mo_gfx_req(mo_gfx_req), .mo_gfx_addr(mo_gfx_addr), .mo_gfx_data(mo_gfx_data),
		.mo_gfx_valid(mo_gfx_valid),

		.ce_pix(ce_pix), .red(vid_r), .green(vid_g), .blue(vid_b),
		.hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),

		.h(h), .v(v), .hpos_out(hpos_out), .cram_a_out(cram_a_out),
		.vas_out(vas_out), .layer_out(layer_out)
	);

	// /B4H (sheet 3, 17F LS04 = ~4H): the SCOM/LETA/ADC clock.  Its rising
	// edge is the falling edge of 4H, i.e. the transition out of h[2:0] == 7.
	wire ce_b4h = ce_7m & (h[2:0] == 3'd7);

	// ---------------------------------------------------------------------
	// SDRAM arbitration windows
	// ---------------------------------------------------------------------
	// The board's graphics ROMs are asynchronous; the SDRAM is not.  A motion-
	// object column has 32 clk_sys from its request (the 4H edge) to its /GLD,
	// a playfield row 40, and a fetch costs 12-13 of them on an idle bus.  The
	// requests are strictly periodic within the 64-clk_sys 8-pixel cell.  A
	// plain round-robin could queue a 68010 cache burst AND a refresh in front
	// of a video fetch and miss that deadline (seen on hardware as one-frame
	// sprite dropouts while the CPU was busy), so the CPU and the refresh are
	// only allowed to START when they will finish before the next video
	// request instant.  The instants and transaction lengths are the
	// parameters above.
	localparam int T_PF   = ARB_T_PF;    // playfield request reaches the arbiter
	localparam int T_MO   = ARB_T_MO;    // motion-object request, every cell
	localparam int T_MO2  = ARB_T_MO2;   // the lock-on's repeat request (PICTD)
	localparam int CPU_TXN = ARB_CPU_TXN; // clk_sys a 4-word CPU burst occupies
	localparam int REF_TXN = ARB_REF_TXN; // clk_sys an AUTO_REFRESH occupies

	// ce_cnt[2:0] == 0 is ce_7m, the LAST clk_sys of a pixel (h steps on that
	// edge), so the count inside a pixel runs 1,2,...,7,0.  Subtracting one
	// (3-bit, wrapping) gives a monotonic 0..7, and {h, that} a monotonic
	// 0..63 cell clock.
	wire [2:0] sub_clk  = ce_cnt[2:0] - 3'd1;
	wire [5:0] cell_clk = {h[2:0], sub_clk};
	function automatic int to_next(input int now, input int t);
		to_next = (t - now + 64) % 64;
	endfunction
	int t_next;
	always_comb begin
		t_next = to_next(cell_clk, T_PF);
		if (to_next(cell_clk, T_MO)  < t_next) t_next = to_next(cell_clk, T_MO);
		if (to_next(cell_clk, T_MO2) < t_next) t_next = to_next(cell_clk, T_MO2);
	end
	wire cpu_ok  = (t_next >= CPU_TXN);
	wire rfsh_ok = (t_next >= REF_TXN);

`ifdef VIND_BRINGUP_DEBUG
	// ---- board bring-up test pattern, NOT built for release ----------------
	logic [3:0] tp_r, tp_g, tp_b;
	vind_testpat u_testpat (
		.clk(clk_sys), .reset(sys_reset), .ce(ce_7m),
		.h_count(hpos_out), .v_count({1'b0, v}),
		.hblank(hblank), .vblank(vblank), .frame_start(1'b0),
		.r(tp_r), .g(tp_g), .b(tp_b));
	assign vga_r = {tp_r, tp_r};
	assign vga_g = {tp_g, tp_g};
	assign vga_b = {tp_b, tp_b};
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_vid = &{1'b0, vid_r, vid_g, vid_b, 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */
`else
	assign vga_r = vid_r;
	assign vga_g = vid_g;
	assign vga_b = vid_b;
`endif

	// =====================================================================
	//  JSA I audio PCB — sheets 14-17
	// =====================================================================
	// The watchdog does NOT reach this board; its only reset paths are
	// power-up and /SNDRES -> SCOM /RESREQ (`snd_reset`).
	/* verilator lint_off UNUSEDSIGNAL */
	logic coin_ctr1, coin_ctr2;
	/* verilator lint_on UNUSEDSIGNAL */

	vind_jsa u_jsa (
		.clk(clk_sys), .reset(sys_reset),
		.ce_6502(ce_6502), .ce_ym(ce_ym), .ce_b4h(ce_b4h),

		.rom_wr(sndrom_wr), .rom_wr_addr(sndrom_addr), .rom_wr_data(sndrom_data),

		.snd_cmd_wr(snd_cmd_wr), .snd_cmd_data(snd_cmd_data),
		.snd_resp_rd(snd_resp_rd), .snd_resp_data(snd_resp_data),
		.snd_full(snd_full), .snd_busy(snd_busy), .snd_reset(snd_reset),

		.coin1(coin1), .coin2(coin2), .self_test(self_test),
		.coin_ctr1(coin_ctr1), .coin_ctr2(coin_ctr2),

		.aud_left(aud_l), .aud_right(aud_r)
	);

	// =====================================================================
	//  Observation-only nets
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused_core = &{1'b0,
		prog_ready,
		eeprom_img_wr, eeprom_img_addr, eeprom_img_data,
		1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
