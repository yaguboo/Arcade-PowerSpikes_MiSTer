//============================================================================
//  Power Spikes -- sound board: Z80 + YM2610
//
//  The board's sound section is a Z80 at 5 MHz with its own 128 K program
//  ROM, talking to a YM2610 at 8 MHz that has two sample ROMs of its own.
//  It talks to the 68000 through a single 8-bit latch, in BOTH directions:
//  the 68000 writes a command and can read back whether the Z80 has taken
//  it (docs/HARDWARE.md section 6).  A one-way latch hangs the main CPU.
//
//  ---- clocking ----------------------------------------------------------
//      Z80      5.000 MHz   40 / 8    HW_CONFIRMED (20 MHz XTAL / 4)
//      YM2610   8.000 MHz   40 / 5    HW_CONFIRMED (own 8 MHz XTAL)
//
//  jt10 documents itself as "clock enabled at 7.5 - 8.5 MHz", so 8.000 is
//  the middle of its range and no rate conversion is needed.
//
//  ---- where the ROMs live ----------------------------------------------
//  The Z80 program ROM is in BRAM here, not in SDRAM, and that is a
//  bandwidth decision, not convenience -- see docs/DECISIONS.md D9.
//  The short version: the SDRAM controller delivers ~5.0 M accesses/s and
//  the rest of the board already wants ~3.5 M.  A Z80 fetching every opcode
//  over the shared bus adds ~1.2 M and puts the design at ~94 % of its
//  memory system, with the sound CPU on the LOWEST arbiter priority.  On the
//  real PCB the Z80 has a dedicated ROM on dedicated pins and never waits,
//  so BRAM is also the more faithful structure.
//
//  The two ADPCM sample ROMs stay in SDRAM: together they are 1.25 MB, which
//  BRAM cannot hold, and their fetch rate is low enough to share (ADPCM-A
//  advances one byte per 666 kHz slot, ADPCM-B one per 55 kHz).
//
//  ---- port map ----------------------------------------------------------
//  pspikes uses spinlbrk_sound_portmap, NOT the identically-plausible
//  pspikes_sound_portmap that belongs to aerofgtb.  Reading the function
//  whose name matches the game gives the wrong map.  FBNeo agrees with the
//  map below, so FBNEO_CROSSCHECK.
//
//      00      ROM bank select, 2 bits         W
//      14      latch read (R) / latch ack (W)
//      18-1b   YM2610                          RW
//============================================================================
`default_nettype none

module ps_sound (
    input  wire        clk,           // 40.000 MHz
    input  wire        rst,
    input  wire        rom_rst,       // PLL-lock only.  MiSTer asserts RESET
                                      // for the WHOLE ROM download, so `rst`
                                      // is high exactly while the sound ROM
                                      // is arriving.  Anything that has to
                                      // observe the download must not be held
                                      // in it -- see the ROM probe below.
    input  wire        ce_en,         // low while paused or downloading
    input  wire        frame,         // one pulse per frame, for the windowed
                                      // sample-fetch counters below

    // --- Z80 program ROM load, snooped off the download stream -------------
    input  wire        rom_we,
    input  wire [15:0] rom_wa,        // word offset inside the soundbank region
    input  wire [15:0] rom_wd,

    // --- 68000 side of the sound latch -------------------------------------
    input  wire [7:0]  latch_din,
    input  wire        latch_we,
    output reg         latch_pending,

    // --- ADPCM sample ROMs, region-relative word addresses -----------------
    // ps_top adds the region base.  Keeping the base out of here means this
    // module cannot disagree with ps_rommap.svh about where anything lives.
    output wire [19:1] adpcma_a,
    input  wire [15:0] adpcma_q,
    output reg         adpcma_req,
    input  wire        adpcma_ack,

    output wire [17:1] adpcmb_a,
    input  wire [15:0] adpcmb_q,
    output reg         adpcmb_req,
    input  wire        adpcmb_ack,

    // --- audio --------------------------------------------------------------
    output wire signed [15:0] snd_l,
    output wire signed [15:0] snd_r,

    // --- observability ------------------------------------------------------
    output reg  [15:0] dbg_z80_cyc,    // Z80 memory cycles, CUMULATIVE
    output reg  [15:0] dbg_ym_wr,      // YM2610 register writes, CUMULATIVE
    output reg  [15:0] dbg_pcma_fetch, // ADPCM-A bytes fetched, CUMULATIVE
    output reg  [15:0] dbg_pcm_late,   // fetches the SDRAM did not finish in
                                       // time, CUMULATIVE.  Expected ZERO --
                                       // the audio counterpart of the sprite
                                       // overrun counter (DEBUG_LOG O2)
    output wire [7:0]  dbg_state,      // {halt_n, pending, nmi_n, int_n,
                                       //  2'd0, bank[1:0]}
    output reg  [15:0] dbg_rom_w0,     // word 0 as it landed in BRAM
    output reg  [15:0] dbg_rom_n,      // words written, saturating
    output reg  [15:0] dbg_peak,       // {|snd_l| peak [15:8], |snd_r| [15:8]}
    output reg  [15:0] dbg_latch_ack,  // commands the Z80 consumed, saturating
    output reg  [15:0] dbg_peak_l,     // full 16-bit max-held |snd_l|
    output reg  [15:0] dbg_peak_r,     // full 16-bit max-held |snd_r|
    output reg  [15:0] dbg_pcma_kon,   // ADPCM-A key-on writes  (bank1 reg 00)
    output reg  [15:0] dbg_fm_kon,     // FM key-on writes       (bank0 reg 28)
    output reg  [15:0] dbg_sample,     // jt10 snd_sample pulses, saturating
    output reg  [15:0] dbg_io_rd,      // Z80 I/O read cycles, saturating
    output reg  [15:0] dbg_last_b1,    // last {register, data} written to bank 1
    output reg  [15:0] dbg_irq,        // YM2610 IRQ assertions (irq_n edges)
    output reg  [15:0] dbg_intack,     // Z80 interrupt acknowledge cycles
    output reg  [15:0] dbg_timer_w,    // writes to bank0 reg 27 (timer control)
    output reg  [15:0] dbg_peak_fm,    // peak |fm_left| INSIDE jt10
    output reg  [15:0] dbg_peak_psg,   // peak psg_snd   INSIDE jt10
    output reg  [15:0] dbg_roe_a,      // ADPCM-A nibble advances (roe_n falls)
    output reg  [15:0] dbg_peak_op,    // peak |op_result_hd| INSIDE jt12
    output reg  [15:0] dbg_aon_cnt,    // times aon_sr[0] reached the counter
    output reg  [15:0] dbg_eg_min,     // MIN-hold of eg_V: 3FF = never opened
    output reg  [15:0] dbg_keyon_cnt,  // operator slots seen with keyon_I high
    output reg  [15:0] dbg_mmr_kon,    // actual jt12_mmr REG_KON decodes
    output reg  [15:0] dbg_kon_latch,  // up_keyon_reg rising edges
    output reg  [15:0] dbg_kon_match,  // key_upnow rising edges
    output reg  [15:0] dbg_csr_slots,  // csr_out rising edges
    output reg  [15:0] dbg_fm_koff,    // 0x28 writes with an EMPTY slot mask
    output reg  [15:0] dbg_last_kon,   // {last 0x28 value, 8'd0}
    output reg  [15:0] dbg_late_fr,   // late sample fetches in the LAST frame
    output reg  [15:0] dbg_fetch_fr,   // total sample fetches in that frame
    output reg  [15:0] dbg_pcmb_fr,     // ADPCM-B fetches in the last frame
    output reg  [15:0] dbg_pcmb_late_fr,// ...delivered after the address moved
    // THE SYMPTOM ITSELF, at last.  Everything measured so far has been a
    // suspected CAUSE -- fetch rates, register writes, peaks, clipping -- and
    // all of them came back healthy while the board still crackles.  A crackle
    // IS a large jump between consecutive samples; music is smooth and noise
    // is not.  So count the jumps.
    //
    // MAME's own audio over 45 s of this game's attract, at 48 kHz:
    //
    //     peak |L|        4059
    //     |delta|         median 10   p99 148   p99.9 392   max 1160
    //     |delta| > 2048  ZERO, in 2.16 million samples
    //
    // So a single delta over 2048 on this board is not "a bit hot", it is an
    // event that correct audio never produces.  Two readings of one fact
    // (board CLAUDE.md 1.3): how many, and how big the worst one was.
    output reg  [15:0] dbg_jump_fr,     // |delta| > 2048 in the last frame
    output reg  [15:0] dbg_maxd_fr,     // largest |delta| in the last frame
    // ...and WHAT THE JUMP LOOKED LIKE.  The count says a fault happened and
    // the magnitude says how big; neither says which fault.  The two samples
    // either side of the first jump in a frame do, because the shape is the
    // signature:
    //
    //     to or from zero        a channel started or stopped
    //     sign flipped, |sum| ~ full scale   arithmetic wrapped
    //     one sample out, next one back      a single bad nibble
    //     a new level that persists          a run of wrong data
    //
    // Board CLAUDE.md 1.3 again: a count that cannot be cross-checked is the
    // instrument this factory has been burned by, and "15 jumps" is exactly
    // that until something says what they were.
    output reg  [15:0] dbg_jump_a,      // sample BEFORE the frame's first jump
    output reg  [15:0] dbg_jump_b       // sample AFTER it
);

  // ---------------------------------------------------------------------
  // Clock enables
  //
  // T80pa wants two enables half a period apart; CEN_p is the rising phase.
  // ---------------------------------------------------------------------
  reg [2:0] zdiv;
  reg [2:0] ydiv;
  always @(posedge clk) begin
    if (rst) begin
      zdiv <= 3'd0;
      ydiv <= 3'd0;
    end else begin
      zdiv <= zdiv + 3'd1;                       // free-running / 8
      ydiv <= (ydiv == 3'd4) ? 3'd0 : ydiv + 3'd1;
    end
  end
  wire cen_p  = ce_en & (zdiv == 3'd0);          // 5.000 MHz
  wire cen_n  = ce_en & (zdiv == 3'd4);
  wire ym_cen = ce_en & (ydiv == 3'd0);          // 8.000 MHz

  // ---------------------------------------------------------------------
  // Reset -- and it has to be MUCH longer than jt10's header suggests.
  //
  // The header says "rst should be at least 6 clk&cen cycles long", and an
  // earlier version of this file took that literally: 64 system clocks, about
  // 13 `cen` ticks. That is not enough.
  //
  // Several of jt12's pipelines are circular shift registers that initialise
  // by SHIFTING RESET VALUES THROUGH THEMSELVES while their internal enable
  // runs (jt12_sh_rst). Those run on `clk_en`, which for YM2610 mode is
  // `cen`/6, and the FM pipeline is 24 stages deep. So a full initialisation
  // needs at least 24 clk_en pulses = 144 cen ticks = 720 system clocks.
  // Thirteen cen ticks gave the pipelines about TWO clk_en pulses.
  //
  // 4096 system clocks is 102 us, roughly 136 clk_en pulses -- five times
  // the depth, and it costs nothing because it happens once at reset.
  // ---------------------------------------------------------------------
  reg [12:0] rstcnt;
  always @(posedge clk) begin
    if (rst) rstcnt <= 13'd0;
    else if (!rstcnt[12]) rstcnt <= rstcnt + 13'd1;
  end
  wire snd_rst = rst | ~rstcnt[12];

  // ---------------------------------------------------------------------
  // Z80
  // ---------------------------------------------------------------------
  wire [15:0] z80_a;
  wire [7:0]  z80_do;
  reg  [7:0]  z80_di;
  wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n;
  wire        ym_irq_n;

  // NMI is the "a command is waiting" line.  MAME drives it as a LEVEL from
  // the latch's data_pending callback, asserted on write and cleared by the
  // Z80's acknowledge write to port 14.
  wire nmi_n = ~latch_pending;
  wire int_n = ym_irq_n;

  T80pa #(.Mode(0)) u_z80 (
      .RESET_n (~snd_rst),
      .CLK     (clk),
      .CEN_p   (cen_p),
      .CEN_n   (cen_n),
      .WAIT_n  (1'b1),        // the program ROM is BRAM: it never stalls
      .INT_n   (int_n),
      .NMI_n   (nmi_n),
      .BUSRQ_n (1'b1),
      .M1_n    (m1_n),
      .MREQ_n  (mreq_n),
      .IORQ_n  (iorq_n),
      .RD_n    (rd_n),
      .WR_n    (wr_n),
      .RFSH_n  (rfsh_n),
      .HALT_n  (halt_n),
      .BUSAK_n (),
      .OUT0    (1'b0),
      .A       (z80_a),
      .DI      (z80_di),
      .DO      (z80_do),
      .REG     (),
      .DIRSet  (1'b0)
  );

  // A refresh cycle also pulls MREQ low.  Decoding it as a real memory access
  // would write work RAM at the refresh address on every M1.
  wire mem_cy = ~mreq_n & rfsh_n;
  wire mem_rd = mem_cy & ~rd_n;
  wire mem_wr = mem_cy & ~wr_n;
  wire io_cy  = ~iorq_n & m1_n;
  wire io_rd  = io_cy & ~rd_n;
  wire io_wr  = io_cy & ~wr_n;

  // ---------------------------------------------------------------------
  // Address decode
  //
  //     0000-77ff   ROM, soundbank offset 0000-77ff
  //     7800-7fff   2 K work RAM
  //     8000-ffff   banked window into the same 128 K ROM, 4 x 32 K
  //
  // MAME builds the "audiocpu" region with ROM_COPY from "soundbank" offset
  // 0, so the low ROM and bank 0 are the same bytes.  There is one ROM.
  // ---------------------------------------------------------------------
  reg [1:0] bank;
  wire sel_ram = (z80_a[15:11] == 5'b01111);              // 7800-7fff

  wire [16:0] rom_byte = z80_a[15] ? {bank, z80_a[14:0]}  // banked window
                                   : {2'b00, z80_a[14:0]};

  // ---------------------------------------------------------------------
  // Program ROM -- 64 K words of BRAM, filled from the download stream.
  // Word W holds byte 2W in [15:8] and byte 2W+1 in [7:0], the same
  // big-endian convention ps_download uses everywhere else.
  // ---------------------------------------------------------------------
  reg [15:0] sndrom [0:65535];
  reg [15:0] rom_q;
  reg        rom_lo;
  always @(posedge clk) begin
    if (rom_we) sndrom[rom_wa] <= rom_wd;
    rom_q  <= sndrom[rom_byte[16:1]];
    rom_lo <= rom_byte[0];
  end

  // Did the program actually arrive?  Without this, "the Z80 runs but never
  // touches the YM2610" has two causes -- a wrong port map, and a ROM full of
  // 0x00, which is NOP and produces exactly the same reading on every other
  // counter.  Word 0 of ROM "19" is ED 56, which is `IM 1`; the rest of the
  // first line is DI / LD SP,$8000 / clear 7800-7fff, so this landmark is
  // also a check that the sound map in docs/HARDWARE.md section 5 is right.
  // Same pattern as the 68000 reset vector in overlay rows 10-12.
  //
  // Reset by `rom_rst`, NOT `rst`.  This is the third time this project has
  // met that trap: the observer of a download cannot be held in the reset
  // that the download asserts.  docs/LESSONS_LEARNED.md L11 rule 2, and the
  // same reason ps_memarb runs on mem_rst.
  always @(posedge clk) begin
    if (rom_rst) begin
      dbg_rom_w0 <= 16'd0;
      dbg_rom_n  <= 16'd0;
    end else if (rom_we) begin
      if (rom_wa == 16'd0) dbg_rom_w0 <= rom_wd;
      if (dbg_rom_n != 16'hFFFF) dbg_rom_n <= dbg_rom_n + 16'd1;
    end
  end
  wire [7:0] rom_byte_q = rom_lo ? rom_q[7:0] : rom_q[15:8];

  // ---------------------------------------------------------------------
  // 2 K work RAM
  // ---------------------------------------------------------------------
  reg [7:0] wram [0:2047];
  reg [7:0] wram_q;
  always @(posedge clk) begin
    if (mem_wr && sel_ram && ce_en) wram[z80_a[10:0]] <= z80_do;
    wram_q <= wram[z80_a[10:0]];
  end

  // ---------------------------------------------------------------------
  // Sound latch
  //
  // MAME configures the latch with set_separate_acknowledge(true): a READ
  // does not clear "pending", only the Z80's write to port 14 does.  The
  // 68000 polls the pending bit at fff007, so clearing it on read instead
  // would let the 68000 overwrite a command the Z80 has not consumed.
  // ---------------------------------------------------------------------
  reg [7:0] latch_data;
  wire      latch_ack = io_wr && (z80_a[7:0] == 8'h14);
  reg       latch_ack_d;
  always @(posedge clk) begin
    latch_ack_d <= latch_ack;
    if (rst) begin
      latch_data    <= 8'h00;
      latch_pending <= 1'b0;
    end else begin
      if (latch_we) begin
        latch_data    <= latch_din;
        latch_pending <= 1'b1;
      end else if (latch_ack & ~latch_ack_d) begin
        latch_pending <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // I/O writes.
  //
  // An I/O cycle holds IORQ and WR for several system clocks, so the write is
  // edged down to a single clock.
  //
  // THE UNIT OF ONE YM2610 WRITE IS ONE RAW CLOCK, NOT ONE `cen`.
  // jt12_mmr says so itself, above its register block:
  //
  //     // this runs at clk speed, no clock gating here
  //     always @(posedge clk) begin : memory_mapped_registers
  //         ...
  //         if( write ) begin
  //
  // `write` is `!cs_n && !wr_n`, sampled on EVERY rising clk. An earlier
  // version of this file held the strobes low across one whole 8 MHz cen
  // period -- five 40 MHz clocks -- on the assumption that jt12 sampled at
  // cen. It does not, so every register write executed FIVE TIMES.
  //
  // Repeated identical writes are mostly idempotent, which is why the write
  // rate looked correct on hardware. What they are not idempotent for is the
  // one-shot UPDATE LEVELS jt12_mmr raises: `up_aon`, `up_keyon`, `up_start`,
  // `psg_wr_n`. Holding those for five clocks re-triggers them:
  //
  //   ADPCM-A: aon_cmd_cpy reloads and jt10_adpcm_cnt restarts the sample
  //            from its start address again and again, so adpcma_addr never
  //            gets past its first byte -- exactly what the board showed.
  //   FM:      key-on is re-asserted, so envelopes restart their attack
  //            continuously and never produce a note.
  //
  // One cause, both symptoms. docs/DEBUG_LOG.md C8.
  // ---------------------------------------------------------------------
  reg  io_wr_d;
  always @(posedge clk) io_wr_d <= io_wr;
  wire io_wr_pulse = io_wr & ~io_wr_d;

  wire ym_sel = (z80_a[7:2] == 6'b000110);       // 18-1b

  reg  [7:0] ym_din_r;
  reg  [1:0] ym_addr_r;
  reg        ym_act;

  always @(posedge clk) begin
    if (rst) begin
      bank      <= 2'd0;
      ym_act    <= 1'b0;
      ym_din_r  <= 8'd0;
      ym_addr_r <= 2'd0;
    end else begin
      ym_act <= 1'b0;                    // exactly one clock wide
      if (io_wr_pulse) begin
        if (z80_a[7:0] == 8'h00) bank <= z80_do[1:0];
        if (ym_sel) begin
          ym_din_r  <= z80_do;
          ym_addr_r <= z80_a[1:0];
          ym_act    <= 1'b1;             // asserted with the captured data,
                                         // so jt12 samples both together on
                                         // the next rising clk
        end
      end
    end
  end

  // A Z80 I/O cycle is at least 24 system clocks, so two of these can never
  // land in consecutive clocks and no queue is needed.

  wire [7:0] ym_dout;

  // jt12_dout registers its output from the ADDRESS PIN, on every clock and
  // regardless of cs_n -- so a read returns whatever register `addr` points
  // at, not whatever was written last.  Feeding it the latched write address
  // all the time would make every status read return the last register the
  // driver happened to write to.  So: latched only while a write is being
  // presented, live from the Z80's address the rest of the time.
  wire [1:0] ym_addr = ym_act ? ym_addr_r : z80_a[1:0];

  // ---------------------------------------------------------------------
  // Z80 read mux
  // ---------------------------------------------------------------------
  always @(*) begin
    z80_di = 8'hFF;
    if (mem_rd)      z80_di = sel_ram ? wram_q : rom_byte_q;
    else if (io_rd) begin
      if      (z80_a[7:0] == 8'h14) z80_di = latch_data;
      else if (ym_sel)              z80_di = ym_dout;
    end
    // An interrupt acknowledge (M1 & IORQ) reads 0xFF, which is RST 38h in
    // IM 0 and ignored in IM 1.  MAME drives the YM2610 IRQ onto
    // INPUT_LINE_0 with no vector, so nothing depends on the value.
  end

  // ---------------------------------------------------------------------
  // YM2610
  // ---------------------------------------------------------------------
  wire [19:0] pcma_addr;
  wire [23:0] pcmb_addr;
  wire        pcma_roe_n, pcmb_roe_n;
  wire        ym_snd_sample;
  wire signed [13:0] op_hd;        // jt12's operator result, before the acc
  wire               aon_sr0;      // the ADPCM-A key-on that reaches the cnt
  wire        [ 9:0] eg_v;         // operator attenuation, 3FF = silent
  wire               keyon_i;      // key-on presented to the operators
  wire               mmr_kon_wr;   // actual jt12_mmr REG_KON data decode
  wire               up_keyon_reg; // captured request awaiting channel/S4
  wire               key_upnow;    // captured request matches channel/S4
  wire               csr_out;      // key state leaving jt12_kon's CSR
  wire signed [15:0] fm_l;
  wire        [ 9:0] psg_v;
  reg  [7:0]  pcma_data, pcmb_data;

  jt10 u_ym (
      .rst          (snd_rst),
      .clk          (clk),
      .cen          (ym_cen),
      .din          (ym_din_r),
      .addr         (ym_addr),
      .cs_n         (~ym_act),
      .wr_n         (~ym_act),
      .dout         (ym_dout),
      .irq_n        (ym_irq_n),
      .adpcma_addr  (pcma_addr),
      .adpcma_bank  (),          // above the 1 MB region; see below
      .adpcma_roe_n (pcma_roe_n),
      .adpcma_data  (pcma_data),
      .adpcmb_addr  (pcmb_addr),
      .adpcmb_roe_n (pcmb_roe_n),
      .adpcmb_data  (pcmb_data),
      .psg_A        (),
      .psg_B        (),
      .psg_C        (),
      // These three are jt10 ports already -- they were simply left open.
      // Peak-holding them splits "the operators produce nothing" from "they
      // produce something and the final mix loses it", with NO modification
      // to the vendored GPL source.
      .dbg_op_result_hd(op_hd),
      .dbg_aon_sr0     (aon_sr0),
      .dbg_eg_V        (eg_v),
      .dbg_keyon_I     (keyon_i),
      .dbg_mmr_kon_wr  (mmr_kon_wr),
      .dbg_up_keyon_reg(up_keyon_reg),
      .dbg_key_upnow   (key_upnow),
      .dbg_csr_out     (csr_out),
      .fm_left      (fm_l),
      .fm_right     (),
      .psg_snd      (psg_v),
      .snd_right    (snd_r),
      .snd_left     (snd_l),
      .snd_sample   (ym_snd_sample),
      .ch_enable    (6'b111111)
  );

  // ---------------------------------------------------------------------
  // Sample ROM fetch -- follow the ADDRESS, with a small cache
  //
  // CORRECTION, and the reason this comment is long: an earlier version of
  // this file switched from address-following to `roe_n`-following on the
  // strength of a MAME dump showing MAME's YM2610 reading its ADPCM-A ROM
  // ~9 300 times a second against this fetcher's 655 000.  That comparison
  // was wrong.
  //
  // jt10 samples `datain` on EVERY `cen` (`data <= !nibble_sel ? ...` in
  // jt10_adpcm_drvA) and `addr1` is time-multiplexed across six channels one
  // slot at a time, so the real chip DOES present a new address and read its
  // ROM every slot -- 666 kHz.  `roe_n` is the ROM's output enable, not a
  // "fetch now" request, and the real ROM answers combinationally.  MAME's
  // 9 300/s is its BEHAVIOURAL model counting logical byte fetches; it does
  // not model the pin multiplexing at all.  Root CLAUDE.md section 5 says
  // exactly this -- MAME is a behavioural reference, not hardware truth --
  // and section 5.1's "dump MAME for rates" was applied to a pin-level
  // question it cannot answer.
  //
  // roe_n-following also MISSES address changes: `roe_n1 <= ~sumup6`, so on a
  // key-on restart (`clr6 && on6`) the address jumps to the sample start and
  // roe_n never asserts, leaving the previous channel's byte on the pins.
  //
  // So: follow the address, which is what the chip does, and make the bus
  // keep up with a cache.  The cache dismissal was wrong too -- "8.1 % of
  // consecutive reads share a word" compared DIFFERENT channels.  Within one
  // channel two nibbles share a word, and a channel that is not playing has a
  // STATIC address, so after one fetch it never needs the bus again.  Idle
  // channels are most of the traffic.
  //
  // Six entries, fully associative on the word address, round-robin replace.
  // ---------------------------------------------------------------------
  // (kept for reference -- the roe_n experiment and why it was withdrawn)
  // ---------------------------------------------------------------------
  // Sample ROM fetch -- FOLLOW roe_n, NOT the address
  //
  // The first version refetched whenever `adpcma_addr` CHANGED, reasoning
  // that jt10 has no handshake on those pins so the byte simply has to be
  // there.  That is true of the DATA contract and wrong about the RATE:
  // jt10 round-robins six ADPCM-A channels at 666 kHz, so the address
  // changes on every slot whether or not that channel is playing.
  //
  // Dumping MAME's own YM2610 settled it.  Its `adpcm_a` address space was
  // tapped and the real chip reads:
  //
  //     ~9 300 bytes/s while ADPCM is playing, 0 when it is not
  //     consecutive reads sharing one 16-bit word:  8.1 %
  //
  // against 10 690 fetches PER FRAME on the board -- 655 000/s, seventy
  // times what the chip needs.  That is what was losing 8.1 % of fetches to
  // arbitration, and no arbiter order fixes a client asking seventy times
  // too often.  (The same dump kills the per-channel word cache in
  // DECISIONS D9: only 8.1 % of consecutive reads share a word, because the
  // channels interleave.)
  //
  // `roe_n` is the strobe the chip actually uses -- `roe_n1 <= ~sumup6` in
  // jt10_adpcm_cnt, asserted only when a channel really advances a nibble.
  // Following it makes the fetch rate the chip's rate.
  //
  // The 1 MB ADPCM-A region is smaller than the YM2610's 25-bit A-bus, so
  // adpcma_bank contributes only above bit 19 and is masked off here, the
  // same way MAME masks the region.  Likewise ADPCM-B's 24-bit bus against a
  // 256 K region.
  // ---------------------------------------------------------------------
  wire [19:0] pcma_want = pcma_addr;             // bank is above the region
  wire [17:0] pcmb_want = pcmb_addr[17:0];

  reg [19:0] pcma_cur;
  reg [17:0] pcmb_cur;
  reg        pcma_late;      // this fetch has already been counted as late
  // `roe_n` is no longer a fetch trigger, but its falling edges are still
  // worth counting: one per nibble the chip actually advances.  THAT is the
  // number comparable with MAME's 9 300 byte-reads/s -- the comparison L17
  // says was made against the wrong quantity.  Two nibbles per byte, so this
  // should land near 18 600/s if the two models agree, while the fetch
  // counter measures bus traffic and legitimately does not.
  reg        roe_a_d;
  always @(posedge clk) begin
    if (rst) begin
      roe_a_d   <= 1'b1;
      dbg_roe_a <= 16'd0;
    end else begin
      roe_a_d <= pcma_roe_n;
      if (roe_a_d && !pcma_roe_n && dbg_roe_a != 16'hFFFF)
        dbg_roe_a <= dbg_roe_a + 16'd1;
    end
  end

  // ---- the cache -------------------------------------------------------
  // Six entries because the chip round-robins six ADPCM-A channels, tagged
  // on the 19-bit WORD address so a channel's two nibbles cost one fetch.
  //
  // REPLACEMENT POLICY.  Six ways holding exactly six live addresses, each
  // touched once per rotation, is the pathological case for both round-robin
  // and LRU: whatever they evict is something another channel is about to
  // ask for, and an idle channel -- whose address never moves and which need
  // never touch the bus again -- is as likely a victim as anything else.
  //
  // But the right victim is knowable without knowing which channel is in the
  // slot.  An ADPCM stream only ever moves FORWARD one nibble at a time, so
  // when the word address misses at W, the entry that just went dead is the
  // one holding **W-1**: the same channel's previous word.  Evict that.
  // Failing that take an invalid way, and only failing both fall back to
  // round-robin -- which is where a key-on restart lands, since that jumps to
  // an arbitrary start address.  Rare, and a wrong victim only costs a fetch.
  // Nothing ever writes the sample ROM after download, so entries only need
  // clearing on reset -- which covers the download, since `rst` is held for
  // the whole transfer.
  localparam PCMA_WAYS = 6;
  reg                  ca_val [0:PCMA_WAYS-1];
  reg [18:0]           ca_tag [0:PCMA_WAYS-1];
  reg [15:0]           ca_dat [0:PCMA_WAYS-1];
  reg [2:0]            ca_rr;                    // round-robin, last resort
  reg [2:0]            fill_way;                 // victim latched at miss

  wire [18:0] pcma_wword = pcma_want[19:1];

  reg         ca_hit;
  reg [15:0]  ca_hit_dat;
  reg  [2:0]  ca_victim;      // way to overwrite on the next fill
  reg         got_empty, got_pred;
  reg  [3:0]  ci;             // a vector, not an `integer`: this is indexed,
                              // and a part-select of an integer is not legal
                              // Verilog-2001.  Four bits so the loop can reach
                              // PCMA_WAYS and terminate.

  always @* begin
    ca_hit     = 1'b0;
    ca_hit_dat = 16'h0000;
    ca_victim  = ca_rr;                       // last resort
    got_empty  = 1'b0;
    got_pred   = 1'b0;
    for (ci = 4'd0; ci < PCMA_WAYS; ci = ci + 4'd1) begin
      if (ca_val[ci] && ca_tag[ci] == pcma_wword) begin
        ca_hit     = 1'b1;
        ca_hit_dat = ca_dat[ci];
      end
      if (!ca_val[ci] && !got_empty) begin    // an empty way beats round-robin
        got_empty = 1'b1;
        ca_victim = ci[2:0];
      end
    end
    // ...and the dead predecessor beats an empty way, so it is tested after
    for (ci = 4'd0; ci < PCMA_WAYS; ci = ci + 4'd1)
      if (ca_val[ci] && ca_tag[ci] == (pcma_wword - 19'd1) && !got_pred) begin
        got_pred  = 1'b1;
        ca_victim = ci[2:0];
      end
  end

  assign adpcma_a = pcma_cur[19:1];
  assign adpcmb_a = pcmb_cur[17:1];

  integer cj;
  always @(posedge clk) begin
    if (rst) begin
      adpcma_req     <= 1'b0;
      pcma_cur       <= 20'd0;
      pcma_data      <= 8'h00;
      pcma_late      <= 1'b0;
      ca_rr          <= 3'd0;
      fill_way       <= 3'd0;
      dbg_pcma_fetch <= 16'd0;
      dbg_pcm_late   <= 16'd0;
      for (cj = 0; cj < PCMA_WAYS; cj = cj + 1) begin
        ca_val[cj] <= 1'b0;
        ca_tag[cj] <= 19'd0;
        ca_dat[cj] <= 16'h0000;
      end
    end else begin
      // The chip's ROM answers whatever address is on its pins, so present
      // the byte for the CURRENT address whenever it is known.  One clock of
      // latency against jt10's `cen` every five, with the address stable for
      // a whole 666 kHz slot, is far inside the deadline: jt10 reloads
      // `data` from `datain` on every cen and the decoder consumes it at
      // cen6, so the byte has ~11 cen ticks to arrive.
      if (ca_hit)
        pcma_data <= pcma_want[0] ? ca_hit_dat[7:0] : ca_hit_dat[15:8];

      if (!adpcma_req) begin
        // A miss is the only thing that touches the bus.
        if (!ca_hit) begin
          pcma_cur   <= pcma_want;
          adpcma_req <= 1'b1;
          pcma_late  <= 1'b0;
          // Latch the victim chosen for THIS address.  By the time the word
          // comes back the address has usually moved on, and picking the way
          // then would evict against the wrong predecessor.
          fill_way   <= ca_victim;
        end
      end else begin
        // Late means the chip moved to another address before this read
        // came back -- a byte the bus genuinely failed to deliver in time.
        if (pcma_wword != pcma_cur[19:1] && !pcma_late) begin
          pcma_late <= 1'b1;
          if (dbg_pcm_late != 16'hFFFF) dbg_pcm_late <= dbg_pcm_late + 16'd1;
        end
        if (adpcma_ack) begin
          adpcma_req         <= 1'b0;
          ca_val[fill_way]   <= 1'b1;
          ca_tag[fill_way]   <= pcma_cur[19:1];
          ca_dat[fill_way]   <= adpcma_q;
          ca_rr              <= (ca_rr == PCMA_WAYS-1) ? 3'd0 : ca_rr + 3'd1;
          if (dbg_pcma_fetch != 16'hFFFF) dbg_pcma_fetch <= dbg_pcma_fetch + 16'd1;
        end
      end
    end
  end

  // Four consecutive stage counters for the FM key-on path.  The first is
  // jt12_mmr's exact REG_KON branch condition; the other three count rising
  // edges of state held between internal clk_en pulses.  LOCAL: these are
  // additive hardware diagnostics and do not feed the YM2610 implementation.
  reg up_keyon_reg_d, key_upnow_d, csr_out_d;
  always @(posedge clk) begin
    if (rst) begin
      up_keyon_reg_d <= 1'b0;
      key_upnow_d    <= 1'b0;
      csr_out_d      <= 1'b0;
      dbg_mmr_kon    <= 16'd0;
      dbg_kon_latch  <= 16'd0;
      dbg_kon_match  <= 16'd0;
      dbg_csr_slots  <= 16'd0;
    end else begin
      up_keyon_reg_d <= up_keyon_reg;
      key_upnow_d    <= key_upnow;
      csr_out_d      <= csr_out;
      if (mmr_kon_wr && dbg_mmr_kon != 16'hFFFF)
        dbg_mmr_kon <= dbg_mmr_kon + 16'd1;
      if (up_keyon_reg && !up_keyon_reg_d && dbg_kon_latch != 16'hFFFF)
        dbg_kon_latch <= dbg_kon_latch + 16'd1;
      if (key_upnow && !key_upnow_d && dbg_kon_match != 16'hFFFF)
        dbg_kon_match <= dbg_kon_match + 16'd1;
      if (csr_out && !csr_out_d && dbg_csr_slots != 16'hFFFF)
        dbg_csr_slots <= dbg_csr_slots + 16'd1;
    end
  end

  // One held word for ADPCM-B -- the degenerate case of the ADPCM-A cache.
  //
  // AND the first instrumentation this channel has ever had.  It was rewritten
  // this session without ever checking that the game uses it; MAME says it
  // does -- the driver has a 256 K `ymsnd:adpcmb` region and a tap on the
  // Z80's YM2610 ports counts 196 writes to bank-0 registers 10-1B in 59
  // seconds, about 19 samples started.  So on the board this should fetch in
  // short bursts and read ZERO on most frames.  Non-zero every frame means the
  // channel never stops, which loops a fragment forever and is what a
  // continuous crackle sounds like.
  reg        pcmb_val;
  reg [16:0] pcmb_tag;
  reg [15:0] pcmb_word;
  reg [15:0] pcmb_acc, pcmb_lacc;
  reg        pcmb_lt;
  wire       pcmb_hit = (pcmb_tag == pcmb_want[17:1]);

  always @(posedge clk) begin
    // ADPCM-B follows the address for the same reason ADPCM-A does: `roe_n`
    // is the ROM's output enable, not a request, and following it misses the
    // key-on restart, where the address jumps to the sample start but roe_n
    // never asserts.  On a one-channel delta-T stream that miss lands on the
    // FIRST byte of every sample, which is the most audible byte there is.
    //
    // No cache here.  ADPCM-B is a single channel, not six interleaved, so
    // its address changes at its own sample rate and two consecutive nibbles
    // already share a word by construction -- the `pcmb_tag` compare
    // below is the whole benefit a cache would have given.
    if (rst) begin
      adpcmb_req <= 1'b0;
      pcmb_cur   <= 18'd0;
      pcmb_data  <= 8'h00;
      pcmb_val   <= 1'b0;
      pcmb_word  <= 16'h0000;
      pcmb_acc   <= 16'd0;
      pcmb_lacc  <= 16'd0;
      pcmb_lt    <= 1'b0;
      dbg_pcmb_fr      <= 16'd0;
      dbg_pcmb_late_fr <= 16'd0;
    end else begin
      if (frame) begin
        dbg_pcmb_fr      <= pcmb_acc;
        dbg_pcmb_late_fr <= pcmb_lacc;
        pcmb_acc  <= 16'd0;
        pcmb_lacc <= 16'd0;
      end
      if (pcmb_val && pcmb_hit)
        pcmb_data <= pcmb_want[0] ? pcmb_word[7:0] : pcmb_word[15:8];

      if (!adpcmb_req) begin
        if (!(pcmb_val && pcmb_hit)) begin
          pcmb_cur   <= pcmb_want;
          adpcmb_req <= 1'b1;
        end
      end else begin
        if (pcmb_want[17:1] != pcmb_cur[17:1] && !pcmb_lt) begin
          pcmb_lt <= 1'b1;
          if (pcmb_lacc != 16'hFFFF) pcmb_lacc <= pcmb_lacc + 16'd1;
        end
        if (adpcmb_ack) begin
          adpcmb_req <= 1'b0;
          pcmb_val   <= 1'b1;
          pcmb_word  <= adpcmb_q;
          pcmb_tag   <= pcmb_cur[17:1];
          pcmb_lt    <= 1'b0;
          if (pcmb_acc != 16'hFFFF) pcmb_acc <= pcmb_acc + 16'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // Counters.  All CUMULATIVE and saturating, like every other counter in
  // this core -- a live value that resets is unreadable off a screenshot.
  // ---------------------------------------------------------------------
  reg mem_cy_d;
  always @(posedge clk) begin
    mem_cy_d <= mem_cy;
    if (rst) begin
      dbg_z80_cyc <= 16'd0;
      dbg_ym_wr   <= 16'd0;
    end else begin
      if (mem_cy & ~mem_cy_d & (dbg_z80_cyc != 16'hFFFF))
        dbg_z80_cyc <= dbg_z80_cyc + 16'd1;
      if (ym_act & (dbg_ym_wr != 16'hFFFF))
        dbg_ym_wr <= dbg_ym_wr + 16'd1;
    end
  end

  // ---------------------------------------------------------------------
  // Audio activity, so that "is there sound" can be answered from a
  // SCREENSHOT.  Nobody working on this core is in the same room as the
  // board, and every other question about this board has been settled by
  // reading a picture rather than by asking someone to listen.
  //
  // Max-hold, never decaying: the question is "did this output ever leave
  // digital silence", and a hold answers that from one frame. 0000 with the
  // Z80 and the YM2610 both counting means the fault is downstream of jt10 --
  // the mixer, AUDIO_S, or the framework -- not in the sound board.
  //
  // Top byte only: 8 bits of a peak is plenty to tell silence from signal,
  // and it leaves one overlay row covering both channels, so "only the left
  // channel works" is visible too.
  // ---------------------------------------------------------------------
  wire [15:0] abs_l = snd_l[15] ? (~snd_l + 16'd1) : snd_l;
  wire [15:0] abs_r = snd_r[15] ? (~snd_r + 16'd1) : snd_r;

  always @(posedge clk) begin
    if (rst) begin
      dbg_peak      <= 16'd0;
      dbg_latch_ack <= 16'd0;
    end else begin
      if (abs_l[15:8] > dbg_peak[15:8]) dbg_peak[15:8] <= abs_l[15:8];
      if (abs_r[15:8] > dbg_peak[7:0])  dbg_peak[7:0]  <= abs_r[15:8];
      if (latch_ack & ~latch_ack_d & (dbg_latch_ack != 16'hFFFF))
        dbg_latch_ack <= dbg_latch_ack + 16'd1;
    end
  end

  // ---------------------------------------------------------------------
  // Register-level instrumentation
  //
  // The write counter says writes are landing at MAME's rate; it does not say
  // they are landing on the right REGISTERS with the right VALUES.  A chip
  // programmed entirely through the address latch and never through the data
  // port would give exactly the reading already seen: a healthy write rate
  // and a silent output.  So shadow jt12's own address latch and count the
  // two writes whose rate MAME can be measured against directly:
  //
  //     bank 1 register 00 = ADPCM-A key on    MAME: 230 in the first 8 s
  //     bank 0 register 28 = FM key on         MAME:  76 in the first 8 s
  //
  // The YM2610 bus is a latch-then-data pair: addr[0]=0 writes the register
  // number for the bank selected by addr[1], addr[0]=1 writes its data.
  // ---------------------------------------------------------------------
  reg [7:0] ymreg0, ymreg1;
  wire      ym_present = ym_act;                   // the clock jt12 samples
  wire      ym_bank    = ym_addr_r[1];
  wire      ym_is_data = ym_addr_r[0];

  always @(posedge clk) begin
    if (rst) begin
      ymreg0       <= 8'd0;
      ymreg1       <= 8'd0;
      dbg_pcma_kon  <= 16'd0;
      dbg_fm_kon    <= 16'd0;
      dbg_fm_koff   <= 16'd0;
      dbg_last_kon  <= 16'd0;
      dbg_last_b1  <= 16'd0;
      dbg_timer_w  <= 16'd0;
    end else if (ym_present) begin
      if (!ym_is_data) begin
        if (ym_bank) ymreg1 <= ym_din_r;
        else         ymreg0 <= ym_din_r;
      end else begin
        if (ym_bank) begin
          dbg_last_b1 <= {ymreg1, ym_din_r};
          // Bank 1 register 00 is the ADPCM-A control byte, and it is NOT all
          // key-on: bit 7 set means key-OFF, and bits 5:0 select channels, so
          // a write with no channel bits is a no-op.  The first version of
          // this counter incremented on every write to that register and
          // reported "9 key-ons" for what may have been nine key-offs.  A
          // counter whose NAME is wrong is worse than no counter.
          if (ymreg1 == 8'h00) begin
            if (!ym_din_r[7] && ym_din_r[5:0] != 6'd0) begin
              if (dbg_pcma_kon != 16'hFFFF) dbg_pcma_kon <= dbg_pcma_kon + 16'd1;
            end
            // ADPCM-A key-OFF used to be counted alongside this.  The symptom
            // it withdrew is closed (STATUS.md), and its overlay row now
            // carries the nibble-advance rate instead.
          end
        end else begin
          // Register 0x28 is slot mask in [7:4] and channel in [2:0].  A
          // write with an empty slot mask is a key-OFF.  This counter used to
          // increment on every 0x28 write and call the total "FM key-on" --
          // the identical flaw Codex found in the ADPCM counter, in the same
          // file, left unfixed because only the ADPCM one was pointed at.
          // MAME writes both: 100 key-on and 120 key-off by t=20 s.
          if (ymreg0 == 8'h28) begin
            dbg_last_kon <= {ym_din_r, 8'd0};
            if (ym_din_r[7:4] != 4'd0) begin
              if (dbg_fm_kon != 16'hFFFF) dbg_fm_kon <= dbg_fm_kon + 16'd1;
            end else begin
              if (dbg_fm_koff != 16'hFFFF) dbg_fm_koff <= dbg_fm_koff + 16'd1;
            end
          end
          if (ymreg0 == 8'h27 && dbg_timer_w != 16'hFFFF)
            dbg_timer_w <= dbg_timer_w + 16'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // Output-stage liveness and a FULL-WIDTH peak.
  //
  // dbg_peak keeps only the top byte of each channel, so it cannot tell
  // "the output stage is dead" from "the output stage runs and everything is
  // at minimum volume".  MAME's own attract peaks at 1350-4059 out of 32768,
  // so a working chip must reach four figures here; an exact 0000 and a 0003
  // mean completely different faults.
  //
  // Sample-to-sample discontinuity, measured at jt10's own sample strobe.
  reg signed [15:0] prev_l;
  reg        [15:0] jump_acc, maxd_acc;
  reg signed [15:0] jump_a, jump_b;
  reg               jump_seen;
  wire signed [16:0] delta   = {snd_l[15], snd_l} - {prev_l[15], prev_l};
  wire        [16:0] adelta  = delta[16] ? (~delta + 17'd1) : delta;
  wire        [15:0] adelta16 = adelta[16] ? 16'hFFFF : adelta[15:0];

  always @(posedge clk) begin
    if (rst) begin
      prev_l      <= 16'sd0;
      jump_acc    <= 16'd0;
      maxd_acc    <= 16'd0;
      jump_a      <= 16'sd0;
      jump_b      <= 16'sd0;
      jump_seen   <= 1'b0;
      dbg_jump_fr <= 16'd0;
      dbg_maxd_fr <= 16'd0;
      dbg_jump_a  <= 16'd0;
      dbg_jump_b  <= 16'd0;
    end else begin
      if (frame) begin
        dbg_jump_fr <= jump_acc;
        dbg_maxd_fr <= maxd_acc;
        dbg_jump_a  <= jump_a;
        dbg_jump_b  <= jump_b;
        jump_acc    <= 16'd0;
        maxd_acc    <= 16'd0;
        jump_seen   <= 1'b0;
      end
      if (ym_snd_sample) begin
        prev_l <= snd_l;
        if (adelta16 > 16'd2048) begin
          if (jump_acc != 16'hFFFF) jump_acc <= jump_acc + 16'd1;
          if (!jump_seen) begin
            jump_seen <= 1'b1;
            jump_a    <= prev_l;   // the sample before
            jump_b    <= snd_l;    // and the one that jumped
          end
        end
        if (adelta16 > maxd_acc) maxd_acc <= adelta16;
      end
    end
  end

  // snd_sample is jt10's own "a new output sample is ready" strobe.  If it
  // never pulses, nothing downstream of the operators is running.
  // ---------------------------------------------------------------------
  reg  io_rd_d;

  always @(posedge clk) begin
    io_rd_d <= io_rd;
    if (rst) begin
      dbg_peak_l <= 16'd0;
      dbg_peak_r <= 16'd0;
      dbg_sample <= 16'd0;
      dbg_io_rd  <= 16'd0;
    end else begin
      if (abs_l > dbg_peak_l) dbg_peak_l <= abs_l;
      if (abs_r > dbg_peak_r) dbg_peak_r <= abs_r;
      if (ym_snd_sample & (dbg_sample != 16'hFFFF))
        dbg_sample <= dbg_sample + 16'd1;
      if (io_rd & ~io_rd_d & (dbg_io_rd != 16'hFFFF))
        dbg_io_rd <= dbg_io_rd + 16'd1;
    end
  end

  // ---------------------------------------------------------------------
  // Is the music being driven at all?
  //
  // This driver is timer-driven: MAME writes bank 0 register 27 -- the timer
  // control and flag-reset register -- 932 times in 8 seconds, i.e. 116 times
  // a second, once per timer service.  Each service is what advances the
  // music and issues the key-ons.
  //
  // The board matches MAME's TOTAL register write rate (527/s against
  // 460-600/s) but keys notes on about fifty times less often.  A driver that
  // writes steadily and rarely plays a note is a driver whose timer service
  // is not running.
  //
  // `dbg_state` already carries INT_n, and it reads 1 in every screenshot --
  // which proves nothing at all.  An interrupt is a brief level, so sampling
  // it at arbitrary instants reads 1 whether interrupts fire constantly or
  // never.  Only edges answer the question, so count them, on both sides:
  //
  //     dbg_irq     jt10 asserted its IRQ            -- the chip's timers run
  //     dbg_intack  the Z80 took an interrupt         -- and the CPU accepts
  //     dbg_timer_w the driver serviced a timer       -- compare 116/s
  //
  // Those three separate "the timers never fire", "they fire and the Z80 has
  // interrupts masked", and "both happen and the music still does not move".
  // ---------------------------------------------------------------------
  // Where does the signal become zero?  jt10's chain is
  //     operators -> fm_snd_left / psg_snd -> jt10_acc -> snd_left
  // so a non-zero fm peak with a zero snd peak puts the fault in the final
  // accumulate/mix, and both zero puts it upstream in envelopes/operators.
  wire [15:0] abs_fm = fm_l[15] ? (~fm_l + 16'd1) : fm_l;

  always @(posedge clk) begin
    if (rst) begin
      dbg_peak_fm  <= 16'd0;
      dbg_peak_psg <= 16'd0;
    end else begin
      if (abs_fm > dbg_peak_fm)                dbg_peak_fm  <= abs_fm;
      if ({6'd0, psg_v} > dbg_peak_psg)        dbg_peak_psg <= {6'd0, psg_v};
    end
  end

  // The single highest-value probe Codex named: if |op_result_hd| never leaves
  // zero, jt10_acc is exonerated and the fault is inside jt12_op -- the
  // operators themselves, not the mixer.  If it DOES leave zero while
  // fm_left stays at zero, the loss is in the accumulate/routing gates.
  // One number splits the remaining search space in half.
  // op_result_hd is zero, so the loss is inside jt12_op.  These two split that:
  //   eg_min stuck at 3FF  -> the envelope never opens; look at the key-on
  //                           path into jt12_eg, not at the operators
  //   keyon_cnt zero       -> key-on never reaches the operator pipeline at
  //                           all, and the envelope question does not arise
  // MIN-hold, not max: an envelope that opens makes eg_V SMALLER.
  wire [13:0] abs_op = op_hd[13] ? (~op_hd + 14'd1) : op_hd;
  reg         aon_sr0_d;

  always @(posedge clk) begin
    aon_sr0_d <= aon_sr0;
    if (rst) begin
      dbg_peak_op   <= 16'd0;
      dbg_aon_cnt   <= 16'd0;
      dbg_eg_min    <= 16'h03FF;      // start at "fully attenuated"
      dbg_keyon_cnt <= 16'd0;
    end else begin
      if ({6'd0, eg_v} < dbg_eg_min) dbg_eg_min <= {6'd0, eg_v};
      if (keyon_i & (dbg_keyon_cnt != 16'hFFFF))
        dbg_keyon_cnt <= dbg_keyon_cnt + 16'd1;
      if ({2'd0, abs_op} > dbg_peak_op) dbg_peak_op <= {2'd0, abs_op};
      if (aon_sr0 & ~aon_sr0_d & (dbg_aon_cnt != 16'hFFFF))
        dbg_aon_cnt <= dbg_aon_cnt + 16'd1;
    end
  end

  reg irq_n_d, intack_d;
  wire intack = ~m1_n & ~iorq_n;          // M1 + IORQ = interrupt acknowledge

  always @(posedge clk) begin
    irq_n_d  <= ym_irq_n;
    intack_d <= intack;
    if (rst) begin
      dbg_irq    <= 16'd0;
      dbg_intack <= 16'd0;
    end else begin
      if (irq_n_d & ~ym_irq_n & (dbg_irq != 16'hFFFF))
        dbg_irq <= dbg_irq + 16'd1;
      if (intack & ~intack_d & (dbg_intack != 16'hFFFF))
        dbg_intack <= dbg_intack + 16'd1;
    end
  end

  // ---------------------------------------------------------------------
  // Sample fetches PER FRAME, not cumulative.
  //
  // The cumulative pair saturates: pcm_late reads FFFF and pcma_fetch reads
  // FFFF, and from those two numbers 0.03 % of fetches being late and ALL of
  // them being late are indistinguishable.  ADPCM-A presents a new address
  // 666 000 times a second, so a 16-bit total is exhausted in a tenth of a
  // second either way -- exactly the failure docs/LESSONS_LEARNED.md L9 and
  // L12 describe, rebuilt here by hand and then used to claim a bandwidth
  // problem that has never actually been measured.
  //
  // Windowed to one frame and latched at the boundary, the pair reads as a
  // rate: late over total, both for the same 1/61 s.  Zero is the answer
  // that matters; a handful is inaudible; thousands is a real shortage.
  // ---------------------------------------------------------------------
  reg [15:0] late_acc, fetch_acc;
  always @(posedge clk) begin
    if (rst) begin
      late_acc     <= 16'd0;
      fetch_acc    <= 16'd0;
      dbg_late_fr  <= 16'd0;
      dbg_fetch_fr <= 16'd0;
    end else if (frame) begin
      dbg_late_fr  <= late_acc;
      dbg_fetch_fr <= fetch_acc;
      late_acc     <= 16'd0;
      fetch_acc    <= 16'd0;
    end else begin
      // "Late" = the chip moved to a different word while this read was
      // still in flight, so the byte it sampled was the wrong one.  This
      // must stay the SAME condition the fetch FSM uses, or it measures the
      // instrument's assumption instead of the hardware -- the exact failure
      // in docs/LESSONS_LEARNED.md L14, which this counter has already made
      // once when the fetch policy changed underneath it.
      if (adpcma_req && pcma_wword != pcma_cur[19:1] && !pcma_late
          && late_acc != 16'hFFFF)
        late_acc <= late_acc + 16'd1;
      if (adpcma_req && adpcma_ack && fetch_acc != 16'hFFFF)
        fetch_acc <= fetch_acc + 16'd1;
    end
  end

  assign dbg_state = {halt_n, latch_pending, nmi_n, int_n, 2'b00, bank};

endmodule

`default_nettype wire
