`timescale 1ns/1ps
//============================================================================
//  Vindicators main board — SP-317 sheets 2, 3 and 4 as one block.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Structure follows the Xybots MiSTer core's
//  `xybots_main_bus.sv` (GPL-3.0), which in turn follows Toobin's
//  `toobin_main_bus.sv`; every equation is Vindicators' own.
//
//  Composes: vind_cpu (TG68K in 68010 mode) + vind_addr_decode (PAL 3C,
//  LS139 4J, LS138 7/8B) + vind_dtack (8D LS163A sequencer + the EWAI latch)
//  + vind_irq + vind_watchdog (22M/N LS197 + the sheet-2 one-shot) +
//  vind_eeprom_2804 (1C + the 18E unlock latch) + vind_nvram_io +
//  vind_inputs (1/2B, 3B, 6B, 9B) + vind_out_latch (10B).
//
//  The memory map, the wait-state table and the schematic-vs-MAME decisions
//  are documented in the submodule headers; this one records the composition.
//
//  ---- the three ports out of here ---------------------------------------
//  1. **Program ROM** — `prog_a` is the 18-bit word address the board forms
//     ({bank, A16, A15, MA14, MA13, A12..A1}), `prog_rd` is /ROM0..2 & W//R,
//     `prog_data` must be valid within the cycle, and `rom_ready` holds the
//     CPU in reset until an image exists.  Nothing here depends on which
//     memory answers the port.
//  2. **The common bus toward the video side** — CA1..CA16 + CA20/CA21, CD
//     out + its output enable, CW//R, /VRAM, /COM, and the two grants coming
//     back, PVCPU (the CPU's VRAM slot) and /ECOM (the video's hold on the
//     common bus).  /VACK is exported so the video sheets' VIRQ latch can be
//     cleared; /VINT comes back as the level.
//  3. **The SCOM mailbox toward the JSA I board** — the SCOM device itself
//     (14/15B on sheet 2, both halves of the 4-wire serial link) is
//     `rtl/sound/vind_scom.sv`.  This module only produces its four strobes
//     (/SCOMWR, /SCOMRD, /SNDRES and the data) and consumes its two flags
//     (FULL -> /SINT, BUSY -> /SCBSY).
//
//  ---- two buses, not one ------------------------------------------------
//  Sheet 4 gives the 7E/8E LS244 and 8C/7C LS245 enables as `/EWAI`, and
//  EWAI = ~(ENOWAI + /COM), asserted **only** for /COM cycles.
//  That is literally correct, and it does NOT lock the CPU out of VRAM/CRAM,
//  because VRAM and CRAM are not on the common bus at all:
//
//    * sheet 6 — VRAM 1M/2M/2N/1N is addressed by **MA1..MA16** (the
//      always-enabled 3D/3E LS244s) and sits on the **raw 68010 D0-D15**,
//      through 3L/3K LS373 (read, G = VCPU, /OC = /VRAMRD = /VRAM + W//R) and
//      4L/4K LS244 (write, /G = VR//W).  `/CLRAM = MA16` splits CRAM off, and
//      sheet 10 puts the CRAM CPU port on the same raw D bus, direction
//      `VW//R`.  Neither uses CA or CD.
//    * so `/EWAI` gates only the I/O block on sheet 3 — the three LS244
//      switch ports, the 9B LS367A status byte, the SCOM and the 10B LS174.
//
//  Therefore `cbus_oe = EWAI` here, literally, and the VRAM/CRAM read path
//  (`cd_in`) is NOT gated by it.  `ma` is the always-driven buffered address.
//
//  ---- CDS, /CIO and CW//R -----------------------------------------------
//  All three are generated on **sheet 5** (the unpopulated ECPU sheet), not on
//  the video sheets: 23D LS158A muxes the two CPUs (`SEL = EWAI`, B = the main
//  CPU), 20D LS32 (9,10->8) forms `CDS = CLDS + CUDS`, and PAL 21D drives
//  `/CIO`.  With the ECPU absent the mux is held on the main side whenever
//  EWAI is high and its A inputs float high otherwise, so
//
//      CDS = EWAI & (~/UDS | ~/LDS)
//
//  is exact.  `/CIO` is the one thing the schematic does not settle: PAL 21D
//  is undumped, but R78 470R ties `/CIO` to `/COM`, so `/CIO = /COM`
//  (inferred).
//  `cw_r` on this module's port list is sheet-4's **W//R** (24D LS04), which
//  is what sheets 6 and 10 actually consume (VR//W, VW//R, /VRAMRD); the
//  23D-muxed `CW//R` reaches only the LS245 DIR and the unpopulated common
//  RAM/ROM, and equals W//R whenever the buffers are on.
//============================================================================

module vind_main_bus #(
	parameter int  CLK_HZ          = 57_272_727,
	parameter int  EE_WRITE_CYCLES = CLK_HZ / 100,   // X2804A 10 ms bound
	parameter int  POR_CYCLES      = CLK_HZ / 100,   // sheet-2 R152 x C60 ~ 10 ms
	parameter bit  WDIS            = 1'b0,           // watchdog-disable jumper
	parameter bit  IPL1_OPEN_COLLECTOR = 1'b1        // see vind_irq
)(
	input  logic        clk,          // clk_sys 57.272727 MHz
	input  logic        ce_7m,        // RCLKA enable, clk_sys / 8
	input  logic        ce_7m_b,      // RCLKB enable (RCLKA's opposite phase)
	input  logic        init_reset,   // FPGA init / ROM not loaded yet
	input  logic        por_req,      // the sheet-2 "RESET" pads (optional)

	// ---- program ROM port ----
	output logic [17:0] prog_a,
	output logic        prog_rd,
	input  logic [15:0] prog_data,
	input  logic        rom_ready,

	// ---- the RAW CPU bus toward the video side (VRAM/CRAM live here) ----
	output logic [16:1] ma,           // 3D/3E LS244, ALWAYS driven (sheet 4)
	input  logic [15:0] cd_in,        // VRAM/CRAM (and the I/O block) -> CPU

	// ---- common bus (the sheet-3 I/O block only) ----
	output logic [16:1] ca,           // 7E/8E LS244, enabled by /EWAI
	output logic        ca20,         // 23D LS158A on sheet 5 (= A20 here)
	output logic        ca21,
	output logic [15:0] cd_out,       // 8C/7C LS245, CPU -> common bus
	output logic        cbus_oe,      // = EWAI, the LS244/LS245 enable
	output logic        cw_r,         // W//R (24D LS04): 1 = the CPU is writing
	output logic        cds,          // synthesised from sheet 5, see header
	output logic        cio_n,        // synthesised from sheet 5, see header
	output logic        com_n,
	output logic        vram_n,
	output logic        ewai,
	input  logic        pvcpu,        // video: the CPU's VRAM slot grant
	input  logic        ecom_n,       // video: /ECOM
	output logic        vack_n,       // -> the VIRQ latch on the video sheets
	output logic        vack_stb,     // 1-clk pulse at the /VACK write
	input  logic        vint_n,       // /VINT from that latch
	input  logic        vblank_n,     // /VBLANK from SYNGEN (LS197 CK1)

	// ---- SCOM mailbox toward the JSA I board (rtl/sound/vind_scom.sv) ----
	output logic        snd_cmd_wr,   // /SCOMWR strobe, 1 clk
	output logic  [7:0] snd_cmd_data, // CD7..CD0 at that instant
	output logic        snd_resp_rd,  // /SCOMRD strobe, 1 clk
	input  logic  [7:0] snd_resp_data,
	output logic        snd_reset,    // /SNDRES strobe -> SCOM /RESREQ, 1 clk
	input  logic        snd_full,     // SCOM FULL  -> /SINT   (ACTIVE LOW)
	input  logic        snd_busy,     // SCOM BUSY  -> /SCBSY  (ACTIVE LOW)

	// ---- control panel, ACTIVE-HIGH "pressed"; [0] = Pn-S1 ... [7] = Pn-S8 ----
	input  logic  [7:0] p1_sw,
	input  logic  [7:0] p2_sw,
	input  logic  [7:0] p3_sw,
	input  logic        self_test,

	// ---- MiSTer NVRAM (index 2) ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_upload,
	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din,

	// ---- the 10B LS174 outputs (their consumers are on the video sheets) ----
	output logic        ereset_n,
	output logic        ltest,
	output logic        lresl,
	output logic        prbk,

	// ---- observation / debug ----
	output logic [23:1] cpu_a,
	output logic [15:0] cpu_dout,
	output logic [15:0] cpu_din,
	output logic        cpu_as,
	output logic        cpu_uds_n,
	output logic        cpu_lds_n,
	output logic        cpu_rw,
	output logic        cpu_dtack,
	output logic  [2:0] cpu_fc,
	output logic  [2:0] ipl,
	output logic        sysres_n,
	output logic        power_on,
	output logic [15:0] pl1, pl2, pl3
);

	// =====================================================================
	//  CPU (5D)
	// =====================================================================
	logic vpa_n, cpu_reset;
	/* verilator lint_off UNUSEDSIGNAL */
	wire  cpu_as_n, cpu_vma_n;
	/* verilator lint_on UNUSEDSIGNAL */
	vind_cpu u_cpu (
		.clk(clk), .ce_7m(ce_7m), .reset(cpu_reset), .ipl(ipl), .vpa_n(vpa_n),
		.a(cpu_a), .dout(cpu_dout), .din(cpu_din),
		.as(cpu_as), .as_n(cpu_as_n), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n),
		.rw(cpu_rw), .dtack(cpu_dtack), .fc(cpu_fc), .vma_n(cpu_vma_n));

	// =====================================================================
	//  Decode (PAL 3C + LS139 4J + LS138 7/8B)
	// =====================================================================
	logic rom0_n, rom1_n, rom2_n, slapcs_n, iosel_n, ma13, ma14;
	logic eeprom_n, unlock_n, wdog_n;
	logic latch_n, sndres_n, scomwr_n, pl1_n, pl2_n, pl3_n, scomrd_n;
	logic w_r, wl_n, dec_vpa_n;

	vind_addr_decode u_dec (
		.a(cpu_a), .as(cpu_as), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n),
		.rw(cpu_rw), .fc(cpu_fc), .cds(cds), .cio_n(cio_n),
		.rom0_n(rom0_n), .rom1_n(rom1_n), .rom2_n(rom2_n), .com_n(com_n),
		.slapcs_n(slapcs_n), .iosel_n(iosel_n), .ma13(ma13), .ma14(ma14),
		.eeprom_n(eeprom_n), .unlock_n(unlock_n), .wdog_n(wdog_n), .vram_n(vram_n),
		.vack_n(vack_n), .latch_n(latch_n), .sndres_n(sndres_n), .scomwr_n(scomwr_n),
		.pl1_n(pl1_n), .pl2_n(pl2_n), .pl3_n(pl3_n), .scomrd_n(scomrd_n),
		.w_r(w_r), .wl_n(wl_n), .vpa_n(dec_vpa_n));

	// The slapstic socket 2C is empty (sheet 4): /SLAPCS reaches nothing.
	// /IOSEL only feeds the LS139, which is inside the decode block.
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_dec = &{1'b0, slapcs_n, iosel_n, dec_vpa_n};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  Bus-cycle edges
	// =====================================================================
	// Every I/O strobe is a LEVEL on the board; the devices react to its edge.
	// The LS138 outputs are gated by CDS, which only appears once the common
	// bus is granted, so their edges are NOT the /AS edge and must be detected
	// on the strobes themselves.
	logic ws_d, wl_n_d, latch_n_d;
	logic vack_n_d, sndres_n_d, scomwr_n_d, scomrd_n_d, unlock_n_d;
	wire  ws = cpu_as & ~cpu_rw & (~cpu_uds_n | ~cpu_lds_n);
	always_ff @(posedge clk) begin
		if (init_reset) begin
			ws_d <= 1'b0; wl_n_d <= 1'b1; latch_n_d <= 1'b1;
			vack_n_d <= 1'b1; sndres_n_d <= 1'b1; scomwr_n_d <= 1'b1;
			scomrd_n_d <= 1'b1; unlock_n_d <= 1'b1;
		end else begin
			ws_d <= ws; wl_n_d <= wl_n; latch_n_d <= latch_n;
			vack_n_d <= vack_n; sndres_n_d <= sndres_n; scomwr_n_d <= scomwr_n;
			scomrd_n_d <= scomrd_n; unlock_n_d <= unlock_n;
		end
	end
	wire wr_stb    = ws    & ~ws_d;     // one write strobe per bus cycle
	wire wl_rise   = wl_n  & ~wl_n_d;   // RISING edge of /WL (18E CK, 1C /WE end)
	wire latch_stb = latch_n & ~latch_n_d;  // RISING edge of /LATCH (10B CK)

	// /UNLOCK reaches the 18E LS74's /PRE through the PAL AND the LS139, two
	// gate delays behind /AS, while /WL is one LS32 behind /LDS.  So when the
	// unlock cycle (a WORD write, pc 0x00358A) ends, /WL rises while /UNLOCK is
	// still low and the preset wins — which is what makes the game's
	// "unlock, then write one byte" sequence work at all.  Everything here is
	// computed from the same registered CPU outputs in the same clk_sys, so the
	// level is stretched by one clk_sys to restore that ordering.
	wire unlock_level = ~unlock_n | ~unlock_n_d;

	// =====================================================================
	//  Program ROM address (sheet 4: the six EPROMs in three 128 KB banks)
	// =====================================================================
	wire [1:0] rom_bank = ~rom0_n ? 2'd0 : (~rom1_n ? 2'd1 : 2'd2);
	assign prog_a  = {rom_bank, cpu_a[16], cpu_a[15], ma14, ma13, cpu_a[12:1]};
	assign prog_rd = (~rom0_n | ~rom1_n | ~rom2_n) & ~w_r;   // /CE & /OE = W//R

	// =====================================================================
	//  The two address/data paths — see the header
	// =====================================================================
	// 3D/3E LS244: enables tied to GND, so MA1..MA16 always follow A1..A16.
	// This is the bus the program EPROMs, the EEPROM, the PAL, the VRAM
	// (sheet 6) and the CRAM (sheet 10) all hang off.
	assign ma      = cpu_a[16:1];

	// 7E/8E LS244 + 8C/7C LS245: enabled by /EWAI, i.e. only for /COM cycles.
	assign cbus_oe = ewai;
	assign ca      = cpu_a[16:1];
	assign ca20    = cpu_a[20];
	assign ca21    = cpu_a[21];
	assign cd_out  = cpu_dout;
	assign cw_r    = ~cpu_rw;                          // 24D LS04 W//R
	// Sheet 5: 23D LS158A (SEL = EWAI) then 20D LS32 (9,10->8).  With the ECPU
	// absent the A inputs float high, so CLDS = CUDS = 0 whenever EWAI is low.
	assign cds     = ewai & (~cpu_uds_n | ~cpu_lds_n);
	assign cio_n   = com_n;                            // PAL 21D, undumped; R78

	// =====================================================================
	//  I/O strobes off the LS138 7/8B
	// =====================================================================
	// The LS138 has NO R/W qualifier — CDS //CIO /CA16 and the three selects are
	// all it looks at — so a write to a read strobe pulses it too.  The program
	// never does that; the strobe is faithful anyway.
	assign vack_stb     = vack_n_d   & ~vack_n;     // falling edge of /VACK
	assign snd_cmd_wr   = scomwr_n_d & ~scomwr_n;   // falling edge of /SCOMWR
	assign snd_cmd_data = cpu_dout[7:0];            // CD7..CD0 through 7C LS245
	assign snd_reset    = sndres_n_d & ~sndres_n;   // falling edge of /SNDRES
	assign snd_resp_rd  = scomrd_n_d & ~scomrd_n;   // falling edge of /SCOMRD

	// =====================================================================
	//  Watchdog (22M/N LS197) and the sheet-2 power-on one-shot
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire [3:0] wd_count;
	/* verilator lint_on UNUSEDSIGNAL */
	vind_watchdog #(.CLK_HZ(CLK_HZ), .POR_CYCLES(POR_CYCLES), .WDIS(WDIS)) u_wdog (
		.clk(clk), .init_reset(init_reset), .por_req(por_req),
		.vblank_n(vblank_n), .wdog_n(wdog_n),
		.power_on(power_on), .sysres_n(sysres_n), .count(wd_count));

	wire sysres = ~sysres_n;
	assign cpu_reset = sysres | init_reset | ~rom_ready;

	// =====================================================================
	//  Interrupts (21E LS08 + R79/R80 + 9F LS11 + 20E LS00)
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire srvi_n;
	/* verilator lint_on UNUSEDSIGNAL */
	vind_irq #(.IPL1_OPEN_COLLECTOR(IPL1_OPEN_COLLECTOR)) u_irq (
		.vint_n(vint_n), .sint_n(snd_full), .as(cpu_as), .fc(cpu_fc),
		.ipl(ipl), .srvi_n(srvi_n), .vpa_n(vpa_n));

	// =====================================================================
	//  EEPROM 1C + the 18E unlock latch + MiSTer NVRAM
	// =====================================================================
	// /CE = /EEPROM, /WE = /WL, so a write lands only when both are low.
	wire eeprom_we = wr_stb & ~eeprom_n & ~wl_n;

	logic [7:0] ee_rdata, ee_load_data, ee_dump_data;
	logic [8:0] ee_load_addr, ee_dump_addr;
	logic       ee_load_we, ee_write_accepted;
	/* verilator lint_off UNUSEDSIGNAL */
	wire        ee_busy, ee_oe_n, ee_unlocked;
	/* verilator lint_on UNUSEDSIGNAL */

	vind_eeprom_2804 #(.CLK_HZ(CLK_HZ), .WRITE_CYCLES(EE_WRITE_CYCLES)) u_eeprom (
		.clk(clk), .init_reset(init_reset), .sysres(sysres),
		.unlock(unlock_level), .wl_rise(wl_rise), .cpu_we(eeprom_we),
		.cpu_addr(cpu_a[9:1]), .cpu_wdata(cpu_dout[7:0]), .cpu_rdata(ee_rdata),
		.busy(ee_busy), .oe_n(ee_oe_n), .unlocked(ee_unlocked),
		.write_accepted(ee_write_accepted),
		.load_we(ee_load_we), .load_addr(ee_load_addr), .load_data(ee_load_data),
		.dump_addr(ee_dump_addr), .dump_data(ee_dump_data));

	vind_nvram_io u_nvram (
		.clk(clk), .init_reset(init_reset), .write_accepted(ee_write_accepted),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_index(ioctl_index), .ioctl_upload(ioctl_upload),
		.load_we(ee_load_we), .load_addr(ee_load_addr), .load_data(ee_load_data),
		.dump_addr(ee_dump_addr), .dump_data(ee_dump_data),
		.ioctl_upload_req(ioctl_upload_req),
		.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din));

	// =====================================================================
	//  Inputs (1/2B, 3B, 6B LS244 + 9B LS367A) and the 10B LS174
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire [7:0] status_byte;
	wire [5:0] latch_q;
	/* verilator lint_on UNUSEDSIGNAL */
	vind_inputs u_inputs (
		.p1_sw(p1_sw), .p2_sw(p2_sw), .p3_sw(p3_sw),
		.vblank(~vblank_n), .self_test(self_test),
		.sint_n(snd_full), .scbsy_n(snd_busy),
		.pl1(pl1), .pl2(pl2), .pl3(pl3), .status(status_byte));

	vind_out_latch u_latch (
		.clk(clk), .sysres(sysres), .latch_stb(latch_stb), .cd(cpu_dout[5:0]),
		.ereset_n(ereset_n), .ltest(ltest), .lresl(lresl), .prbk(prbk),
		.q(latch_q));

	// =====================================================================
	//  Read data
	// =====================================================================
	// What can drive the CPU's D15:0:
	//   * the six EPROMs, gated by /ROM0..2 (address only) and /OE = W//R;
	//   * the 2804A on D7:0, gated by /CE = /EEPROM and /OE = the unlock latch;
	//   * the VRAM 3L/3K LS373 and the CRAM CPU port, gated by /VRAM & R//W
	//     (the RAW D bus — they are not on the common bus at all);
	//   * the 8C/7C LS245 from the common bus, gated by /EWAI = the I/O block.
	// Everything else — the write-only strobes, the whole undecoded map, and
	// the unpopulated LETA/ADC lanes — leaves the bus floating.  There is no
	// bus-error timeout (BERR is tied to PR3), so such a cycle still gets DTACK
	// with 0 waits and reads the pulled-up/floating value, modelled as 0xFFFF —
	// which is also MAME's `unmap_value_high()`.
	logic [15:0] cd_rd;
	always_comb begin
		if      (!pl1_n)    cd_rd = pl1;
		else if (!pl2_n)    cd_rd = pl2;
		else if (!pl3_n)    cd_rd = pl3;
		else if (!scomrd_n) cd_rd = {8'hFF, snd_resp_data};  // SCOM on CD7:0
		else                cd_rd = 16'hFFFF;   // nothing else drives CD0-CD15
	end

	logic [15:0] rdata_comb;
	always_comb begin
		if      (prog_rd)                         rdata_comb = prog_data;
		else if (!eeprom_n && cpu_rw && !ee_oe_n) rdata_comb = {8'hFF, ee_rdata};
		// VRAM (3L/3K LS373, /OC = /VRAMRD) and CRAM (sheet 10) drive the RAW
		// D bus — no /EWAI, no PVCPU: the LS373 holds the word the CPU slot
		// fetched until /VRAMRD releases at the end of the cycle.
		else if (!vram_n && cpu_rw)               rdata_comb = cd_in;
		else if (cbus_oe && cpu_rw)               rdata_comb = cd_rd;
		else                                      rdata_comb = 16'hFFFF;
	end

	// Register the read path so the value the CPU latches has settled a full
	// clk_sys, and then HOLD it once /DTACK is asserted.
	//
	// A 68000-family CPU latches the data at the end of the cycle, after DTACK;
	// on the board every source keeps driving until /AS releases — the VRAM
	// through the 3L/3K LS373 (which HOLDS the CPU slot's word until /VRAMRD
	// goes away) and the I/O block through the LS245 pair (whose /EWAI cannot
	// drop before /COM does).  A live mux here would instead follow whatever
	// the video model drives one clk_sys later, so the value is tracked while
	// /DTACK is inactive and frozen when it asserts, which captures exactly
	// the word that was on the bus at the acknowledge point.  Since `cbus_oe`
	// is literally EWAI, this is a data-settling register rather than a
	// workaround for a gated mux, and it is the behaviour the board has.
	//
	// ...with ONE exception, and it is the video side: the VRAM/CRAM source
	// keeps driving AFTER /DTACK.  The sheet-6 multiplex grants the CPU its
	// RCLKA slot in the SAME RCLKA in which the sequencer asserts /DTACK, and
	// the array answers inside that slot, so a register frozen on /DTACK alone
	// would capture the bus from BEFORE the slot — the CPU would read 0000 out
	// of a colour-RAM cell holding 8000 and the self test would report COLOR
	// RAM BAD.  The 3L/3K LS373 holds the slot's word until /VRAMRD releases at
	// the end of the cycle, so this source is safe to keep tracking.
	wire track_rd = ~cpu_dtack | (~vram_n & cpu_rw);
	always_ff @(posedge clk) if (track_rd) cpu_din <= rdata_comb;

	// =====================================================================
	//  DTACK / wait states (8D LS163A + 22F 74S74 + the EWAI latch)
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire       dt_rco, dt_sd_q, dt_ewai_n, dt_enowai;
	wire [3:0] dt_wcnt;
	/* verilator lint_on UNUSEDSIGNAL */
	vind_dtack u_dtack (
		.clk(clk), .ce_7m(ce_7m), .ce_7m_b(ce_7m_b), .reset(init_reset),
		.as(cpu_as), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n), .rw(cpu_rw),
		.eeprom_n(eeprom_n), .com_n(com_n), .vram_n(vram_n), .vpa_n(vpa_n),
		.pvcpu(pvcpu), .ecom_n(ecom_n),
		.dtack(cpu_dtack), .ewai(ewai), .ewai_n(dt_ewai_n), .enowai(dt_enowai),
		.rco(dt_rco), .sd_q(dt_sd_q), .wcnt(dt_wcnt));

endmodule
