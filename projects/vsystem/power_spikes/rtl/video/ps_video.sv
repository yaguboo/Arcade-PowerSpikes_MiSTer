//============================================================================
//  Power Spikes -- video top: timing, tilemap, palette, output
//
//  Layer order on this board (MAME screen_update_pspikes):
//      tilemap  ->  sprites priority 1  ->  sprites priority 0
//  The tilemap is the bottom layer, it is OPAQUE (no transparent pen), and
//  there is nothing under it -- so palette entry 0 is never the backdrop for
//  this game, it is just another tilemap colour.
//
//  ps_sprite resolves the two sprite passes internally into one line buffer,
//  so the mixer here is a single transparency test.
//
//  Palette: 2048 entries of xRGB555 = xRRRRRGGGGGBBBBB (MAME emupal.h).
//  Tilemap colours occupy 0-1023, sprites 1024-2047.
//============================================================================
`default_nettype none

module ps_video #(
    // The visible line count, shared with ps_crtc so the sprite and tilemap
    // engines can tell which lines are worth rendering.  Repeating 240 in
    // each of them is how a timing change goes half-applied.
    parameter int V_TOTAL   = 256,
    parameter int V_VISIBLE = 240,
    parameter int H_VISIBLE = 352,
    parameter int H_TOTAL   = 456
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    // --- registers from the CPU side ---------------------------------------
    input  wire [7:0]  gfxbank,
    input  wire [2:0]  char_palbank,
    input  wire [1:0]  spr_palbank,
    input  wire [8:0]  scrolly,
    input  wire        flip_screen,

    // --- C7-01 GGA timing registers -> ps_crtc ------------------------------
    input  wire [31:0] gga_h,          // regs {00,01,02,03}
    input  wire [31:0] gga_v,          // regs {08,09,0a,0b}
    input  wire        gga_h_ok,       // all four written since reset
    input  wire        gga_v_ok,

    // --- dual-port RAM, video side -----------------------------------------
    output wire [10:0] vram_addr,
    input  wire [15:0] vram_data,
    output wire [10:0] raster_addr,
    input  wire [15:0] raster_data,
    output wire [10:0] pal_addr,
    input  wire [15:0] pal_data,
    output wire [8:0]  spr_addr,
    input  wire [15:0] spr_data,
    output wire [12:0] sprlut_addr,
    input  wire [15:0] sprlut_data,

    // --- tile ROM through the arbiter --------------------------------------
    output wire [24:0] gfx1_addr,
    input  wire [15:0] gfx1_data,
    output wire        gfx1_req,
    input  wire        gfx1_ack,

    // --- sprite ROM through the arbiter ------------------------------------
    output wire [24:0] gfx2_addr,
    input  wire [15:0] gfx2_data,
    output wire        gfx2_req,
    input  wire        gfx2_ack,

    // --- output ------------------------------------------------------------
    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue,
    output reg         hsync,
    output reg         vsync,
    output reg         hblank,
    output reg         vblank,
    output wire        ce_pix_out,

    output wire        vblank_start,   // -> 68000 IRQ1
    output wire [15:0] dbg_tm_late,    // tilemap rows whose fetch missed phase 7
    output wire [15:0] dbg_tm_late_l,  // ...and where: {first third, hcnt >= 215}
    output wire [79:0] dbg_crtc,       // ps_crtc's own measurement, 5 words
    output wire [8:0]  dbg_hcnt,
    output wire [8:0]  dbg_vcnt,
    output wire [15:0] dbg_spr_drawn,
    output wire [15:0] dbg_spr_hit,
    output wire [15:0] dbg_spr_overrun,
    output wire [15:0] dbg_spr_snap1,
    output wire [15:0] dbg_spr_snap2,
    output wire [15:0] dbg_spr_nonrom,
    output wire [15:0] dbg_spr_workload,
    output wire [15:0] dbg_raster_msg,
    output wire [15:0] dbg_raster_court,
    output wire [15:0] dbg_o6_map,
    output wire [15:0] dbg_o6_tile,
    output wire [15:0] dbg_o6_pos,
    output wire [15:0] dbg_o6_first,
    output wire [15:0] dbg_o6_sx,
    output wire [15:0] dbg_o6_blitx,
    output wire [15:0] dbg_o6_row0,
    output wire [15:0] dbg_o6_row1,
    output wire [15:0] dbg_o6_row2,
    output wire [15:0] dbg_o6_row3
);

  // ---------------------------------------------------------------------
  // Timing
  // ---------------------------------------------------------------------
  wire [8:0] hcnt, vcnt;
  wire       hb, vb, hs, vs, visible, line_start;

  ps_crtc #(.V_TOTAL(V_TOTAL), .V_VISIBLE(V_VISIBLE),
            .H_VISIBLE(H_VISIBLE), .H_TOTAL(H_TOTAL)) u_crtc (
      .clk(clk), .rst(rst), .ce_pix(ce_pix),
      .gga_h(gga_h), .gga_v(gga_v), .gga_h_ok(gga_h_ok), .gga_v_ok(gga_v_ok),
      .hcnt(hcnt), .vcnt(vcnt),
      .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
      .visible(visible),
      .vblank_start(vblank_start), .line_start(line_start),
      .dbg_w0(dbg_crtc[79:64]), .dbg_w1(dbg_crtc[63:48]),
      .dbg_w2(dbg_crtc[47:32]), .dbg_w3(dbg_crtc[31:16]),
      .dbg_w4(dbg_crtc[15:0])
  );

  assign dbg_hcnt = hcnt;
  assign dbg_vcnt = vcnt;
  assign ce_pix_out = ce_pix;

  // ---------------------------------------------------------------------
  // Flip screen.
  //
  // The DIP and the palette-bank bit 7 both drive it.  On the real board
  // flipping is done in the scan hardware, so it mirrors the whole visible
  // window.  Applying it to the fetch coordinates keeps every layer
  // consistent for free once sprites arrive.
  //
  // NOT YET VERIFIED against hardware or MAME pixels.  Power Spikes is a
  // cocktail-capable board and MAME marks its cocktail support
  // "preliminary", so this is the least-trustworthy part of the file.
  // ---------------------------------------------------------------------
  wire [8:0] fx_h = flip_screen ? (9'd351 - hcnt) : hcnt;
  wire [8:0] fx_v = flip_screen ? (9'd239 - vcnt) : vcnt;

  // ---------------------------------------------------------------------
  // Tilemap
  // ---------------------------------------------------------------------
  wire [9:0] tm_pix;

  ps_tilemap #(.V_VISIBLE(V_VISIBLE), .V_TOTAL(V_TOTAL),
               .H_VISIBLE(H_VISIBLE), .H_TOTAL(H_TOTAL)) u_tilemap (
      .dbg_late(dbg_tm_late),
      .dbg_late_l(dbg_tm_late_l),
      .clk(clk), .rst(rst), .ce_pix(ce_pix),
      .hcnt(fx_h), .vcnt(fx_v), .line_start(line_start),
      .gfxbank(gfxbank), .char_palbank(char_palbank), .scrolly(scrolly),
      .vram_addr(vram_addr), .vram_data(vram_data),
      .raster_addr(raster_addr), .raster_data(raster_data),
      .dbg_raster_msg(dbg_raster_msg), .dbg_raster_court(dbg_raster_court),
      .rom_addr(gfx1_addr), .rom_data(gfx1_data),
      .rom_req(gfx1_req), .rom_ack(gfx1_ack),
      .pix(tm_pix)
  );

  // ---------------------------------------------------------------------
  // Sprites
  //
  // The sprite engine runs on RAW hcnt/vcnt, not the flipped coordinates:
  // it renders into a line buffer indexed by the sprite's own X, and MAME
  // applies flip_screen inside the sprite maths (ox -> 308-ox, and the flip
  // bits invert).  Feeding it flipped counters as well would flip twice.
  // ---------------------------------------------------------------------
  wire [9:0] sp_pix;
  wire       sp_opaque;

  ps_sprite #(.V_TOTAL(V_TOTAL), .V_VISIBLE(V_VISIBLE)) u_sprite (
      .clk(clk), .rst(rst), .ce_pix(ce_pix),
      .hcnt(hcnt), .vcnt(vcnt), .line_start(line_start),
      .spr_palbank(spr_palbank), .flip_screen(flip_screen),
      .spr_addr(spr_addr), .spr_data(spr_data),
      .lut_addr(sprlut_addr), .lut_data(sprlut_data),
      .rom_addr(gfx2_addr), .rom_data(gfx2_data),
      .rom_req(gfx2_req), .rom_ack(gfx2_ack),
      .pix(sp_pix), .opaque(sp_opaque),
      .dbg_drawn(dbg_spr_drawn), .dbg_hit(dbg_spr_hit),
      .dbg_overrun(dbg_spr_overrun),
      .dbg_snap1(dbg_spr_snap1),
      .dbg_snap2(dbg_spr_snap2),
      .dbg_nonrom(dbg_spr_nonrom),
      .dbg_workload(dbg_spr_workload),
      .dbg_o6_map(dbg_o6_map),
      .dbg_o6_tile(dbg_o6_tile),
      .dbg_o6_pos(dbg_o6_pos),
      .dbg_o6_first(dbg_o6_first),
      .dbg_o6_sx(dbg_o6_sx),
      .dbg_o6_blitx(dbg_o6_blitx),
      .dbg_o6_row0(dbg_o6_row0),
      .dbg_o6_row1(dbg_o6_row1),
      .dbg_o6_row2(dbg_o6_row2),
      .dbg_o6_row3(dbg_o6_row3)
  );

  // ---------------------------------------------------------------------
  // Mixer -> palette lookup
  //
  // One layer today, so the mux is trivial; it exists in this shape so that
  // adding the two sprite passes is an edit to one place.
  // ---------------------------------------------------------------------
  // Sprite colours live at 1024-2047, tilemap colours at 0-1023.
  wire [10:0] pal_index = sp_opaque ? {1'b1, sp_pix} : {1'b0, tm_pix};
  assign pal_addr = pal_index;

  // ---------------------------------------------------------------------
  // Output.  Palette RAM has one clock of latency, so the sync/blank flags
  // are delayed one ce_pix to line up with the colour they belong to.
  // ---------------------------------------------------------------------
  reg hb_d, vb_d, hs_d, vs_d, vis_d;

  always @(posedge clk) begin
    if (rst) begin
      {red, green, blue} <= 24'd0;
      {hsync, vsync, hblank, vblank} <= 4'd0;
      {hb_d, vb_d, hs_d, vs_d, vis_d} <= 5'd0;
    end else if (ce_pix) begin
      hb_d <= hb; vb_d <= vb; hs_d <= hs; vs_d <= vs; vis_d <= visible;

      hblank <= hb_d; vblank <= vb_d;
      hsync  <= hs_d; vsync  <= vs_d;

      if (vis_d) begin
        // xRRRRRGGGGGBBBBB -> 8 bits each, replicating the top bits so that
        // 5'b11111 maps to 8'hFF rather than 8'hF8.
        red   <= {pal_data[14:10], pal_data[14:12]};
        green <= {pal_data[ 9: 5], pal_data[ 9: 7]};
        blue  <= {pal_data[ 4: 0], pal_data[ 4: 2]};
      end else begin
        {red, green, blue} <= 24'd0;
      end
    end
  end

endmodule

`default_nettype wire
