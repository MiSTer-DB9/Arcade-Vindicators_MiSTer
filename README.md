# Vindicators for MiSTer FPGA

A hardware recreation of Atari Games' 1988 arcade title **Vindicators**,
implemented as an FPGA core for the
[MiSTer](https://github.com/MiSTer-devel/Main_MiSTer/wiki) platform.

This is not a software port. The core reconstructs the original PCB set — the
**SP-317** game board (Motorola 68010 + the SYNGEN video-sync custom) and the
Atari **JSA I** stand-alone audio board A043713 (6502 + YM2151 + POKEY) — from
Atari's own schematic package and from the four PAL fuse dumps that ship in the
ROM set, with MAME 0.289 used as a functional oracle where the drawings are
silent. Where a schematic and MAME disagree, the schematic wins and the
disagreement is recorded: see
[Where this core differs from MAME](#where-this-core-differs-from-mame).

Vindicators is its own platform. It is not Atari System 1 or System 2, though
it shares the SYNGEN video custom and the GPC/PFHS graphics customs with that
family, and shares the JSA I audio board with Blasteroids, Xybots and
Skull & Crossbones. Unlike Xybots it has **no SLAPSTIC**, and unlike most JSA I
boards its POKEY *is* populated (its TMS5220 is not).

## Supported ROM sets

All eight MAME sets run on identical RTL. They differ only in the six main-CPU
EPROMs, plus the character ROM in the German set; the graphics ROMs, the sound
ROM and the download-stream layout are byte-identical across every set.

| MRA | MAME set | Region / revision |
| --- | --- | --- |
| `Vindicators.mra` | `vindictr` | World, rev 5 (parent) |
| `_alternatives/_Vindicators/Vindicators (rev 4).mra` | `vindictr4` | World, rev 4 |
| `_alternatives/_Vindicators/Vindicators (rev 2).mra` | `vindictr2` | World, rev 2 |
| `_alternatives/_Vindicators/Vindicators (rev 1).mra` | `vindictr1` | World, rev 1 |
| `_alternatives/_Vindicators/Vindicators (Europe, rev 5).mra` | `vindictre` | Europe, rev 5 |
| `_alternatives/_Vindicators/Vindicators (Europe, rev 4).mra` | `vindictre4` | Europe, rev 4 |
| `_alternatives/_Vindicators/Vindicators (Europe, rev 3).mra` | `vindictre3` | Europe, rev 3 |
| `_alternatives/_Vindicators/Vindicators (German, rev 1).mra` | `vindictrg` | Germany, rev 1 |

The seven alternates carry `zip="<clone>.zip|vindictr.zip"`, the standard
merged-set arrangement: MiSTer takes the changed program ROMs from the clone
archive and everything else from the parent, so keep `vindictr.zip` alongside
any clone archive.

## Requirements

| Item | Requirement |
| --- | --- |
| Board | DE10-Nano (Cyclone V `5CSEBA6U23I7`) |
| SDRAM | **Required** — a standard 32 MB module (MT48LC16M16-class) |
| Display | Horizontal (ROT0) cabinet, **336 × 240 visible at 59.696 Hz** |
| ROMs | Supplied by you from a MAME archive; none are included here |

**The SDRAM module is not optional.** The 1 MB of playfield/motion-object
graphics *and* the 384 KB 68010 program ROM live in it (the program ROM behind
a small prefetching line cache), 1.375 MB of the module in total. There is no
block-RAM fallback for either. The 64 KB sound ROM, the 16 KB character ROM,
video RAM, colour RAM and the two motion-object line buffers are on-chip. The
controller is addressed for the usual 4-bank × 13-bit-row × 9-bit-column part,
so a legacy 8 MB module will not work even though little of the module is used.

**Refresh rate.** This core runs the raster at **456 × 263 counts, 59.696 Hz**,
derived from the Atari sync PROM the SYNGEN custom replaced, rather than from
MAME's published 262 / 59.923 — see
[the divergence table](#where-this-core-differs-from-mame). If a display
refuses to lock, that is the first thing to check.

## Installation

1. Copy `releases/Vindicators_YYYYMMDD.rbf` to `_Arcade/cores/` on the SD card.
2. Copy `releases/Vindicators.mra` to `_Arcade/`, and any wanted alternates from
   `releases/_alternatives/` to `_Arcade/_alternatives/`.
3. Place the matching MAME ROM archive (`vindictr.zip`, etc.) in `games/mame/`.

**No ROM data is included in this repository, and none ever will be.** The MRA
builds the correct memory image from an archive you already own.

## Controls

Vindicators has a **twin-stick tank panel** per player: two sticks that each
push Forward and pull Back, each with a Trigger on the front and a Thumb button
on the top. Steering is differential — both sticks forward drives ahead, one
forward and one back spins the tank.

Eight switches per player, and a MiSTer pad has one stick, so the mapping puts
the **left** stick on the D-pad's up/down and the **right** stick on two
buttons:

| Control | Panel switch |
| --- | --- |
| D-pad Up | **L Forward** (left stick forward) |
| D-pad Down | **L Back** (left stick back) |
| A | **R Forward** (right stick forward) |
| B | **R Back** (right stick back) |
| L | **L Trigger** |
| R | **R Trigger** |
| X | **L Thumb** |
| Y | **R Thumb** |
| Start | Start (1P / 2P) |
| Select | Coin |

D-pad left/right are unused — the real panel has no lateral switch. Any of the
eight switches can be rebound in MiSTer's *Define joystick buttons*; the names
above are the ones the OSD shows, and they are the same names the game's own
Switch Test page uses.

Coins are read on the **JSA audio board**, as on the real cabinet, and the two
chutes are **not** swapped — Coin 1 is chute 1. (The sibling Xybots board does
swap them; this one does not, and MAME agrees.)

## Options

Vindicators has **no DIP switches**. Every operator setting — difficulty,
lives, coinage, tank damage, bookkeeping — lives in the on-board Atari 2804A
EEPROM at 1C and is edited from the game's own self-test, reached with the OSD
**Service** toggle. Settings and high scores persist through MiSTer's
*Save Settings*; the MRA declares a 512-byte NVRAM at index 2. The EEPROM ships
erased (all `0xFF`), exactly as the Atari System 1, Toobin' and Xybots MRAs do,
and the game writes its own defaults on first boot.

| OSD item | Effect |
| --- | --- |
| Aspect ratio | Original / Full Screen / two user ratios |
| Orientation | Original / Flip |
| Scale | Normal / V-Integer / HV-Integer / Narrower HV-Integer |
| **Analog alignment** (page) | CRT H-Size, CRT H-Position, Analog VGA H-Shift, Analog VGA V-Shift |
| Service | the cabinet self-test switch (also the JSA board's SW1 — one switch, both boards, as on the real cabinet) |
| Reset | core reset |

The analog alignment page is the same one as in the
[Arcade-Toobin_MiSTer](https://github.com/MiSTer-devel/Arcade-Toobin_MiSTer),
[Arcade-Klax_MiSTer](https://github.com/MiSTer-devel/Arcade-Klax_MiSTer) and
[Arcade-Xybots_MiSTer](https://github.com/MiSTer-devel/Arcade-Xybots_MiSTer)
cores, for centring and sizing the picture on an analog CRT. It acts on the
output side only (`rtl/video/vind_analog_adjust.sv`): the native 456 × 263
raster, the 7.159 MHz dot clock and the 59.696 Hz refresh are untouched, and at
the zero settings the stage is a bit-exact bypass, so the default picture is
the one that was compared against MAME and checked on hardware. None of it
touches core timing.

## Hardware baseline

| Block | Implementation |
| --- | --- |
| Main CPU | Motorola **68010** @ 7.159090 MHz (14.318181 MHz ÷ 2) — TG68K in its 68010 mode |
| Protection | **none**: no SLAPSTIC. The 2C socket is decoded but empty, as on the board |
| Program ROM | 384 KB (six 27512s at 1D/2D, 1F/2F, 1K/2K), streamed from SDRAM behind a 32-word line cache |
| Sound board | Atari JSA I (A043713): 6502 @ 1.7897725 MHz + YM2151 @ 3.579545 MHz + **POKEY** @ 1.7897725 MHz. The TMS5220C at 3D is **not populated** and is not implemented |
| Main↔sound link | the **SCOM** custom serial mailbox, four wires, not a parallel latch |
| Raster | SYNGEN: 456 × 263 total, **336 × 240 visible**, 7.159090 MHz pixel clock, 59.696 Hz |
| Playfield | 64 × 64 column-major map of 8 × 8 4 bpp tiles, 3-bit bank, 9-bit X and Y scroll, D15 = horizontal flip |
| Alphanumerics | 64 × 31 map of 8 × 8 2 bpp characters, drawn on top; columns 42–63 of every 8th row are **control words** (bank, PF/MO scroll, `/PFSPC`, scanline IRQ) |
| Motion objects | 1024-entry **linked list** of 4 consecutive words, restarted from a 64-entry SLIP table every 8 lines; per-line vertical match; ping-pong line buffers; **≤ 57 list entries scanned per line** |
| Priority | PAL16L8 **17D** (`136059-1151`, the dumped fuse map, used verbatim) + the GPC custom at 13J |
| Palette | 2048 × 16-bit colour RAM, I:R:G:B 4:4:4:4, through the sheet-11 resistor-ladder DACs with the 18M intensity adder |
| NVRAM | Atari 2804A parallel EEPROM, one-shot unlock strobe, lock-after-write |
| Watchdog | the sheet-4 LS197 chain, 8 `/VBLANK` periods, cleared by a write to `0x2E0000` |
| Interrupts | IRQ4 = the programmable **scanline** interrupt (VIRQ), ack at `0x360000`; IRQ6 = the sound board |

The whole core runs in a single **57.272727 MHz** `clk_sys` domain with integer
clock enables, which is how the real board works: the JSA crystal
(3.579545 MHz) is exactly a quarter of the video crystal (14.318181 MHz), so
every rate on both PCBs is an integer division of `clk_sys`. There are no
fractional enables anywhere.

Resource use on the DE10-Nano's Cyclone V (`5CSEBA6U23I7`), for the bitstream in
`releases/`: **16,169 / 41,910 ALMs (39 %)**, 364 / 553 M10K blocks (66 %),
2.79 / 5.66 Mbit of block memory (49 %), 59 / 112 DSP blocks (53 %). Quartus
17.0.2 with multi-corner analysis on: **every slack entry positive, TNS 0.000
on every clock and every check** (setup, hold, recovery, removal) across all
144 analysed corner/check combinations. The game logic has margin (`clk_sys`
setup +2.01 ns; the SDRAM pins +8.3 ns setup and +2.0 ns hold, with every SDRAM
address, command and data register in an I/O cell so that timing does not move
between builds); the tightest path in the design is in the MiSTer framework's
HDMI scaler on the HDMI PLL clock, at +0.115 ns. That path is
placement-sensitive, which is why `Vindicators.qsf` pins the fitter seed;
re-check timing if you change it. On this netlist Quartus 17.0.2's fitter
crashes with an access violation during physical synthesis for seeds 1 and 2;
seed 3, the one pinned, completes.

## Accuracy and verification

This core was developed with AI assistance. Because that raises a fair question
about whether the result was actually checked, here is the verification record.
The test harness lives in the development repository and is not part of this
release; what follows describes what it checks.

**Schematic provenance** — every sheet of SP-317 that carries logic (2–11 for
the game board, 14–17 for the audio board) was transcribed before any RTL was
written, and every strobe in the memory map has an address-bit equation with a
sheet and IC citation behind it. The four PALs that ship in the ROM set
(`136059-1150` 3C, `-1151` 17D, `-1152` 17E, `-1153` 7N) were decoded with
`jedutil` and their equations are implemented **verbatim**, not approximated.

**Simulation suite** — 38 testbenches (Icarus Verilog, plus GHDL + Yosys
netlists of the vendored VHDL cores for the co-simulations), each paired with a
warning-clean Verilator lint. A test must be shown able to fail: several run a
deliberately broken mutant first and fail if the mutant passes.

**Main CPU boot** — the 68010 bus is co-simulated against MAME 0.289 through
reset, the RAM and ROM tests, the EEPROM unlock protocol and the scanline
interrupt path, comparing address, data, size, direction and program counter
event by event.

**Video** — MAME is instrumented to capture complete video state (alpha,
playfield and motion-object RAM plus the palette) at chosen frames; those
states are replayed through the real core RTL and compared to MAME's own
rendered bitmap pixel for pixel on captured frames covering attract, gameplay
and the self-test screens. The alpha layer, the playfield, the motion-object
engine, the priority PAL, the GPC, the colour RAM and the DAC each also have
their own focused bench.

**Sound** — the JSA I board is compared to MAME: the 6502's I/O accesses and
the YM2151 register stream in order and in value, the SCOM command / response
handshake, the POKEY output stage and the analogue mixer's gain law.

**Memory path** — every ROM region is reproducible by hash from a MAME archive,
and the MRA byte stream is proved to reconstruct the download image; every
`<part crc=…>` across the eight MRAs is checked against the actual zip members.
The graphics plane-interleave map is proved non-vacuously (the reversed map
produces a different, wrong hash).

**Hardware** — verified on a DE10-Nano with a 32 MB SDRAM module: boot, attract,
gameplay with coins and controls, the self-test Switch Test, sound from both
the YM2151 and the POKEY, and EEPROM settings surviving a power cycle. Three
defects that only showed on hardware (an interrupt-entry hang, a sprite fetch
one cell late, and one-frame sprite dropouts under CPU load) were each
reproduced in simulation and fixed before this release.

## Where this core differs from MAME

MAME is this project's functional oracle and every check above measures the
core *against* it, so this is a narrow list, not a general claim. It is where
the SP-317 schematics document something MAME's model does not — and in one
case MAME's own source flags the gap.

| Behaviour | MAME | This core |
| --- | --- | --- |
| **Playfield / motion-object priority** | "the MO wins unless `mopriority & 4`"; `/PFSPC` is a no-op | the decision the board actually makes, in **PAL 17D** (`136059-1151`, dumped): `PFWIN = PF/M & G`, comparing the MO priority bits against three playfield attribute bits, gated by the per-playfield-colour `PF/M` bit that the PFHS custom selects out of the `/PFSPC` register |
| **SHADE** | `0x100` is OR-ed into the colour address immediately, whatever layer the pixel came from | `SHADE` is AND-ed with `CA9`, so it can only darken a **playfield** pixel, and it arrives one pixel late through the 12F pipeline — as drawn |
| **Motion objects per line** | no per-line limit (`0 = unlimited`) | the sequencer accepts **one 4-word list entry per 8 pixel clocks**, so at most **57 entries** are scanned on a line and a long list is truncated at the right-hand end, as on the board |
| **Lines per frame** | `set_raw(..., 262, ...)`, 59.923 Hz, above a comment saying these are *"from published specs, not derived"* | **263 lines, 59.696 Hz.** Sheet 6 shows the vertical counter, blanking and sync are entirely internal to the SYNGEN custom, so the total is whatever its own vertical PROM says — and that PROM (Atari 136032-102) walks to 256 + 6 + 1 = 263 |
| **Palette DAC** | an exact `×15` multiply into the 17-step `ztable = {0,3,4,…,0x11}` | the **sheet-11 resistor ladders** driven by the 18M intensity adder (`IOUT = INT + 2·MOG + 2 mod 16`), computed in exact rational arithmetic |
| **Periodic sound IRQ** | the divider free-runs; a new interrupt is raised on schedule whether or not the last one was taken | the `÷14` stage **stops while the interrupt is pending** and restarts when it is acknowledged, as the sheet-17 divider does |
| **Main ↔ sound link** | an instantaneous parallel mailbox | the **SCOM serial link**: a write is shifted across four wires and lands ≈12 µs later, and `/SCBSY` clears when the frame completes rather than when the 6502 reads the port |
| **Self-test switch source** | read from `0x260010` **bit 12** — which is a P2 stick switch, not a service switch | the cabinet service switch, routed to the audio board over JSCM-1 and read back on `0x260010` **D1**, exactly as sheet 2 wires it |
| **Coin chutes** | not swapped | not swapped — **the same**. Recorded here only because the sibling Xybots board *is* swapped and the question comes up |
| **Wait states** | none anywhere | the board's: 1 extra RCLKA for the EEPROM, and stalls for common-bus and VRAM cycles |
| **Colour-RAM write during the picture** | the new colour simply takes effect; nothing else on the line changes | the CPU and the video share the colour RAM's address bus with no arbitration (sheet 10), so the CPU's access slot takes one pixel's colour lookup and skips two output-register loads: the pixel before the write stays on screen for two more pixels and the next is one position late — **three pixels altered, no new colour** |

Notes on the ones you might actually see:

**Priority and SHADE.** These are the two divergences with a real chance of
changing a pixel, and they are also the two where the hardware evidence is
strongest — 17D is a dumped PAL, not a reconstruction. The frame comparisons
run against MAME's own rendered output and pass, so on the captured frames the
two models agree; the difference is in what happens on frames nobody has
captured.

**The 57-object limit.** MAME draws every entry a list contains. The hardware
cannot: it gets one entry per 8 pixel clocks and the line ends. Whether
Vindicators' own object lists ever reach that many entries on a line has not
been swept as thoroughly as the sibling Xybots core's were, so this is the most
likely place for a visible difference to turn up on hardware.

**The DAC.** The two transfer curves agree for ordinary pixels — the idle
`MOG = 111` makes the hardware's intensity sum a no-op — and differ by two
`ztable` steps on an intensity-kludge pixel. A `DAC_MAME_COMPAT` parameter
selects MAME's curve so the frame comparisons can match bit for bit; the
shipping build uses the schematic's.

**The colour-RAM write.** Vindicators writes its palette only outside the
visible picture once it has booted — a MAME trace of 10,740 attract frames
logged no colour-RAM write in the active picture after the first frame — so
this is not something you will see in play. The written colour does not
appear on a real board either. During the write the colour RAM's data buffers
put the CPU's word on the nets feeding the output registers, but the only
clock edge that reaches those registers comes from the same signal that turns
the buffers on. It arrives before the word does, inside the registers' setup
time. The core models the nets and the gated clock as drawn.

**The sound IRQ and the SCOM.** Both are timing differences, not data
differences: the same commands arrive in the same order with the same values.
The periodic-IRQ stop is observable only when the 6502 leaves the interrupt
masked for more than 286 µs, which the real sound ROM does occasionally.

## Open items

**1. Two undumped PROMs in the motion-object path.** 11N (82S147, 512 × 8) and
9J (82S129, 256 × 4) are not in the ROM set and are reconstructed behaviourally
from what the surrounding logic demands. The sharpest symptom that something is
not fully understood is that the 9K width-counter preset needs four bits while
sheet 8 reads its `D` input as ground. Real dumps are the only thing that can
close this.

**2. Two undumped PALs on the audio board.** 2L and 2M both drive `/YAM` and
`/REST`, so one of them must have those outputs permanently tri-stated; the
core assumes 2M owns them. Neither PAL is in the ROM set. No behaviour in this
game distinguishes the two readings, but a dump would settle it.

**3. The fifth game-board PAL, 21D, is undumped**, so `/CIO` is modelled as
`/COM` (there is a 470 Ω resistor between the two nets, which is the evidence).
The only consequence of a narrower `/CIO` would be to kill two unused address
aliases of the I/O block.

**4. A SYNGEN dump would settle the 263-line count directly.** The vertical
total is derived from the System 1 sync PROM and the discrete circuit the
SYNGEN custom replaced; the custom itself has not been decapped.

**5. The SDRAM read-capture phase is inherited, not swept here.** The SDRAM
controller captures read data open-loop — it latches the data pins a fixed
number of clocks after the read command, with the phase of the clock sent to
the chip a constant in the PLL. That is how MiSTer cores handle SDR SDRAM in
general. The constant is the one the Toobin' and Xybots cores swept across
eight bitstreams on hardware, and the program ROM, playfield, text and sprites
are all correct on the boards this core has run on, but it has not been swept
independently for this core. The address, command and data registers of the
SDRAM interface all sit in the FPGA's I/O cells, so the interface timing is the
same in every build; an earlier build with the address registers in the fabric
showed a rare wrong 8-pixel tile row, which is what that looks like. If a
future build shows scrambled graphics while the text layer stays clean, this is
the first suspect.

**6. The YM2151 : POKEY mix balance** is 2.98 : 1, computed from the sheet-16
resistor network, against MAME's 1.5 : 1. Applying a resistor ratio needs each
chip's absolute analogue full scale, which SP-317 does not give, so the core
applies it to equalised digital full scales and exposes `PK_FS_X2` as the knob.
This one wants an ear on real hardware.

## Building

Quartus Prime **17.0.2** (Lite or Standard) — the version MiSTer standardises
on; `Vindicators.qsf` pins it. Open `Vindicators.qpf` and run a full compile,
or from a shell:

```
quartus_sh --flow compile Vindicators
```

The bitstream lands in `output_files/Vindicators.rbf`, already named for the
`<rbf>Vindicators</rbf>` the MRAs ask for, so there is no rename step.

Source files are listed in `files.qip`, which Quartus reads but cannot edit —
add and remove entries by hand. **Never add files through the Quartus GUI**: it
rewrites the `.qsf`. `clean.bat` removes every build product.

## Repository layout

```text
Vindicators.qpf / .qsf / .sdc / .srf   Quartus project
Arcade-Vindicators.sv                  Glue between the MiSTer framework and the core
files.qip                              Source file list
rtl/vind_core.sv                       Game logic top: the four blocks below
  main/                                SP-317 sheets 2-4: 68010, decode, DTACK, IRQ, watchdog, EEPROM, inputs
  video/                               Sheets 5-11: SYNGEN, VRAM, alpha, playfield, motion objects, priority, DAC
  sound/                               Sheets 14-17: the JSA I audio board and the SCOM link
  mem/                                 SDRAM controller, ROM download, program-ROM cache, graphics fetch
  lib/                                 Vendored CPU and sound-chip cores (TG68K, T65, jt51, POKEY)
  pll/                                 PLL megafunction
sys/                                   MiSTer framework — unmodified
releases/                              Dated RBF + MRA files
```

## Attribution

This core's own RTL, and this tree, are **GPL-3.0-or-later** (`LICENSE`).
Individual third-party components keep their own notices, which must be
preserved; `NOTICE.md` is the authoritative list.

| Component | Author | License |
| --- | --- | --- |
| MiSTer framework (`sys/`) | Till Harbaum, Alexey Melnikov (sorgelig) and MiSTer-devel contributors | GPL-2.0-or-later / GPL-3.0-or-later per file |
| TG68K (68000/68010/68020 soft CPU, used in 68010 mode as the main CPU) | Tobias Gubener | LGPL-2.1-or-later |
| T65 (6502, the JSA I sound CPU) | Daniel Wallner, with fixes by Mike Johnson, Wolfgang Scherr and Morten Leikvoll (OpenCores / FPGAArcade) | BSD-style |
| POKEY | Mike Johnson (MikeJ, FPGAArcade) | BSD-style |
| jt51 (YM2151) | Jose Tejada (jotego), <https://github.com/jotego/jt51> | GPL-3.0-or-later |
| analog_hsize (CRT H-Size / H-Position resampler) | Umberto Parisi (rmonic79), Arcade-Raiden_MiSTer | GPL-3.0-or-later |
| Altera/Intel PLL megafunction | Intel Corporation (generated IP) | Intel FPGA IP licence, as generated |

The TG68K 68010 wrapper, the SDRAM path, the JSA I building blocks and the
verification methodology come from the
[Arcade-Toobin_MiSTer](https://github.com/MiSTer-devel/Arcade-Toobin_MiSTer)
core, which uses the same 68010 and the same audio board. The SYNGEN raster,
the analog alignment page, the MiSTer glue and the test harness come from this
author's [Arcade-Xybots_MiSTer](https://github.com/MiSTer-devel/Arcade-Xybots_MiSTer)
core. The SYNGEN, PFHS, GPC and line-buffer customs were cross-checked against
d18c7db's [Arcade-Gauntlet_MiSTer](https://github.com/MiSTer-devel/Arcade-Gauntlet_MiSTer),
which models the same Atari parts. Every equation in this core was
re-derived from SP-317 and the PAL dumps before it was written down.

Thanks to the MAME team, whose `vindictr.cpp`, `atarijsa.cpp` and `atarimo.cpp`
served as the functional oracle throughout, and to whoever preserved the Atari
SP-317 schematic package and the operator manual.

Vindicators and its ROMs, artwork and manuals are © Atari Games and its
successors. This project contains no copyrighted ROM data.
