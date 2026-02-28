/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,    // Dedicated outputs
    input  wire [7:0] uio_in,    // IOs: Input path
    output wire [7:0] uio_out,   // IOs: Output path
    output wire [7:0] uio_oe,    // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,       // always 1 when the design is powered, so you can ignore it
    input  wire       clk,       // clock
    input  wire       rst_n       // reset_n - low to reset
);

  // -------------------------
  // IO direction: keep uio as inputs
  // -------------------------
  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;

  // -------------------------
  // Controls
  // -------------------------
  wire run_en    = ena & uio_in[0];
  wire step_mode = uio_in[1];
  wire step_in   = uio_in[2];

  // -------------------------
  // Tick generator (neuron update enable)
  // tick_div = 256 << uio_in[7:5]  (min 256 cycles, max 32768 cycles)
  // -------------------------
  wire [2:0]  tick_scale = uio_in[7:5];
  wire [15:0] tick_div   = (16'd256 << tick_scale);

  reg  [15:0] tick_cnt;
  wire        div_tick = (tick_cnt == (tick_div - 16'd1));

  // Step pulse rising-edge detect
  reg  step_d;
  wire step_rise = step_in & ~step_d;

  wire neuron_tick = step_mode ? step_rise : div_tick;

  // -------------------------
  // EIF neuron core (fixed-point, small LUT exponential)
  // -------------------------
  localparam integer V_W = 12;

  // Internal state
  reg  signed [V_W-1:0] V;
  reg  [5:0]            refrac_cnt;
  reg                   spike_pulse;

  // Model params (tweak these freely)
  localparam signed [V_W-1:0] V_RESET = 12'sd0;
  localparam signed [V_W-1:0] V_T     = 12'sd512;   // "soft threshold" where exp starts
  localparam signed [V_W-1:0] V_SPIKE = 12'sd1024;  // hard spike threshold
  localparam integer          LEAK_SHIFT      = 5;  // leak = V/32 per tick
  localparam integer          I_SHIFT         = 1;  // input current gain (x2)
  localparam integer          EXP_SLOPE_SHIFT = 6;  // slope/DeltaT control (smaller => steeper)
  localparam [5:0]            T_REFRAC        = 6'd16;

  // Saturation bounds for V_W signed
  localparam signed [V_W-1:0] V_MAX = {1'b0, {(V_W-1){1'b1}}}; // +2047 for V_W=12
  localparam signed [V_W-1:0] V_MIN = {1'b1, {(V_W-1){1'b0}}}; // -2048 for V_W=12

  // 16-entry exponential LUT (monotone, clamped by index)
  // Values are already in "V units per tick" (roughly), chosen to be stable with default params.
  function automatic [11:0] exp_lut;
    input [3:0] idx;
    begin
      case (idx)
        4'd0:  exp_lut = 12'd0;
        4'd1:  exp_lut = 12'd1;
        4'd2:  exp_lut = 12'd2;
        4'd3:  exp_lut = 12'd3;
        4'd4:  exp_lut = 12'd5;
        4'd5:  exp_lut = 12'd7;
        4'd6:  exp_lut = 12'd10;
        4'd7:  exp_lut = 12'd14;
        4'd8:  exp_lut = 12'd20;
        4'd9:  exp_lut = 12'd28;
        4'd10: exp_lut = 12'd40;
        4'd11: exp_lut = 12'd56;
        4'd12: exp_lut = 12'd80;
        4'd13: exp_lut = 12'd112;
        4'd14: exp_lut = 12'd160;
        4'd15: exp_lut = 12'd224;
        default: exp_lut = 12'd0;
      endcase
    end
  endfunction

  // Neuron update
  always @(posedge clk) begin
    if (!rst_n) begin
      tick_cnt     <= 16'd0;
      step_d       <= 1'b0;
      V            <= V_RESET;
      refrac_cnt   <= 6'd0;
      spike_pulse  <= 1'b0;
    end else begin
      // tick divider runs continuously (even when paused) so you can resume smoothly
      if (div_tick) tick_cnt <= 16'd0;
      else         tick_cnt <= tick_cnt + 16'd1;

      step_d <= step_in;

      // default: no spike
      spike_pulse <= 1'b0;

      if (run_en && neuron_tick) begin
        // Refractory handling: hold at reset value for T_REFRAC ticks after a spike
        if (refrac_cnt != 6'd0) begin
          refrac_cnt <= refrac_cnt - 6'd1;
          V          <= V_RESET;
        end else begin
          // Intermediates (wider to avoid overflow)
          reg signed [15:0] I_w;
          reg signed [15:0] leak_w;
          reg signed [15:0] exp_w;
          reg signed [15:0] dv_w;
          reg signed [16:0] v_sum;

          reg signed [V_W-1:0] x;
          reg [3:0] idx;

          // Input current: signed ui_in, scaled
          I_w = $signed({{8{ui_in[7]}}, ui_in}) <<< I_SHIFT;

          // Leak: proportional to V (E_L = 0)
          leak_w = $signed(V) >>> LEAK_SHIFT;

          // Exponential term:
          // x = V - V_T; if x <= 0 => exp = 0; else idx = (x >> EXP_SLOPE_SHIFT) clamped to 15
          x = V - V_T;
          if (x <= 0) begin
            idx   = 4'd0;
            exp_w = 16'sd0;
          end else begin
            // compute index, clamp
            // (x is signed positive here, so logical shift is OK, but use arithmetic for safety)
            reg [7:0] idx_raw;
            idx_raw = (x >>> EXP_SLOPE_SHIFT);
            if (idx_raw[7:4] != 4'd0) idx = 4'd15;
            else                      idx = idx_raw[3:0];
            exp_w = $signed({4'b0000, exp_lut(idx)}); // unsigned LUT -> positive signed
          end

          // Euler step: dV = I - leak + exp
          dv_w  = I_w - leak_w + exp_w;
          v_sum = $signed({{(17-V_W){V[V_W-1]}}, V}) + $signed({{1{dv_w[15]}}, dv_w});

          // Saturating add into V
          if (v_sum > $signed({1'b0, V_MAX})) begin
            V <= V_MAX;
          end else if (v_sum < $signed({1'b1, V_MIN})) begin
            V <= V_MIN;
          end else begin
            V <= v_sum[V_W-1:0];
          end

          // Spike check (use the *next* unclamped-ish value: compare v_sum)
          if (v_sum >= $signed({{(17-V_W){V_SPIKE[V_W-1]}}, V_SPIKE})) begin
            spike_pulse <= 1'b1;
            V          <= V_RESET;
            refrac_cnt <= T_REFRAC;
          end
        end
      end
    end
  end

  // -------------------------
  // Outputs
  // uo_out[7]   = spike pulse
  // uo_out[6:0] = membrane (top bits of signed V)
  // -------------------------
  wire [6:0] V_disp = V[V_W-1 -: 7]; // top 7 bits (2's complement)
  assign uo_out = {spike_pulse, V_disp};

  // List all unused inputs to prevent warnings
  // (uio_in[4:3] currently unused)
  wire _unused = &{uio_in[4:3], 1'b0};

endmodule
