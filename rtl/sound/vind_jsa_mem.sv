//============================================================================
//  Vindicators (Atari Games, 1988) — JSA I audio PCB: 6502 memory.
//  2H 8Kx8 work RAM + 2K 27512 64 KB program ROM with the A13B/A12B bank page.
//
//  Ported from `Arcade-Toobin_MiSTer/rtl/sound/toobin_jsa_mem.sv`
//  (Toobin' MiSTer core, GPL-3.0; same A043713 audio PCB) and re-checked
//  against SP-317 sheet 15; the loader port is kept.
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- the hardware (SP-317 sheet 15) --------------------------------------
//  2K is a 27512: pin 1 carries SA15, which is what proves 64 KB rather than
//  the 27256 the drawing's part box also allows.  Its A13/A12 pins are NOT
//  SA13/SA12 — they are `A13B`/`A12B`, 2L-PAL outputs:
//
//      ($3xxx window) = !SA15 · !SA14 · SA13 · SA12
//      A13B = ($3xxx window) ? BA13 : SA13
//      A12B = ($3xxx window) ? BA12 : SA12
//
//  so the 4 KB window at $3000-$3FFF selects one of four 4 KB pages out of the
//  ROM's low 16 KB, and everything at $4000-$FFFF addresses the ROM directly:
//
//      bank window  ROM addr = {2'b00, BA13, BA12, SA11..SA0}
//      fixed ROM    ROM addr = SA15..SA0
//
//  ROM $0000-$2FFF is reachable ONLY through the bank window (the CPU's own
//  $0000-$2FFF is RAM and I/O), which is why the loader must fill all 64 KB.
//  BA13/BA12 come from the 5H /WRIO latch (vind_jsa_io) and clear to 0 at /POR.
//
//  2H is an 8K x 8 SRAM: A12..A0 = SA12..SA0, /CS1 = /RAM, /WE = /SWR,
//  /OE = /SRD.  Reads of the ROM are gated by /ROM + /SRD; there is no path
//  that writes it, so `we` here only ever reaches the RAM array.
//
//  ---- BRAM inference note (kept verbatim from the Toobin' port) -----------
//  Registered (BRAM) read: dout is valid one clk after addr/selects.  Each
//  array has its OWN dedicated registered-output read (ram_q / rom_q) so both
//  infer as M10K.  A single shared 'dout' output register muxed across the two
//  arrays defeats inference ("asynchronous read logic"): the M10K's output
//  register cannot be shared, so the 64 KB ROM would fall back to ~512 K flip-
//  flops and overflow the device (Quartus error 276003).
//============================================================================

module vind_jsa_mem
(
	input  logic        clk,
	// loader (byte writes over the whole 64 KB ROM image)
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,
	// 6502 access
	input  logic [15:0] addr,
	input  logic  [7:0] din,
	input  logic        we,          // 6502 write (RAM only)
	input  logic        sel_ram,
	input  logic        sel_bank,
	input  logic        sel_rom,
	input  logic  [1:0] bank,        // {BA13, BA12} from the 5H /WRIO latch
	output logic  [7:0] dout
);

	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] ram [0:8191];    // 2H  8 KB
	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] rom [0:65535];   // 2K 64 KB
`ifndef ALTERA_RESERVED_QIS
	initial begin for (int i = 0; i < 8192; i++) ram[i] = 8'h00; end  // sim-only
`endif

	// A13B/A12B substitution, exactly as the 2L PAL does it.
	wire [15:0] rom_off = sel_bank ? {2'b00, bank, addr[11:0]} : addr;

	logic [7:0] ram_q, rom_q;
	logic       sel_ram_q, sel_romish_q;
	always_ff @(posedge clk) begin
		if (rom_wr) rom[rom_wr_addr] <= rom_wr_data;
		if (we && sel_ram) ram[addr[12:0]] <= din;
		ram_q        <= ram[addr[12:0]];
		rom_q        <= rom[rom_off];
		sel_ram_q    <= sel_ram;
		sel_romish_q <= sel_bank | sel_rom;
	end

	always_comb begin
		if      (sel_ram_q)    dout = ram_q;
		else if (sel_romish_q) dout = rom_q;
		else                   dout = 8'hFF;
	end

endmodule
