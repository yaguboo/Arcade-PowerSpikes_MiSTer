//============================================================================
//  Power Spikes -- hardware debug overlay
//  *** TEMPORARY.  REMOVE BEFORE RELEASE. ***
//
//  On a DE10-Nano there is no debugger and no console.  Without this, a black
//  screen means "something is wrong" and nothing more.  The core draws its own
//  state as coloured blocks so one screenshot answers "how far did it get".
//
//  ENCODING -- identical to NA-1/NA-2's na2_dbg so the same decoder works:
//      16 cells per row, each cell one bit, BIT 15 LEFTMOST.
//      Rows are 4 px tall with the 4th line left as a dark gutter, and a
//      1 px dark gutter between cells so they stay countable in a scaled
//      screenshot.  Green = 1, dark red = 0.
//  tools/read_overlay.py decodes a PNG back into these numbers.
//
//  Row 0   16 boot landmarks, latched.  This is the row to read first.
//            15 halted          14 read >= 0x010000   13 read >= 0x001000
//            12 gfxbank written 11 sound latch write  10 GGA write
//             9 raster write     8 spriteram write     7 sprlut write
//             6 palette write    5 VRAM write          4 work RAM read
//             3 work RAM write   2 fetched 0x000400    1 read 0x000004
//             0 read 0x000000
//  Row 1   completed CPU reads          Row 2   completed CPU writes
//  Row 3   work RAM writes              Row 4   VRAM writes
//  Row 5   palette writes               Row 6   sprite lookup RAM writes
//  Row 7   I/O writes                   Row 8   GGA writes
//  Row 9   unmapped accesses            -- expected to stay ZERO
//  Row 10  first word read at 0x000000  -- must be 0x0011 (SSP high half)
//  Row 11  first word read at 0x000004  -- must be 0x0000 (PC high half)
//  Row 12  first word read at 0x000006  -- must be 0x0400 (PC low half)
//  Row 13  highest ROM WORD address fetched, bits 15:0.  Bit 16 does not
//          fit; row 0 flag 14 covers 'got past 0x010000' instead.
//  Row 14  arbiter CPU stall clocks, saturating
//  Row 15  { halted_n, dl_active, pll_alive, probe_done, 4'd0, ioctl_index }
//          probe_done says the ROM probe actually ran.  Without it a
//          reading of 0000 in rows 26-27 means either 'gfx2 is zeros' or
//          'the probe never got the bus', and those need different fixes.
//          pll_alive toggles while the PLL's third output runs; it is the
//          load that stops Quartus deleting that output.  See D7.
//  Row 16  { gfxbank[7:0], sound_latch[7:0] }
//  Row 17  vblank interrupts raised
//  Row 18  { GGA reg 0 , GGA reg 8 }  -- docs/HARDWARE.md section 3 says the
//          game writes 0x57 and 0x77.  Reading them back off real hardware
//          turns a MAME comment into a measurement, and is the first step
//          towards decoding the GGA's timing registers.
//
//  2026-10-06 -- PAGE 1 (rows 18-35) IS NOW THE GGA / IRQ PAGE.  The rows
//  below were reassigned; the descriptions further down for 21, 22, 26-30
//  and 32-35 are history.  Each one answered its question (O19, the sound
//  bring-up, the boot probes) and one screenshot of this page now carries
//  the timing registers, the timing they produced and the IRQ evidence.
//  DEBUG_LOG O22.
//      18  {reg 00, reg 08}                       (unchanged)
//      28  {reg 01, reg 09}    29 {reg 02, reg 0a}
//      30  {reg 03, reg 0b}    32 {reg 04, reg 0c}
//      26  {regs drive H, regs drive V, geometry mismatch, 0000, lines/frame}
//      27  clk_sys cycles per frame >> 4          (40 MHz: 61.33 Hz = 40762)
//      34  {0000000, pixels per line}
//      35  {hsync on [8:2], hsync off [8:2], 00}  (pixel = field * 4)
//      33  {vsync on [8:1], vsync off [8:1]}      (line  = field * 2)
//      21  frames with NO interrupt acknowledge   (boot + paused frames)
//      22  {frames whose vblank ended with the IRQ still pending,
//           frames with two or more acknowledges}
//  Rows 26-35 are counted by ps_crtc off its own outputs, not copied from
//  the registers: two readings of one fact.
//
//  Row 19  sprite tile-rows blitted, CUMULATIVE
//  Row 26  gfx2 word 0x06003A read back out of SDRAM
//  Row 27  gfx2 word 0x06003B
//          Expected FFFF then FF3F.  FF3F then FFFF means the .mra pairs
//          g7j and g7l the wrong way round.  Anything else means the
//          gfx2 region did not arrive at all.
//  Row 25  sprites that were enabled AND covered the line, CUMULATIVE.
//          If row 25 counts and row 19 does not, the sprite is being
//          selected but its tile fetch or blit is failing.
//  Row 23  LIVE STALL: address of the bus cycle the CPU is stuck on, high
//          half {1'b0, addr[23:16]}, latched once after 4096 clocks with a
//          strobe up and no acknowledge.
//  Row 24  the same address, low half addr[15:0].
//          Bit 15 of row 23 is the "a stall was latched" flag.
//
//          These exist because the SATURATING cpu-wait counter in the
//          arbiter cannot tell "waited a lot, over the whole run" from
//          "is wedged right now", and it reads 0xFFFF either way.  That
//          ambiguity sent one investigation down the wrong path.  This
//          names the exact address instead.
//  Row 21  download words ISSUED to the memory bus (dl_req rising edges)
//  Row 22  download words ACKNOWLEDGED (dl_ack pulses)
//          Rows 21 and 22 must end EQUAL.  If 22 lags 21 and stops, the
//          memory bus stopped acknowledging, and with ioctl_wait enabled
//          that is a hang: ioctl_wait stays high and the HPS spins forever
//          waiting for io_ack.  Two readings of one fact -- issued vs taken.
//  Row 20  sprite lines that RAN OUT OF TIME, cumulative.  Expected to stay
//          zero; a rising count means the SDRAM budget is short and sprites
//          are being dropped (docs/DEBUG_LOG.md O2).
//  Row 28  Z80 memory cycles, CUMULATIVE.  Nonzero means the sound CPU is
//          fetching at all; if this counts and row 29 does not, the Z80 is
//          running but never reaches the YM2610, which points at the port
//          map rather than at the chip.
//  Row 29  YM2610 register writes, CUMULATIVE
//  Row 30  ADPCM-A sample bytes fetched from SDRAM, CUMULATIVE
//  Row 32  sound ROM word 0 as it landed in BRAM.  Must read ED56 -- that is
//          `IM 1`, the first instruction of ROM "19".  0000 means the
//          download snoop missed the region and the Z80 is executing NOPs,
//          which counts on row 28 exactly like a healthy Z80 would.
//  Row 33  sound ROM words written, saturating.  FFFF means the whole 64 K
//          words arrived; anything less names a truncated load.
//  Row 34  { peak |left| , peak |right| }, top byte of each, MAX-HELD.
//          0000 while rows 28-30 count means jt10 is running and the fault
//          is downstream of it.  This is how "is there sound" gets answered
//          from a screenshot by someone who is not near the board.
//  Row 36  full 16-bit max-held peak |snd_l|          MAME reaches 1350-4059
//  Row 37  full 16-bit max-held peak |snd_r|          in its own attract, so
//          a working chip must show four figures here.  Row 34's top-byte
//          version cannot tell an exact 0000 from a 0003, and those are
//          different faults.
//  Row 38  ADPCM-A key-on writes (bank 1 register 00)  MAME: 230 in 8 s
//  Row 39  FM key-on writes      (bank 0 register 28)  MAME:  76 in 8 s
//          These shadow jt12's own address latch, so they count writes that
//          reached a REGISTER, not writes that reached the chip.  A chip
//          programmed only through its address latch would show a healthy
//          write rate on row 29 and zero on both of these.
//  Row 40  jt10 snd_sample pulses, saturating.  Zero means nothing
//          downstream of the FM operators is running at all.
//  Row 41  Z80 I/O READ cycles, saturating.  MAME does 10-18 k/s of these
//          against 500 writes, so a board that does far fewer is not
//          polling the chip the way the real driver does.
//  Row 42  last {register, data} written to bank 1 -- a spot check that the
//          values arriving are the values MAME writes.
//  Row 43  YM2610 IRQ assertions (falling edges of jt10's irq_n)
//  Row 44  Z80 interrupt acknowledge cycles (M1 + IORQ together)
//  Row 45  writes to bank 0 register 27, the timer control/flag-reset
//          register.  MAME writes it 932 times in 8 s = 116/s, once per
//          timer service, and each service is what advances the music.
//          Rows 43-45 separate 'the timers never fire' from 'they fire
//          and the Z80 has interrupts masked' from 'both happen'.
//          dbg_state's INT_n bit cannot: an interrupt is a brief level,
//          so sampling it in a screenshot reads 1 either way.
//  Row 35  commands the Z80 acknowledged (port 14 writes), saturating.
//          Compare against row 0 flag 11 and row 16: if the 68000 is sending
//          and this stays 0, the NMI path is the suspect, not the YM2610.
//  Row 31  { snd_state[7:0], pcm_late[7:0] }
//          snd_state = {z80 HALT_n, latch pending, NMI_n, INT_n, 2'd0, bank}
//          pcm_late counts sample fetches the memory bus did not finish
//          before the YM2610 moved on.  Expected to stay ZERO -- it is the
//          audio counterpart of row 20, and exists for the same reason:
//          so "the sound is wrong" can be split from "the bus is short".
//
//  Row 60  actual jt12_mmr REG_KON data decodes
//  Row 61  up_keyon_reg rising edges (request captured on clk_en)
//  Row 62  key_upnow rising edges (captured channel reaches S4)
//  Row 63  csr_out rising edges (operator key state left the key CSR)
//
//  Rows 10-12 exist because they cross-check each other AND the ROM builder:
//  tools/build_rom.py asserts the same three values before it writes the
//  image.  If the overlay disagrees with the builder, the fault is between
//  the .mra and SDRAM, not in the CPU.  Root CLAUDE.md 6.5: verify the
//  instrument, and prefer two readings of the same fact.
//============================================================================
`default_nettype none

module ps_dbg #(
    parameter int H_VISIBLE = 352,
    parameter int V_START   = 8
) (
    input  wire        clk,
    input  wire        ce_pix,
    input  wire        enable,
    // 54 rows at 4 px would cover 216 of 240 lines and leave nothing of the
    // game to match a MAME frame against.  Draw 18 at a time instead.
    input  wire [1:0]  page,
    input  wire        rst_i,

    input  wire [8:0]  hcnt,
    input  wire [8:0]  vcnt,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,

    // --- what to show ------------------------------------------------------
    input  wire [23:1] cpu_addr,
    input  wire        cpu_rd,
    input  wire        cpu_wr,
    input  wire        cpu_ack,
    input  wire [15:0] cpu_din,
    input  wire        halted_n,
    input  wire [15:0] cpu_stall,
    input  wire [7:0]  gfxbank,
    input  wire [7:0]  sound_latch,
    input  wire [15:0] gga,
    input  wire [63:0] gga_x,         // {01,09} {02,0a} {03,0b} {04,0c}
    input  wire [79:0] crtc,          // ps_crtc measurement, 5 words
    input  wire [31:0] iack_x,        // {no-IACK frames, {pending, >=2}}
    input  wire [15:0] spr_drawn,
    input  wire [15:0] spr_hit,
    input  wire [15:0] rom_w0,
    input  wire [15:0] rom_w1,
    input  wire        probe_done,
    input  wire [15:0] spr_overrun,
    input  wire        vblank_irq,
    input  wire        dl_active,
    input  wire        pll_alive,
    input  wire        dl_req,
    input  wire        dl_ack,
    input  wire [7:0]  ioctl_index,
    input  wire [15:0] pcm_late,
    input  wire [7:0]  snd_state,
    input  wire [15:0] snd_peak_l,
    input  wire [15:0] snd_peak_r,
    input  wire [15:0] snd_pcma_kon,
    input  wire [15:0] snd_fm_kon,
    input  wire [15:0] snd_sample,
    input  wire [15:0] snd_io_rd,
    input  wire [15:0] snd_last_b1,
    input  wire [15:0] snd_irq,
    input  wire [15:0] snd_intack,
    input  wire [15:0] snd_timer_w,
    input  wire [15:0] snd_peak_fm,
    input  wire [15:0] snd_peak_psg,
    input  wire [15:0] raster_msg,
    input  wire [15:0] raster_court,
    input  wire [15:0] o6_map,
    input  wire [15:0] o6_tile,
    input  wire [15:0] o6_pos,
    input  wire [15:0] o6_first,
    input  wire [15:0] o6_sx,
    input  wire [15:0] o6_blitx,
    input  wire [15:0] snd_roe_a,
    input  wire [15:0] burst_first,
    input  wire [15:0] tm_late,
    input  wire [15:0] pcma_late_fr,
    input  wire [15:0] pcma_fetch_fr,
    input  wire [15:0] snd_peak_op,
    input  wire [15:0] snd_aon_cnt,
    input  wire [15:0] snd_eg_min,
    input  wire [15:0] snd_keyon_cnt,
    input  wire [15:0] snd_mmr_kon,
    input  wire [15:0] snd_kon_latch,
    input  wire [15:0] snd_kon_match,
    input  wire [15:0] snd_csr_slots,
    input  wire [15:0] snd_fm_koff,
    input  wire [15:0] snd_last_kon,
    input  wire [15:0] o6_row0,
    input  wire [15:0] o6_row1,
    input  wire [15:0] o6_row2,
    input  wire [15:0] o6_row3,
    input  wire [15:0] snd_jump_fr,
    input  wire [15:0] snd_maxd_fr,
    input  wire [15:0] sprwr_disp,
    input  wire [15:0] vramwr_disp
);

  localparam int CELL_W = H_VISIBLE / 16;   // 22 px
  localparam int ROW_H  = 4;
  localparam int N_ROWS = 72;
  localparam int PAGE_ROWS = 18;

  // ---------------------------------------------------------------------
  // Event detection.  A bus cycle counts once, when it is acknowledged --
  // cpu_rd/cpu_wr are HELD until ack, so counting the strobe would count
  // one cycle many times and every number would be meaningless.
  // ---------------------------------------------------------------------
  wire done  = cpu_ack & (cpu_rd | cpu_wr);
  wire rdone = cpu_ack & cpu_rd;
  wire wdone = cpu_ack & cpu_wr;

  wire sel_rom    = (cpu_addr[23:18] == 6'b000000);
  wire sel_work   = (cpu_addr[23:16] == 8'h10);
  wire sel_sprlut = (cpu_addr[23:14] == 10'b0010_0000_00);
  wire sel_vram   = (cpu_addr[23:12] == 12'hFF8);
  wire sel_spr    = (cpu_addr[23:12] == 12'hFFC) && (cpu_addr[11:10] == 0);
  wire sel_raster = (cpu_addr[23:12] == 12'hFFD);
  wire sel_pal    = (cpu_addr[23:12] == 12'hFFE);
  wire sel_io     = (cpu_addr[23:12] == 12'hFFF) && (cpu_addr[11:4] == 0);
  wire sel_gga    = (cpu_addr[23:12] == 12'hFFF)
                    && (cpu_addr[11:2] == 10'b0100_0000_00);
  wire mapped     = sel_rom | sel_work | sel_sprlut | sel_vram | sel_spr
                  | sel_raster | sel_pal | sel_io | sel_gga;

  reg [15:0] n_dl_req, n_dl_ack;
  reg [12:0] stall_cnt;
  reg [23:1] stall_addr;
  reg        stall_seen;
  reg        dl_req_d;
  reg [15:0] n_read, n_write, n_work_w, n_vram_w, n_pal_w, n_sprlut_w;
  reg [15:0] n_io_w, n_gga_w, n_unmapped, n_vbl;
  reg [15:0] first_0000, first_0004, first_0006;
  reg        got_0000, got_0004, got_0006;
  reg [16:0] max_word;   // highest ROM WORD address fetched
  reg [15:0] flags;
  reg        vbl_d;

  // EVERY COUNTER AND FLAG HERE NEEDS A RESET.
  //
  // They had none.  The .qsf sets ALLOW_POWER_UP_DONT_CARE, so an
  // uninitialised register may come up as 1, and row 0 duly read 0x7FFF --
  // every boot landmark set, including "sprite lookup RAM written" while
  // row 6 counted ZERO such writes.  Those two come from the same condition
  // in this file, so the pair contradicted each other and that is what
  // exposed it.  An instrument that reports success at power-up is worse
  // than no instrument.
  always @(posedge clk) begin
    if (rst_i) begin
      flags      <= 16'd0;
      n_read     <= 16'd0;  n_write    <= 16'd0;
      n_work_w   <= 16'd0;  n_vram_w   <= 16'd0;
      n_pal_w    <= 16'd0;  n_sprlut_w <= 16'd0;
      n_io_w     <= 16'd0;  n_gga_w    <= 16'd0;
      n_unmapped <= 16'd0;  n_vbl      <= 16'd0;
      n_dl_req   <= 16'd0;  n_dl_ack   <= 16'd0;
      stall_cnt  <= 13'd0;  stall_addr <= 23'd0;  stall_seen <= 1'b0;
      first_0000 <= 16'd0;  first_0004 <= 16'd0;  first_0006 <= 16'd0;
      got_0000   <= 1'b0;   got_0004   <= 1'b0;   got_0006   <= 1'b0;
      max_word   <= 17'd0;
      vbl_d      <= 1'b0;   dl_req_d   <= 1'b0;
    end else begin
    vbl_d <= vblank_irq;
    if (vblank_irq & ~vbl_d) n_vbl <= n_vbl + 16'd1;

    if (done && !mapped) n_unmapped <= n_unmapped + 16'd1;

    if (rdone) begin
      n_read <= n_read + 16'd1;
      if (sel_rom) begin
        if (cpu_addr[17:1] > max_word) max_word <= cpu_addr[17:1];
        if (cpu_addr[23:1] == 23'h000000 && !got_0000) begin
          first_0000 <= cpu_din; got_0000 <= 1'b1; flags[0] <= 1'b1;
        end
        if (cpu_addr[23:1] == 23'h000002 && !got_0004) begin
          first_0004 <= cpu_din; got_0004 <= 1'b1; flags[1] <= 1'b1;
        end
        if (cpu_addr[23:1] == 23'h000003 && !got_0006) begin
          first_0006 <= cpu_din; got_0006 <= 1'b1;
        end
        if (cpu_addr[23:1] == 23'h000200) flags[2]  <= 1'b1;  // 0x000400
        if (cpu_addr[23:1] >= 23'h000800) flags[13] <= 1'b1;  // 0x001000
        if (cpu_addr[23:1] >= 23'h008000) flags[14] <= 1'b1;  // 0x010000
      end
      if (sel_work) flags[4] <= 1'b1;
    end

    if (wdone) begin
      n_write <= n_write + 16'd1;
      if (sel_work)   begin n_work_w   <= n_work_w   + 16'd1; flags[3] <= 1'b1; end
      if (sel_vram)   begin n_vram_w   <= n_vram_w   + 16'd1; flags[5] <= 1'b1; end
      if (sel_pal)    begin n_pal_w    <= n_pal_w    + 16'd1; flags[6] <= 1'b1; end
      if (sel_sprlut) begin n_sprlut_w <= n_sprlut_w + 16'd1; flags[7] <= 1'b1; end
      if (sel_spr)    flags[8] <= 1'b1;
      if (sel_raster) flags[9] <= 1'b1;
      if (sel_gga)    begin n_gga_w <= n_gga_w + 16'd1; flags[10] <= 1'b1; end
      if (sel_io) begin
        n_io_w <= n_io_w + 16'd1;
        if (cpu_addr[3:1] == 3'd3) flags[11] <= 1'b1;   // sound latch
        if (cpu_addr[3:1] == 3'd1) flags[12] <= 1'b1;   // gfxbank
      end
    end

    // Download bus accounting.  dl_req is HELD until dl_ack, so count its
    // rising edge, not its level.
    dl_req_d <= dl_req;
    if (dl_req && !dl_req_d) n_dl_req <= n_dl_req + 16'd1;
    if (dl_ack)              n_dl_ack <= n_dl_ack + 16'd1;

    // LIVE stall detector: a strobe held with no ack for 4096 clocks is a
    // wedge, not slowness.  Latch the first one and stop, so the reported
    // address is the cycle that actually died.
    if (!(cpu_rd | cpu_wr) || cpu_ack) begin
      stall_cnt <= 13'd0;
    end else if (!stall_cnt[12]) begin
      stall_cnt <= stall_cnt + 13'd1;
      if (stall_cnt == 13'd4094 && !stall_seen) begin
        stall_addr <= cpu_addr;
        stall_seen <= 1'b1;
      end
    end

    flags[15] <= ~halted_n;
    end
  end

  // ---------------------------------------------------------------------
  // Draw
  // ---------------------------------------------------------------------
  wire [8:0] y    = vcnt - V_START[8:0];
  // page * 18 = page*16 + page*2.  Declared here, before use: `default_nettype
  // none plus a forward reference is the sort of thing one tool accepts and
  // the next rejects.
  // SEVEN bits, not six.  With 71 rows the case labels reach 70, and `6'd64`
  // truncates to 0 -- rows 64-70 silently drew on top of rows 0-6 and the
  // values they carried were invisible.  Quartus said so ("truncated literal
  // to match 6 bits") and the warning policy is why it was read.
  wire [6:0] row_in_page = {1'b0, y[7:2]};
  wire [6:0] page_base   = {1'b0, page, 4'd0} + {3'd0, page, 2'b00} - {4'd0, page, 1'b0};
  wire       in_v = enable && (vcnt >= V_START) && (y < PAGE_ROWS * ROW_H)
                    && ((page_base + row_in_page) < 7'd72);
  wire       in_h = (hcnt < H_VISIBLE);
  wire       active = in_v && in_h;

  // NOTE: `/` and `%` by 22 are a real divider and a real modulo in logic --
  // CELL_W is H_VISIBLE/16 and 352/16 = 22, which is not a power of two.
  // Inherited from NA-1/NA-2's overlay, which ships with the same construct
  // (CELL_W = 19 there).  It is affordable only because this is debug logic
  // that is deleted before release; do not copy the pattern into the board.
  // If the fitter ever struggles, replacing this with a counter reset at
  // each cell boundary removes both operators.
  // 34 rows needs 6 bits of row index; y[6:2] silently wrapped rows 32-33 on
  // top of rows 0-1, which is the sort of overlay bug that gets read as an
  // RTL bug.
  wire [6:0] row = page_base + row_in_page;
  wire [8:0] col9 = hcnt / CELL_W[8:0];
  wire [3:0] cell_i = (col9 > 9'd15) ? 4'd15 : col9[3:0];
  wire [3:0] bit_i  = 4'd15 - cell_i;

  wire gutter = ((hcnt % CELL_W[8:0]) == 0) || (y[1:0] == 2'd3);

  // Named wires: some tools reject `expr[bit_i]` on a concatenation where
  // others accept it, and a file that will not compile takes the whole build
  // down.  NA-1/NA-2 hit exactly this.
  wire [15:0] r15 = {halted_n, dl_active, pll_alive, probe_done, 4'd0, ioctl_index};
  wire [15:0] r16 = {gfxbank, sound_latch};
  wire [15:0] r13 = max_word[15:0];
  wire [15:0] r23 = {stall_seen, 7'd0, stall_addr[23:16]};
  wire [15:0] r24 = {stall_addr[15:1], 1'b0};
  wire [15:0] r31 = {snd_state, pcm_late[7:0]};
  // Page 1, reassigned 2026-10-06 -- see the header.
  wire [15:0] r21 = iack_x[31:16];
  wire [15:0] r22 = iack_x[15:0];
  wire [15:0] r26 = crtc[79:64];
  wire [15:0] r27 = crtc[63:48];
  wire [15:0] r34 = crtc[47:32];
  wire [15:0] r35 = crtc[31:16];
  wire [15:0] r33 = crtc[15:0];
  wire [15:0] r28 = gga_x[63:48];
  wire [15:0] r29 = gga_x[47:32];
  wire [15:0] r30 = gga_x[31:16];
  wire [15:0] r32 = gga_x[15:0];

  reg cur;
  always @(*) begin
    case (row)
      7'd0:  cur = flags[bit_i];
      7'd1:  cur = n_read[bit_i];
      7'd2:  cur = n_write[bit_i];
      7'd3:  cur = n_work_w[bit_i];
      7'd4:  cur = n_vram_w[bit_i];
      7'd5:  cur = n_pal_w[bit_i];
      7'd6:  cur = n_sprlut_w[bit_i];
      7'd7:  cur = n_io_w[bit_i];
      7'd8:  cur = n_gga_w[bit_i];
      7'd9:  cur = n_unmapped[bit_i];
      7'd10: cur = first_0000[bit_i];
      7'd11: cur = first_0004[bit_i];
      7'd12: cur = first_0006[bit_i];
      7'd13: cur = r13[bit_i];
      7'd14: cur = cpu_stall[bit_i];
      7'd15: cur = r15[bit_i];
      7'd16: cur = r16[bit_i];
      7'd17: cur = n_vbl[bit_i];
      7'd18: cur = gga[bit_i];
      7'd19: cur = spr_drawn[bit_i];
      7'd20: cur = spr_overrun[bit_i];
      // Rows 21 and 22 counted ROM-download requests and acks, which
      // answered a boot-time question this core stopped having once it
      // booted.  They carry the sprite overrun probe now, and they sit on
      // the same page as the overrun itself so ONE screenshot answers it:
      // row 20 says a line failed, 21 says how much of that line was spent
      // outside S_ROM, 22 says how much work the line actually had.
      7'd21: cur = r21[bit_i];
      7'd22: cur = r22[bit_i];
      7'd23: cur = r23[bit_i];
      7'd24: cur = r24[bit_i];
      7'd25: cur = spr_hit[bit_i];
      // Rows 26 and 27 read back the first two program-ROM words, which
      // answered a boot question this core stopped having once it booted.
      // They carry the band-gated overrun snapshot now.
      7'd26: cur = r26[bit_i];
      7'd27: cur = r27[bit_i];
      7'd28: cur = r28[bit_i];
      7'd29: cur = r29[bit_i];
      7'd30: cur = r30[bit_i];
      7'd31: cur = r31[bit_i];
      7'd32: cur = r32[bit_i];
      7'd33: cur = r33[bit_i];
      7'd34: cur = r34[bit_i];
      7'd35: cur = r35[bit_i];
      7'd36: cur = snd_peak_l[bit_i];
      7'd37: cur = snd_peak_r[bit_i];
      7'd38: cur = snd_pcma_kon[bit_i];
      7'd39: cur = snd_fm_kon[bit_i];
      7'd40: cur = snd_sample[bit_i];
      7'd41: cur = snd_io_rd[bit_i];
      7'd42: cur = snd_last_b1[bit_i];
      7'd43: cur = snd_irq[bit_i];
      7'd44: cur = snd_intack[bit_i];
      7'd45: cur = snd_timer_w[bit_i];
      7'd46: cur = snd_peak_fm[bit_i];
      7'd47: cur = snd_peak_psg[bit_i];
      // Rows 48/49 carried the raster readback, which answered its
      // question -- the message row and the court share one scroll value,
      // so rowscroll is not what moves that row.  They now carry sx and
      // blit_x so that ox, sx and blit_x are all on ONE page and one
      // screenshot carries the whole chain.  docs/DEBUG_LOG.md O6.
      7'd48: cur = o6_sx[bit_i];
      7'd49: cur = o6_blitx[bit_i];
      7'd50: cur = o6_map[bit_i];
      7'd51: cur = o6_tile[bit_i];
      7'd52: cur = o6_pos[bit_i];
      7'd53: cur = o6_first[bit_i];
      7'd54: cur = snd_roe_a[bit_i];
      7'd55: cur = snd_peak_op[bit_i];
      7'd56: cur = snd_aon_cnt[bit_i];
      7'd57: cur = sprwr_disp[bit_i];   // was a duplicate of row 48
      7'd58: cur = snd_eg_min[bit_i];
      7'd59: cur = snd_keyon_cnt[bit_i];
      7'd60: cur = snd_mmr_kon[bit_i];
      7'd61: cur = snd_kon_latch[bit_i];
      7'd62: cur = snd_kon_match[bit_i];
      7'd63: cur = snd_csr_slots[bit_i];
      7'd64: cur = snd_fm_koff[bit_i];
      7'd65: cur = vramwr_disp[bit_i];  // was snd_last_kon, question closed
      7'd66: cur = pcma_late_fr[bit_i];  // was the jump shape; it did its job
      7'd67: cur = pcma_fetch_fr[bit_i]; // per FRAME; row 30 is cumulative
      7'd68: cur = burst_first[bit_i];  // was o6_row2; O6 is closed
      7'd69: cur = tm_late[bit_i];   // was spr_words; that question is answered   // was o6_row3; O6 is closed
      7'd70: cur = snd_jump_fr[bit_i];  // was ADPCM-A late; that is characterised
      7'd71: cur = snd_maxd_fr[bit_i];  // was ADPCM-A fetches
      default: cur = 1'b0;
    endcase
  end

  wire [23:0] cell_rgb = gutter ? 24'h101010
                       : cur    ? 24'h30E030
                                : 24'h401010;

  assign rgb_out = active ? cell_rgb : rgb_in;

endmodule

`default_nettype wire
