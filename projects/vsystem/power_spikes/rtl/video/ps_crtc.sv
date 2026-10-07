//============================================================================
//  Power Spikes -- video timing, driven by the C7-01 GGA registers
//
//  docs/HARDWARE.md sections 2 and 3 have the evidence.  In short:
//
//      pixel clock  7.159090 MHz   = 14.31818 / 2   (divider UNVERIFIED)
//      refresh      61.327 Hz      vs 61.31 Hz measured on a PCB
//
//  HARDWARE-DERIVED FROM REGISTER TRAFFIC -- NOT FROM A DATASHEET.
//
//  The game writes twelve GGA registers once, in the first ~100 us after
//  reset, and never again (MAME tap, tools/mame/ps_gga.lua; all four sets
//  write the identical values).  Read as
//
//      H:  (reg + 1) * 4      V:  (reg + 1) * 2
//
//      reg 00 01 02 03 = 57 63 69 71  ->  352  400  424  456
//      reg 08 09 0a 0b = 77 79 7b 7f  ->  240  244  248  256
//      meaning           display-end  sync-start  sync-end  total
//
//  the written values land exactly on three numbers that were established
//  independently of them: MAME's visarea width 352, the 240 visible lines the
//  game itself declares through raster RAM (HARDWARE.md section 2), and the
//  456 x 256 totals that 61.31 Hz on a 7.16 MHz pixel clock requires.  That
//  fit is the whole of the evidence.  No datasheet, no scope trace: the
//  register MEANINGS are a decode, and the sync positions in particular rest
//  on it alone.  Registers 04/05 and 0c/0d (1f/00) are not decoded.
//
//  So the counters follow the registers, as the GGA must.  Until a group has
//  been written (all four of its registers), or if what was written is not a
//  sane ordering, that group runs on the defaults below -- which are the
//  same values every known set writes, so the board looks the same either
//  way.  The overlay reports which source is live (row 26 bits 15:14).
//
//  New values take effect at the end of a frame, never mid-frame: the game
//  writes address/data pairs one register at a time, and a half-updated
//  group must not reach the counters.
//
//  ONE THING DOES NOT FOLLOW THE REGISTERS: the tilemap and sprite engines
//  are scheduled against the compile-time H_VISIBLE / H_TOTAL / V_VISIBLE /
//  V_TOTAL parameters (fetch lead, line budgets).  Every known set writes
//  exactly those values, so they agree.  A set that wrote a different
//  geometry would get correct sync and blanking from here and a misaligned
//  picture from them.  The overlay flags a disagreement (row 26 bit 13).
//============================================================================
`default_nettype none

module ps_crtc #(
    // Defaults, used until the game writes the GGA.  The visible/total pair
    // is also what the rest of the video pipeline is scheduled against.
    // Sized, not `int`: these are compared against 10-bit registers, and
    // part-selecting an int parameter is shaky in Quartus 17.0 (ps_top).
    parameter [9:0] H_TOTAL    = 10'd456,
    parameter [9:0] H_VISIBLE  = 10'd352,
    parameter [9:0] H_SYNC_ON  = 10'd400,   // = (0x63+1)*4, see header
    parameter [9:0] H_SYNC_OFF = 10'd424,   // = (0x69+1)*4
    parameter [9:0] V_TOTAL    = 10'd256,
    parameter [9:0] V_VISIBLE  = 10'd240,
    parameter [9:0] V_SYNC_ON  = 10'd244,   // = (0x79+1)*2
    parameter [9:0] V_SYNC_OFF = 10'd248    // = (0x7b+1)*2
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    // GGA registers {00,01,02,03} and {08,09,0a,0b}, and whether each group
    // has been written in full since reset.
    input  wire [31:0] gga_h,
    input  wire [31:0] gga_v,
    input  wire        gga_h_ok,
    input  wire        gga_v_ok,

    output reg  [8:0]  hcnt,
    output reg  [8:0]  vcnt,
    output reg         hblank,
    output reg         vblank,
    output reg         hsync,
    output reg         vsync,
    output wire        visible,

    // one ce_pix-wide pulse at the first pixel of the first blanked line
    output reg         vblank_start,
    // one ce_pix-wide pulse at the start of every line
    output reg         line_start,

    // --- measurement: what the counters actually did ----------------------
    // Counted, not copied from the registers, so a decode that never reached
    // the counters shows up as a disagreement on the overlay.
    output wire [15:0] dbg_w0,   // {src_h, src_v, mismatch, 4'd0, lines/frame}
    output wire [15:0] dbg_w1,   // clk cycles per frame >> 4
    output wire [15:0] dbg_w2,   // {7'd0, ce_pix per line}
    output wire [15:0] dbg_w3,   // {hsync on [8:2], hsync off [8:2], 2'b00}
    output wire [15:0] dbg_w4    // {vsync on [8:1], vsync off [8:1]}
);

  assign visible = ~hblank & ~vblank;

  localparam [9:0] D_H_VIS = H_VISIBLE;
  localparam [9:0] D_H_SON = H_SYNC_ON;
  localparam [9:0] D_H_SOF = H_SYNC_OFF;
  localparam [9:0] D_H_TL  = H_TOTAL - 10'd1;
  localparam [9:0] D_V_VIS = V_VISIBLE;
  localparam [9:0] D_V_SON = V_SYNC_ON;
  localparam [9:0] D_V_SOF = V_SYNC_OFF;
  localparam [9:0] D_V_TL  = V_TOTAL - 10'd1;

  // ---------------------------------------------------------------------
  // Register decode.  Eleven bits so (0xff+1)*4 = 1024 does not wrap.
  // ---------------------------------------------------------------------
  function automatic [10:0] x4(input [7:0] r);
    x4 = {1'b0, r, 2'b00} + 11'd4;
  endfunction
  function automatic [10:0] x2(input [7:0] r);
    x2 = {2'b00, r, 1'b0} + 11'd2;
  endfunction

  wire [10:0] rh_vis = x4(gga_h[31:24]);
  wire [10:0] rh_son = x4(gga_h[23:16]);
  wire [10:0] rh_sof = x4(gga_h[15: 8]);
  wire [10:0] rh_tot = x4(gga_h[ 7: 0]);
  wire [10:0] rv_vis = x2(gga_v[31:24]);
  wire [10:0] rv_son = x2(gga_v[23:16]);
  wire [10:0] rv_sof = x2(gga_v[15: 8]);
  wire [10:0] rv_tot = x2(gga_v[ 7: 0]);

  // The counters are nine bits, so a total above 512 cannot be honoured.
  wire h_sane = gga_h_ok && (rh_vis < rh_son) && (rh_son < rh_sof) &&
                (rh_sof <= rh_tot) && (rh_tot <= 11'd512);
  wire v_sane = gga_v_ok && (rv_vis < rv_son) && (rv_son < rv_sof) &&
                (rv_sof <= rv_tot) && (rv_tot <= 11'd512);

  // Totals minus one, as the counters compare them.  Only meaningful when
  // the group is sane, which bounds them to 9 bits.
  wire [10:0] rh_tl = rh_tot - 11'd1;
  wire [10:0] rv_tl = rv_tot - 11'd1;

  // Live timing, loaded at the end of each frame.
  reg [9:0] h_vis, h_son, h_sof, h_tl;   // h_tl = total - 1
  reg [9:0] v_vis, v_son, v_sof, v_tl;
  reg       src_h, src_v;

  wire [8:0] h_last = h_tl[8:0];
  wire [8:0] v_last = v_tl[8:0];
  wire       eol    = (hcnt == h_last);
  wire       eof    = eol && (vcnt == v_last);

  always @(posedge clk) begin
    vblank_start <= 1'b0;
    line_start   <= 1'b0;

    if (rst) begin
      hcnt   <= 9'd0;
      vcnt   <= 9'd0;
      hblank <= 1'b0;
      vblank <= 1'b0;
      hsync  <= 1'b0;
      vsync  <= 1'b0;
      h_vis  <= D_H_VIS;  h_son <= D_H_SON;  h_sof <= D_H_SOF;  h_tl <= D_H_TL;
      v_vis  <= D_V_VIS;  v_son <= D_V_SON;  v_sof <= D_V_SOF;  v_tl <= D_V_TL;
      src_h  <= 1'b0;
      src_v  <= 1'b0;
    end else if (ce_pix) begin
      if (eol) begin
        hcnt       <= 9'd0;
        line_start <= 1'b1;
        if (vcnt == v_last) vcnt <= 9'd0;
        else                vcnt <= vcnt + 9'd1;
      end else begin
        hcnt <= hcnt + 9'd1;
      end

      // Blanking and sync are decoded from the *next* counter value so the
      // flags line up with the pixel they belong to.
      begin : decode
        reg [8:0] nh, nv;
        nh = eol ? 9'd0 : hcnt + 9'd1;
        nv = eol ? ((vcnt == v_last) ? 9'd0 : vcnt + 9'd1) : vcnt;

        hblank <= ({1'b0, nh} >= h_vis);
        vblank <= ({1'b0, nv} >= v_vis);
        hsync  <= ({1'b0, nh} >= h_son) && ({1'b0, nh} < h_sof);
        vsync  <= ({1'b0, nv} >= v_son) && ({1'b0, nv} < v_sof);

        if ({1'b0, nv} == v_vis && nh == 9'd0) vblank_start <= 1'b1;
      end

      // Last pixel of the frame: the next frame runs on whatever the
      // registers say now.
      if (eof) begin
        if (h_sane) begin
          h_vis <= rh_vis[9:0]; h_son <= rh_son[9:0];
          h_sof <= rh_sof[9:0]; h_tl  <= rh_tl[9:0];
        end else begin
          h_vis <= D_H_VIS; h_son <= D_H_SON; h_sof <= D_H_SOF; h_tl <= D_H_TL;
        end
        if (v_sane) begin
          v_vis <= rv_vis[9:0]; v_son <= rv_son[9:0];
          v_sof <= rv_sof[9:0]; v_tl  <= rv_tl[9:0];
        end else begin
          v_vis <= D_V_VIS; v_son <= D_V_SON; v_sof <= D_V_SOF; v_tl <= D_V_TL;
        end
        src_h <= h_sane;
        src_v <= v_sane;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Measurement.  Everything here is counted off the outputs above.
  // ---------------------------------------------------------------------
  reg        hs_q, vs_q;
  reg  [8:0] pix_n, pix_line, line_n, lines_fr;
  reg [19:0] clk_n, clk_fr;
  reg  [8:0] hs_on, hs_off, vs_on, vs_off;

  always @(posedge clk) begin
    if (rst) begin
      hs_q <= 1'b0; vs_q <= 1'b0;
      pix_n <= 9'd0; pix_line <= 9'd0; line_n <= 9'd0; lines_fr <= 9'd0;
      clk_n <= 20'd0; clk_fr <= 20'd0;
      hs_on <= 9'd0; hs_off <= 9'd0; vs_on <= 9'd0; vs_off <= 9'd0;
    end else begin
      hs_q <= hsync;
      vs_q <= vsync;
      // hsync/vsync change on the same clock as the counter they were
      // decoded for, so the counter value here is the edge's own position.
      if ( hsync && !hs_q) hs_on  <= hcnt;
      if (!hsync &&  hs_q) hs_off <= hcnt;
      if ( vsync && !vs_q) vs_on  <= vcnt;
      if (!vsync &&  vs_q) vs_off <= vcnt;

      clk_n <= clk_n + 20'd1;
      if (ce_pix) begin
        if (eol) begin
          pix_line <= pix_n + 9'd1;
          pix_n    <= 9'd0;
          if (vcnt == v_last) begin
            lines_fr <= line_n + 9'd1;
            line_n   <= 9'd0;
            clk_fr   <= clk_n;
            clk_n    <= 20'd0;
          end else begin
            line_n <= line_n + 9'd1;
          end
        end else begin
          pix_n <= pix_n + 9'd1;
        end
      end
    end
  end

  // Do the registers describe the geometry the rest of the pipeline was
  // scheduled for?  See the header.
  wire mismatch = (h_vis != D_H_VIS) || (h_tl != D_H_TL) ||
                  (v_vis != D_V_VIS) || (v_tl != D_V_TL);

  assign dbg_w0 = {src_h, src_v, mismatch, 4'd0, lines_fr};
  assign dbg_w1 = clk_fr[19:4];
  assign dbg_w2 = {7'd0, pix_line};
  assign dbg_w3 = {hs_on[8:2], hs_off[8:2], 2'b00};
  assign dbg_w4 = {vs_on[8:1], vs_off[8:1]};

endmodule

`default_nettype wire
