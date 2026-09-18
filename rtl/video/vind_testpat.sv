`timescale 1ns/1ps
//============================================================================
//  Vindicators board bring-up test pattern: SMPTE colour bars, a grey ramp, a
//  2-pixel white frame on the 336 x 240 visible edge and a bouncing box.  It
//  shows at a glance that the PLL locks and ce_7m toggles, that the 456 x 263
//  raster from vind_syngen locks a monitor and MiSTer's scaler, and that the
//  RGB path through arcade_video is wired right.  4 bits per channel, matching
//  the CRAM's I:R:G:B 4:4:4:4 word (SP-317 sheet 10); full intensity only.
//
//  Built only when VIND_BRINGUP_DEBUG is defined, so it is not part of the
//  release bitstream.  It models no hardware.
//============================================================================

module vind_testpat (
	input  logic       clk,
	input  logic       reset,
	input  logic       ce,            // ce_7m, one pulse per pixel
	input  logic [8:0] h_count,       // vind_syngen hpos: 0..335 while visible
	input  logic [8:0] v_count,       // vind_syngen 1V..128V: 0..239 while visible
	input  logic       hblank,
	input  logic       vblank,
	input  logic       frame_start,

	output logic [3:0] r,
	output logic [3:0] g,
	output logic [3:0] b
);
	localparam logic [8:0] H_ACTIVE = 9'd336;
	localparam logic [8:0] V_ACTIVE = 9'd240;

	localparam logic [8:0] BOX_SIZE = 9'd32;
	localparam logic [8:0] BOX_XMAX = H_ACTIVE - BOX_SIZE;   // 304
	localparam logic [8:0] BOX_YMAX = V_ACTIVE - BOX_SIZE;   // 208

	// 336 = 8 bars x 42 px = 16 ramp steps x 21 px, both exact.
	localparam logic [5:0] BAR_W    = 6'd42;
	localparam logic [4:0] STEP_W   = 5'd21;

	// ---- bouncing box, one step per frame (~59.92 Hz) --------------------
	logic [8:0] box_x, box_y;
	logic       box_dx, box_dy;   // 1 = moving in the increasing direction

	always_ff @(posedge clk) begin
		if (reset) begin
			box_x  <= 9'd40;
			box_y  <= 9'd40;
			box_dx <= 1'b1;
			box_dy <= 1'b1;
		end else if (ce && frame_start) begin
			if (box_dx) begin
				if (box_x >= BOX_XMAX - 9'd2) begin box_x <= BOX_XMAX; box_dx <= 1'b0; end
				else                                box_x <= box_x + 9'd2;
			end else begin
				if (box_x <= 9'd2)            begin box_x <= 9'd0;    box_dx <= 1'b1; end
				else                                box_x <= box_x - 9'd2;
			end
			if (box_dy) begin
				if (box_y >= BOX_YMAX - 9'd1) begin box_y <= BOX_YMAX; box_dy <= 1'b0; end
				else                                box_y <= box_y + 9'd1;
			end else begin
				if (box_y == 9'd0)            begin                    box_dy <= 1'b1; end
				else                                box_y <= box_y - 9'd1;
			end
		end
	end

	// ---- per-line bar / ramp indices -------------------------------------
	// Counters instead of x/42 and x/21 so no divider is inferred.  They are
	// cleared throughout HBLANK, so at h_count == k they read exactly k.
	logic [5:0] bar_cnt;
	logic [2:0] bar_idx;
	logic [4:0] step_cnt;
	logic [3:0] ramp_lvl;

	always_ff @(posedge clk) begin
		if (reset) begin
			bar_cnt  <= 6'd0;
			bar_idx  <= 3'd0;
			step_cnt <= 5'd0;
			ramp_lvl <= 4'd0;
		end else if (ce) begin
			if (hblank) begin
				bar_cnt  <= 6'd0;
				bar_idx  <= 3'd0;
				step_cnt <= 5'd0;
				ramp_lvl <= 4'd0;
			end else begin
				if (bar_cnt == BAR_W - 6'd1) begin
					bar_cnt <= 6'd0;
					bar_idx <= bar_idx + 3'd1;
				end else begin
					bar_cnt <= bar_cnt + 6'd1;
				end
				if (step_cnt == STEP_W - 5'd1) begin
					step_cnt <= 5'd0;
					ramp_lvl <= ramp_lvl + 4'd1;
				end else begin
					step_cnt <= step_cnt + 5'd1;
				end
			end
		end
	end

	// ---- pattern ---------------------------------------------------------
	wire       active    = ~hblank & ~vblank;
	wire [8:0] x         = h_count;
	wire [8:0] y         = v_count;

	// 2-pixel white frame exactly on the 336 x 240 visible edge.
	wire       on_border = active &&
	                       ((x < 9'd2) || (x >= H_ACTIVE - 9'd2) ||
	                        (y < 9'd2) || (y >= V_ACTIVE - 9'd2));

	// 32 x 32 bouncing box.
	wire       in_box    = active &&
	                       (x >= box_x) && (x < box_x + BOX_SIZE) &&
	                       (y >= box_y) && (y < box_y + BOX_SIZE);

	// Bottom 60 lines: 16-step grey ramp.
	wire       in_ramp   = active && (y >= 9'd180);

	logic [3:0] bar_r, bar_g, bar_b;
	always_comb begin
		case (bar_idx)                                        // SMPTE order
			3'd0:    {bar_r, bar_g, bar_b} = {4'hF, 4'hF, 4'hF};  // white
			3'd1:    {bar_r, bar_g, bar_b} = {4'hF, 4'hF, 4'h0};  // yellow
			3'd2:    {bar_r, bar_g, bar_b} = {4'h0, 4'hF, 4'hF};  // cyan
			3'd3:    {bar_r, bar_g, bar_b} = {4'h0, 4'hF, 4'h0};  // green
			3'd4:    {bar_r, bar_g, bar_b} = {4'hF, 4'h0, 4'hF};  // magenta
			3'd5:    {bar_r, bar_g, bar_b} = {4'hF, 4'h0, 4'h0};  // red
			3'd6:    {bar_r, bar_g, bar_b} = {4'h0, 4'h0, 4'hF};  // blue
			default: {bar_r, bar_g, bar_b} = {4'h0, 4'h0, 4'h0};  // black
		endcase
	end

	logic [3:0] nr, ng, nb;
	always_comb begin
		if      (!active)   {nr, ng, nb} = {4'h0, 4'h0, 4'h0};
		else if (on_border) {nr, ng, nb} = {4'hF, 4'hF, 4'hF};
		else if (in_box)    {nr, ng, nb} = {4'hF, 4'h8, 4'h0};   // orange box
		else if (in_ramp)   {nr, ng, nb} = {ramp_lvl, ramp_lvl, ramp_lvl};
		else                {nr, ng, nb} = {bar_r, bar_g, bar_b};
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			r <= 4'h0;
			g <= 4'h0;
			b <= 4'h0;
		end else if (ce) begin
			r <= nr;
			g <= ng;
			b <= nb;
		end
	end
endmodule
