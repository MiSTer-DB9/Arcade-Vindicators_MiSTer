`timescale 1ns/1ps
//============================================================================
//  Vindicators 68010 address decode — SP-317 sheet 4 (PAL 3C, LS139 4J) and
//  sheet 3 (LS138 7/8B), gate for gate.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  Structure derives from the Xybots MiSTer core's
//  `xybots_addr_decode.sv` (GPL-3.0); every equation below is Vindicators'
//  own, read off SP-317 sheets 4 and 3.
//
//  ---- PAL16L8 3C = 136059-1150 (sheet 4) --------------------------------
//  Pin map from the drawing:  1=BAS 2=A19 3=A18 4=A17 5=A16 6=A15 7=A14
//  8=A13 9=BS0 11=BS1 | 12=MA14' 13=MA13' 14=/SLAPCS 15=/IOSEL 16=/COM
//  17=/ROM2 18=/ROM1 19=/ROM0.  Fuse map decoded from the PAL dump with
//  `jedutil`, re-checked against the sheet:
//
//      /ROM0   = /A19 & /A18 & /A17                        ; 000000-01FFFF
//      /ROM1   = /A19 & /A18 &  A17                        ; 020000-03FFFF
//      /ROM2   = /A19 &  A18 & /A17                        ; 040000-05FFFF
//      /COM    =  BAS & /A19 &  A18 &  A17                 ; 060000-07FFFF
//      /SLAPCS =  BAS & /A19 &  A18 & /A17 & A16 & A15     ; 058000-05FFFF
//      /IOSEL  =  BAS &  A19 &  A18 &  A17                 ; 0E0000-0FFFFF
//      /MA13'  = /A13 + (/A19 & A18 & /A17 & A16 & A15 & A14 & /BS0)
//      /MA14'  = /A14 + (/A19 & A18 & /A17 & A16 & A15 & A13 & /BS1)
//
//  **/ROM0..2 carry no BAS term** — the six program EPROMs are chip-enabled by
//  address alone and only /OE = W//R gates their drivers.  A20/A21 are not PAL
//  inputs, so /COM, /IOSEL and the ROMs all repeat every 1 MB.
//
//  The 2C slapstic socket is believed unpopulated (sheet 4).  With it empty
//  the PAL's BS0/BS1 inputs float high, the two bank product terms drop out
//  and pins 13/12 simply re-drive A13/A14 — which is what `BS0`/`BS1` default
//  to here.  /SLAPCS is still decoded even though it reaches an empty socket,
//  so nothing else answers in 0x058000-0x05FFFF.
//
//  ---- LS139 4J (sheet 4) ------------------------------------------------
//      /G = /IOSEL   A = A20   B = A21
//      /EEPROM = /IOSEL & /A21 & /A20      0E0000-0FFFFF
//      /UNLOCK = /IOSEL & /A21 &  A20      1E0000-1FFFFF
//      /WDOG   = /IOSEL &  A21 & /A20      2E0000-2FFFFF
//      /VRAM   = /IOSEL &  A21 &  A20      3E0000-3FFFFF
//  A16..A1 reach none of these, so each output covers a full 128 KW block.
//
//  ---- LS138 7/8B (sheet 3) ----------------------------------------------
//      G1 = CDS   /G2A = /CIO   /G2B = CA16     n = 4*/CA20 + 2*CA5 + CA4
//      Y0 /VACK  Y1 /LATCH  Y2 /SNDRES  Y3 /SCOMWR   (A20 = 1 -> 0x360000)
//      Y4 /PL1   Y5 /PL2    Y6 /PL3     Y7 /SCOMRD   (A20 = 0 -> 0x260000)
//  `CDS` and `/CIO` are COMMON-BUS signals produced on the video sheets; they
//  are inputs here, exactly as they are pins on this sheet.  `CA20`, `CA16`,
//  `CA5`, `CA4` are the buffered copies of the CPU's A20/A16/A5/A4 (the
//  A1..A16 buffers are 7E/8E on sheet 4; CA20's buffer is on the video
//  sheets, so it is taken here as a straight copy of A20).
//
//  ---- what nobody decodes (= every mirror) ------------------------------
//    A23, A22  68010 pins 52/51 are bare stubs      -> the map repeats every 4 MB
//    A21, A20  not seen by /ROM0..2 or /COM          -> ROM and I/O alias every 1 MB
//    A16..A1   not seen by the LS139                 -> /EEPROM //UNLOCK //WDOG //VRAM
//                                                       each cover 0x?E0000-0x?FFFFF
//    A15..A6   not seen by the LS138                 -> each I/O strobe repeats
//                                                       every 0x40 through 0x?60000-0x?6FFFF
//    A3..A1    not seen by the LS138 (they go to the unpopulated LETA/ADC)
//                                                    -> each strobe covers 16 bytes
//  Verified in simulation: the decoded bits behave as above, and no undecoded
//  bit changes any output.
//
//  ---- derived control (sheet 4) -----------------------------------------
//    6D  LS04 (1->2)   BAS  = ~/AS            (an INPUT here; the CPU wrapper
//                                              already hands over an active-high
//                                              /AS copy)
//    24D LS04 (3->4)   W//R = ~R//W           -> /OE of all six EPROMs
//    20D LS32 (1,2->3) /WL  = R//W + /LDS     -> EEPROM /WE and the 18E CK
//    9F  LS11 + 20E LS00  /VPA = ~(BAS & FC0 & FC1 & FC2)
//============================================================================

module vind_addr_decode #(
	// 2C slapstic socket empty -> the PAL's BS inputs float HIGH (sheet 4).
	parameter bit BS0 = 1'b1,
	parameter bit BS1 = 1'b1
)(
	input  logic [23:1] a,        // 68010 A23..A1 (A23/A22 are stubs on the board)
	input  logic        as,       // BAS: active-high copy of /AS
	input  logic        uds_n,
	input  logic        lds_n,
	input  logic        rw,       // R//W, 1 = read
	input  logic  [2:0] fc,

	// ---- common-bus qualifiers, from the video sheets (sheet 3) ----
	input  logic        cds,      // CDS  -> LS138 G1
	input  logic        cio_n,    // /CIO -> LS138 /G2A

	// ---- PAL 3C ----
	output logic        rom0_n,
	output logic        rom1_n,
	output logic        rom2_n,
	output logic        com_n,
	output logic        slapcs_n,
	output logic        iosel_n,
	output logic        ma13,     // PAL pin 13 -> ROM socket A12
	output logic        ma14,     // PAL pin 12 -> ROM socket A13

	// ---- LS139 4J ----
	output logic        eeprom_n,
	output logic        unlock_n,
	output logic        wdog_n,
	output logic        vram_n,

	// ---- LS138 7/8B ----
	output logic        vack_n,
	output logic        latch_n,
	output logic        sndres_n,
	output logic        scomwr_n,
	output logic        pl1_n,
	output logic        pl2_n,
	output logic        pl3_n,
	output logic        scomrd_n,

	// ---- derived ----
	output logic        w_r,      // W//R (ROM /OE): low during READS
	output logic        wl_n,     // /WL
	output logic        vpa_n
);

	// ---- PAL16L8 3C ------------------------------------------------------
	assign rom0_n   = ~(~a[19] & ~a[18] & ~a[17]);
	assign rom1_n   = ~(~a[19] & ~a[18] &  a[17]);
	assign rom2_n   = ~(~a[19] &  a[18] & ~a[17]);
	assign com_n    = ~(as & ~a[19] &  a[18] &  a[17]);
	assign slapcs_n = ~(as & ~a[19] &  a[18] & ~a[17] & a[16] & a[15]);
	assign iosel_n  = ~(as &  a[19] &  a[18] &  a[17]);

	// Pins 13/12.  Active-low outputs: /MA13' = /A13 + <bank term>, so the pin
	// itself (MA13') is the AND of the complements.
	wire slap_win = ~a[19] & a[18] & ~a[17] & a[16] & a[15];
	assign ma13 = ~(~a[13] | (slap_win & a[14] & ~BS0));
	assign ma14 = ~(~a[14] | (slap_win & a[13] & ~BS1));

	// ---- LS139 4J --------------------------------------------------------
	wire [1:0] sel139 = {a[21], a[20]};
	assign eeprom_n = ~(~iosel_n & (sel139 == 2'd0));
	assign unlock_n = ~(~iosel_n & (sel139 == 2'd1));
	assign wdog_n   = ~(~iosel_n & (sel139 == 2'd2));
	assign vram_n   = ~(~iosel_n & (sel139 == 2'd3));

	// ---- LS138 7/8B ------------------------------------------------------
	// ENABLE = CDS & /CIO & /CA16 ; n = 4*/CA20 + 2*CA5 + CA4
	wire       ls138_en = cds & ~cio_n & ~a[16];
	wire [2:0] sel138   = {~a[20], a[5], a[4]};
	assign vack_n   = ~(ls138_en & (sel138 == 3'd0));
	assign latch_n  = ~(ls138_en & (sel138 == 3'd1));
	assign sndres_n = ~(ls138_en & (sel138 == 3'd2));
	assign scomwr_n = ~(ls138_en & (sel138 == 3'd3));
	assign pl1_n    = ~(ls138_en & (sel138 == 3'd4));
	assign pl2_n    = ~(ls138_en & (sel138 == 3'd5));
	assign pl3_n    = ~(ls138_en & (sel138 == 3'd6));
	assign scomrd_n = ~(ls138_en & (sel138 == 3'd7));

	// ---- derived control -------------------------------------------------
	assign w_r   = ~rw;                       // 24D LS04
	assign wl_n  = rw | lds_n;                // 20D LS32
	assign vpa_n = ~(as & fc[0] & fc[1] & fc[2]);   // 9F LS11 + 20E LS00

	// A23/A22 are bare stubs, A14..A6 and A12..A1 reach no decoder on these
	// sheets (A14/A13 do reach the PAL and are used above).  Sink the rest so
	// the tools agree the omission is deliberate — it IS the mirror map.
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_a = &{1'b0, a[23], a[22], a[12:6], a[3:1], uds_n};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
