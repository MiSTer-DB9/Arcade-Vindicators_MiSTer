derive_pll_clocks
derive_clock_uncertainty

# ============================================================================
#  Vindicators core timing constraints.
#
#  There is exactly ONE fabric clock in the game half of this design:
#
#     clk_sys = 57.272727 MHz  (emu|pll outclk_0 = PLL 50 MHz x 63 / 5 / 11)
#             = 4 x 14.318181 MHz, the SP-317 master crystal.  Period 17.461 ns.
#
#  Everything below it advances on synchronous, integer clock ENABLES generated
#  in rtl/vind_core.sv from one free-running /32 counter:
#
#     ce_14m  = clk_sys / 4   = 14.318181 MHz  (SYNGEN master)
#     ce_7m   = clk_sys / 8   =  7.159091 MHz  (VIDCLK pixel AND the 68010)
#     ce_ym   = clk_sys / 16  =  3.579545 MHz  (JSA I crystal, = video xtal / 4)
#     ce_6502 = clk_sys / 32  =  1.789772 MHz  (JSA I 6502)
#
#  Each slower enable is a strict subset of every faster one, so no fractional
#  or asynchronous enable exists anywhere and there is no CDC inside the game
#  logic.  outclk_1 is the same 57.272727 MHz, phase-shifted, for SDRAM_CLK.
#
#  Multicycle exceptions exist only for the CE-gated vendored blocks (TG68K,
#  T65, jt51), following the rule inherited from the Xybots/Toobin' cores: only
#  INTRA-block reg->reg paths inside a hierarchy where every sequential process
#  takes the same enable; outputs to full-rate logic stay single-cycle; nothing
#  running at full rate gets an exception.
# ============================================================================

# ============================================================================
#  MAIN CPU — TG68K in 68010 mode (rtl/main/vind_cpu.sv -> u_tg68k), paced by
#  cpu_cen = the main board's RCLKA enable (clk_sys/8, withheld on a program-ROM
#  cache miss).  Toobin's constraint, same reasoning: the cpu1 kernel and its
#  ALU only update under clkena_in/clkena_lw, which include cpu_cen, so
#  intra-kernel paths have at least 8 clk_sys.  TG68K.vhd's own wrapper (the
#  free-running sync counter and the mixed-edge bus state machines) is NOT
#  covered and is analysed at full rate.
# ============================================================================
set_multicycle_path -setup -end 8 -from [get_registers {*u_main|u_cpu|u_tg68k|cpu1|*}] -to [get_registers {*u_main|u_cpu|u_tg68k|cpu1|*}]
set_multicycle_path -hold  -end 7 -from [get_registers {*u_main|u_cpu|u_tg68k|cpu1|*}] -to [get_registers {*u_main|u_cpu|u_tg68k|cpu1|*}]

# ============================================================================
#  CE-gated vendored blocks on the JSA I board.  Same hierarchy names as the
#  Xybots core (vind_jsa: u_cpu = T65_wrap -> u_t65; u_ym -> u_jt51).
# ============================================================================
# ---- JSA I 6502 only --------------------------------------------------------
# Every sequential process in T65.vhd is gated by the same Enable input, which
# rtl/sound/vind_jsa.sv drives from ce_6502 = clk_sys/32.  Eight cycles is
# deliberately conservative against the real 32-clock interval, and it keeps the
# exception away from anything that might be re-timed into it.  The collection
# is the T65 core inside the wrapper only — the wrapper's own flat-port glue,
# the mailbox, the mixer and the LPF are ordinary full-rate paths.
set_multicycle_path -setup -end 8 -from [get_registers {*u_jsa|u_cpu|u_t65|*}] -to [get_registers {*u_jsa|u_cpu|u_t65|*}]
set_multicycle_path -hold  -end 7 -from [get_registers {*u_jsa|u_cpu|u_t65|*}] -to [get_registers {*u_jsa|u_cpu|u_t65|*}]

# ---- jt51 LFO / channel registers into the phase generator ------------------
# jt51 drives the LFO PM value, the channel frequency/modulation registers and
# the operator register file from cen_p1, which vind_jsa wires to ce_6502; the
# phase generator's keycode_II destination is clocked by the same enable.  At
# 57.27 MHz successive cen_p1 pulses are 32 fabric clocks apart, so these data
# cannot be launched and captured on adjacent clk_sys edges.  The exception is
# kept on the exact source blocks and the exact destination rather than
# relaxing all of jt51: its timer flags and wrapper state do NOT uniformly share
# this enable.  Two clocks is deliberately conservative, with the standard N-1
# hold adjustment.
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_lfo|pm[*]}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_lfo|pm[*]}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kc[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kf[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|pms[*]*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kc[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kf[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|pms[*]*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_op|u_reg1op|*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_op|u_reg1op|*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

# ============================================================================
#  SDRAM external I/O timing (MT48LC16M16 class, CL2, 57.272727 MHz controller).
#  SDRAM_CLK is PLL outclk_1 wired straight to the pin in Arcade-Vindicators.sv.
#  Its phase (rtl/pll/pll_0002.v) decides when read data is captured; that is
#  settled on hardware, not by this analysis.
# ============================================================================
create_generated_clock -name SDRAM_CLK \
  -source [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

set_input_delay  -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]

set_output_delay -clock SDRAM_CLK -max  1.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]

set_multicycle_path -setup -end 2 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold -end 1 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
