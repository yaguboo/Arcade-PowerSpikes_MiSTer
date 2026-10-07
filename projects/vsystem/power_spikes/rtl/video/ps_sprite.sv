//============================================================================
//  Power Spikes -- VS8904 / VS8905 sprite engine
//
//  Scanline renderer: while line L is being displayed, line L+1 is rendered
//  into a line buffer.  The real chip does the same thing -- that is why the
//  sprite list has a start index and why zoom is expressed per tile row.
//
//  ---- sprite RAM ---------------------------------------------------------
//  0x200 words, four per sprite.  docs/HARDWARE.md section 7.
//
//      word 0   [8:0] Y        [15:12] Y zoom
//      word 1   [8:0] X        [15:12] X zoom
//      word 2   [3:0] colour   [4] priority   [7] ENABLE, ACTIVE LOW
//               [10:8] xsize-1 [11] flipx     [14:12] ysize-1  [15] flipy
//      word 3   map index -- NOT a tile number
//
//  The list does not start at 0.  spriteram[0x1fe] * 4 is the first entry,
//  clamped to 0x1fc.
//
//  ---- the map index ------------------------------------------------------
//  Word 3 indexes the 16 K sprite lookup RAM, and THAT word is the tile
//  number.  MAME advances the index once per tile and then applies a
//  correction per row (handle_xsize_map_inc): +1 for xsize 2, +3 for 4,
//  +2 for 5, +1 for 6.  Written out, the row stride is
//
//      xsize   0  1  2  3  4  5  6  7      (tiles across = xsize+1)
//      stride  1  2  4  4  8  8  8  8
//
//  which is (xsize+1) rounded UP TO A POWER OF TWO.  The hardware lays
//  sprite tiles out in power-of-2 blocks; MAME's four special cases are that
//  one fact written as a table.  So:
//
//      map index of tile (x, y) = base + y * stride + x
//
//  ---- zoom ---------------------------------------------------------------
//  zoom = 32 - raw, so raw 0 is 1:1 and larger raw shrinks.  A 16-pixel tile
//  covers zoom/2 destination pixels, and destination pixel c of a tile reads
//  source column (c * zoom) >> 5.  Tile n starts at (zoom * n) / 2 from the
//  sprite origin.
//
//  MAME's own header says the zoom is "probably not 100% accurate" and that
//  pspikes' zooming attract-mode text "is horrible", so this is the first
//  place a pixel comparison should be expected to disagree.   UNVERIFIED
//
//  ---- layering -----------------------------------------------------------
//  MAME draws pri==1 sprites, then pri==0, both over the tilemap, each pass
//  walking the list from `first` UP to the end, and later writes winning --
//  which is the same picture MAME gets by walking DOWN and keeping the FIRST
//  write, because both leave the highest index owning the pixel.
//
//  This does exactly that: two passes, descending, writing unconditionally.
//
//  The tempting optimisation is to reverse it into ONE pass with "first
//  write wins", carrying the priority bit per pixel.  That halves the
//  sprite-RAM traffic and it is what this module did first -- but it needs a
//  read-modify-write on the line buffer, and a combinationally-read memory
//  array does not infer as M10K.  It becomes 12 288 flip-flops instead, on a
//  device with 41 910 ALMs.  Two passes and an unconditional write keep the
//  buffer as real block RAM and the blit at one pixel per clock.
//
//  Cost: the sprite list is walked twice.  dbg_overrun counts lines that ran
//  out of time, so the cost is measured rather than assumed.
//============================================================================
`default_nettype none

module ps_sprite #(
    parameter int V_TOTAL   = 256,     // both must come from ps_video
    parameter int V_VISIBLE = 240
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,
    input  wire        line_start,

    input  wire [1:0]  spr_palbank,
    input  wire        flip_screen,

    // --- sprite RAM (video side of the dual-port block) --------------------
    output reg  [8:0]  spr_addr,
    input  wire [15:0] spr_data,

    // --- sprite lookup RAM (video side) ------------------------------------
    output reg  [12:0] lut_addr,
    input  wire [15:0] lut_data,

    // --- sprite ROM through the arbiter ------------------------------------
    output reg  [24:0] rom_addr,
    input  wire [15:0] rom_data,
    output reg         rom_req,
    // THIS ENGINE HAS NO DEADLINE OVERRIDE, AND MUST NOT BE GIVEN ONE.
    //
    // It renders the NEXT line into a line buffer, so its deadline is a whole
    // line -- 2,549 clocks.  The tilemap draws the pixel being scanned out
    // now and has 39.  An override here was built and measured and removed;
    // ps_top.sv, at `arb_urgent`, has the numbers.  `dbg_overrun` below is
    // what says whether this engine needs help, and it reads 0.
    input  wire        rom_ack,

    // --- pixel out ---------------------------------------------------------
    output wire [9:0]  pix,       // {colour[5:0], pixel[3:0]} within 1024..2047
    output wire        opaque,

    // --- observability -----------------------------------------------------
    // CUMULATIVE, wrapping.  These were per-LINE once (dbg_drawn latched the
    // previous line's total at every line_start) and that made them useless
    // as a diagnostic: the overlay is painted across the TOP of the screen,
    // so the value on show was the count for a scanline near the top, where
    // this game happens to have no sprites.  It read 0 while sprites were
    // being drawn perfectly well further down the frame.
    // A counter whose window is not the thing you are asking about is not an
    // instrument -- docs/LESSONS_LEARNED.md L9.
    output reg  [15:0] dbg_drawn,     // tile rows blitted, cumulative
    output reg  [15:0] dbg_hit,       // sprites that were enabled AND on-line
    output reg  [15:0] dbg_overrun,
    // Where does an OVERRUNNING line spend its time?  dbg_overrun says a line
    // failed to finish, and nothing says why.  The arithmetic for the screen
    // that flickers -- 29 list entries, six 1x1 unzoomed hits -- comes to
    // about 476 clocks of non-ROM work against a 2549-clock line, so either
    // the time went into S_ROM waiting on SDRAM, or the list the FPGA walks
    // is not the list MAME's census described.
    //
    // S_ROM is the only unbounded state in the machine, so counting the
    // cycles that are busy but NOT in S_ROM separates the two: ~476 means the
    // rest was lost waiting for sprite ROM; well above ~1000 means the
    // workload itself is bigger than the census said.  Both are latched at
    // the instant the overrun is counted, so they describe the line that
    // actually failed rather than an average.
    output reg  [15:0] dbg_nonrom,   // busy-but-not-S_ROM cycles, that line
    output reg  [15:0] dbg_workload, // {words acked, sprites hit} on that line
    // The snapshot above was overwritten by EVERY overrun and carried no line
    // number.  At roughly 3,000 overruns a second and 61.31 frames a second
    // that is about 49 per frame, while the only band that visibly flickers is
    // y=145..159 -- so the numbers read off the overlay were not necessarily
    // from the line the defect is on.  These two freeze the FIRST overrun
    // inside that band each frame, and carry enough state to tell "the line
    // was cut off part way" from "this is what the line actually needed".
    output reg  [15:0] dbg_snap1,    // {tile rows DEMANDED, target line}
    output reg  [15:0] dbg_snap2,    // {pass, xi, word_n, list index}
    // --- O6: what does this module actually compute for the message line? ---
    // The board's attract is never at the same instant as MAME's, so absolute
    // positions cannot be compared.  map_base and the tile_no it resolves to
    // CAN be: the sprite lookup RAM is a character table and is largely
    // static, so `does lut[map_base] here equal lut[map_base] in MAME` is a
    // fair question at any moment.  docs/DEBUG_LOG.md O6.
    output reg  [15:0] dbg_o6_map,     // map_base of a sprite on the message line
    output reg  [15:0] dbg_o6_tile,    // the tile number it resolved to, xi=0
    output reg  [15:0] dbg_o6_pos,     // {ox[8:0], xsize[2:0], ysize[2:0], 1'b0}
    output reg  [15:0] dbg_o6_first,   // the list pointer the board computed
    output reg  [15:0] dbg_o6_sx,       // {sx[8:0], 7'd0} for tile 0
    output reg  [15:0] dbg_o6_blitx,     // {blit_x[8:0], tile_w[5:0], 1'b0}
    // The 64 pixel-nibbles of the latched sprite's first tile row, straight
    // off the ROM fetch.  ox, sx and blit_x are all confirmed identical to
    // MAME, so position is not the fault; this says whether the DATA is.
    // tile_no is known, so these four words can be compared against
    // roms/pspikes.bin directly with no board-vs-MAME timing question.
    output reg  [15:0] dbg_o6_row0,
    output reg  [15:0] dbg_o6_row1,
    output reg  [15:0] dbg_o6_row2,
    output reg  [15:0] dbg_o6_row3
);

  `include "ps_rommap.svh"

  // ---------------------------------------------------------------------
  // Line buffer: two 512-entry buffers, rendered into alternately.
  //
  //     [10] valid   [9:4] colour   [3:0] pixel
  //
  // The renderer writes the buffer for line vcnt+1.  The display reads the
  // other one and zero-fills behind itself, so a buffer is always empty by
  // the time it is rendered into again and there is no separate clear pass.
  //
  // WHY TWO ARRAYS AND NOT ONE WITH THE PARITY IN THE TOP ADDRESS BIT.
  //
  // One array was tidier and it cost 7,673 ALMs.  It made the display port
  // read and write THE SAME ADDRESS in the same cycle -- read the pixel, then
  // clear it -- and the read has to return the value from before the write.
  // No M10K port can do that: same-port read-during-write gives new data or
  // don't-care, never old.  Quartus cannot map it, says nothing about it, and
  // builds all 11,264 bits out of registers.  On MiSTer there was room to
  // absorb that; on Pocket it was most of the reason the design came out at
  // 126 % of the device.
  //
  // Split in two, each buffer is a plain simple-dual-port: one write port --
  // the renderer while it is the render buffer, the zero-fill while it is the
  // display buffer, and it is never both at once -- and one read port.  The
  // zero-fill runs ONE pixel behind the read, so the two ports never share an
  // address and the M10K's mixed-port behaviour never has to be reasoned
  // about at all.
  //
  // Every entry IS read once per line: the display walks hcnt over the full
  // H_TOTAL of 456, and sprite X is 9 bits, so entries 456..511 are never
  // read and never cleared.  They are also never displayed, so a stale value
  // there cannot reach the screen.
  // ---------------------------------------------------------------------
  localparam int LBW = 11;

  reg [LBW-1:0] lb0 [0:511];
  reg [LBW-1:0] lb1 [0:511];

  wire render_buf  = ~vcnt[0];   // rendering line vcnt+1
  wire display_buf =  vcnt[0];

  wire [8:0] disp_x = hcnt;

  // The zero-fill, trailing the read by one pixel.
  reg [8:0] clr_x;
  reg       clr_buf;
  reg       clr_v;

  // At the line wrap the trailing fill still points at the buffer that has
  // just become the RENDER buffer.  Dropping that one fill is free -- it is
  // the entry at the last hcnt, which is outside the visible width and never
  // displayed -- and it keeps the renderer's write port uncontended.
  wire clr_go = clr_v & ce_pix & (clr_buf != render_buf);

  wire           w0_en = (~render_buf & wr_en) | (clr_go & ~clr_buf);
  wire [8:0]     w0_a  = (~render_buf & wr_en) ? wr_addr : clr_x;
  wire [LBW-1:0] w0_d  = (~render_buf & wr_en) ? wr_data : {LBW{1'b0}};

  wire           w1_en = ( render_buf & wr_en) | (clr_go &  clr_buf);
  wire [8:0]     w1_a  = ( render_buf & wr_en) ? wr_addr : clr_x;
  wire [LBW-1:0] w1_d  = ( render_buf & wr_en) ? wr_data : {LBW{1'b0}};

  reg [LBW-1:0] q0, q1;
  reg           q_sel;

  always @(posedge clk) begin
    if (w0_en) lb0[w0_a] <= w0_d;
    if (w1_en) lb1[w1_a] <= w1_d;

    if (ce_pix) begin
      q0      <= lb0[disp_x];
      q1      <= lb1[disp_x];
      q_sel   <= display_buf;
      clr_x   <= disp_x;
      clr_buf <= display_buf;
      clr_v   <= 1'b1;
    end
  end

  wire [LBW-1:0] disp_q = q_sel ? q1 : q0;

  assign pix    = disp_q[9:0];
  assign opaque = disp_q[10];

  // ---------------------------------------------------------------------
  // Render side
  // ---------------------------------------------------------------------
  localparam [3:0] S_IDLE  = 4'd0,  S_FIRST0 = 4'd1,  S_FIRST1 = 4'd2,
                   S_A0    = 4'd3,  S_A1     = 4'd4,  S_A2     = 4'd5,
                   S_A3    = 4'd6,  S_DECIDE = 4'd7,  S_LUT0   = 4'd8,
                   S_LUT1  = 4'd9,  S_ROM    = 4'd10, S_BLIT   = 4'd11,
                   S_XNEXT = 4'd12, S_NEXT   = 4'd13, S_LUTW   = 4'd14;

  reg [3:0] st;

  // Probe state.  12 bits saturating: a line is 2549 clocks, so 4095 cannot
  // wrap into a small number and read as healthy.
  reg [11:0] nonrom_cnt;
  reg [7:0]  hits_line;
  // How many words the arbiter actually DELIVERED on this line.  The state
  // machine is cut off at line_start, so an overrunning line's busy time is
  // exactly one line -- 2,549 clocks -- and S_ROM time is 2549 minus the
  // non-ROM count.  Dividing that by the words actually acked is the real
  // cost per fetch, where everything so far has only been a lower bound.
  reg [7:0]  acks_line;
  // ...and how many TILES it started.  152 words for six 1x1 sprites is 25
  // words each where four would do, so the question is no longer whether the
  // memory is slow -- at 10 clocks a word it is not -- but why the engine
  // asks for six times what the picture needs.  Words per tile settles it:
  // four means the tile count is wrong, more means the fetch loop is.
  reg [3:0]  tiles_line;
  // Tile ROWS this line asked for, counted from the FPGA's own attributes:
  // xsize+1 added once per accepted hit.  Not saturating -- six hits can
  // legitimately demand up to 48 rows, and a counter that stops short is how
  // the last one read 15 and meant nothing.
  reg [7:0]  demand_tiles;
  reg        snap_done;

  reg [8:0]  idx;          // current sprite attribute word index (multiple of 4)
  reg [8:0]  first;
  reg [15:0] a0, a1, a2;
  reg [15:0] map_base;

  reg [8:0]  target;       // the scanline being rendered

  // The line this render is FOR.  `vcnt + 1` does not wrap on its own: vcnt
  // counts 0..255 in nine bits, so at 255 it produced 256, a target no sprite
  // can ever cover -- line 0 came out with no sprites on it at all.
  wire [8:0] next_line       = (vcnt == V_TOTAL - 1) ? 9'd0 : vcnt + 9'd1;
  wire       next_is_visible = (next_line < V_VISIBLE);

  // decoded attributes
  wire [8:0] oy_raw = a0[8:0];
  wire [3:0] zy_raw = a0[15:12];
  wire [8:0] ox_raw = a1[8:0];

  // FLIP SCREEN.  MAME mirrors the sprite's ORIGIN and negates the per-tile
  // offsets, on top of inverting the flip bits:
  //
  //     ox = 308 - ox;  oy = 208 - oy;  fx = !fx;  fy = !fy;
  //     sx = ((ox + zoomx * (flip_screen ? -cx : cx) / 2 + 16) & 0x1ff) - 16
  //
  // (vsystem_spr2.cpp).  This module inverted the flip bits and stopped there,
  // so with flip on the tilemap turned over and the sprites stayed where they
  // were -- which is not a subtle error, it is the game unplayable upside
  // down.  Never noticed because flip screen had never once been switched on.
  wire [8:0] ox     = flip_screen ? (9'd308 - ox_raw) : ox_raw;
  wire [8:0] oy     = flip_screen ? (9'd208 - oy_raw) : oy_raw;
  wire [3:0] zx_raw = a1[15:12];
  wire [3:0] colour = a2[3:0];
  wire       pri    = a2[4];
  wire       enable = a2[7];
  wire [2:0] xsize  = a2[10:8];
  wire       flipx  = a2[11] ^ flip_screen;
  wire [2:0] ysize  = a2[14:12];
  wire       flipy  = a2[15] ^ flip_screen;

  wire [5:0] zoomx = 6'd32 - {2'b00, zx_raw};
  wire [5:0] zoomy = 6'd32 - {2'b00, zy_raw};

  // row stride = (xsize+1) rounded up to a power of two
  reg [3:0] stride;
  always @(*) begin
    case (xsize)
      3'd0:    stride = 4'd1;
      3'd1:    stride = 4'd2;
      3'd2,
      3'd3:    stride = 4'd4;
      default: stride = 4'd8;
    endcase
  end

  // --- vertical coverage -------------------------------------------------
  // Find the loop row y whose on-screen position covers `target`.
  reg [2:0]  hit_y;
  reg        hit;
  reg [3:0]  src_row;
  // Registered copies, latched in S_DECIDE.  See the note there.
  reg [2:0]  hit_y_r;
  reg [3:0]  src_row_r;
  reg signed [21:0] src_prod;
  // The lookup index, computed wide and then sliced.  `(...) & 13'h1fff`
  // assigned to a 13-bit target is a truncation warning for a value that is
  // deliberately wrapped; the slice says the same thing without one.
  wire [15:0] lut_sum = map_base + {9'd0, hit_y_r} * {12'd0, stride}
                        + {13'd0, xi};

  integer yi;
  reg [2:0]  cy_t;
  reg [8:0]  zy_t;
  reg signed [12:0] sy_w;
  reg signed [10:0] sy_t;
  reg signed [10:0] dy_t;

  always @(*) begin
    hit     = 1'b0;
    hit_y   = 3'd0;
    src_row = 4'd0;
    // Defaults for the loop temporaries too.  They are only READ inside the
    // `if (yi <= ysize)` that assigns them, so the held value could never
    // reach an output -- but Quartus still inferred three transparent
    // latches, and a latch in what should be combinational logic is the
    // shape that works in one fit and not the next.  docs/DEBUG_LOG.md O5.
    cy_t     = 3'd0;
    zy_t     = 9'd0;
    sy_w     = 13'sd0;
    sy_t     = 11'sd0;
    dy_t     = 11'sd0;
    src_prod = 22'sd0;
    for (yi = 0; yi < 8; yi = yi + 1) begin
      if (yi <= ysize) begin
        cy_t = flipy ? (ysize - yi[2:0]) : yi[2:0];
        // (oy + zoomy*cy/2 + 16) & 0x1ff, then -16, with the middle term
        // NEGATED when the screen is flipped.  Computed signed and masked
        // afterwards, the way MAME's int arithmetic does it.
        zy_t = (zoomy * cy_t) >> 1;
        sy_w = $signed({4'd0, oy}) +
               (flip_screen ? -$signed({4'd0, zy_t}) : $signed({4'd0, zy_t})) +
               13'sd16;
        sy_t = $signed({2'b00, sy_w[8:0]}) - 11'sd16;
        dy_t = $signed({2'b00, target}) - sy_t;
        if (!hit && dy_t >= 0 && dy_t < $signed({5'd0, zoomy[5:1]})) begin
          hit     = 1'b1;
          hit_y   = yi[2:0];
          // source row = (dy * zoomy) >> 5, then flipped inside the tile
          // Named intermediate: `(a*b >> 5) & 4'hF` assigned to a 4-bit
          // target is a truncation Quartus warns about, and the project
          // targets zero project-owned warnings.  The value is unchanged.
          src_prod = dy_t * $signed({5'd0, zoomy});
          src_row  = flipy ? (4'd15 - src_prod[8:5]) : src_prod[8:5];
        end
      end
    end
  end

  // --- per-tile-column state --------------------------------------------
  reg [2:0]  xi;
  reg [63:0] rowbits;
  reg [1:0]  word_n;
  // blit_x / blit_c / px_val moved into the decoupled blitter above; the
  // sequencer no longer walks pixels.

  wire [2:0] cx      = flipx ? (xsize - xi) : xi;
  wire [8:0] zx_t    = (zoomx * cx) >> 1;
  wire signed [12:0] sx_w = $signed({4'd0, ox}) +
                            (flip_screen ? -$signed({4'd0, zx_t})
                                         : $signed({4'd0, zx_t})) + 13'sd16;
  wire [8:0] sx      = sx_w[8:0] - 9'd16;
  wire [5:0] tile_w  = zoomx[5:1];                 // destination width
  // WIDEN THE MULTIPLY EXPLICITLY.  This was
  //     wire [3:0] src_col_raw = ((blit_c * zoomx) >> 5) & 4'hF;
  // and Verilog sizes the whole right-hand side to the CONTEXT width, which
  // here is 6 bits (the widest operand), not the 12 the product needs.  So
  // blit_c * zoomx was evaluated modulo 64 and the >> 5 then yielded only 0
  // or 1: every pixel of a sprite came from source column 0 or 1.
  //
  // On screen that is solid vertical stripes at exactly the right position
  // and size -- which is why it looked like a ROM or interleave fault and
  // cost a detour through both.  The gfx2 data was correct all along; the
  // ROM probe in ps_top proved that before this was found.

  // pixel p: byte p>>1, low nibble first

  // --- line-buffer write ------------------------------------------------
  // The blitter runs on its OWN, beside the fetch, and this is the fix for
  // DEBUG_LOG O17.
  //
  // Measured on the line that flickers -- y=145, tagged, not inferred -- the
  // engine demands 38 tile rows, is delivered exactly 38, and needs
  //
  //     38 rows x 4 words x 10.5 clocks   1,596
  //     non-ROM work                        954
  //                                       -----
  //                                       2,550   against a 2,549-clock line
  //
  // over by about one clock.  Nothing is wasted and nothing is repeated; the
  // work is simply a hair more than the line holds.  608 of those 954 non-ROM
  // clocks are S_BLIT: sixteen pixels a tile, thirty-eight tiles, and the
  // sequencer did them with the memory idle because S_ROM and S_BLIT were
  // strictly consecutive.
  //
  // Fetching a row costs about 42 clocks and drawing it costs 16, so handing
  // the finished row to a blitter that drains itself while the next row is
  // being fetched hides the whole 608 behind the fetch.  It buys far more
  // than the deficit and it costs no block RAM, which matters because Pocket
  // has about 32 M10K of headroom (DEBUG_LOG O16).
  //
  // Blitting cannot start earlier than a whole row: `src_col` is
  // `blit_c * zoomx >> 5`, so a zoomed sprite reads its source pixels out of
  // order and the word that supplies pixel 0 is not always the first one.
  reg [63:0] bl_row;
  reg [8:0]  bl_x;
  reg [5:0]  bl_c, bl_w;
  reg [5:0]  bl_zoomx;
  reg        bl_flipx;
  reg [3:0]  bl_colour;
  reg [1:0]  bl_pal;
  reg        bl_busy;

  wire [11:0] bl_prod    = {6'd0, bl_c} * {6'd0, bl_zoomx};
  wire [3:0]  bl_src_raw = bl_prod[8:5];
  wire [3:0]  bl_src     = bl_flipx ? (4'd15 - bl_src_raw) : bl_src_raw;
  wire [3:0]  bl_px      = bl_row[{bl_src, 2'b00} +: 4];

  reg           wr_en;
  reg [8:0]     wr_addr;
  reg [LBW-1:0] wr_data;

  // ---------------------------------------------------------------------
  // Sequencer
  // ---------------------------------------------------------------------
  reg        pass;         // 0 = pri==1 sprites, 1 = pri==0 sprites

  always @(posedge clk) begin
    wr_en <= 1'b0;

    // One pixel a clock, independent of whatever the sequencer is doing.
    if (rst) begin
      bl_busy <= 1'b0;
    end else if (line_start) begin
      // The line buffer swaps here, so a row still draining would land on the
      // wrong line.  Drop it: it belongs to the line that just ended.
      bl_busy <= 1'b0;
    end else if (bl_busy) begin
      if (bl_c >= bl_w) begin
        bl_busy   <= 1'b0;
        dbg_drawn <= dbg_drawn + 16'd1;
      end else begin
        if (bl_px != 4'hF) begin          // 15 is the transparent pen
          wr_en   <= 1'b1;
          wr_addr <= bl_x;
          wr_data <= {1'b1, bl_pal, bl_colour, bl_px};
        end
        bl_c <= bl_c + 6'd1;
        bl_x <= bl_x + 9'd1;
      end
    end

    if (rst) begin
      st          <= S_IDLE;
      rom_req     <= 1'b0;
      dbg_drawn   <= 16'd0;
      dbg_hit     <= 16'd0;
      dbg_overrun <= 16'd0;
      dbg_nonrom  <= 16'd0;
      dbg_workload<= 16'd0;
      nonrom_cnt  <= 12'd0;
      hits_line   <= 8'd0;
      acks_line   <= 8'd0;
      tiles_line  <= 4'd0;
      demand_tiles<= 8'd0;
      snap_done   <= 1'b0;
      dbg_snap1   <= 16'd0;
      dbg_snap2   <= 16'd0;
    end else begin
      // Busy, and not parked in S_ROM waiting for the arbiter.
      if (st != S_IDLE && st != S_ROM && nonrom_cnt != 12'hFFF)
        nonrom_cnt <= nonrom_cnt + 12'd1;
      if (line_start) begin
        // A line that has not finished by the next line_start ran out of
        // time.  Counting that is the only way to know the budget is enough
        // -- see docs/DEBUG_LOG.md O2.  This check stays OUTSIDE the visible
        // test below: the last visible line's render is cut off by exactly
        // this edge, and moving the counter inside would stop it seeing that.
        if (st != S_IDLE) begin
          dbg_overrun <= dbg_overrun + 16'd1;
          // `target` still holds the line that just failed to finish.
          //
          // THIS USED TO BE FILTERED TO y=145..159 and that hid the defect it
          // was built to find.  The band was chosen because that is where the
          // flicker could be SEEN -- and the overlay covers the top 72 lines,
          // so the busiest sprite row on the screen, "RECEIVING:" at y=16..21,
          // was never once looked at.  When it started overrunning, every
          // snapshot row read 0 and the counter said 880 overruns a second.
          // An instrument windowed on where you can look is windowed on the
          // wrong thing (LESSONS_LEARNED L9, and now L28).
          //
          // First overrun of each FRAME, wherever it is.  SNAP1 already
          // carries `target`, so the probe says which line by itself.
          if (!snap_done) begin
            dbg_nonrom   <= {tiles_line, nonrom_cnt};
            dbg_workload <= {acks_line, hits_line};
            dbg_snap1    <= {demand_tiles, target[7:0]};
            dbg_snap2    <= {2'b00, pass, xi, word_n, idx[8:1]};
            snap_done    <= 1'b1;
          end
        end
        // Re-arm once a frame, in vertical blanking.
        if (!next_is_visible) snap_done <= 1'b0;
        nonrom_cnt <= 12'd0;
        hits_line  <= 8'd0;
        acks_line  <= 8'd0;
        tiles_line <= 4'd0;
        demand_tiles <= 8'd0;
        rom_req <= 1'b0;

        if (next_is_visible) begin
          target   <= next_line;
          spr_addr <= 9'h1fe;
          st       <= S_FIRST0;
        end else begin
          // Vertical blanking.  Nothing rendered now is ever shown, and
          // walking the sprite list anyway costs SDRAM bandwidth at priority
          // 1 during the sixteen lines when the 68000 -- priority 5, its
          // program ROM in the same SDRAM -- is doing the whole frame's video
          // update in one burst (docs/DEBUG_LOG.md O10).  Stand down.
          st <= S_IDLE;
        end
      end else begin
        case (st)
          S_IDLE: ;

          // spriteram[0x1fe] * 4, clamped to 0x1fc
          S_FIRST0: st <= S_FIRST1;
          S_FIRST1: begin
            // first = 4 * spriteram[0x1fe], clamped to 0x1fc
            first    <= (spr_data[6:0] == 7'h7f) ? 9'h1fc : {spr_data[6:0], 2'b00};
            dbg_o6_first <= {7'd0, (spr_data[6:0] == 7'h7f) ? 9'h1fc
                                                           : {spr_data[6:0], 2'b00}};
            // MAME walks 0x1f8 DOWN to `first`, twice, pri==1 then pri==0 --
            // and it is FIRST-WRITE-WINS, not last.  `prio_zoom_transpen`
            // adds priority bit 31 to its mask, writes a non-transparent
            // pixel only where the existing priority is unmasked, and then
            // stamps that pixel 31, so no later sprite can replace it
            // (drawgfx.cpp:1225, drawgfxt.ipp:216).  This module's header
            // said "LATER WRITES WIN" and that was a misreading; it is what
            // put overlapping sprites -- which on this board is all TEXT,
            // 16 px tiles placed 8 px apart -- out by up to two characters
            // while isolated sprites stayed pixel-exact.  docs/DEBUG_LOG O6.
            //
            // Reproduced WITHOUT a read-modify-write, which the line buffer
            // cannot afford (see the header): walking descending and keeping
            // the first write is the same outcome as walking ASCENDING and
            // keeping the last, because both leave the highest index owning
            // the pixel.  The pass order flips with it, so that pri==1 still
            // beats pri==0: draw pri==0 first, then pri==1 over it.
            idx      <= {spr_data[6:0], 2'b00};
            spr_addr <= {spr_data[6:0], 2'b00};
            pass     <= 1'b0;
            // MAME: for (attr = 0x1F8; attr != first-4; attr -= 4).  When
            // spriteram[0x1fe] is 0x7f the masked `first` is 0x1FC, start
            // already equals end and the loop body never runs -- NO sprites,
            // not one.  Walking ascending, that has to be caught here rather
            // than at the end, or 0x1FC gets drawn on the way past.
            st       <= (spr_data[6:0] == 7'h7f) ? S_IDLE : S_A0;
          end

          S_A0: begin spr_addr <= idx + 9'd1; st <= S_A1; end
          S_A1: begin a0 <= spr_data; spr_addr <= idx + 9'd2; st <= S_A2; end
          S_A2: begin a1 <= spr_data; spr_addr <= idx + 9'd3; st <= S_A3; end
          S_A3: begin a2 <= spr_data;                          st <= S_DECIDE; end

          S_DECIDE: begin
            map_base <= spr_data;             // word 3, still on the bus
            // PIPELINE THE COVERAGE SEARCH.
            //
            // `hit_y` and `src_row` are combinational out of the unrolled
            // 8-way y search, which itself is combinational out of `a0`.
            // Using them directly in S_LUT0 put a0 -> search -> multiply ->
            // add -> lut_addr in ONE clock: 23.6 ns of logic on a 25 ns
            // period, and after the overlay grew the fitter stopped meeting
            // it -- slack -0.534, reproduced on two independent builds.
            //
            // Latching them here costs nothing: S_DECIDE already exists and
            // already spends a clock, and the search result is stable by the
            // time it runs.  This does NOT reduce the logic -- O3's Pocket
            // ALM problem is untouched and still wants the search serialised
            // into the state machine -- it only stops one clock having to
            // contain all of it.
            hit_y_r   <= hit_y;
            src_row_r <= src_row;
            // pass 0 draws pri==1, pass 1 draws pri==0
            // pass 0 draws pri==0, pass 1 draws pri==1 -- reversed with the
            // walk direction so the later pass still wins.
            if (!enable || !hit || (pri != pass)) begin
              st <= S_NEXT;
            end else begin
              dbg_hit <= dbg_hit + 16'd1;
              if (hits_line != 8'hFF) hits_line <= hits_line + 8'd1;
              demand_tiles <= demand_tiles + {5'd0, xsize} + 8'd1;
              xi <= 3'd0;
              st <= S_LUT0;
            end
          end

          // map index -> tile number, through the 16 K lookup RAM
          S_LUT0: begin
            lut_addr <= lut_sum[12:0];
            st       <= S_LUTW;
          end

          // ONE WAIT STATE, and it is the whole of docs/DEBUG_LOG.md O6.
          //
          // `ps_dpram` has a registered output: the word for the address
          // presented on one clock appears on the NEXT.  The sprite-RAM walk
          // above honours that -- S_A0 sets idx+1 and S_A1 reads the value
          // for idx -- but this path set lut_addr in S_LUT0 and consumed
          // lut_data in S_LUT1, one edge too early.  Every tile came from
          // the PREVIOUS lookup.
          //
          // A tile is 16 px and a character cell is 8, so being one lookup
          // behind is exactly the two-cell displacement measured on screen;
          // and after an idle gap the stale value is the last lookup of the
          // previous traversal, which is why the text came out ROTATED with
          // the end wrapped to the front rather than merely shifted.
          //
          // The overlay agreed with the bug: it latched the CURRENT map_base
          // beside the STALE lut_data, so the two numbers it showed came
          // from different transactions and matched MAME individually.
          // docs/LESSONS_LEARNED.md L14.
          S_LUTW: st <= S_LUT1;
          S_LUT1: begin
            // Latch one sprite from the HIGH-SCORE text.  Line 150 is inside
            // the rank-4 row of the score-ranking screen, which is STATIC --
            // an animated demo frame has to be scene-matched before anything
            // can be compared, a static screen does not.  Every text line on
            // that screen measures 16 px right of MAME's while the background
            // measures 0, the same offset the message line shows.
            // ysize == 0 means ONE tile tall, which the high-score text is
            // and the player portraits either side of it are not.  Without
            // this the latch kept catching a portrait (ysize=4) and the
            // numbers meant nothing.
            if (target == 9'd150 && xi == 3'd0 && ysize == 3'd0) begin
              dbg_o6_map  <= map_base;
              dbg_o6_tile <= lut_data;
              dbg_o6_pos  <= {ox, xsize, ysize, 1'b0};
              // sx is MAME's ox + zoomx*cx/2, wrapped; this module then blits
              // at sx-4.  If the 16 px lives between ox and sx, this says so.
              dbg_o6_sx   <= {sx, 7'd0};
            end
            // blit_x is where writing actually starts and tile_w is how many
            // pixels get written.  ox, sx and blit_x now all land on overlay
            // page 2, so one screenshot carries the whole chain:
            //     ox -> sx (MAME's formula) -> blit_x (sx-4) -> tile_w pixels
            if (target == 9'd150 && xi == 3'd0 && ysize == 3'd0)
              dbg_o6_blitx <= {sx - 9'd4, tile_w, 1'b0};
            rom_addr <= GFX2_BASE_W + {lut_data, 6'd0} + {src_row_r, 2'b00};
            if (tiles_line != 4'hF) tiles_line <= tiles_line + 4'd1;
            rom_req  <= 1'b1;
            word_n   <= 2'd0;
            st       <= S_ROM;
          end

          S_ROM: begin
            if (rom_req && rom_ack) begin
              if (acks_line != 8'hFF) acks_line <= acks_line + 8'd1;
              // word W supplies bytes 2W (high half) and 2W+1 (low half)
              rowbits[{word_n, 4'd0} +: 8] <= rom_data[15:8];
              rowbits[{word_n, 4'd8} +: 8] <= rom_data[7:0];
              if (target == 9'd150 && xi == 3'd0 && ysize == 3'd0) begin
                case (word_n)
                  2'd0: dbg_o6_row0 <= rom_data;
                  2'd1: dbg_o6_row1 <= rom_data;
                  2'd2: dbg_o6_row2 <= rom_data;
                  2'd3: dbg_o6_row3 <= rom_data;
                endcase
              end
              if (word_n == 2'd3) begin
                rom_req <= 1'b0;
                // Sprites live in the SAME 512-wide bitmap as the tilemap and
                // the visible window crops 4 from the left of BOTH.  The
                // tilemap carried that offset from the start and the sprite
                // did not, which put every sprite 4 pixels right of where
                // the tilemap put its own graphics.
                st      <= S_BLIT;
              end else begin
                word_n   <= word_n + 2'd1;
                rom_addr <= rom_addr + 25'd1;
              end
            end
          end

          // One clock: hand the finished row to the blitter and go and fetch
          // the next one.  `rowbits` is complete here because word 3 landed on
          // the previous clock.  The wait can only happen if a row somehow
          // took longer to draw than the next took to fetch, which at 16
          // clocks against 42 it does not.
          S_BLIT: if (!bl_busy) begin
            bl_row    <= rowbits;
            bl_x      <= sx - 9'd4;
            bl_c      <= 6'd0;
            bl_w      <= tile_w;
            bl_zoomx  <= zoomx;
            bl_flipx  <= flipx;
            bl_colour <= colour;
            bl_pal    <= spr_palbank;
            bl_busy   <= 1'b1;
            st        <= S_XNEXT;
          end

          S_XNEXT: begin
            if (xi == xsize) st <= S_NEXT;
            else begin xi <= xi + 3'd1; st <= S_LUT0; end
          end

          S_NEXT: begin
            if (idx >= 9'h1f8) begin
              // end of this pass -- 0x1f8 is the last entry, inclusive
              if (pass) begin
                st <= S_IDLE;               // both passes done
              end else begin
                pass     <= 1'b1;
                idx      <= first;
                spr_addr <= first;
                st       <= S_A0;
              end
            end else begin
              idx      <= idx + 9'd4;
              spr_addr <= idx + 9'd4;
              st       <= S_A0;
            end
          end

          default: st <= S_IDLE;
        endcase
      end
    end
  end

endmodule

`default_nettype wire
