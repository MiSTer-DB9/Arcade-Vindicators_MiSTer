//============================================================================
//  Vindicators (Atari Games, 1988) — JSA I audio PCB: 6502 address decode.
//
//  Ported from `Arcade-Toobin_MiSTer/rtl/sound/toobin_jsa_decode.sv`
//  (Toobin' MiSTer core, GPL-3.0; same A043713 audio PCB) and re-checked
//  against SP-317 sheet 15.  The one change made here is the /YAM window
//  (see below).
//  This program is free software under the GNU GPL v3 or later.
//
//  ---- what the hardware is (SP-317 sheet 15) ------------------------------
//  Two PALs and one LS138 do the whole decode:
//
//    2L-PAL (PAL16L8A)  /RAM /ROM /SWR /SRD A13B A12B      (SA10 is NOT an input)
//    2M-FPAL (PAL16L8)  /YAM /REST READY                   (sees SA10 and 1790K)
//    4M LS138           G1 = /SRD, G2A = /REST, G2B = SA10,
//                       C:B:A = SA9 : SA2 : SA1
//
//  LS138 enable   = /SRD · /REST · !SA10  -> the $2800-$2BFF half of /REST
//  LS138 select   = 4·SA9 + 2·SA2 + SA1
//
//    Y0 $2800  no device            Y4 $2A00  /VOICE  (3F LS374A staging latch)
//    Y1 $2802  /RDP   (SCOM RD)     Y5 $2A02  /WRP    (SCOM WR)
//    Y2 $2804  /RDIO  (5J LS240A)   Y6 $2A04  /WRIO   (5H LS273A)
//    Y3 $2806  /IRQACK (5K LS74)    Y7 $2A06  /MIX    (5F LS273B)
//
//  The LS138 never sees SA0 or SA3..SA8, so every strobe has a $01F9 mirror
//  and a $FE06 care mask.  **The Vindicators sound ROM uses the mirrors**:
//  `LDA $280A` (/RDP, $4137), `LDA/BIT $280C` (/RDIO, $4016/$414B),
//  `LDA $280E` (/IRQACK, $41B4/$41C2) — so decoding only the base addresses
//  would break the board.  That is the non-vacuity proof for the mask.
//
//  ---- differences from Toobin's file --------------------------------------
//  * `sel_ym`: Toobin' (following MAME's `map(0x2000,0x2001)`) decodes two
//    bytes.  The real 2M-FPAL only sees SA15..SA9, so
//        /YAM = !SA15·!SA14·SA13·!SA12·!SA11·!SA10·!SA9   ->  $2000-$21FF
//    with the register select on SA0 alone, i.e. the YM2151 is mirrored every
//    two bytes across $2000-$21FF.  No Vindicators software uses the mirrors
//    (`$2000`/`$2001` only), so this is hardware fidelity with no behavioural
//    difference.
//  * `sel_voice` is a live strobe here, not a tie-off: on this board 3F feeds
//    the /MIX latch.  That wiring lives in vind_jsa_bus.
//
//  ---- decode anomaly noted, not implemented -------------------------------
//  On sheet 15 the LS138's G1 is drawn active-HIGH and wired to /SRD, which is
//  elsewhere the active-low read strobe.  For $280A/$280C/$280E to read at all,
//  2L's /SRD must be region-qualified.  Neither MAME nor any shipping core
//  models /SRD, and this decoder is purely address-based, so the anomaly has no
//  RTL consequence.  Likewise the 2M-FPAL READY wait-state stretcher is cycle
//  timing only and is not modelled.
//============================================================================

module vind_jsa_decode
(
	input  logic [15:0] addr,
	output logic        sel_ram,     // $0000-$1FFF   2H 8Kx8 SRAM
	output logic        sel_ym,      // $2000-$21FF   2F YM2151   (/YAM)
	output logic        sel_rdp,     // $2802 m$01F9  SCOM RD     (/RDP)
	output logic        sel_rdio,    // $2804 m$01F9  5J LS240A   (/RDIO)
	output logic        sel_irqack,  // $2806 m$01F9  5K LS74 CLR (/IRQACK)
	output logic        sel_voice,   // $2A00 m$01F9  3F LS374A   (/VOICE)
	output logic        sel_wrp,     // $2A02 m$01F9  SCOM WR     (/WRP)
	output logic        sel_wrio,    // $2A04 m$01F9  5H LS273A   (/WRIO)
	output logic        sel_mix,     // $2A06 m$01F9  5F LS273B   (/MIX)
	output logic        sel_pokey,   // $2C00-$2C0F m$03F0  3K POKEY
	output logic        sel_bank,    // $3000-$3FFF   banked ROM page
	output logic        sel_rom,     // $4000-$FFFF   fixed ROM
	output logic        ym_reg,      // YM2151 register select = SA0
	output logic  [3:0] pokey_reg    // POKEY register = SA3..SA0
);

	localparam logic [15:0] M28 = 16'hFE06;  // ~$01F9 : LS138 care mask
	localparam logic [15:0] MPK = 16'hFC00;  // POKEY: /REST · SA10, regs SA3:0

	assign sel_ram    = (addr[15:13] == 3'b000);            // 2L: !SA15·!SA14·!SA13
	assign sel_ym     = (addr[15:9]  == 7'b0010000);        // 2M: $2000-$21FF
	assign sel_rdp    = (addr & M28) == 16'h2802;
	assign sel_rdio   = (addr & M28) == 16'h2804;
	assign sel_irqack = (addr & M28) == 16'h2806;
	assign sel_voice  = (addr & M28) == 16'h2A00;
	assign sel_wrp    = (addr & M28) == 16'h2A02;
	assign sel_wrio   = (addr & M28) == 16'h2A04;
	assign sel_mix    = (addr & M28) == 16'h2A06;
	assign sel_pokey  = (addr & MPK) == 16'h2C00;           // /REST · SA10
	assign sel_bank   = (addr[15:12] == 4'h3);              // $3000-$3FFF
	assign sel_rom    = (addr[15:14] != 2'b00);             // $4000-$FFFF

	assign ym_reg    = addr[0];
	assign pokey_reg = addr[3:0];

endmodule
