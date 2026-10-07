//============================================================================
//  Power Spikes -- ioctl byte stream -> SDRAM words
//
//  This is platform transport, so it lives in integration/ and not in rtl/:
//  root CLAUDE.md section 4 keeps ioctl_* out of the board.  The board sees
//  only dl_addr / dl_data / dl_req / dl_ack.
//
//  The MRA tool streams the download image one byte at a time, ascending
//  from 0.  SDRAM is 16 bits wide, and ps_rommap.svh fixes the convention:
//
//      word W  =  { byte 2W , byte 2W+1 }      byte 2W in bits [15:8]
//
//  which is big-endian, so the 68000 reads program words the right way round
//  with no further swapping anywhere in the core.  tools/build_rom.py has
//  already byteswapped the 68000 region relative to the file on disk (MAME's
//  ROM_LOAD16_WORD_SWAP), so the two conventions meet exactly here.  Check
//  the reset vector if this is ever in doubt: SSP must read 0x00110000.
//
//  ioctl_wait is asserted while a word is waiting to go into SDRAM.  Without
//  it the HPS outruns the memory bus and the tail of the image is lost --
//  silently, because a ROM that is 99 % correct still boots for a while.
//============================================================================
`default_nettype none

module ps_download (
    input  wire        clk,
    input  wire        rst,

    // --- from the platform --------------------------------------------------
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    input  wire [15:0] ioctl_index,
    output wire        ioctl_wait,

    // --- to the board's memory port ----------------------------------------
    output reg  [24:0] dl_addr,
    output reg  [15:0] dl_data,
    output reg         dl_req = 1'b0,   // see the note on `busy` below
    input  wire        dl_ack,
    output wire        dl_active
);

  // The MRA's <rom index="0"> is the ROM image.  Match all 16 bits: index
  // 0x00FE is the later <switches> transfer and must not reach ROM space.
  wire is_rom = (ioctl_index == 16'd0);

  reg [7:0] hold;      // the even byte, waiting for its odd partner

  // THE POWER-UP VALUE HERE IS NOT OPTIONAL.
  //
  // ioctl_wait goes onto HPS_BUS[37], which sys_top.v calls io_wait, and
  // io_wait high stops sys_top from ever raising io_ack.  MiSTer's main
  // spins on io_ack for EVERY word it sends the core, so a `busy` that comes
  // out of configuration set wedges the HPS before the core has done
  // anything at all.  The .qsf sets ALLOW_POWER_UP_DONT_CARE, which makes an
  // uninitialised register genuinely free to power up either way.
  //
  // Inherited verbatim from NA-1/NA-2's na2_membus, which carries the same
  // comment on the same signal for the same reason.  Nothing else in this
  // core has that reach.
  reg       busy = 1'b0;

  assign ioctl_wait = busy;
  // Keep write ownership through the acknowledgement of the final word.  The
  // host may lower ioctl_download immediately after presenting its last byte.
  assign dl_active = (ioctl_download & is_rom) | busy;

  always @(posedge clk) begin
    if (rst) begin
      dl_req <= 1'b0;
      busy   <= 1'b0;
      hold   <= 8'd0;
    end else begin
      if (dl_req && dl_ack) begin
        dl_req <= 1'b0;
        busy   <= 1'b0;
      end

      if (ioctl_wr && is_rom) begin
        if (!ioctl_addr[0]) begin
          // even byte: high half of the word, held until the odd byte
          hold <= ioctl_dout;
        end else begin
          dl_addr <= ioctl_addr[25:1];
          dl_data <= {hold, ioctl_dout};
          dl_req  <= 1'b1;
          busy    <= 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire
