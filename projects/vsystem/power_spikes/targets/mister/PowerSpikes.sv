//============================================================================
//  Video System "Power Spikes" for MiSTer -- board wrapper
//
//  Wires the board-independent core in rtl/ps_top.sv to the MiSTer
//  framework: clocks, HPS I/O, ROM download, SDRAM and video.
//
//  STATE OF PLAY -- read this before believing anything on screen.
//  This build contains the 68000, the full address decode, all board RAM,
//  video timing, the tilemap layer and the VS8904/8905 sprite engine.
//  It does NOT contain the Z80 or the YM2610.  So:
//
//      no sound            silence is expected, not a fault
//      video               tilemap + sprites; the picture should be the game
//
//  Anything beyond that on screen is a bug, not progress.  The debug overlay
//  (OSD -> Debug overlay) is the instrument; tools/read_overlay.py decodes it.
//
//  Power Spikes is a horizontal game (MAME rotate=0), so unlike NA-1/NA-2
//  there is no screen_rotate and no MISTER_FB.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports this core does not use /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

// No framebuffer: this game is horizontal, so nothing rotates and the qsf
// does not define MISTER_FB.  The FB_* ports therefore DO NOT EXIST --
// sys/emu_ports.vh declares them inside `ifdef MISTER_FB.  Assigning them
// anyway creates implicit nets that go nowhere and synthesis warns about
// each one, which is how this was found.
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN,
        DDRAM_BE, DDRAM_WE, DDRAM_RD} = 0;

// Aspect ratio.  Nothing drives these by default and an undriven output is
// only a warning, so the picture would just come out the wrong shape.
// 352 x 240 on a 4:3 monitor is the original.
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

assign VGA_F1      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// jt10 puts out signed 16-bit stereo already mixed (FM + SSG + ADPCM), so
// AUDIO_S is 1 and nothing is scaled here.  AUDIO_MIX stays 0: the board is
// genuinely stereo -- MAME routes YM2610 channel 1 left and channel 2 right
// -- so mixing the two channels together would be a change, not a fix.
assign AUDIO_S   = 1;
assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"PowerSpikes;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	// The .mra carries a full <switches> block (SW1:1-8, SW2:1-8, transcribed
	// switch by switch from MAME).  Without this one line the framework loads
	// those defaults at ioctl index 254 -- the board really does get them --
	// but no menu ever shows them, so Service Mode, Difficulty and the rest
	// were set in stone at whatever the .mra shipped.  Added 2026-09-03.
	"DIP;",

	// ---- Debug submenu, page 1 ---------------------------------------------
	// These four are probes, not settings a player wants, so they live on their
	// own page and the first screen stays Aspect ratio / Scandoubler Fx / DIP.
	// Same shape NA-1/NA-2 settled on (its CONF_STR, "H1P1,Debug;").  The
	// status bits are UNTOUCHED -- this changes where the items are SHOWN, not
	// what they mean -- so every existing .mra OSD default still applies.
	//
	// NA-2 additionally hides the page behind status_menumask bit 1 until the
	// .mra unlocks it.  Power Spikes has no such descriptor bit, so the page is
	// always visible here; adding the mask is a separate change.

	// MiSTer clears every status bit on a fresh core load, so the DEFAULT is
	// what a session actually starts with.  During bring-up status[10]=0 meant
	// On; since 2026-10-05 (public release) 0 means Off, and status[11]=0
	// means the core's video, so a bare RBF load shows the game.  The .mra
	// OSD defaults (tools/build_rom.py OSD_DEFAULTS) were flipped with it.
	"P1O[10],Debug overlay,Off,On;",
	// The overlay has grown to 54 rows.  At 4 px a row that is 216 lines of a
	// 240-line screen, which leaves nothing of the game to match a MAME frame
	// against -- and matching the scene is how every video comparison in this
	// project establishes that two pictures are the same moment.  So it pages:
	// 18 rows at a time, 72 lines, leaving 168 lines of game visible.
	"P1O[13:12],Overlay page,0-17,18-35,36-53,54-70;",
	"P1O[11],Video source,Core,Test pattern;",
	// Freezes the 68000 and the sound (ps_top: ce_en = ~pause & ~dl_active).
	// The video engines keep scanning and keep contending for SDRAM, so a
	// paused screen is a STATIC picture drawn by a LIVE renderer -- which is
	// the only way to photograph a frame-to-frame artefact without the
	// game's own animation confounding it.
	"P1O[14],Pause CPU,Off,On;",
	"P1,Debug;",
	"-;",
	// --- 표준 OSD, docs/OSD_POLICY.md -------------------------------------
	// `On` 이 먼저여야 기본이 On 이다.  비트 15 인 이유는 10~14 가 이미
	// 쓰이고 있어서다 -- 기존 비트는 옮기지 않는다 (OSD_POLICY 4절).
	// 비트 16 은 메뉴 줄이 없는 .mra 전용 자동 코인이다.  2026-09-15 까지
	// 그것이 비트 15 에 있어서 이 항목과 겹쳤다.
	"O[15],Pause when OSD open,On,Off;",
	"-;",
	"R[0],Reset;",
	// Three buttons, and Coin on Select -- the same shape the working
	// NA-1/NA-2 core uses.
	//
	// This used to declare SIX, with a separate "Start P2" sitting on
	// Select and Coin pushed out to R.  That is why a player could move and
	// press the three game buttons but could find no start and no coin: the
	// two controls everyone reaches for were not where anyone reaches.
	// Player 2 does not need an entry of its own -- it presses Start on its
	// OWN pad, which is joystick_1 bit 7.
	//
	// *** THE NAMES ARE A/B/C, NOT Toss/Spike/Special.  2026-09-03. ***
	// Those three action names were invented; the board has no such controls.
	// The PCB wires three buttons per player (JAMMA B1-B3, and the board's OWN
	// I/O TEST screen calls them "1P A / 1P B / 1P C" -- the strings are at
	// program-ROM $15BB7).  But the GAME only ever reads button A:
	//   * every gameplay input read goes through the getters at $CA0E (level)
	//     and $CA94 (edge), and every mask those callers apply is $01/$02/$04/
	//     $08/$0C/$0F (stick) or $10 / btst #4 (button A).  Bit 5 and bit 6 are
	//     never tested by gameplay code.
	//   * B and C reach the game only through the "any of A/B/C" mask
	//     `andi.b #$70` -- attract skip, continue, name entry.
	//   * individually they appear only in the built-in test mode (dispatch
	//     table $15984) and in the developer debug keys at $04B6/$04EC/$053C,
	//     which are gated by $10004A -- written at $001222 from DSW bit 15,
	//     i.e. SW2:8 "Debug", the switch Video System documents as "must be
	//     off".  With it on, P1 B freezes the game and P1 C advances one frame.
	// So all three stay wired (the test mode and that DIP need them), but the
	// names now say what the board says.  docs/MAME_NOTES.md section "Buttons".
	"J1,A (Action),B,C,Start,Coin,Pause;",
	"jn,A,B,X,Start,Select,R;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire [127:0] status;
wire  [1:0] buttons;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;

wire [31:0] joystick_0, joystick_1;
wire [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(),
	.joystick_3(),

	.ps2_key(ps2_key),

	// hps_io declares these inputs with no default, so leaving them open
	// makes them float.  NA-1/NA-2 lost a session to exactly that: an open
	// ioctl_wait goes onto HPS_BUS[37] as "core not ready" and hung the HPS
	// partway through the ROM load.  Tie every one of them off explicitly.
	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0),
	.ps2_kbd_clk_in(1'b0),
	.ps2_kbd_data_in(1'b0),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b0),
	.ps2_mouse_data_in(1'b0),
	.video_rotated(1'b0),
	.new_vmode(1'b0),
	// OSD defaults come from the .mra, not from a rebuild.  Bit 0 (Reset) is
	// masked off: seeding it would hold the core in reset from the moment the
	// .mra finished loading, which is a baffling way to find an .mra typo.
	.status_in({104'd0, mra_status[23:1], 1'b0}),
	.status_set(mra_status_set),
	.info_req(1'b0),
	.info(8'd0),
	.sd_lba('{default:32'd0}),
	.sd_blk_cnt('{default:6'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{default:8'd0}),
	.ioctl_upload(),
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),
	.ioctl_din(8'd0)
);

///////////////////   .MRA-SUPPLIED OSD DEFAULTS   ///////////////////////
//
// MiSTer clears every status bit on a fresh arcade load, so the DEFAULT is
// what a session actually starts with.  Rebuilding the bitstream to flip a
// debug option costs ~50 minutes; editing three bytes in the .mra costs
// seconds.  Mechanism copied from NA-1/NA-2.
//
//   <rom index="1"><part>hh mm ll</part></rom>
//     hh = status[23:16]   mm = status[15:8]   ll = status[7:0]
//
// tools/build_rom.py generates this block; see OSD_DEFAULTS there.
reg [23:0] mra_status      = 24'd0;
reg        mra_status_seen = 1'b0;
reg        ioctl_dl_d      = 1'b0;
reg        mra_status_done = 1'b0;
reg        mra_status_set  = 1'b0;

always @(posedge clk_sys) begin
	// !ioctl_addr[26:2] so only the first FOUR bytes can land here.
	if (ioctl_wr && (ioctl_index == 16'd1) && !ioctl_addr[26:2]) begin
		case (ioctl_addr[1:0])
			2'd0: mra_status[23:16] <= ioctl_dout;
			2'd1: mra_status[15:8]  <= ioctl_dout;
			2'd2: begin mra_status[7:0] <= ioctl_dout; mra_status_seen <= 1'b1; end
			default: ;
		endcase
	end
end

always @(posedge clk_sys) begin
	ioctl_dl_d     <= ioctl_download;
	mra_status_set <= 1'b0;
	if (ioctl_dl_d && !ioctl_download && mra_status_seen && !mra_status_done) begin
		// Only when NO saved settings were loaded.  MiSTer loads <setname>.CFG
		// into status BEFORE the ROM download, and status_set makes Main replace
		// all 128 bits with status_in (Main_MiSTer user_io.cpp
		// check_status_change) -- so pushing the .mra defaults unconditionally
		// overwrote every saved OSD setting on every load ("settings do not
		// save", reported 2026-10-07).  A saved file has some bit of [127:1]
		// set; a fresh load has none.  [0] is the reset bit Main pulses.
		mra_status_set  <= ~|status[127:1];
		mra_status_done <= 1'b1;
	end
end

///////////////////////   CLOCKS   ///////////////////////////////
//
// 40.000 MHz, and every board clock divides from it exactly:
//     68000 / 4 = 10 MHz, Z80 / 8 = 5 MHz, YM2610 / 5 = 8 MHz.
// outclk_1 is the same frequency shifted half a period for SDRAM_CLK
// (-12500 ps at 40 MHz).
//
// NA-1/NA-2's worst bug was a PLL Quartus accepted, TimeQuest blessed and
// the fitter programmed with an out-of-range VCO, so the core clock never
// ran on hardware and nothing said a word.  40 MHz from a 50 MHz reference
// is an exact 4/5 ratio (VCO 800 MHz), which is far safer than the 50.113
// they needed -- but the gate stays: build.sh runs tools/check_pll.py
// against the Fitter's PLL Usage Summary, which reports the counters as
// PROGRAMMED rather than as requested.  Do not remove that check.

wire clk_sys, clk_sdram, clk_aux, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_aux),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

// clk_aux is the 250 MHz output that exists only to force the PLL solver
// into a legal VCO (rtl/pll/pll_0002.v explains why).  It MUST HAVE A REAL
// LOAD.  Left unconnected, Quartus deletes the counter, re-solves the PLL
// with two outputs, and puts the VCO straight back to the 400 MHz that
// stopped clk_sys running -- which is exactly what happened on the first
// attempt at this fix, and tools/check_pll.py caught it with
// "the fitter programmed 2 outputs, 3 were expected".
//
// So it drives a counter whose top bit is observable in the debug overlay.
// That is a genuine instrument as well as a load: if pll_alive never
// toggles, the third output is not running.
reg [23:0] aux_cnt = 24'd0;
always @(posedge clk_aux) aux_cnt <= aux_cnt + 24'd1;

reg [2:0] aux_sync = 3'd0;
always @(posedge clk_sys) aux_sync <= {aux_sync[1:0], aux_cnt[23]};
wire pll_alive = aux_sync[2] ^ aux_sync[1];   // toggling => that clock runs

wire rst_sys = RESET | status[0] | buttons[1] | ~pll_locked;

// The core is held in reset while ROMs load.  The memory bus must NOT be:
// it is the thing doing the loading.
wire rst_mem = ~pll_locked;

///////////////////////   INPUT   ////////////////////////////////
//
// docs/HARDWARE.md section 9.  Everything is ACTIVE LOW, and note that P2
// sits in IN0 while P1 sits in IN1 -- the order is inverted from the obvious
// and swapping them makes the game look like it works until two people play.
//
// joystick bit order from the J1 line above:
//   0 right  1 left  2 down  3 up  4 button A  5 button B  6 button C
//   7 Start  8 Coin        -- per pad, so P2 uses its own pad's Start/Select
//
// All three buttons stay wired even though the game plays with A alone: the
// board's own I/O TEST checks 1P/2P A, B and C, the "any button" mask
// `andi.b #$70` accepts all three at attract/continue prompts, and DSW SW2:8
// "Debug" turns B into freeze and C into frame-advance.  See the J1 line.

// --- Pause -----------------------------------------------------------------
// 버튼 토글 + OSD 자동 정지.  ioctl_download 에서 반드시 푼다.
// docs/OSD_POLICY.md 2절.
wire pause_btn = joystick_0[9] | joystick_1[9];   // J1 6번째 = Pause
reg  pause_btn_d, pause_latch;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (ioctl_download)                  pause_latch <= 1'b0;
	else if (~pause_btn_d & pause_btn)   pause_latch <= ~pause_latch;
end
// 사용자 pause 는 즉시 걸린다.  status[14] (Debug "Pause CPU") 만 ps_top 의
// PAUSE_DELAY_FRAMES 지연을 탄다 -- 원래 둘이 한 입력으로 합쳐져 있어서
// 로드 후 약 50 초 동안 R 도 OSD 자동 정지도 아무 일도 하지 않았다.
wire pause_user = pause_latch | (OSD_STATUS & ~status[15]);

wire [31:0] j1 = joystick_0;
wire [31:0] j2 = joystick_1;

wire [15:0] in0 = ~{
	1'b0,            // 15 unknown
	m_service,       // 14 service
	2'b00,           // 13-12 unknown
	m_start2,        // 11
	m_start1,        // 10
	m_coin2,         //  9
	m_coin1,         //  8
	1'b0,            //  7 unknown
	j2[6], j2[5], j2[4],           // P2 buttons 3,2,1
	j2[0], j2[1], j2[2], j2[3]     // P2 right,left,down,up
};

wire [15:0] in1 = ~{
	8'h00,
	1'b0,
	j1[6], j1[5], j1[4],           // P1 buttons 3,2,1
	j1[0], j1[1], j1[2], j1[3]     // P1 right,left,down,up
};

// Each pad drives its own start and coin.  P1's Start is joystick_0 bit 7 and
// P2's is joystick_1 bit 7 -- not two entries on one pad.
// DIAGNOSTIC AUTO-COIN, status[16].  Set only by the _autocoin .mra.
//
// It was status[15] until 2026-09-15, which is also "Pause when OSD open":
// this item has no CONF_STR line, so the OSD standardisation saw bit 15 as
// free.  Turning that menu item Off dropped a coin and pressed Start 30 s
// after load.  tools/build_rom.py OSD_DEFAULTS moved with it.
//
// The screen this core drops sprites on is the third HOW TO PLAY page, and it
// only exists after a coin, a start and a team select.  That made every
// measurement of the defect depend on somebody being at the board.
//
// Injecting the keypresses over ssh does not work: the board has /dev/uinput
// and the kernel enumerates a virtual keyboard from it happily -- it appears
// in /proc/bus/input/devices as a kbd -- but MiSTer ignores it, which is
// consistent with MiSTer creating its own uinput device and skipping ones it
// did not make. The OSD key never opened the OSD.
//
// So the core inserts the coin itself. MAME says coin then start is enough:
// the team select confirms on its own timer, and the instruction screens
// follow. Frame counts come from that MAME run (tools/ps_coin_burst.lua).
// The clock is 40 MHz, so a 24-bit counter reaches 0.42 s and a coin dropped
// there lands before the game has finished booting.  Count in 32 bits, and
// only once the ROM download has finished -- the download itself takes real
// time and holds the core in reset, so counting from `reset` would measure
// the transfer rather than the game.
reg [31:0] ac_cnt;
always @(posedge clk_sys)
  if (rst_sys || ioctl_download) ac_cnt <= 32'd0;
  else if (~&ac_cnt)           ac_cnt <= ac_cnt + 32'd1;

// 40 MHz: coin at 30 s, start at 33 s, each held ~0.25 s.  Generous on
// purpose -- the game has to reach attract before it will take a credit, and
// an .mra that comes up already coined is only useful if it works every time.
wire ac_coin  = status[16] && (ac_cnt > 32'd1_200_000_000) && (ac_cnt < 32'd1_210_000_000);
wire ac_start = status[16] && (ac_cnt > 32'd1_320_000_000) && (ac_cnt < 32'd1_330_000_000);

wire m_start1  = j1[7] | ac_start;
wire m_start2  = j2[7];
wire m_coin1   = j1[8] | ac_coin;
wire m_coin2   = j2[8];
wire m_service = 1'b0;

// DIP switches arrive from the .mra <switches> block at ioctl index 254.
// SW1 is the low byte, SW2 the high byte; the board reads them active-low
// and the .mra default is FF,FF.
reg [15:0] dsw = 16'hFFFF;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'h00FE) && !ioctl_addr[26:1]) begin
		if (!ioctl_addr[0]) dsw[7:0]  <= ioctl_dout;
		else                dsw[15:8] <= ioctl_dout;
	end
end

///////////////////////   CORE   /////////////////////////////////

wire [24:0] mem_addr;
wire [15:0] mem_dout, mem_din;
wire        mem_req, mem_we, mem_ack;
wire  [1:0] mem_ds;

wire [24:0] dl_addr;
wire [15:0] dl_data;
wire        dl_req, dl_ack, dl_active;

wire [7:0]  vid_r, vid_g, vid_b;
wire        ce_pix, hblank, vblank, hsync, vsync;

wire [23:1] dbg_addr;
wire        dbg_rd, dbg_wr, dbg_ack, dbg_halted_n, dbg_vbl_irq;
wire [15:0] dbg_din;
wire [15:0] dbg_cpu_stall;
wire [8:0]  dbg_hcnt, dbg_vcnt;
wire [7:0]  dbg_gfxbank, dbg_sound_latch;
wire [15:0] dbg_gga, dbg_spr_drawn, dbg_spr_hit, dbg_spr_overrun;
wire [63:0] dbg_gga_x;
wire [79:0] dbg_crtc;
wire [31:0] dbg_iack_x;
wire [15:0] dbg_spr_nonrom, dbg_spr_workload;
wire [15:0] dbg_spr_snap1, dbg_spr_snap2;
wire [15:0] dbg_rom_w0, dbg_rom_w1;
wire        dbg_probe_done;
wire [15:0] dbg_z80_cyc, dbg_ym_wr, dbg_pcma_fetch, dbg_pcm_late;
wire [7:0]  dbg_snd_state;
wire [15:0] dbg_snd_rom_w0, dbg_snd_rom_n, dbg_snd_peak, dbg_snd_latch_ack;
wire [15:0] dbg_snd_peak_l, dbg_snd_peak_r, dbg_snd_pcma_kon, dbg_snd_fm_kon, dbg_snd_sample, dbg_snd_io_rd, dbg_snd_last_b1;
wire [15:0] dbg_snd_irq, dbg_snd_intack, dbg_snd_timer_w;
wire [15:0] dbg_snd_peak_fm, dbg_snd_peak_psg;
wire [15:0] dbg_raster_msg, dbg_raster_court;
wire [15:0] dbg_o6_map, dbg_o6_tile, dbg_o6_pos, dbg_o6_first, dbg_o6_sx, dbg_o6_blitx;
wire [15:0] dbg_o6_row0, dbg_o6_row1, dbg_o6_row2, dbg_o6_row3;
wire [15:0] dbg_jump_fr, dbg_maxd_fr;
wire [15:0] dbg_sprwr_disp, dbg_vramwr_disp;
wire [15:0] dbg_pcma_late_fr, dbg_pcma_fetch_fr, dbg_burst_first, dbg_tm_late, dbg_tm_late_l;
wire [15:0] dbg_snd_roe_a, dbg_snd_peak_op, dbg_snd_aon_cnt;
wire [15:0] dbg_snd_eg_min, dbg_snd_keyon_cnt;
wire [15:0] dbg_snd_mmr_kon, dbg_snd_kon_latch;
wire [15:0] dbg_snd_kon_match, dbg_snd_csr_slots;
wire [15:0] dbg_snd_fm_koff, dbg_snd_last_kon;
wire signed [15:0] snd_l, snd_r;

ps_download u_download
(
	.clk(clk_sys),
	.rst(rst_mem),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.dl_addr(dl_addr),
	.dl_data(dl_data),
	.dl_req(dl_req),
	.dl_ack(dl_ack),
	.dl_active(dl_active)
);

ps_top ps
(
	.clk(clk_sys),
	.rst(rst_sys),
	.mem_rst(rst_mem),
	.pause(pause_user),
	.pause_dbg(status[14]),

	.mem_addr(mem_addr),
	.mem_din(mem_din),
	.mem_dout(mem_dout),
	.mem_req(mem_req),
	.mem_we(mem_we),
	.mem_ds(mem_ds),
	.mem_ack(mem_ack),

	.dl_active(dl_active),
	.dl_addr(dl_addr),
	.dl_data(dl_data),
	.dl_req(dl_req),
	.dl_ack(dl_ack),

	.in0(in0),
	.in1(in1),
	.dsw(dsw),

	.red(vid_r), .green(vid_g), .blue(vid_b),
	.hsync(hsync), .vsync(vsync),
	.hblank(hblank), .vblank(vblank),
	.ce_pix(ce_pix),

	.snd_l(snd_l),
	.snd_r(snd_r),

	.dbg_addr(dbg_addr),
	.dbg_rd(dbg_rd),
	.dbg_wr(dbg_wr),
	.dbg_ack(dbg_ack),
	.dbg_din(dbg_din),
	.dbg_vbl_irq(dbg_vbl_irq),
	.dbg_halted_n(dbg_halted_n),
	.dbg_cpu_stall(dbg_cpu_stall),
	.dbg_hcnt(dbg_hcnt),
	.dbg_vcnt(dbg_vcnt),
	.dbg_gfxbank(dbg_gfxbank),
	.dbg_sound_latch(dbg_sound_latch),
	.dbg_gga(dbg_gga),
	.dbg_gga_x(dbg_gga_x),
	.dbg_crtc(dbg_crtc),
	.dbg_iack_x(dbg_iack_x),
	.dbg_spr_drawn(dbg_spr_drawn),
	.dbg_spr_hit(dbg_spr_hit),
	.dbg_rom_w0(dbg_rom_w0),
	.dbg_rom_w1(dbg_rom_w1),
	.dbg_probe_done(dbg_probe_done),
	.dbg_spr_overrun(dbg_spr_overrun),
	.dbg_spr_snap1(dbg_spr_snap1),
	.dbg_spr_snap2(dbg_spr_snap2),
	.dbg_spr_nonrom(dbg_spr_nonrom),
	.dbg_spr_workload(dbg_spr_workload),
	.dbg_z80_cyc(dbg_z80_cyc),
	.dbg_ym_wr(dbg_ym_wr),
	.dbg_pcma_fetch(dbg_pcma_fetch),
	.dbg_pcm_late(dbg_pcm_late),
	.dbg_snd_state(dbg_snd_state),
	.dbg_snd_rom_w0(dbg_snd_rom_w0),
	.dbg_snd_rom_n(dbg_snd_rom_n),
	.dbg_snd_peak(dbg_snd_peak),
	.dbg_snd_latch_ack(dbg_snd_latch_ack),
	.dbg_snd_peak_l(dbg_snd_peak_l),
	.dbg_snd_peak_r(dbg_snd_peak_r),
	.dbg_snd_pcma_kon(dbg_snd_pcma_kon),
	.dbg_snd_fm_kon(dbg_snd_fm_kon),
	.dbg_snd_sample(dbg_snd_sample),
	.dbg_snd_io_rd(dbg_snd_io_rd),
	.dbg_snd_last_b1(dbg_snd_last_b1),
	.dbg_snd_irq(dbg_snd_irq),
	.dbg_snd_intack(dbg_snd_intack),
	.dbg_snd_timer_w(dbg_snd_timer_w),
	.dbg_snd_peak_fm(dbg_snd_peak_fm),
	.dbg_snd_peak_psg(dbg_snd_peak_psg),
	.dbg_raster_msg(dbg_raster_msg),
	.dbg_raster_court(dbg_raster_court),
	.dbg_o6_map(dbg_o6_map),
	.dbg_o6_tile(dbg_o6_tile),
	.dbg_o6_pos(dbg_o6_pos),
	.dbg_o6_first(dbg_o6_first),
	.dbg_o6_sx(dbg_o6_sx),
	.dbg_o6_blitx(dbg_o6_blitx),
	.dbg_o6_row0(dbg_o6_row0),
	.dbg_o6_row1(dbg_o6_row1),
	.dbg_o6_row2(dbg_o6_row2),
	.dbg_o6_row3(dbg_o6_row3),
	.dbg_jump_fr(dbg_jump_fr),
	.dbg_maxd_fr(dbg_maxd_fr),
	.dbg_burst_first(dbg_burst_first),
	.dbg_tm_late(dbg_tm_late),
	.dbg_tm_late_l(dbg_tm_late_l),
	.dbg_pcma_late_fr(dbg_pcma_late_fr),
	.dbg_pcma_fetch_fr(dbg_pcma_fetch_fr),
	.dbg_sprwr_disp(dbg_sprwr_disp),
	.dbg_vramwr_disp(dbg_vramwr_disp),
	.dbg_snd_roe_a(dbg_snd_roe_a),
	.dbg_snd_peak_op(dbg_snd_peak_op),
	.dbg_snd_aon_cnt(dbg_snd_aon_cnt),
	.dbg_snd_eg_min(dbg_snd_eg_min),
	.dbg_snd_keyon_cnt(dbg_snd_keyon_cnt)
	,.dbg_snd_mmr_kon(dbg_snd_mmr_kon)
	,.dbg_snd_kon_latch(dbg_snd_kon_latch)
	,.dbg_snd_kon_match(dbg_snd_kon_match)
	,.dbg_snd_csr_slots(dbg_snd_csr_slots),
	.dbg_snd_fm_koff(dbg_snd_fm_koff),
	.dbg_snd_last_kon(dbg_snd_last_kon)
);

///////////////////////   SDRAM   ////////////////////////////////

reg  [3:0] sdram_init_cnt = 0;
wire       sdram_init = ~sdram_init_cnt[3];
always @(posedge clk_sys) begin
	if (!pll_locked)     sdram_init_cnt <= 0;
	else if (sdram_init) sdram_init_cnt <= sdram_init_cnt + 1'd1;
end

ps_sdram #(.CLK_HZ(40_000_000), .REFRESH_CLK(280)) u_sdram
(
	.clk        (clk_sys),
	.init       (sdram_init),
	.addr       (mem_addr),
	.din        (mem_din),
	.dout       (mem_dout),
	.req        (mem_req),
	.we         (mem_we),
	.ds         (mem_ds),
	.ack        (mem_ack),
	.SDRAM_A    (SDRAM_A),
	.SDRAM_BA   (SDRAM_BA),
	.SDRAM_DQ   (SDRAM_DQ),
	.SDRAM_DQML (SDRAM_DQML),
	.SDRAM_DQMH (SDRAM_DQMH),
	.SDRAM_nCS  (SDRAM_nCS),
	.SDRAM_nWE  (SDRAM_nWE),
	.SDRAM_nRAS (SDRAM_nRAS),
	.SDRAM_nCAS (SDRAM_nCAS),
	.SDRAM_CKE  (SDRAM_CKE)
);

///////////////////////   VIDEO   ////////////////////////////////

wire [2:0] fx = status[4:2];

// Debug overlay.  Painted over the picture rather than beside it, so it is
// readable on any scaler setting; tools/read_overlay.py decodes a screenshot.
wire [7:0] ov_r, ov_g, ov_b;

ps_dbg u_dbg
(
	.clk(clk_sys),
	.ce_pix(ce_pix),
	.enable(status[10]),
	.page(status[13:12]),
	.rst_i(rst_sys),
	.hcnt(dbg_hcnt),
	.vcnt(dbg_vcnt),
	.rgb_in({vid_r, vid_g, vid_b}),
	.rgb_out({ov_r, ov_g, ov_b}),

	.cpu_addr(dbg_addr),
	.cpu_rd(dbg_rd),
	.cpu_wr(dbg_wr),
	.cpu_ack(dbg_ack),
	.cpu_din(dbg_din),
	.halted_n(dbg_halted_n),
	.vblank_irq(dbg_vbl_irq),
	.cpu_stall(dbg_cpu_stall),
	.gfxbank(dbg_gfxbank),
	.sound_latch(dbg_sound_latch),
	.gga(dbg_gga),
	.gga_x(dbg_gga_x),
	.crtc(dbg_crtc),
	.iack_x(dbg_iack_x),
	.spr_drawn(dbg_spr_drawn),
	.spr_hit(dbg_spr_hit),
	.rom_w0(dbg_rom_w0),
	.rom_w1(dbg_rom_w1),
	.probe_done(dbg_probe_done),
	.spr_overrun(dbg_spr_overrun),
	.dl_active(dl_active),
	.pll_alive(pll_alive),
	.dl_req(dl_req),
	.dl_ack(dl_ack),
	.ioctl_index(ioctl_index[7:0]),
	.pcm_late(dbg_pcm_late),
	.snd_state(dbg_snd_state),
	.snd_peak_l(dbg_snd_peak_l),
	.snd_peak_r(dbg_snd_peak_r),
	.snd_pcma_kon(dbg_snd_pcma_kon),
	.snd_fm_kon(dbg_snd_fm_kon),
	.snd_sample(dbg_snd_sample),
	.snd_io_rd(dbg_snd_io_rd),
	.snd_last_b1(dbg_snd_last_b1),
	.snd_irq(dbg_snd_irq),
	.snd_intack(dbg_snd_intack),
	.snd_timer_w(dbg_snd_timer_w),
	.snd_peak_fm(dbg_snd_peak_fm),
	.snd_peak_psg(dbg_snd_peak_psg),
	.raster_msg(dbg_raster_msg),
	.raster_court(dbg_raster_court),
	.o6_map(dbg_o6_map),
	.o6_tile(dbg_o6_tile),
	.o6_pos(dbg_o6_pos),
	.o6_first(dbg_o6_first),
	.o6_sx(dbg_o6_sx),
	.o6_blitx(dbg_o6_blitx),
	.o6_row0(dbg_o6_row0),
	.o6_row1(dbg_o6_row1),
	.o6_row2(dbg_o6_row2),
	.o6_row3(dbg_o6_row3),
	.snd_jump_fr(dbg_jump_fr),
	.snd_maxd_fr(dbg_maxd_fr),
	.burst_first(dbg_burst_first),
	.tm_late(dbg_tm_late),
	.pcma_late_fr(dbg_pcma_late_fr),
	.pcma_fetch_fr(dbg_pcma_fetch_fr),
	.sprwr_disp(dbg_sprwr_disp),
	.vramwr_disp(dbg_vramwr_disp),
	.snd_roe_a(dbg_snd_roe_a),
	.snd_peak_op(dbg_snd_peak_op),
	.snd_aon_cnt(dbg_snd_aon_cnt),
	.snd_eg_min(dbg_snd_eg_min),
	.snd_keyon_cnt(dbg_snd_keyon_cnt),
	.snd_mmr_kon(dbg_snd_mmr_kon),
	.snd_kon_latch(dbg_snd_kon_latch),
	.snd_kon_match(dbg_snd_kon_match),
	.snd_csr_slots(dbg_snd_csr_slots),
	.snd_fm_koff(dbg_snd_fm_koff),
	.snd_last_kon(dbg_snd_last_kon)
);

///////////////////////   VIDEO BISECTION   //////////////////////////////
//
// The core came up on hardware with a completely blank (white) frame: no
// game, and not even the debug overlay, which paints its own colours and
// does not depend on the palette.  That narrows the fault to "the video
// path is not sweeping at all" -- but it does not say WHICH half is at
// fault, the core's video or the target's wiring into arcade_video.
//
// So this is a bisection.  It generates its own timing from clk_sys with
// NO RESET AT ALL -- deliberately, because a stuck rst_sys is one of the two
// candidate causes and a test pattern that shares the suspect reset would
// prove nothing.  Selected by status[11], which the .mra can set, so
// switching between the two costs an .mra edit rather than a rebuild.
//
//   bars visible  -> arcade_video, the scaler and the target wiring are fine,
//                    and the fault is inside ps_video / ps_top
//   still white   -> the fault is at the target level or in the clock itself
reg [8:0] tp_acc = 9'd0;
reg       tp_ce  = 1'b0;
reg [8:0] tp_h   = 9'd0;
reg [8:0] tp_v   = 9'd0;

always @(posedge clk_sys) begin
	if (tp_acc + 9'd63 >= 9'd352) begin
		tp_acc <= tp_acc + 9'd63 - 9'd352;
		tp_ce  <= 1'b1;
	end else begin
		tp_acc <= tp_acc + 9'd63;
		tp_ce  <= 1'b0;
	end
	if (tp_ce) begin
		if (tp_h == 9'd455) begin
			tp_h <= 9'd0;
			tp_v <= (tp_v == 9'd255) ? 9'd0 : tp_v + 9'd1;
		end else begin
			tp_h <= tp_h + 9'd1;
		end
	end
end

wire       tp_hb = (tp_h >= 9'd352);
wire       tp_vb = (tp_v >= 9'd240);
wire       tp_hs = (tp_h >= 9'd372) && (tp_h < 9'd408);
wire       tp_vs = (tp_v >= 9'd244) && (tp_v < 9'd248);
// Coarse vertical bars plus a horizontal ramp: any sweep at all is obvious,
// and a frozen counter shows as a flat colour.
wire [7:0] tp_r = {8{tp_h[5]}};
wire [7:0] tp_g = {8{tp_v[5]}};
wire [7:0] tp_b = tp_h[7:0];

wire use_core = ~status[11];

wire       v_ce = use_core ? ce_pix : tp_ce;
wire       v_hb = use_core ? hblank : tp_hb;
wire       v_vb = use_core ? vblank : tp_vb;
wire       v_hs = use_core ? hsync  : tp_hs;
wire       v_vs = use_core ? vsync  : tp_vs;
wire [23:0] v_rgb = use_core ? {ov_r, ov_g, ov_b} : {tp_r, tp_g, tp_b};

// 352 visible pixels.  WIDTH is what arcade_video uses for the "Original"
// aspect ratio; getting it wrong stretches the picture and nothing errors.
arcade_video #(.WIDTH(352), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(v_ce),
	.RGB_in(v_rgb),
	.HBlank(v_hb),
	.VBlank(v_vb),
	.HSync(v_hs),
	.VSync(v_vs),
	.fx(fx)
);

endmodule
