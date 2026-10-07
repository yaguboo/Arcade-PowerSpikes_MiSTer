//============================================================================
//  Power Spikes -- SDRAM arbiter
//
//  ps_sdram is a single-port controller.  Six things on this board want ROM
//  data, so something has to order them.  On the real PCB they do not
//  compete: each has its own mask ROM and its own pins.  Sharing one SDRAM is
//  a platform artefact, so the arbiter's job is to make the sharing invisible
//  -- nobody may be starved long enough to change board behaviour.
//
//  Priority, highest first:
//
//    0  download   ROM loading; the CPU is held in reset, so it owns the bus
//    1  tilemap    HARD real-time: two words per 8 pixels, and the shifter
//               loads seven pixel clocks -- about 39 system clocks -- after
//               the request goes out, whether the data arrived or not
//    2  sprite     soft: it renders the NEXT line into a buffer, so its
//               deadline is a whole line, about 2550 system clocks
//    3  adpcma     YM2610 sample fetch -- the real chip reads its ROM pins
//               once per 666 kHz slot, so this is NOT a low-rate client
//    4  adpcmb     likewise
//    5  cpu        stalls, and that is not free -- see below
//    6  z80        idle: the sound CPU runs from BRAM (DECISIONS D9)
//
//  **The sprite used to outrank the tilemap**, on the reasoning that "a late
//  sprite word is a visible glitch on that scanline".  That reasoning had the
//  deadlines backwards.  The sprite engine renders into a line buffer for the
//  NEXT line and has ~2550 clocks of slack; its overrun counter has read 0
//  throughout.  The tilemap draws the pixel being scanned out now and has 39.
//  So the client with 65x less slack was the one being made to wait.
//
//  The symptom was a background that shimmered only where sprites were dense
//  -- moving text, the advertising boards, the net -- and only across roughly
//  the first third of each scanline, which is how long the sprite engine holds
//  the bus after line_start.  MAME's own sprite load makes the same
//  prediction: 14 tile-rows on the busiest line of the demo match is about 756
//  clocks, and 756 clocks is 135 pixels of a 352-pixel line.  Attract screens
//  with no text carry 7 sprites and shimmer not at all.
//
//  Arithmetic for the swap: the tilemap needs two words per 8 pixels, about
//  14 clocks in every 45, so it takes 31 % of the bus and leaves the sprite
//  engine 1760 clocks a line against the ~756 it needs.  `dbg_overrun` is the
//  check that this is true, and it must stay 0.
//
//  **This order was changed twice on 2026-08-31 and both changes were
//  reverted.**  ADPCM was losing 8.1 % of its fetches, so it was moved above
//  the CPU (no effect) and then above the sprite engine (never measured).
//  Both were guesses.
//
//  What replaced the guesses was itself wrong, and the correction matters
//  here.  MAME's YM2610 was dumped and read its ADPCM-A ROM ~9 300 times a
//  second against this board's 655 000, which was written up as a seventyfold
//  over-fetch.  It is not: MAME's device model counts the bytes its decoder
//  consumed, while jt10 -- like the real chip -- reads its ROM pins once per
//  666 kHz slot across six interleaved channels.  The two numbers never
//  measured the same thing.  docs/LESSONS_LEARNED.md L17.
//
//  So this arbiter really does carry an ADPCM client asking hundreds of
//  thousands of times a second, sitting ABOVE the 68000, whose program ROM is
//  in the same SDRAM.  A stalled 68000 is not harmless: the game does all its
//  video updates in one burst per frame and this core gives it only 16
//  blanking lines to finish in (docs/DEBUG_LOG.md O10).  Stretching that
//  burst pushes it into the visible area.  `dbg_cpu_stall` free-runs and
//  saturates, so it cannot say how much -- the per-frame burst-end probe in
//  ps_top.sv is what answers it.  The fetcher now sits behind a word cache
//  (rtl/sound/ps_sound.sv), which is a bandwidth fix, not an ordering one.
//
//  Grant is held until the controller acks, so a client that raises req must
//  keep it up and keep its address stable until ack.  That is the same
//  contract ps_sdram itself has.
//============================================================================
`default_nettype none

module ps_memarb #(
    parameter int N = 7
) (
    input  wire            clk,
    input  wire            rst,

    // --- deadline override -------------------------------------------------
    // A client whose bit is set here is picked before any client whose bit is
    // not, regardless of index.  It exists for exactly one situation: a client
    // with a HARD deadline that normally sits low in the order because it is
    // usually not urgent.
    //
    // ADPCM-A is that client.  jt10 presents a new sample address every 666
    // kHz slot -- about 60 clocks at 40 MHz -- and consumes whatever is on
    // `datain` at the end of it.  A byte that arrives after the slot has moved
    // on is a WRONG NIBBLE, and jt10_acc amplifies ADPCM-A by 7.25x on its way
    // into the mix, so one wrong nibble becomes an output step that correct
    // audio never makes: measured at 15 jumps over 2048 in a single frame,
    // against MAME's ZERO in 2.16 million samples (docs/DEBUG_LOG.md O13).
    //
    // This is not the priority reorder that was tried and reverted on
    // 2026-08-31.  That one moved a client up permanently on a guess.  This
    // leaves the order alone and lets one client jump the queue only in the
    // clocks where it would otherwise miss a deadline -- and only that client,
    // only then.
    //
    // ADPCM-A IS THE ONLY CLIENT THAT MAY SET A BIT HERE.  The sprite engine
    // was given one on 2026-09-02 and it undid O11: an override is a priority
    // inversion with a window around it, and the window was drawn against a
    // line length that a fix one commit later made obsolete.  Measured: 0-383
    // tilemap deadline misses a frame, none of them in the first third, while
    // the sprite engine's own overrun counter read 0 the whole time.  The
    // client with 2,549 clocks of slack does not get to interrupt the client
    // with 39.  See ps_top.sv at `arb_urgent`.
    input  wire [N-1:0]    urgent,

    // --- client side (index 0 = highest priority) --------------------------
    input  wire [N-1:0]        req,
    input  wire [25*N-1:0]     addr,     // flattened: word address per client
    input  wire [16*N-1:0]     din,
    input  wire [N-1:0]        we,
    input  wire [2*N-1:0]      ds,
    output reg  [N-1:0]        ack,
    output wire [15:0]         dout,     // shared: valid for the acked client

    // --- controller side ---------------------------------------------------
    output wire [24:0]     m_addr,
    output wire [15:0]     m_din,
    input  wire [15:0]     m_dout,
    output wire            m_req,
    output wire            m_we,
    output wire [1:0]      m_ds,
    input  wire            m_ack,

    // --- observability -----------------------------------------------------
    output reg  [15:0]     dbg_cpu_stall   // clocks the CPU waited, saturating
);

  // ---------------------------------------------------------------------
  // Winner selection.  Locked while a transaction is in flight so the
  // address the controller latched cannot change under it.
  // ---------------------------------------------------------------------
  reg              busy;
  reg  [$clog2(N)-1:0] sel;

  // Lowest set bit of req -- but an urgent request outranks every
  // non-urgent one.  Two passes, urgent second so it wins.
  reg  [$clog2(N)-1:0] pick;
  reg                  any;
  reg                  any_urgent;
  integer i;
  always @(*) begin
    pick       = '0;
    any        = 1'b0;
    any_urgent = 1'b0;
    for (i = N-1; i >= 0; i = i - 1)
      if (req[i]) begin pick = i[$clog2(N)-1:0]; any = 1'b1; end
    for (i = N-1; i >= 0; i = i - 1)
      if (req[i] && urgent[i]) begin
        pick       = i[$clog2(N)-1:0];
        any_urgent = 1'b1;
      end
    if (any_urgent) any = 1'b1;
  end

  always @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
      sel  <= '0;
    end else if (!busy) begin
      if (any) begin sel <= pick; busy <= 1'b1; end
    end else if (m_ack) begin
      busy <= 1'b0;
    end
  end

  // Latched at grant, not driven from the live client bus.  `busy` locked the
  // SELECTION but the address still came straight from the winning client, so
  // a client that changed its address while its own transaction was in flight
  // retargeted that transaction.  The tilemap does exactly that: it assigns
  // `rom_addr` unconditionally at every phase 0, so a fetch that was late by
  // more than one tile was reissued to the wrong address.  Independent of the
  // priority change above, and not measured by dbg_tm_late.
  reg [24:0] l_addr;
  reg [15:0] l_din;
  reg        l_we;
  reg [1:0]  l_ds;
  always @(posedge clk)
    if (!busy && any) begin
      l_addr <= addr[25*pick +: 25];
      l_din  <= din [16*pick +: 16];
      l_we   <= we  [pick];
      l_ds   <= ds  [2*pick +: 2];
    end

  assign m_req  = busy;
  assign m_addr = l_addr;
  assign m_din  = l_din;
  assign m_we   = l_we;
  assign m_ds   = l_ds;
  assign dout   = m_dout;

  always @(*) begin
    ack = '0;
    if (busy && m_ack) ack[sel] = 1'b1;
  end

  // ---------------------------------------------------------------------
  // How long the CPU actually waits.  Root CLAUDE.md 6.5: a claim needs a
  // measurement, and "the CPU is not starved" is a claim.  CPU is client 3.
  // ---------------------------------------------------------------------
  localparam int CPU = 5;
  always @(posedge clk) begin
    if (rst)
      dbg_cpu_stall <= 16'd0;
    else if (req[CPU] && !ack[CPU] && dbg_cpu_stall != 16'hFFFF)
      dbg_cpu_stall <= dbg_cpu_stall + 16'd1;
  end

endmodule

`default_nettype wire
