//============================================================================
//  ps_romcache -- a small direct-mapped word cache for the 68000's program ROM
//
//  WHY THIS EXISTS, measured rather than assumed.
//
//  The 68000's work RAM is BRAM and answers in a clock.  Its program ROM is in
//  SDRAM behind a strict-priority arbiter, and `cpu_ack = rom_ack`, so every
//  instruction fetch waits for a full SDRAM transaction.  Counted on hardware,
//  per frame, over the sixteen lines of vertical blanking:
//
//      68000 clocks spent waiting for ROM    8848 - 9129
//      ROM fetches completed                 1232 - 1259
//      = 7.19 system clocks of wait per fetch, 21.7 % of the blank interval
//
//  That is not contention: `docs/DECISIONS.md` D10 already stood the sprite
//  and tilemap engines down during blanking, so the CPU has the bus nearly to
//  itself there and still waits.  It is the SDRAM transaction itself -- one
//  activate/read/precharge per word.
//
//  It matters because of what the game does with those lines.  Its whole
//  per-frame video update runs in one burst inside vertical blanking, and MAME
//  -- the same game, an unobstructed 68000 -- finishes that burst at line 16.1
//  where this core's blanking ends at 16.  The game is tuned to the boundary.
//  With the interrupt-acknowledge bug fixed (DEBUG_LOG O10) the burst's median
//  came back inside blanking, but 4 frames in 20 still ended at 17-19, and the
//  ~3 lines of overrun match the ~3.5 lines of measured ROM wait.
//
//  WHY A CACHE WORKS HERE.  The burst is a loop: a short body executed many
//  times, so a cache large enough to hold the working set turns almost every
//  fetch after the first pass into a two-clock hit.
//
//  SIZING, measured rather than guessed.  The first version had 128 entries --
//  256 bytes of code -- on the reasoning that this was "far more than the
//  inner loops involved".  On hardware it moved the wait from 7.19 clocks per
//  fetch only to 5.89.  A hit costs 2 clocks and a miss 9 (the two extra are
//  this FSM's lookup, which a miss pays before the memory request goes out),
//  so 5.89 means a hit rate of about 44 %: the handler's working set is larger
//  than 256 bytes, which in hindsight is unsurprising for code that updates
//  sprites, raster and palette in one pass.
//
//  1024 entries is 2 KB of code and about 24 kbit of the device's 5.6 Mbit.
//  At a 90 % hit rate the average becomes ~2.7 clocks, which is ~4.5 clocks
//  saved on each of ~1300 fetches per blank interval: about 2.3 scanlines.
//
//  This is deliberately NOT a prefetcher.  Prefetching needs a second
//  outstanding request and a policy for what to do when the CPU branches
//  away; caching what was actually fetched needs neither and cannot issue a
//  transaction the CPU did not ask for.
//
//  COHERENCY.  The 68000 cannot write this region -- `sel_rom` is read-only in
//  ps_main -- and the only thing that changes it is the ROM download, during
//  which `rst` is held.  So reset-invalidate is sufficient and there is no
//  snooping to get wrong.
//============================================================================
`default_nettype none

module ps_romcache #(
    parameter int IDX_BITS = 10,         // 1024 entries -- see the sizing note
    parameter int AW       = 17          // word-address width, [AW:1]
) (
    input  wire            clk,
    input  wire            rst,

    // --- CPU side: same contract ps_main already speaks -------------------
    input  wire [AW:1]     c_a,
    input  wire            c_rd,         // level, held until c_ack
    output reg             c_ack,        // one-clock pulse, data valid with it
    output reg  [15:0]     c_q,

    // --- memory side: same contract the arbiter already speaks ------------
    output reg  [AW:1]     m_a,
    output reg             m_rd,
    input  wire            m_ack,
    input  wire [15:0]     m_q
);

  // No hit/miss counters here on purpose.  The overlay already carries the
  // number this cache exists to move: 68000 clocks spent waiting for ROM in a
  // frame's vblank, divided by fetches completed in it (rows 66 and 67).  That
  // was 7.19 before; a hit costs two clocks.  A separate hit counter would be
  // a second instrument for the same fact, and this project has been burned
  // more than once by trusting a counter that agreed with its own assumption
  // (LESSONS_LEARNED L12, L14).

  localparam int TAG_BITS = AW - IDX_BITS;   // c_a is [AW:1], so index is
                                             // c_a[IDX_BITS:1]

  reg                     v   [0:(1<<IDX_BITS)-1];
  reg [TAG_BITS-1:0]      tag [0:(1<<IDX_BITS)-1];
  reg [15:0]              dat [0:(1<<IDX_BITS)-1];

  wire [IDX_BITS-1:0] idx    = c_a[IDX_BITS:1];
  wire [TAG_BITS-1:0] cur_tg = c_a[AW:IDX_BITS+1];

  localparam [1:0] S_IDLE = 2'd0, S_LOOK = 2'd1, S_FILL = 2'd2, S_DONE = 2'd3;
  reg [1:0] st;

  // Registered lookup.  A combinational hit would have to drive c_ack in the
  // same clock the request appears, which puts a 128-way tag compare and the
  // data mux in one path; one clock of latency against the 7.19 being removed
  // is not worth that risk.
  reg                le_v;
  reg [TAG_BITS-1:0] le_tag;
  reg [15:0]         le_dat;
  reg [IDX_BITS-1:0] le_idx;
  reg [TAG_BITS-1:0] le_cur;

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      st         <= S_IDLE;
      c_ack      <= 1'b0;
      c_q        <= 16'h0000;
      m_rd       <= 1'b0;
      m_a        <= {AW{1'b0}};
      for (i = 0; i < (1<<IDX_BITS); i = i + 1) v[i] <= 1'b0;
    end else begin
      c_ack <= 1'b0;

      case (st)
        S_IDLE: begin
          if (c_rd) begin
            le_v   <= v[idx];
            le_tag <= tag[idx];
            le_dat <= dat[idx];
            le_idx <= idx;
            le_cur <= cur_tg;
            m_a    <= c_a;
            st     <= S_LOOK;
          end
        end

        S_LOOK: begin
          if (le_v && le_tag == le_cur) begin
            c_q   <= le_dat;
            c_ack <= 1'b1;
            st    <= S_DONE;
          end else begin
            m_rd <= 1'b1;
            st   <= S_FILL;
          end
        end

        S_FILL: begin
          if (m_ack) begin
            m_rd        <= 1'b0;
            v  [le_idx] <= 1'b1;
            tag[le_idx] <= le_cur;
            dat[le_idx] <= m_q;
            c_q         <= m_q;
            c_ack       <= 1'b1;
            st          <= S_DONE;
          end
        end

        // `c_rd` is a level held until the CPU sees its acknowledge, so wait
        // for it to drop before looking at it again -- otherwise one read is
        // acknowledged twice.
        S_DONE: if (!c_rd) st <= S_IDLE;

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
