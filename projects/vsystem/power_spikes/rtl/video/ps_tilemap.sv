//============================================================================
//  Power Spikes -- tilemap layer
//
//  One 64 x 32 map of 8x8 4bpp tiles, with per-scanline horizontal scroll.
//
//  ---- scroll semantics ---------------------------------------------------
//  Taken from MAME's tilemap.cpp, not guessed: the sign is easy to get
//  backwards and a backwards scroll still looks plausible.  The chain is
//
//    driver:  set_scrollx((i + scrolly) & 0xff, rasterram[i])
//             set_scrolly(0, scrolly)
//    tilemap: effective_rowscroll = (dx - m_rowscroll[row]) % width,  dx = 0
//             draw_instance(xpos = effective, ...);  then  x -= xpos
//
//  The two negations cancel, and so does the (i + scrolly) against the row
//  lookup, leaving:
//
//      tile_x = (bitmap_x + rasterram[screen_y]) & 0x1FF
//      tile_y = (bitmap_y + scrolly)             & 0x0FF
//      bitmap_x = screen_x + 4          (MAME visarea starts at x = 4)
//
//  The raster index is the SCREEN line, not the tilemap row.  Indexing by
//  tilemap row would look almost right and shear whenever scrolly != 0.
//
//  ---- pixel order --------------------------------------------------------
//  gfx_8x8x4_packed_lsb, from src/emu/video/generic.cpp:
//      x order { 1*4, 0*4, 3*4, 2*4, ... }  and planes { STEP4(0,1) }
//  Working the bit offsets through, that is simply:
//      byte B holds pixel 2B in its LOW nibble and pixel 2B+1 in its HIGH
//  so a row is read as four bytes, low nibble first.  32 bytes per tile,
//  4 bytes (2 SDRAM words) per row.
//
//  ---- fetch budget -------------------------------------------------------
//  Two words per 8 pixels at 7.16 MHz = 1.8 M words/s out of the arbiter.
//============================================================================
`default_nettype none

module ps_tilemap #(
    parameter int V_VISIBLE = 240,     // all three must come from ps_video
    parameter int V_TOTAL   = 256,
    parameter int H_VISIBLE = 352,
    parameter int H_TOTAL   = 456
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,

    // --- timing ------------------------------------------------------------
    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,
    input  wire        line_start,

    // --- registers ---------------------------------------------------------
    input  wire [7:0]  gfxbank,        // [7:4] for code[12]=0, [3:0] for =1
    input  wire [2:0]  char_palbank,
    input  wire [8:0]  scrolly,

    // --- VRAM (video side of the dual-port block) --------------------------
    output wire [10:0] vram_addr,
    input  wire [15:0] vram_data,

    // --- raster RAM (video side) -------------------------------------------
    output wire [10:0] raster_addr,
    input  wire [15:0] raster_data,
    output wire [15:0] dbg_raster_msg,
    output wire [15:0] dbg_raster_court,

    // --- tile ROM through the arbiter --------------------------------------
    output reg  [24:0] rom_addr,
    input  wire [15:0] rom_data,
    output reg         rom_req,
    // PER FRAME, not cumulative.  The cumulative pair saturated at FFFF in
    // 25 seconds, which made the ratio between them -- the whole point of
    // having two -- unreadable.  LESSONS_LEARNED L12 is about exactly this:
    // an answer you cannot read is not an answer, and zero is not the only
    // unreadable one.
    output reg  [15:0] dbg_late,      // tile rows loaded before their fetch returned
    // ...and WHERE, as two saturating bytes: {first third, last 40 %}.  One
    // bin was enough while the only suspect held the bus from line_start
    // (O11).  It stopped being enough the moment a second suspect appeared at
    // the OTHER end of the line: the sprite override lived at hcnt >= 215, so
    // "not in the first third" was all one bin could say, and that is the
    // same answer for "the middle" and for "the tail".  Two bins plus the
    // total give three.
    output reg  [15:0] dbg_late_l,
    input  wire        rom_ack,

    // --- pixel out ---------------------------------------------------------
    // Palette index 0..1023.  This layer is fully OPAQUE -- see the note by
    // the assignment at the bottom.
    output wire [9:0]  pix
);

  `include "ps_rommap.svh"

  // ---------------------------------------------------------------------
  // Raster RAM is indexed by screen line, latched once per line so a CPU
  // write mid-line cannot tear the line being drawn.  On the real board the
  // display logic samples it at one point per line too.        INFERRED
  // ---------------------------------------------------------------------
  // Read two raster values back off hardware.  MAME's own raster RAM holds
  // 0x1FE7 (mod 512 = 487) for EVERY line from 0 to 183, so the message row
  // and the court share one scroll value there -- yet on the board the
  // message row lands 2 character cells (16 px) right of MAME's while the
  // court matches at dx=0 with |diff| 0.86. Either the board's raster RAM
  // holds something else, or the scroll is not what is moving that row.
  // These say which, without guessing.               docs/DEBUG_LOG.md O6
  reg [15:0] dbg_ras_msg, dbg_ras_court;
  assign dbg_raster_msg   = dbg_ras_msg;
  assign dbg_raster_court = dbg_ras_court;



  // Latched and cleared at the top of blanking, inside the main clocked block
  // below -- a separate always block would be a second driver for the same
  // registers.  A frame is at most 240 lines of 44 tiles, so a per-frame count
  // cannot reach FFFF and cannot lie by saturating.
  reg [15:0] acc;
  reg [7:0]  acc_l, acc_r;
  reg [8:0]  vcnt_d;

  // ROWSCROLL IS READ ONE LINE AHEAD, and that is the fix for O12.
  //
  // `line_start` fires at hcnt 0 -- which is also the first VISIBLE pixel,
  // because horizontal blanking sits at the END of the line (hcnt 352..455).
  // So a rowscroll latched at line_start arrives at the same moment the pixel
  // that needs it is already being output, while the fetch pipeline needs
  // eleven pixels of lead.  The first tile of every line was therefore fetched
  // under the PREVIOUS line's scroll.
  //
  // MAME has no pipeline -- it draws each row with that row's own scrollx --
  // so the two disagree in exactly the leftmost tile, which is what a
  // board-vs-MAME comparison measured: the leftmost 8 columns differ on every
  // frame, 1010-1225 pixels of 1920, before and after the O11 fix alike.
  // docs/DEBUG_LOG.md O12.
  //
  // Reading vcnt+1 during the previous line's blanking gives the pipeline the
  // whole of that blanking to fetch the first tile with the right scroll.
  wire [8:0] next_line = (vcnt == V_TOTAL - 1) ? 9'd0 : vcnt + 9'd1;
  wire       ahead     = (hcnt >= H_VISIBLE);        // in horizontal blanking

  reg [8:0] rowscroll, rowscroll_next;
  assign raster_addr = {2'b00, ahead ? next_line : vcnt};
  always @(posedge clk) begin
    // Latched all through blanking; the last value before line_start is the
    // one the next line uses, and the pipeline has already been fetching with
    // it for the whole of that blanking.
    if (ahead) rowscroll_next <= raster_data[8:0];
    if (line_start) begin
      rowscroll <= rowscroll_next;
      if (vcnt == 9'd24)  dbg_ras_msg   <= raster_data;   // the message row
      if (vcnt == 9'd100) dbg_ras_court <= raster_data;   // the court
    end
  end

  // ---------------------------------------------------------------------
  // Fetch coordinate leads the output by 8 pixels: while tile N is shifting
  // out, tile N+1 is being fetched.
  // ---------------------------------------------------------------------
  // H_FETCH_LEAD = MAME's visarea offset (4) plus the pipeline lead, and the
  // TOTAL was calibrated against MAME rather than reasoned about.  Sweeping
  // the background band of a board screenshot against MAME's own frame gave
  //     dx = +1, dy = 0    mean |diff| 1.70   (runner-up 8.35)
  // so the naive 4 + 8 = 12 was one pixel too many.  docs/DEBUG_LOG.md O1
  // said not to guess this and to settle it with a picture; this is that
  // picture.
  localparam int H_FETCH_LEAD = 11;

  // During blanking the pipeline is already working on the NEXT line, so it
  // uses that line's scroll and row.
  wire [8:0] eff_scroll = ahead ? rowscroll_next : rowscroll;
  wire [8:0] eff_row    = ahead ? next_line      : vcnt;

  // THE FETCH POINTER WRAPS INTO THE NEXT LINE during blanking, and without
  // that the first tile of every line is never fetched at all.
  //
  // Reading the next line's scroll early (above) was necessary and not
  // sufficient: with `fetch_x = hcnt + 11 + scroll`, blanking at hcnt 352..455
  // puts the pointer at tile columns 45..58, and at the line wrap it jumps
  // straight from 58 to 1.  Column 0 is skipped, so at hcnt 0 the shifter
  // still holds whatever was loaded during blanking -- a tile from the far
  // right of the map.  Measured: with the early scroll alone the leftmost 8
  // columns still differed from MAME on 805-1054 of 1920 pixels, and the
  // colours were another tile's, not a shifted version of the right one.
  //
  // Subtracting H_TOTAL during blanking makes the pointer negative and then
  // continuous into the next line: fetch_x reaches 0 at hcnt = 445 - scroll,
  // so tile 0 is loaded into the shifter before hcnt 0 needs it.  Nothing is
  // fetched while it is negative -- those pixels belong to no line.
  wire signed [11:0] fetch_sx = $signed({3'b000, hcnt})
                              - (ahead ? H_TOTAL[11:0] : 12'sd0)
                              + H_FETCH_LEAD[11:0]
                              + $signed({3'b000, eff_scroll});
  wire        fetch_valid = (fetch_sx >= 0);
  wire [9:0]  fetch_x     = fetch_sx[9:0];

  // ...AND ALMOST ALL OF THAT SWEEP IS THROWN AWAY.
  //
  // Blanking is 104 pixels, so the pointer crosses thirteen tile boundaries
  // and issues thirteen two-word fetches -- but the shifter is reloaded at
  // every one of them, so only the LAST survives into hcnt 0.  Twelve fetches,
  // twenty-four SDRAM words a line, are read and overwritten unseen.
  //
  // Nobody noticed because the tilemap is priority 1 and never waits for
  // itself.  The sprite engine waits: it is priority 2, it renders the NEXT
  // line, and on a line it is going to overrun it is still fetching right
  // through this blanking (`dbg_overrun` is exactly that condition).  So the
  // waste is spent out of the one client that has none to spare, at the one
  // moment it has none -- and that is the third HOW TO PLAY screen's
  // "RECEIVING:" row, ten characters wide, y=16..21, 880 overruns a second.
  //
  // Keep the last three tile groups.  The load that matters is the last
  // phase 7 before the wrap, at hcnt 448..455; its own fetch was issued at
  // the phase 0 seven pixels earlier, hcnt 441..448.  A 24-pixel window
  // starts at 432 and covers that pair whatever the scroll's phase, with a
  // whole spare group after it.  Sixteen would also do; three groups is one
  // more than the argument needs, because the argument is about alignment
  // and this is the left edge of every line (docs/DEBUG_LOG.md O12).
  localparam int PRIME_PX = 24;
  wire prime_win = (hcnt >= H_TOTAL - PRIME_PX);
  wire fetch_go  = fetch_valid & (~ahead | prime_win);
  wire [8:0]  tile_y      = eff_row + scrolly;

  // The stand-down follows the line being FETCHED FOR, not the line being
  // scanned.  Those differ during horizontal blanking, where the pipeline is
  // already working on the next line -- and at vcnt 255 the next line is 0,
  // the first VISIBLE line, whose first tile has to be fetched right there.
  //
  // Using vcnt alone left exactly eight pixels wrong in the whole frame: row
  // 0, columns 0-7, black where MAME had tile colour.  Everything else
  // matched to the pixel.
  wire in_vblank = (eff_row >= V_VISIBLE);

  wire [5:0] tcol = fetch_x[8:3];
  wire [4:0] trow = tile_y[7:3];
  assign vram_addr = {trow, tcol};

  wire [2:0] phase = fetch_x[2:0];

  // effective tile number = (code & 0x0fff) | (gfxbank[sel] << 12)
  wire [3:0]  banksel = vram_data[12] ? gfxbank[3:0] : gfxbank[7:4];
  wire [15:0] tile_no = {banksel, vram_data[11:0]};

  // word address = base + tile*16 + row*2
  wire [24:0] tile_base = GFX1_BASE_W + {tile_no, tile_y[2:0], 1'b0};

  // ---------------------------------------------------------------------
  // Two-word fetch, then load the shifter at the tile boundary.
  // ---------------------------------------------------------------------
  reg [31:0] rowbits;
  reg [31:0] shifter;
  reg [2:0]  pal, pal_next;
  reg        word_hi;

  always @(posedge clk) begin
    if (rst) begin
      rom_req    <= 1'b0;
      word_hi    <= 1'b0;
      dbg_late   <= 16'd0;
      dbg_late_l <= 16'd0;
      acc        <= 16'd0;
      acc_l      <= 8'd0;
      acc_r      <= 8'd0;
      vcnt_d     <= 9'd0;
      rowbits <= 32'd0;
      shifter <= 32'd0;
      pal     <= 3'd0;
      pal_next<= 3'd0;
    end else begin
      // --- ROM side: two words per tile row ---------------------------
      if (rom_req && rom_ack) begin
        if (!word_hi) begin
          // word 0 = { byte0, byte1 } big-endian
          rowbits[7:0]   <= rom_data[15:8];
          rowbits[15:8]  <= rom_data[7:0];
          word_hi        <= 1'b1;
          rom_addr       <= rom_addr + 25'd1;
          rom_req        <= 1'b1;
        end else begin
          rowbits[23:16] <= rom_data[15:8];
          rowbits[31:24] <= rom_data[7:0];
          word_hi        <= 1'b0;
          rom_req        <= 1'b0;
        end
      end

      // --- per-frame windowing for the deadline counters -----------------
      vcnt_d <= vcnt;
      if (vcnt == V_VISIBLE && vcnt_d != V_VISIBLE) begin
        dbg_late   <= acc;
        dbg_late_l <= {acc_l, acc_r};
        acc        <= 16'd0;
        acc_l      <= 8'd0;
        acc_r      <= 8'd0;
      end

      // --- pixel side --------------------------------------------------
      if (ce_pix) begin
        if (phase == 3'd0) begin
          // vram_data is valid for the tile we are about to fetch
          pal_next <= vram_data[15:13];
          rom_addr <= tile_base;
          // ...but not during vertical blanking, where the fetch runs the
          // full width of sixteen lines nobody sees -- about 1 800 SDRAM
          // reads a frame, taken at priority 2 from a 68000 at priority 5
          // that is trying to finish the frame's video update inside those
          // same sixteen lines (docs/DEBUG_LOG.md O10).
          rom_req  <= ~in_vblank & fetch_go;
          word_hi  <= 1'b0;
        end

        if (phase == 3'd7) begin
          // DEADLINE.  The two ROM words for this tile row were asked for at
          // phase 0 and are loaded into the shifter here, seven pixel clocks
          // later -- about 39 system clocks at a 7.159 MHz pixel clock and a
          // 40 MHz system clock.  Two SDRAM reads normally take far less, but
          // this client sits at arbiter priority 2 and there is nothing in the
          // design that makes it wait: if the second word has not arrived,
          // `rowbits` still holds bytes from the PREVIOUS tile row and the
          // shifter loads a mixture.  That paints an eight-pixel block of
          // background with part of the wrong tile, and it moves around with
          // bus contention, so it changes every frame.
          //
          // A person watching the board reports a shimmer that is present on
          // STATIONARY sprites and, they added, behind text as well -- and
          // what sprites and text have in common is the background behind
          // them.  The sprite engine has had an overrun counter since
          // DEBUG_LOG O2; this layer has never had one.  Count it before
          // changing anything.
          // TWO READINGS OF ONE FACT (this board's CLAUDE.md 1.3).  A bare
          // count of missed deadlines cannot be cross-checked, and a single
          // uncheckable number is what this project has been burned by
          // repeatedly.  So also count WHERE: if the cause is the sprite
          // engine holding the bus from line_start, the misses must cluster
          // in the first third of the line, which is independently what a
          // person watching the board reports ("1P court, the whole way up,
          // about a third").  Spread evenly instead, and the explanation is
          // wrong no matter what the total says.
          //
          //     high byte / dbg_late  ~ 1.0   -> start-of-line starvation
          //                          ~ 0.34  -> uniform, something else
          //     low byte  / dbg_late  ~ 1.0   -> tail-of-line starvation, the
          //                                     window the sprite override
          //                                     used to occupy (hcnt >= 215)
          if (rom_req) begin
            if (acc   != 16'hFFFF) acc   <= acc   + 16'd1;
            if (hcnt <  9'd120 && acc_l != 8'hFF) acc_l <= acc_l + 8'd1;
            if (hcnt >= 9'd215 && acc_r != 8'hFF) acc_r <= acc_r + 8'd1;
          end
          shifter <= rowbits;
          pal     <= pal_next;
        end else begin
          shifter <= {4'b0000, shifter[31:4]};
        end
      end
    end
  end

  wire [3:0] colour = shifter[3:0];

  // Colours 0-1023 in 64 banks of 16: (charpalettebank*8 + tilepal) * 16.
  //
  // THIS LAYER IS OPAQUE, INCLUDING COLOUR 0.  Power Spikes' VIDEO_START
  // never calls set_transparent_pen on tilemap[0] -- only karatblz/turbofrc/
  // aerofgtb do, on their SECOND tilemap, and wbbc97 on its first.  So every
  // pixel here is drawn, and colour 0 means "palette entry palsel*16", not
  // "show the backdrop".
  //
  // Treating colour 0 as transparent looks almost right -- most tiles have a
  // dark colour 0 and the backdrop is usually dark too -- and quietly
  // replaces every such pixel with palette entry 0.
  assign pix = {char_palbank, pal, colour};

endmodule

`default_nettype wire
