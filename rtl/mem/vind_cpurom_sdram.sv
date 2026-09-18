`timescale 1ns/1ps
//============================================================================
//  Vindicators 68010 program ROM out of SDRAM — the six 27512s at 1D/2D,
//  1F/2F, 1K/2K (SP-317 sheet 4) behind a prefetching set-associative cache.
//
//  Copyright (C) 2026 the Vindicators MiSTer core authors.  GPL-3.0-or-later;
//  see LICENSE.  The req/valid adapter shape comes from Toobin's
//  `toobin_cpurom_sdram.sv` (GPL-3.0); the cache, the prefetch and the
//  replacement policy are this core's, because Vindicators' main bus does NOT
//  gate DTACK on the ROM.
//
//  ---- why a cache is not optional here -------------------------------------
//  384 KB of program ROM will not fit in M10K next to everything else, so it
//  lives in SDRAM.  But sheet 4 gives ROM cycles **zero wait states**: the 8D
//  LS163A loads 15 the moment BAS rises and RCO asserts /DTACK immediately,
//  with no term that depends on the ROM at all.  `vind_main_bus` implements
//  exactly that, so the 68010 latches `prog_data` within a cycle or two of
//  presenting `prog_a`, and an SDRAM round trip (10 clk_sys at best, ~60 worst
//  case with the other two clients and a refresh) is far too slow to sit in
//  that path.
//
//  So the ROM port contract — "data is valid one clk_sys after the address" —
//  is met **on a cache hit**; a miss is the one place this core departs from
//  the board, and it is covered by stretching the CPU clock (see `stall`
//  below).  The whole job of this module is to make misses disappear in steady
//  state.
//
//  ---- the structure --------------------------------------------------------
//  Defaults: **WAYS = 2, LINES = 8192 sets per way, 4 words (8 bytes) per
//  line** = 2 x 64 KB = 128 KB of the 384 KB program resident, out of the
//  spare block RAM.  Both parameters are generic: `WAYS = 1, LINES = 8`
//  reproduces a plain 8-line direct-mapped cache bit for bit.
//
//    * a line is 4 words, filled by ONE 4-word SDRAM burst (never crosses an
//      SDRAM row: the line is 4-aligned and a row is 512 words);
//    * word address bits [14:2] are the set index, [17:15] the tag, [1:0] the
//      word within the line.  Two addresses collide in a set iff they are a
//      multiple of 64 KB apart;
//    * **2 ways with true LRU** (one bit per set: "the way to replace next").
//      A direct-mapped cache thrashes as soon as a code loop and a data table
//      sit a multiple of 64 KB apart — a single 68010 instruction can touch
//      both — and the 384 KB program is exactly six such 64 KB pages.  With
//      two ways that pair costs two misses, once;
//    * the **next-line prefetch is kept**: whenever the CPU is reading a
//      resident line whose successor is not resident, that successor is
//      fetched.  Line N+1 is always a different set than line N, so a
//      prefetch can never evict the line the CPU is reading.  This is what
//      makes a straight-line run miss zero times, not once per line.
//
//  ---- how the M10K shape sets the pipeline ---------------------------------
//  At 2 x 32 K words the data arrays MUST be block RAM, and an M10K read is
//  synchronous.  So the lookup is a two-stage pipeline, and everything about
//  the port contract falls out of that:
//
//    stage 0 (the cycle `addr` is presented): the set index drives the read
//            port of both data arrays, both tag arrays and the LRU array;
//    stage 1 (one clk_sys later): the registered tag/valid words are compared
//            against the registered address's tag, `data` is the combinational
//            way mux of the two registered data words, and `ready` is
//            `hit & (addr_r == addr)`.
//
//  A hit therefore still presents `data` exactly **one clk_sys after `addr`**,
//  which is the ROM port contract, unchanged.  What the block RAM does cost is
//  one clk_sys on the MISS path: the miss is only known at stage 1, so the
//  fill request reaches the arbiter a cycle after the address, and a cold miss
//  takes 17 clk_sys.  That is a trade this core takes deliberately: a miss
//  already needs the stall, and a cache this size means misses stop happening.
//
//  Three hazards the block-RAM shape creates, and what handles each:
//
//    1. READ-DURING-WRITE.  The arrays are `no_rw_check` (the M10K "don't
//       care" mode — no bypass logic), so a read that collides with the write
//       of the same address returns garbage.  It can only collide with THIS
//       module's own fill, so the cycle after any tag write is forced to
//       "miss" (`blk`) if it is looking at that set.  One cycle later the
//       array is settled and the same address hits.
//    2. THE VALID BITS CANNOT BE CLEARED IN ONE CYCLE.  16 K valid bits live
//       in the tag arrays, so `reset` starts a walk (`clr_run`) that writes
//       all `LINES` sets invalid, one set per clk_sys, and holds `ready` low
//       until it finishes.  It costs nothing in practice: `reset` here is
//       `init_reset | ~rom_loaded` (vind_mem.sv), which is asserted for the
//       whole multi-million-cycle ioctl download, so the walk is long finished
//       before the 68010 leaves reset.  If reset is ever shorter than LINES
//       clk_sys the CPU simply stalls for the remainder — correct, not fast.
//    3. THE PREFETCH NEEDS A SECOND LOOKUP.  Checking whether line N+1 is
//       resident is a second, different set index in the same cycle, so each
//       way's tag array (and the LRU array) is kept as **two identical
//       copies**, one addressed by the current set and one by the next set.
//       Writes go to both.  Explicit duplication, rather than leaving Quartus
//       to infer a two-read-port RAM, because the prefetch path must never be
//       the reason a 64-block memory falls out of M10K.
//
//  M10K cost at the defaults (1 KB of usable data per block): data
//  2 x 32 K x 16 b = 128 blocks, tags 4 copies x 8192 x 4 b = 16, LRU
//  2 copies x 8192 x 1 b = 2 => **146**, and the fitter reports exactly 146
//  M10K, 145 ALMs and 217 registers for this instance.  Two things are worth
//  keeping if this module is edited: the arrays must stay plain
//  `q <= mem[raddr]` (a ternary write-forward inside the read makes Quartus
//  call it "asynchronous read logic" and leave the whole array uninferred —
//  measured, it cost 8192 flip-flops and ~9600 logic cells), and the LRU
//  forward therefore lives at its USE site, on the registered write.
//
//  ---- what a miss costs, and the integration hook --------------------------
//  `ready` is per-access: it is high when `data` corresponds to the address
//  currently on `addr`.  `stall` is its complement while `rd` is asserted, and
//  it is the signal an integrator must use — the main bus asserts /DTACK for a
//  ROM cycle regardless, so on a miss the CPU would latch stale data.
//  `vind_core` consumes it as `main_ce_7m = ce_7m & ~prog_stall`, which
//  stretches the whole main board's clock until the line arrives.
//============================================================================

module vind_cpurom_sdram #(
	parameter int AW = 24,
	parameter logic [AW-1:0] PROG_BASE = 24'h000000,  // word address of the region
	parameter int PROG_WORDS = 'h30000,               // 384 KB = 192 K words
	parameter int WAYS  = 2,                          // 1 = direct mapped
	parameter int LINES = 8192                        // sets per way
)(
	input  logic          clk,
	input  logic          reset,

	// ---- 68010 side: the board's ROM port, plus the two extra flags ----
	input  logic          rd,               // /ROM0..2 & W//R
	input  logic [17:0]   addr,             // word address
	output logic [15:0]   data,             // valid 1 clk_sys after addr ON A HIT
	output logic          ready,            // `data` belongs to the current addr
	output logic          stall,            // rd & ~ready: hold the CPU

	// ---- arbiter read port ----
	output logic          c_req,
	output logic [AW-1:0] c_addr,
	output logic  [1:0]   c_blen,
	input  logic          c_valid,
	input  logic          c_last,
	input  logic [15:0]   c_rdata
);

	localparam int LINE_WORDS = 4;
	localparam int OFF_BITS   = 2;                        // $clog2(LINE_WORDS)
	localparam int IDX_BITS   = $clog2(LINES);
	localparam int LINE_BITS  = 18 - OFF_BITS;            // 16: address of a line
	localparam int TAG_BITS   = LINE_BITS - IDX_BITS;     // 3 at LINES = 8192
	localparam int TW         = TAG_BITS + 1;             // {valid, tag}
	localparam int DAW        = IDX_BITS + OFF_BITS;      // data-array address
	localparam logic [LINE_BITS-1:0] LINE_MAX =
	           LINE_BITS'(PROG_WORDS / LINE_WORDS);       // first line past the ROM

	assign c_blen = 2'(LINE_WORDS - 1);

	// ==== storage ==============================================================
	// One 32 K x 16 data array per way (64 M10K each at the defaults) and two
	// identical copies of each way's {valid, tag} array: copy `a` is addressed
	// by the set the CPU is reading, copy `b` by the set of the NEXT line, which
	// is what the prefetch tests.  Same for the LRU bit.  `no_rw_check` = the
	// M10K don't-care read-during-write mode, which `blk` below covers.
	(* ramstyle = "no_rw_check, M10K" *) logic [15:0]   dmem0  [0:LINES*LINE_WORDS-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [15:0]   dmem1  [0:LINES*LINE_WORDS-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [TW-1:0] tmem0a [0:LINES-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [TW-1:0] tmem0b [0:LINES-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [TW-1:0] tmem1a [0:LINES-1];
	(* ramstyle = "no_rw_check, M10K" *) logic [TW-1:0] tmem1b [0:LINES-1];
	(* ramstyle = "no_rw_check, M10K" *) logic          lrua   [0:LINES-1];
	(* ramstyle = "no_rw_check, M10K" *) logic          lrub   [0:LINES-1];

	// ==== stage 0: the lookup addresses, straight off `addr` ===================
	// Only the SET and the word-in-line are needed here — the tag is compared at
	// stage 1, against the REGISTERED address.
	wire [IDX_BITS-1:0]  cur_idx  = addr[IDX_BITS+OFF_BITS-1:OFF_BITS];
	wire [OFF_BITS-1:0]  cur_off  = addr[OFF_BITS-1:0];
	// only the SET of the next line is needed at stage 0 (its tag is compared at
	// stage 1), and the low IDX_BITS of `cur_line + 1` are exactly this:
	wire [IDX_BITS-1:0]  pf_idx   = cur_idx + 1'b1;

	logic [17:0] addr_r;
	logic        rd_r;
	always_ff @(posedge clk) begin
		addr_r <= addr;
		rd_r   <= rd;
	end

	// ==== stage 1: what the registered arrays are describing ===================
	wire [LINE_BITS-1:0] s_line = addr_r[17:OFF_BITS];
	wire [IDX_BITS-1:0]  s_idx  = s_line[IDX_BITS-1:0];
	wire [TAG_BITS-1:0]  s_tag  = s_line[LINE_BITS-1:IDX_BITS];
	wire [LINE_BITS-1:0] n_line = s_line + 1'b1;
	wire [IDX_BITS-1:0]  n_idx  = n_line[IDX_BITS-1:0];
	wire [TAG_BITS-1:0]  n_tag  = n_line[LINE_BITS-1:IDX_BITS];
	wire                 n_in_rom = (n_line < LINE_MAX);

	// ==== the write ports (driven combinationally from the fill engine) ========
	logic        dw_we0, dw_we1;
	logic [DAW-1:0]      dw_addr;
	logic        tw_we0, tw_we1;
	logic [IDX_BITS-1:0] tw_idx;
	logic [TW-1:0]       tw_data;
	logic                lru_we;
	logic [IDX_BITS-1:0] lru_idx;
	logic                lru_val;

	logic [15:0]   d_q0, d_q1;
	logic [TW-1:0] t_cur0, t_cur1, t_nxt0, t_nxt1;
	logic          lru_cur, lru_nxt;

	always_ff @(posedge clk) begin
		// way 0
		if (dw_we0) dmem0[dw_addr] <= c_rdata;
		d_q0 <= dmem0[{cur_idx, cur_off}];
		if (tw_we0) tmem0a[tw_idx] <= tw_data;
		if (tw_we0) tmem0b[tw_idx] <= tw_data;
		t_cur0 <= tmem0a[cur_idx];
		t_nxt0 <= tmem0b[pf_idx];
		// way 1 — the `WAYS == 2` guards are constant-folded, so at WAYS = 1
		// these arrays are neither read nor written and Quartus removes them.
		if (WAYS == 2) begin
			if (dw_we1) dmem1[dw_addr] <= c_rdata;
			d_q1 <= dmem1[{cur_idx, cur_off}];
			if (tw_we1) tmem1a[tw_idx] <= tw_data;
			if (tw_we1) tmem1b[tw_idx] <= tw_data;
			t_cur1 <= tmem1a[cur_idx];
			t_nxt1 <= tmem1b[pf_idx];
			if (lru_we) lrua[lru_idx] <= lru_val;
			if (lru_we) lrub[lru_idx] <= lru_val;
			lru_cur <= lrua[cur_idx];
			lru_nxt <= lrub[pf_idx];
		end else begin
			d_q1    <= 16'h0000;
			t_cur1  <= '0;
			t_nxt1  <= '0;
			lru_cur <= 1'b0;
			lru_nxt <= 1'b0;
		end
	end

	// ---- read-during-write guard ---------------------------------------------
	// `no_rw_check` means a read colliding with a write to the same address
	// returns don't-care.  The only writer is this module, so the cycle whose
	// array outputs were sampled at the edge that wrote a set is forced to miss;
	// the following cycle sees the settled array and hits.
	logic                tw_en_q;
	logic [IDX_BITS-1:0] tw_idx_q;
	always_ff @(posedge clk) begin
		tw_en_q  <= tw_we0 | tw_we1;
		tw_idx_q <= tw_idx;
	end
	wire blk = tw_en_q && (tw_idx_q == s_idx);

	// ==== the invalidate walk ==================================================
	// See hazard 2 in the header.  Power-up value = "walk in progress", and any
	// rising edge of `reset` restarts it, so a fresh ioctl download can never
	// leave a stale line behind: without the restart the cache keeps lines it
	// filled from an SDRAM that the download has since overwritten.
	logic                clr_run;
	logic [IDX_BITS-1:0] clr_idx;
	logic                reset_q;
	// Power-up state, as an `initial` rather than a declaration initialiser,
	// which is the form the lint accepts alongside the always_ff below.  Quartus
	// implements it as the Cyclone V register power-up value; `reset_q = 0` is
	// what makes the very first clock see a RISING edge of a `reset` that is
	// already high at power-up, and start the walk.
	initial begin
		clr_run = 1'b1;
		clr_idx = '0;
		reset_q = 1'b0;
	end
	// plain `always`, not `always_ff`: IEEE 1800 9.2.2.4 forbids a second
	// process writing an always_ff variable, and the `initial` above is one.
	always @(posedge clk) begin
		reset_q <= reset;
		if (reset && !reset_q) begin
			clr_run <= 1'b1;
			clr_idx <= '0;
		end else if (clr_run) begin
			clr_idx <= clr_idx + 1'b1;
			if (clr_idx == IDX_BITS'(LINES-1)) clr_run <= 1'b0;
		end
	end

	// ==== the tag compare ======================================================
	wire hit0 = t_cur0[TW-1] && (t_cur0[TAG_BITS-1:0] == s_tag);
	wire hit1 = (WAYS == 2) && t_cur1[TW-1] && (t_cur1[TAG_BITS-1:0] == s_tag);
	wire hit  = (hit0 | hit1) && !blk && !clr_run;

	wire nhit0 = t_nxt0[TW-1] && (t_nxt0[TAG_BITS-1:0] == n_tag);
	wire nhit1 = (WAYS == 2) && t_nxt1[TW-1] && (t_nxt1[TAG_BITS-1:0] == n_tag);
	wire n_present = nhit0 | nhit1;

	// ---- the ROM port contract: `data` one clk_sys after `addr` ----
	assign data  = hit1 ? d_q1 : d_q0;
	assign ready = hit && (addr_r == addr);
	assign stall = rd & ~ready;

	// ==== replacement ==========================================================
	// True LRU over two ways is one bit per set: "the way to replace next".  An
	// invalid way always wins over it.
	//
	// WRITE FORWARDING, and it is not optional: a hit rewrites its own set's LRU
	// bit every cycle of the 32-clk_sys bus cycle, so when the CPU steps to an
	// ALIASING line — the same set, a different tag, which is exactly the thrash
	// case two ways exist to fix — the read and the write collide and a
	// `no_rw_check` array answers don't-care.  The forward is done HERE, on the
	// registered write of the previous cycle, and not as a ternary inside the
	// array's read: Quartus calls that "asynchronous read logic" and leaves the
	// whole array uninferred, which costs 8192 flip-flops and an 8192:1 mux.
	logic                lru_we_q, lru_val_q;
	logic [IDX_BITS-1:0] lru_idx_q;
	always_ff @(posedge clk) begin
		lru_we_q  <= lru_we;
		lru_idx_q <= lru_idx;
		lru_val_q <= lru_val;
	end
	wire lru_cur_f = (lru_we_q && lru_idx_q == s_idx) ? lru_val_q : lru_cur;
	wire lru_nxt_f = (lru_we_q && lru_idx_q == n_idx) ? lru_val_q : lru_nxt;

	wire vic_cur = (WAYS != 2)   ? 1'b0 :
	               !t_cur0[TW-1] ? 1'b0 :
	               !t_cur1[TW-1] ? 1'b1 : lru_cur_f;
	wire vic_nxt = (WAYS != 2)   ? 1'b0 :
	               !t_nxt0[TW-1] ? 1'b0 :
	               !t_nxt1[TW-1] ? 1'b1 : lru_nxt_f;

	// ==== fill engine ==========================================================
	typedef enum logic [1:0] { F_IDLE, F_REQ, F_FILL, F_SETTLE } fstate_t;
	fstate_t st;

	logic [IDX_BITS-1:0] f_idx;
	logic [TAG_BITS-1:0] f_tag;
	logic [OFF_BITS-1:0] f_off;
	logic                f_way;

	// A demand fill is wanted when the address the CPU is STILL holding missed.
	// A prefetch is wanted when it hit and the next line is absent; `n_idx` is
	// never `s_idx`, so a prefetch can never evict the line being read.
	wire miss_now = rd_r && (addr_r == addr) && !hit && !blk && !clr_run;
	wire want_pf  = rd_r && hit && !n_present && n_in_rom && !clr_run;

	wire do_dem = (st == F_IDLE) && miss_now;
	wire do_pf  = (st == F_IDLE) && !miss_now && want_pf;
	wire fill_start = do_dem | do_pf;
	wire fill_done  = (st == F_FILL) && c_valid && c_last;

	wire [LINE_BITS-1:0] start_line = do_dem ? s_line : n_line;
	wire [IDX_BITS-1:0]  start_idx  = do_dem ? s_idx  : n_idx;
	wire [TAG_BITS-1:0]  start_tag  = do_dem ? s_tag  : n_tag;
	wire                 start_way  = do_dem ? vic_cur : vic_nxt;

	// ---- the array write ports ----
	always_comb begin
		// data: one word per burst beat into the way being filled
		dw_we0  = (st == F_FILL) && c_valid && (f_way == 1'b0);
		dw_we1  = (st == F_FILL) && c_valid && (f_way == 1'b1) && (WAYS == 2);
		dw_addr = {f_idx, f_off};

		// tags: the walk clears both ways; a starting fill invalidates its
		// victim; a completing fill validates it with its new tag.
		tw_we0  = 1'b0;
		tw_we1  = 1'b0;
		tw_idx  = clr_idx;
		tw_data = '0;
		if (clr_run) begin
			tw_we0  = 1'b1;
			tw_we1  = (WAYS == 2);
			tw_idx  = clr_idx;
			tw_data = '0;                       // valid = 0
		end else if (fill_start) begin
			tw_we0  = (start_way == 1'b0);
			tw_we1  = (start_way == 1'b1) && (WAYS == 2);
			tw_idx  = start_idx;
			tw_data = '0;
		end else if (fill_done) begin
			tw_we0  = (f_way == 1'b0);
			tw_we1  = (f_way == 1'b1) && (WAYS == 2);
			tw_idx  = f_idx;
			tw_data = {1'b1, f_tag};
		end

		// LRU: whichever way was just used stops being the victim.  A completing
		// fill outranks a hit, which repeats for the rest of the bus cycle.
		lru_we  = 1'b0;
		lru_idx = s_idx;
		lru_val = 1'b0;
		if (WAYS == 2) begin
			if (fill_done) begin
				lru_we  = 1'b1;
				lru_idx = f_idx;
				lru_val = ~f_way;
			end else if (hit) begin
				lru_we  = 1'b1;
				lru_idx = s_idx;
				lru_val = ~hit1;
			end
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= F_IDLE; c_req <= 1'b0; f_off <= '0;
			f_idx <= '0; f_tag <= '0; f_way <= 1'b0;
		end else begin
			case (st)
				F_IDLE: begin
					f_off <= '0;
					if (fill_start) begin
						c_addr <= PROG_BASE + AW'({start_line, {OFF_BITS{1'b0}}});
						f_idx  <= start_idx;
						f_tag  <= start_tag;
						f_way  <= start_way;
						c_req  <= 1'b1;
						st     <= F_REQ;
					end
				end
				// hold c_req until the burst's last word (the arbiter contract)
				F_REQ: st <= F_FILL;
				F_FILL: begin
					if (c_valid) begin
						f_off <= f_off + 1'b1;
						if (c_last) begin
							c_req <= 1'b0;
							st    <= F_SETTLE;
						end
					end
				end
				// one dead cycle so the tag arrays' read pipeline shows the write
				// that just completed before another fill can be decided on
				F_SETTLE: st <= F_IDLE;
				default: st <= F_IDLE;
			endcase
		end
	end

endmodule
