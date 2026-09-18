//============================================================================
//  Vindicators (Atari Games, 1988) — JSA I audio PCB: the 6502 bus.
//  Composes vind_jsa_decode + vind_jsa_mem + vind_jsa_io, adds the 3F /VOICE
//  staging latch, and exposes YM2151 / POKEY / SCOM ports for the cores that
//  attach at the edges.  This is the whole board minus the 6502, the YM2151,
//  POKEY, the mixer and the SCOM link.
//
//  Derived from `Arcade-Toobin_MiSTer/rtl/sound/toobin_jsa_bus.sv`
//  (Toobin' MiSTer core, GPL-3.0; same A043713 audio PCB), re-checked against
//  SP-317 sheets 15 and 16.  Vindicators-specific changes: the 3F /VOICE
//  staging latch feeds /MIX; the coin counters and the ROM bank are brought
//  out; the SCOM link moved up to vind_jsa, so this module takes the mailbox
//  as a set of ports.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- bus timing ----------------------------------------------------------
//  `ce` marks a valid 6502 bus cycle (1790K).  Reads mux combinationally; the
//  RAM/ROM read is registered inside vind_jsa_mem (address presented one ce
//  early, as for a synchronous memory).
//
//  ---- the 3F LS374A /VOICE staging latch (SP-317 sheet 16) ----------------
//  $2A00 (/VOICE) clocks SD7..SD0 into 3F; its outputs VO7..VO0 go to the (on
//  Vindicators absent) TMS5220C data pins **and** to the D inputs of the 5F
//  /MIX latch.  $2A06 (/MIX) only clocks the transfer — the byte written to
//  $2A06 never reaches 5F.  MAME (`atarijsa.cpp`, `mix_w(data)`) and the
//  Toobin' RTL (`mix_data = cpu_dout`) both take the $2A06 data instead; the
//  results agree for this ROM only because every `STA $2A06` is preceded by
//  `STA $2A00` with the same accumulator ($42F2, $59D0, $5AC9).
//
//  ---- 6502 /IRQ (sheet 15, R28 10K pull-up) -------------------------------
//  Open-collector wired-OR of Q8 (the periodic timer, sheet 17) and the
//  YM2151's own IRQ pin (2F pin 2, sheet 16).  Both are level sources.
//
//  ---- open bus ------------------------------------------------------------
//  /IRQACK, /VOICE, /MIX and the undecoded gaps put nothing on SD7..SD0, so
//  the byte the 6502 latches is open bus; 8'hFF is where a floating TTL bus
//  settles.  MAME's `sound_irq_ack_r` returns 0x00.  Not observable: the sound
//  ROM discards it (`$41B4 LDA $280E / RTS`, `$41C2 LDA $280E / PLA`).
//============================================================================

module vind_jsa_bus #(
	parameter bit MAME_FREERUN = 1'b0   // -> vind_jsa_io: MAME's free-running IRQ
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,             // 6502 bus-cycle enable (1790K)
	input  logic        ce_jsa,         // 3579K, for the periodic IRQ divider

	// ---- 6502 ----
	input  logic [15:0] cpu_addr,
	input  logic  [7:0] cpu_dout,       // 6502 write data
	input  logic        cpu_rnw,        // 1 = read
	output logic  [7:0] cpu_din,        // read data to the 6502
	output logic        cpu_irq,        // /IRQ wired-OR: periodic timer + YM2151
	input  logic        ym_irq,         // YM2151 IRQ pin (active high here)

	// ---- ROM loader ----
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,

	// ---- SCOM 1M (audio-board half of the link; vind_scom) ----
	output logic        scom_rdp,       // /RDP  strobe: 6502 read  $2802
	output logic        scom_wrp,       // /WRP  strobe: 6502 write $2A02
	output logic  [7:0] scom_wrp_data,
	input  logic  [7:0] scom_cmd_data,  // byte delivered at /RDP
	input  logic        scom_sfull,     // 1M pin 5 /BUSY -> SFULL -> /RDIO D5
	input  logic        scom_nmi,       // 1M pin 4 /FULL (1 = asserted)

	// ---- board inputs / outputs ----
	input  logic        coin1,          // JCOIN-4 "Coin 1"
	input  logic        coin2,          // JCOIN-3 "Coin 2"
	input  logic        self_test,      // SW1 / JSCOM-1
	output logic        ym_reset_n,     // /YAMRES
	output logic        coin_ctr1,      // CCTR1 -> Q9
	output logic        coin_ctr2,      // CCTR2 -> Q10
	output logic  [1:0] cpu_bank,       // {BA13, BA12}

	// ---- YM2151 (2F) ----
	output logic        ym_cs,
	output logic        ym_a0,
	output logic        ym_we,
	output logic        ym_rd,
	output logic  [7:0] ym_dout,
	input  logic  [7:0] ym_din,

	// ---- POKEY (3K) ----
	output logic        pk_cs,
	output logic  [3:0] pk_addr,
	output logic        pk_we,
	output logic        pk_rd,
	output logic  [7:0] pk_dout,
	input  logic  [7:0] pk_din,

	// ---- /MIX write (to vind_jsa_mix) ----
	output logic        mix_wr,
	output logic  [7:0] mix_data        // VO7..VO0, from the 3F latch
);

	// ---- decode (2L / 2M PALs + 4M LS138) ----
	wire sel_ram, sel_ym, sel_rdp, sel_rdio, sel_irqack, sel_voice,
	     sel_wrp, sel_wrio, sel_mix, sel_pokey, sel_bank, sel_rom, ym_reg;
	wire [3:0] pokey_reg;
	vind_jsa_decode u_dec (
		.addr(cpu_addr), .sel_ram(sel_ram), .sel_ym(sel_ym), .sel_rdp(sel_rdp),
		.sel_rdio(sel_rdio), .sel_irqack(sel_irqack), .sel_voice(sel_voice),
		.sel_wrp(sel_wrp), .sel_wrio(sel_wrio), .sel_mix(sel_mix), .sel_pokey(sel_pokey),
		.sel_bank(sel_bank), .sel_rom(sel_rom), .ym_reg(ym_reg), .pokey_reg(pokey_reg) );

	wire wr_stb = ce & ~cpu_rnw;
	wire rd_stb = ce &  cpu_rnw;

	// ---- 3F 74LS374A: the /VOICE staging latch (/OC tied to GND) ----
	logic [7:0] voice_data;
	always_ff @(posedge clk) begin
		if (reset) voice_data <= 8'h00;
		else if (sel_voice & wr_stb) voice_data <= cpu_dout;
	end

	// ---- 5F 74LS273B is clocked by /MIX from VO7..VO0, not from SD ----
	assign mix_wr   = sel_mix & wr_stb;
	assign mix_data = voice_data;

	// ---- memory (2H RAM + 2K ROM + the A13B/A12B bank page) ----
	wire [7:0] mem_dout;
	vind_jsa_mem u_mem (
		.clk(clk), .rom_wr(rom_wr), .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data),
		.addr(cpu_addr), .din(cpu_dout), .we(wr_stb & sel_ram),
		.sel_ram(sel_ram), .sel_bank(sel_bank), .sel_rom(sel_rom), .bank(cpu_bank),
		.dout(mem_dout) );

	// ---- SCOM strobes ----
	assign scom_rdp      = sel_rdp & rd_stb;
	assign scom_wrp      = sel_wrp & wr_stb;
	assign scom_wrp_data = cpu_dout;

	// ---- I/O + banking + the periodic sound IRQ ----
	wire [7:0] rdio_data;
	wire       sound_irq;
	vind_jsa_io #(.MAME_FREERUN(MAME_FREERUN)) u_io (
		.clk(clk), .reset(reset), .ce_jsa(ce_jsa),
		.wrio_wr(sel_wrio & wr_stb), .wrio_data(cpu_dout),
		.irqack(sel_irqack & ce),        // /IRQACK fires on read OR write to $2806
		.self_test(self_test), .nmi_line_n(~scom_nmi), .resp_full(scom_sfull),
		.coin1(coin1), .coin2(coin2),
		.cpu_bank(cpu_bank), .coin_ctr1(coin_ctr1), .coin_ctr2(coin_ctr2),
		.ym_reset_n(ym_reset_n), .rdio_data(rdio_data), .sound_irq(sound_irq) );

	// ---- YM / POKEY strobes ----
	assign ym_cs   = sel_ym;
	assign ym_a0   = ym_reg;
	assign ym_we   = sel_ym & wr_stb;
	assign ym_rd   = sel_ym & rd_stb;
	assign ym_dout = cpu_dout;
	assign pk_cs   = sel_pokey;
	assign pk_addr = pokey_reg;
	assign pk_we   = sel_pokey & wr_stb;
	assign pk_rd   = sel_pokey & rd_stb;
	assign pk_dout = cpu_dout;

	// ---- 6502 read mux ----
	always_comb begin
		if      (sel_ram || sel_bank || sel_rom) cpu_din = mem_dout;
		else if (sel_ym)                         cpu_din = ym_din;
		else if (sel_rdp)                        cpu_din = scom_cmd_data;
		else if (sel_rdio)                       cpu_din = rdio_data;
		else if (sel_pokey)                      cpu_din = pk_din;
		else                                     cpu_din = 8'hFF;   // open bus
	end

	// R28 10K pull-up with Q8 and the YM2151 pin 2 both open-collector on it.
	assign cpu_irq = sound_irq | ym_irq;

endmodule
