`include "src/top.sv"
`timescale 1ns/1ps

/* ============================================================================
 *  top_tb.sv
 *  Exercises:  PICO trigger -> camera FSM -> async FIFO -> SDRAM write
 *              -> LCD framebuffer read -> LCD timing pixels out
 *
 *  Practical notes (read these before complaining about X's in the waveform):
 *
 *  1. ECP5 primitives.  top.sv pulls in lcd_fb.sv which instantiates `pll`
 *     (EHXPLLL) and ODDRX1F.  Compile with the ecp5u sim models, e.g.:
 *
 *       iverilog -g2012 \
 *         -y $(yosys-config --datdir)/ecp5/ \
 *         -DLATTICE_ECP5_SIM \
 *         -o build/top_tb.vvp tb/top_tb.sv \
 *         $(yosys-config --datdir)/ecp5/cells_sim.v
 *
 *     If the primitive models aren't available, the `force` on .locked below
 *     will at least keep the data path alive even if the PLL output clocks
 *     are flat. You'll still see the camera path move data into the FIFO.
 *
 *  2. No SDRAM behavioral model is attached.  Writes are observable
 *     (wr_en/wr_ack handshake on the controller), but reads return X on
 *     sdram_dq, so the LCD output will be black/X. To verify the read path
 *     too, drop a Micron MT48LC16M16A2 sim model (or any IS42S16160B clone)
 *     on the sdram_* bus and the LCD pixel stream will come back as the
 *     captured pattern.
 *
 *  3. Shortened "fake frame".  Sending the full 320x240x2 = 153,600 bytes per
 *     frame at 25 MHz pclk is ~6 ms of sim time. We send a handful of bytes
 *     per HREF for a handful of HREFs so the dataflow is visible without a
 *     huge VCD. Your camera FSM stays in `Capture` because counter never
 *     hits 76800 — that's fine, the TB ends with $finish first.
 * ========================================================================= */

module top_tb;

// --------------------------------------------------------
// Clocks
// --------------------------------------------------------
logic clk_tb;           // 25 MHz FPGA system clock
logic pclk_tb;          // 25 MHz OV7670 pixel clock (same rate, separate net)

localparam CLK_PERIOD = 40;   // 40 ns -> 25 MHz

always #(CLK_PERIOD/2) clk_tb  = ~clk_tb;
always #(CLK_PERIOD/2) pclk_tb = ~pclk_tb;

// --------------------------------------------------------
// DUT I/O
// --------------------------------------------------------
logic       pico_trigger_tb;
logic       vsync_tb;
logic       href_tb;
logic [7:0] dcam_tb;

wire        sio_d_tb;    // SCCB (we bypass the config, so left floating)
wire        sio_c_tb;
wire        reset_tb;
wire        pwdn_tb;
wire        xclk_tb;

wire        lcd_clk_tb;
wire        lcd_hsync_tb, lcd_vsync_tb, lcd_de_tb;
wire [4:0]  lcd_r_tb, lcd_b_tb;
wire [5:0]  lcd_g_tb;

wire        sdram_clk_tb, sdram_cke_tb;
wire        sdram_cs_n_tb, sdram_ras_n_tb, sdram_cas_n_tb, sdram_we_n_tb;
wire [1:0]  sdram_ba_tb, sdram_dqm_tb;
wire [12:0] sdram_a_tb;
wire [15:0] sdram_dq_tb;

// --------------------------------------------------------
// DUT
// --------------------------------------------------------
top dut (
    .clkTOP         (clk_tb),
    .PICOTriggerTOP (pico_trigger_tb),

    .pclkTOP        (pclk_tb),
    .vsyncTOP       (vsync_tb),
    .hrefTOP        (href_tb),
    .DataComeTOP    (dcam_tb),

    .sio_dTOP       (sio_d_tb),
    .sio_cTOP       (sio_c_tb),
    .reset_TOP      (reset_tb),
    .pwdn_TOP       (pwdn_tb),
    .xclkTOP        (xclk_tb),

    .lcdCLK         (lcd_clk_tb),
    .hsync4SCREEN   (lcd_hsync_tb),
    .vsync4SCREEN   (lcd_vsync_tb),
    .de             (lcd_de_tb),
    .lcdr           (lcd_r_tb),
    .lcdg           (lcd_g_tb),
    .lcdb           (lcd_b_tb),

    .sdram_clk      (sdram_clk_tb),
    .sdram_cke      (sdram_cke_tb),
    .sdram_cs_n     (sdram_cs_n_tb),
    .sdram_ras_n    (sdram_ras_n_tb),
    .sdram_cas_n    (sdram_cas_n_tb),
    .sdram_we_n     (sdram_we_n_tb),
    .sdram_ba       (sdram_ba_tb),
    .sdram_a        (sdram_a_tb),
    .sdram_dqm      (sdram_dqm_tb),
    .sdram_dq       (sdram_dq_tb)
);

// --------------------------------------------------------
// Waveform dump
// --------------------------------------------------------
initial begin
    $dumpfile("build/top.vcd");
    $dumpvars(0, top_tb);
end

// --------------------------------------------------------
// Fake-frame parameters (shortened for sim feasibility)
// --------------------------------------------------------
localparam BYTES_PER_LINE     = 16;   // real OV7670 QVGA YUV422 = 640
localparam LINES_PER_FRAME    = 4;    // real = 240
localparam HBLANK_CYCLES      = 8;    // pclks between HREFs
localparam VSYNC_PULSE_CYCLES = 20;   // pclks vsync is high
localparam VFRONT_CYCLES      = 16;   // pclks after vsync before first HREF

logic [7:0] byte_counter;

// --------------------------------------------------------
// Stimulus tasks (drive D_data with a recognizable ramp so you
// can tell which byte ended up where in the FIFO/SDRAM)
// --------------------------------------------------------
task automatic send_line(input int n_bytes);
    int i;
    begin
        @(posedge pclk_tb);
        href_tb = 1'b1;
        for (i = 0; i < n_bytes; i++) begin
            dcam_tb       = byte_counter;
            byte_counter  = byte_counter + 1;
            @(posedge pclk_tb);
        end
        href_tb = 1'b0;
        dcam_tb = 8'h00;
    end
endtask

task automatic send_frame;
    int l;
    begin
        // VSYNC pulse marks frame start
        @(posedge pclk_tb);
        vsync_tb = 1'b1;
        repeat (VSYNC_PULSE_CYCLES) @(posedge pclk_tb);
        vsync_tb = 1'b0;
        repeat (VFRONT_CYCLES) @(posedge pclk_tb);

        for (l = 0; l < LINES_PER_FRAME; l++) begin
            send_line(BYTES_PER_LINE);
            repeat (HBLANK_CYCLES) @(posedge pclk_tb);
        end
    end
endtask

// --------------------------------------------------------
// Main sequence
// --------------------------------------------------------
initial begin
    // Init all stimulus signals BEFORE clocks start ticking real work
    clk_tb          = 1'b0;
    pclk_tb         = 1'b0;
    pico_trigger_tb = 1'b0;
    vsync_tb        = 1'b0;
    href_tb         = 1'b0;
    dcam_tb         = 8'h00;
    byte_counter    = 8'h01;   // start at 1 so 0x00 is "no data"

    // Bypass the SCCB config FSM — we don't want to wait for I2C-like
    // signalling to complete in sim. After this force, the camera FSM
    // sees ready=1 and will respond to captureInstructonFromPico.
    force dut.cameraMOD.ready = 1'b1;

    // Force PLL locked high in case ECP5 primitives aren't modeled.
    // If you DO have ecp5u sim models, this is harmless (locked will
    // come up on its own and the force just overrides briefly).
    force dut.SDRAMWRITE.locked = 1'b1;

    // Let the SDRAM controller's INIT_WAIT (10,000 cycles @ 100 MHz =
    // 100 us) and the subsequent precharge/refresh/LMR finish.
    // Margin: 200 us.
    #200_000;

    $display("[%0t] init complete, asserting PICO trigger", $time);

    // Pulse the capture trigger from the Pico.
    // The FSM samples this on posedge pclk; level-trigger is fine.
    @(posedge pclk_tb);
    pico_trigger_tb = 1'b1;
    @(posedge pclk_tb);
    @(posedge pclk_tb);
    pico_trigger_tb = 1'b0;

    // Drive one shortened "frame" of sensor data
    send_frame();

    // Let the async FIFO drain into SDRAM and let the LCD scan out a bit.
    // One full LCD frame at 9 MHz pixel clk is ~298*572 = 170,456 cycles
    // = ~18.9 ms — too long. Just give it a few hundred us to see the
    // sdram_rd_addr increment and lcd_de/hsync/vsync toggle.
    #500_000;

    release dut.cameraMOD.ready;
    release dut.SDRAMWRITE.locked;

    $display("[%0t] simulation finished", $time);
    $finish;
end

// --------------------------------------------------------
// Watchdog so a runaway sim doesn't hang forever
// --------------------------------------------------------
initial begin
    #2_000_000;   // 2 ms hard cap
    $display("[%0t] WATCHDOG: hit 2 ms hard timeout", $time);
    $finish;
end

// --------------------------------------------------------
// Live $display monitors — useful for terminal-only debug
// --------------------------------------------------------

// Camera FSM pushed a 16-bit pixel into the async FIFO
always @(posedge pclk_tb) begin
    if (dut.cameraMOD.w_en)
        $display("[%0t] CAM->FIFO  pixel=%h  byte_counter=%0d",
                 $time, dut.cameraMOD.w_data, byte_counter);
end

// Glue logic pushed a write into the SDRAM controller and got ack
always @(posedge dut.clk_100m) begin
    if (dut.wr_en && dut.wr_ack)
        $display("[%0t] FIFO->SDRAM addr=%0d data=%h",
                 $time, dut.sdramADDRESS, dut.async2SDRAM);
end

// LCD timing rolled over to a new frame
always @(posedge lcd_clk_tb) begin
    if (dut.SDRAMWRITE.timing_inst.new_frame)
        $display("[%0t] LCD new_frame", $time);
end

endmodule