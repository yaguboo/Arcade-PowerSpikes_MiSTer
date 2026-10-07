//============================================================================
//  Power Spikes -- main CPU board: 68000, address decode, board RAM, I/O
//
//  Every address here comes from docs/HARDWARE.md section 4, which is taken
//  from MAME's pspikes_map and cross-checked against FBNeo.  The overlaps are
//  real hardware, not typos:
//
//      fff000 reads IN0   and its ODD byte writes the palette bank
//      fff002 reads IN1   and its ODD byte writes the gfx bank
//      fff004 reads DSW   and the WORD write is scroll Y
//      fff006 -- odd byte reads sound-latch-pending and writes the latch
//
//  Byte lanes matter.  A decode that ignores UDS/LDS will write the palette
//  bank every time the game polls the inputs.
//
//  Program ROM is NOT here.  It reaches the board over the neutral rom_*
//  port so that MiSTer can back it with SDRAM and Pocket with its own
//  memory, per root CLAUDE.md section 4.  Board RAM is on the board,
//  because the board owns its own arbitration.
//============================================================================
`default_nettype none

module ps_main (
    input  wire        clk,          // 40.000 MHz system clock
    input  wire        rst,
    input  wire        ce_en,        // global enable (low during download)
    input  wire        cpu_rst,      // hold the CPU (download)

    // --- program ROM, neutral interface ------------------------------------
    output wire [17:1] rom_addr,     // 256 K region, word address
    input  wire [15:0] rom_data,
    output wire        rom_rd,
    input  wire        rom_ack,

    // --- video hardware, CPU side ------------------------------------------
    // Dual-port: the video side of each of these lives in ps_video on the
    // pixel clock.  The real board arbitrates through the GGA; here the two
    // ports are genuinely independent, which is why they are true dual-port
    // RAM rather than a shared bus with a mux.
    output wire [11:1] vram_addr,
    output wire [15:0] vram_din,
    input  wire [15:0] vram_dout,
    output wire [1:0]  vram_we,

    output wire [9:1]  spr_addr,
    output wire [15:0] spr_din,
    output wire [1:0]  spr_we,

    output wire [11:1] raster_addr,
    output wire [15:0] raster_din,
    input  wire [15:0] raster_dout,
    output wire [1:0]  raster_we,

    output wire [11:1] pal_addr,
    output wire [15:0] pal_din,
    input  wire [15:0] pal_dout,
    output wire [1:0]  pal_we,

    output wire [13:1] sprlut_addr,
    output wire [15:0] sprlut_din,
    input  wire [15:0] sprlut_dout,
    output wire [1:0]  sprlut_we,

    // --- video control registers -------------------------------------------
    output reg  [7:0]  gfxbank,      // fff003: [7:4] bank0, [3:0] bank1
    output reg  [1:0]  spr_palbank,  // fff001 [1:0]
    output reg  [2:0]  char_palbank, // fff001 [4:2]
    output reg         flip_screen,  // fff001 [7]
    output reg  [8:0]  scrolly,      // fff004 word write

    // C7-01 GGA.  ps_crtc derives the video timing from registers 00-03 and
    // 08-0b (docs/HARDWARE.md section 3 -- a decode from register traffic,
    // not a datasheet).  gga_written says which registers the game has
    // written since reset, so the CRTC runs on its defaults until it has.
    output reg  [7:0]  gga_regs [0:15],
    output reg  [15:0] gga_written,

    // --- sound -------------------------------------------------------------
    output reg  [7:0]  sound_latch,
    output reg         sound_latch_we,
    input  wire        sound_pending,

    // --- inputs ------------------------------------------------------------
    input  wire [15:0] in0,
    input  wire [15:0] in1,
    input  wire [15:0] dsw,

    // --- interrupt ---------------------------------------------------------
    input  wire        vblank_irq,   // level, cleared by ack
    output wire        iack_stb,     // 68000 interrupt-acknowledge cycle

    // --- observability -----------------------------------------------------
    output wire [23:1] dbg_addr,
    output wire        dbg_rd,
    output wire        dbg_wr,
    output wire [15:0] dbg_dout,
    output wire [15:0] dbg_din,     // what the CPU READ, not what it wrote
    output wire        dbg_ack,
    output wire [31:0] dbg_d7,
    output wire        dbg_halted_n
);

  // ---------------------------------------------------------------------
  // CPU
  // ---------------------------------------------------------------------
  wire [23:1] a;
  wire [15:0] cpu_dout;
  reg  [15:0] cpu_din;
  wire        cpu_rd, cpu_wr, uds_n, lds_n;
  reg         cpu_ack;
  wire [2:0]  fc;

  // IRQ1 on vblank.  irq1_line_hold in MAME: asserted at vblank, released
  // when the CPU acknowledges.
  wire [2:0] ipl_n = vblank_irq ? 3'b110 : 3'b111;   // level 1 active low

  // 40 MHz / 4 = 10.000 MHz, the board's 68000 clock (HW_CONFIRMED).
  ps_m68k #(.CLK_DIV(4)) u_cpu (
      .clk      (clk),
      .rst      (rst),
      .cpu_rst  (cpu_rst),
      .ce_en    (ce_en),
      .iack_stb (iack_stb),
      .addr     (a),
      .dout     (cpu_dout),
      .din      (cpu_din),
      .rd       (cpu_rd),
      .wr       (cpu_wr),
      .uds_n    (uds_n),
      .lds_n    (lds_n),
      .ack      (cpu_ack),
      .ipl_n    (ipl_n),
      .fc       (fc),
      .dbg_d7   (dbg_d7),
      .as_n     (),
      .halted_n (dbg_halted_n)
  );

  wire [1:0] be = {~uds_n, ~lds_n};      // byte enables: [1]=high, [0]=low
  wire [1:0] we = cpu_wr ? be : 2'b00;

  // ---------------------------------------------------------------------
  // Address decode
  //
  // Decoded exactly as MAME lists the ranges.  Whether the real board
  // mirrors these regions across the unlisted address space is UNVERIFIED,
  // so unmapped reads return 0xFFFF (open bus) and are counted for debug
  // rather than silently ignored.
  // ---------------------------------------------------------------------
  wire sel_rom    = (a[23:18] == 6'b000000);                 // 000000-03ffff
  wire sel_work   = (a[23:16] == 8'h10);                     // 100000-10ffff
  wire sel_sprlut = (a[23:14] == 10'b0010_0000_00);          // 200000-203fff
  wire sel_vram   = (a[23:12] == 12'hFF8);                   // ff8000-ff8fff
  wire sel_spr    = (a[23:12] == 12'hFFC) && (a[11:10] == 0);// ffc000-ffc3ff
  wire sel_raster = (a[23:12] == 12'hFFD);                   // ffd000-ffdfff
  wire sel_pal    = (a[23:12] == 12'hFFE);                   // ffe000-ffefff
  wire sel_io     = (a[23:12] == 12'hFFF) && (a[11:4]  == 0);// fff000-fff00f
  wire sel_gga    = (a[23:12] == 12'hFFF) && (a[11:2] == 10'b0100_0000_00);
                                                             // fff400-fff403

  // ---------------------------------------------------------------------
  // Work RAM -- 64 K, the largest single block on the board
  // ---------------------------------------------------------------------
  wire [15:0] work_dout;
  ps_ram #(.AW(15)) u_work (
      .clk (clk),
      .addr(a[15:1]),
      .din (cpu_dout),
      .we  (sel_work ? we : 2'b00),
      .dout(work_dout)
  );

  // ---------------------------------------------------------------------
  // Video-side RAM ports (CPU side of the dual-port blocks)
  // ---------------------------------------------------------------------
  assign vram_addr   = a[11:1];
  assign vram_din    = cpu_dout;
  assign vram_we     = sel_vram   ? we : 2'b00;

  assign spr_addr    = a[9:1];
  assign spr_din     = cpu_dout;
  assign spr_we      = sel_spr    ? we : 2'b00;

  assign raster_addr = a[11:1];
  assign raster_din  = cpu_dout;
  assign raster_we   = sel_raster ? we : 2'b00;

  assign pal_addr    = a[11:1];
  assign pal_din     = cpu_dout;
  assign pal_we      = sel_pal    ? we : 2'b00;

  assign sprlut_addr = a[13:1];
  assign sprlut_din  = cpu_dout;
  assign sprlut_we   = sel_sprlut ? we : 2'b00;

  // ---------------------------------------------------------------------
  // Program ROM
  // ---------------------------------------------------------------------
  assign rom_addr = a[17:1];
  assign rom_rd   = cpu_rd & sel_rom;

  // ---------------------------------------------------------------------
  // I/O writes
  //
  // fff001 / fff003 are ODD bytes: they are only written when LDS is
  // asserted.  fff004 scroll Y is a WORD write.  Getting the byte lane wrong
  // here is silent -- the game keeps running and the screen is wrong.
  // ---------------------------------------------------------------------
  integer i;
  always @(posedge clk) begin
    sound_latch_we <= 1'b0;

    if (rst) begin
      gfxbank      <= 8'h00;
      spr_palbank  <= 2'b00;
      char_palbank <= 3'b000;
      flip_screen  <= 1'b0;
      scrolly      <= 9'd0;
      sound_latch  <= 8'h00;
      for (i = 0; i < 16; i = i + 1) gga_regs[i] <= 8'h00;
      gga_written  <= 16'h0000;
      gga_addr     <= 4'h0;
    end else if (ce_en && cpu_wr && !wr_taken) begin
      if (sel_io) begin
        case (a[3:1])
          3'd0: if (!lds_n) begin              // fff001
                  spr_palbank  <= cpu_dout[1:0];
                  char_palbank <= cpu_dout[4:2];
                  flip_screen  <= cpu_dout[7];
                end
          3'd1: if (!lds_n) gfxbank <= cpu_dout[7:0];          // fff003
          3'd2: begin                                          // fff004 word
                  if (!uds_n) scrolly[8]   <= cpu_dout[8];
                  if (!lds_n) scrolly[7:0] <= cpu_dout[7:0];
                end
          3'd3: if (!lds_n) begin                              // fff007
                  sound_latch    <= cpu_dout[7:0];
                  sound_latch_we <= 1'b1;
                end
          default: ;
        endcase
      end
      if (sel_gga && !lds_n) begin
        // Address/data pair: ODD offset latches the 4-bit address, EVEN
        // offset writes the data.  a[1] selects which.
        if (a[1]) gga_addr <= cpu_dout[3:0];
        else begin
          gga_regs[gga_addr]    <= cpu_dout[7:0];
          gga_written[gga_addr] <= 1'b1;
        end
      end
    end
  end

  reg [3:0] gga_addr;

  // A write must take effect exactly once even though cpu_wr is held until
  // ack.  wr_taken gates the register file after the first accepted cycle.
  reg wr_taken;
  always @(posedge clk) begin
    if (rst)                 wr_taken <= 1'b0;
    else if (!cpu_wr)        wr_taken <= 1'b0;
    else if (ce_en && cpu_wr) wr_taken <= 1'b1;
  end

  // ---------------------------------------------------------------------
  // Read mux and bus acknowledge
  //
  // Every on-chip RAM here answers in one clock.  Only the ROM can stall,
  // so it is the only source that gates cpu_ack.
  // ---------------------------------------------------------------------
  reg rd_d;
  always @(posedge clk) rd_d <= cpu_rd & ce_en;

  always @(*) begin
    cpu_din = 16'hFFFF;
    if      (sel_rom)    cpu_din = rom_data;
    else if (sel_work)   cpu_din = work_dout;
    else if (sel_sprlut) cpu_din = sprlut_dout;
    else if (sel_vram)   cpu_din = vram_dout;
    else if (sel_raster) cpu_din = raster_dout;
    else if (sel_pal)    cpu_din = pal_dout;
    else if (sel_io) begin
      case (a[3:1])
        3'd0: cpu_din = in0;
        3'd1: cpu_din = in1;
        3'd2: cpu_din = dsw;
        3'd3: cpu_din = {8'hFF, 7'h7F, sound_pending};   // fff007 low byte
        default: cpu_din = 16'hFFFF;
      endcase
    end
  end

  always @(*) begin
    if (sel_rom) cpu_ack = rom_ack;
    else         cpu_ack = ce_en & (rd_d | cpu_wr);
  end

  assign dbg_addr = a;
  assign dbg_rd   = cpu_rd;
  assign dbg_wr   = cpu_wr;
  assign dbg_dout = cpu_dout;
  assign dbg_din  = cpu_din;
  assign dbg_ack  = cpu_ack;

endmodule


//----------------------------------------------------------------------------
//  Byte-writable synchronous RAM.  One clock of read latency.
//----------------------------------------------------------------------------
module ps_ram #(parameter int AW = 12) (
    input  wire            clk,
    input  wire [AW-1:0]   addr,
    input  wire [15:0]     din,
    input  wire [1:0]      we,
    output reg  [15:0]     dout
);
  reg [7:0] hi [0:(1<<AW)-1];
  reg [7:0] lo [0:(1<<AW)-1];

  always @(posedge clk) begin
    if (we[1]) hi[addr] <= din[15:8];
    if (we[0]) lo[addr] <= din[7:0];
    dout <= {hi[addr], lo[addr]};
  end
endmodule

`default_nettype wire
