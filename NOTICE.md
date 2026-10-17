# NOTICE — third-party components and attributions

This repository's own RTL, documentation and tooling are **GPL-3.0** (see
`LICENSE`). This file names every third-party component compiled into the
core, its authors, and its license, with the paths as they exist in this
repository. File headers are preserved in place.

## Compiled into the bitstream

| Component | Author(s) | License | Location |
|---|---|---|---|
| MiSTer framework (`sys_top`, `hps_io`, `arcade_video`, `video_freak`, `screen_rotate`, `ascal`, PLL config, …) | Till Harbaum, Alexey Melnikov (sorgelig), MiSTer-devel contributors | GPL-3.0-or-later | `sys/` |
| Altera/Intel PLL megafunction instance | Intel Corporation (generated IP) | Intel FPGA IP licence, as generated | `rtl/pll*/` |
| `crt_adjust.sv` — CRT Adjust line buffer (H-Size / H-Position / V-Shift), MiSTer-CRT-Adjust upstream commit `c682de9`, with the four adaptations listed in its header | Umberto Parisi (rmonic79), <https://github.com/rmonic79/MiSTer-CRT-Adjust> | GPL-3.0-or-later | `rtl/video/crt_adjust.sv` |
| TG68K 68000/68010/68020 soft CPU, used in **68010 mode** as the main CPU | Tobias Gubener. Carries the `cpu_cen` clock-enable modification from the Toobin' MiSTer core, plus two edits marked VINDICATORS in `TG68K.vhd`: the falling-edge bus process is delayed one clock (`cpu_cen_f`), and the E-clock / VPA synchroniser advances on `cpu_cen` so that autovectored interrupt cycles terminate correctly | LGPL-2.1-or-later | `rtl/lib/TG68K/` |
| T65 6502 soft CPU + `T65_wrap`, the JSA I sound CPU (1J) | Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll | BSD-style (OpenCores) | `rtl/lib/T65/` |
| jt51 YM2151 (OPM) FM core, the JSA I YM2151 (2F) + YM3012 (2D) | Jose Tejada (jotego) | GPL-3.0-or-later | `rtl/lib/jt51/` |
| POKEY, the JSA I POKEY (3K) | Mike Johnson (MikeJ, FPGAArcade), via the Toobin' core | BSD-style (see the file header) | `rtl/lib/POKEY/` |

## Derived work — Vindicators RTL written from, or structurally based on, GPL-3.0 cores

Each of these files keeps a header naming what it derives from. All are
GPL-3.0-or-later, the same licence this repository ships under.

| Vindicators file(s) | Derived from |
|---|---|
| `rtl/video/vind_syngen.sv`, `vind_testpat.sv` | Xybots MiSTer core (this author's prior project), GPL-3.0; SYNGEN behaviour cross-checked with `Arcade-Gauntlet_MiSTer` `SYNGEN.vhd` by d18c7db |
| `rtl/video/vind_analog_adjust.sv` | MiSTer-CRT-Adjust `examples/core_side_snippet.v` (Umberto Parisi, GPL-3.0), by way of the Blasteroids MiSTer core's glue (this author's), GPL-3.0; re-derived for this raster and 8-clock pixel |
| `rtl/vind_core.sv`, `Arcade-Vindicators.sv`, `Vindicators.sdc` | Xybots / Toobin' MiSTer cores, GPL-3.0 |
| `rtl/main/vind_cpu.sv` | Toobin' `toobin_cpu.sv` (the TG68K 68010 wrapper, `cpu_cen` pacing and IPL synchroniser), GPL-3.0 |
| `rtl/main/vind_main_bus.sv`, `vind_addr_decode.sv`, `vind_dtack.sv`, `vind_irq.sv`, `vind_watchdog.sv`, `vind_inputs.sv` | structure from the Xybots core's `xybots_main_bus.sv` / `xybots_addr_decode.sv` / `xybots_dtack.sv` / `xybots_irq.sv` / `xybots_watchdog.sv` / `xybots_inputs.sv`, GPL-3.0; every equation re-derived from SP-317 |
| `rtl/main/vind_eeprom_2804.sv`, `vind_nvram_io.sv` | Xybots `xybots_eeprom_2804.sv` / `xybots_nvram_io.sv`, themselves from Toobin', GPL-3.0 |
| `rtl/sound/vind_jsa_decode.sv`, `vind_jsa_mem.sv`, `vind_ym.sv`, `vind_pokey.sv`, `vind_pokey_out.sv`, `vind_jsa_lpf.sv` | Toobin' `toobin_jsa_decode.sv` / `toobin_jsa_mem.sv` / `toobin_ym.sv` / `toobin_pokey.sv` / `toobin_pokey_out.sv` / `toobin_jsa_lpf.sv` (the same A043713 audio PCB), GPL-3.0; re-derived against SP-317 sheets 14-17 |
| `rtl/sound/vind_jsa_io.sv`, `vind_jsa_bus.sv`, `vind_jsa_mix.sv`, `vind_jsa.sv` | Toobin' `toobin_jsa_io.sv` / `toobin_jsa_bus.sv` / `toobin_jsa_mix.sv` / `toobin_jsa.sv` with the Xybots port's LS74-dominant `/IRQACK`, GPL-3.0; the periodic-IRQ divider, the 3F `/VOICE` staging latch, the mixer gain law and the `lpf_engage` term are Vindicators-specific |
| `rtl/sound/vind_scom.sv` | register semantics from Toobin' `toobin_sound_comm.sv` / Xybots `xybots_sound_comm.sv`, GPL-3.0; the serial transport, the `/EFULL` back-channel and the `/SCBSY` meaning are new, from SP-317 sheets 2 and 17 |

## Reference material (read for behaviour, never compiled or redistributed)

MAME **0.289** driver sources (`vindictr.cpp`, `atarijsa.cpp`, `atarimo.cpp`;
BSD-3-Clause, copyright Aaron Giles and the MAME contributors) were used as a
functional oracle. The Atari SP-317 schematic package, the Vindicators operator
manual, and all ROM images are inputs that are **never committed or
redistributed** by this project.

## Trademarks and content

This project distributes no ROM data and no copyrighted artwork. *Vindicators*
is a trademark of its rights holders. Use only with software you are legally
entitled to.
