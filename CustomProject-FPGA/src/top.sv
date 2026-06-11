`include "asych_fifo.sv"
`include "lcd_fb.sv"
`include "lcd_timing.sv"
`include "ecspll.sv"
`include "SDRAM.sv"
`include "OV7670cameraSM.sv"
`include "SPI_MISO(slave).sv"
module top (


    input logic SCK, // 
    input logic CSn, //
    input logic MOSI, // MOSI TX
    output logic MISO, // MISO RX

    input logic clkTOP,
    input logic Capturing, 
    input logic buttonInput, // mode change
    
    input logic pclkTOP, 
    input logic vsyncTOP,
    input logic hrefTOP,
    input logic [7:0] DataComeTOP,


    inout logic sio_dTOP,
    output logic sio_cTOP,
    output logic reset_TOP,
    output logic pwdn_TOP,
    output logic xclkTOP,

    output logic lcdCLK,
    output logic hsync4SCREEN,
    output logic vsync4SCREEN,
    output logic de,
    output logic [4:0] lcdr,
    output logic [5:0] lcdg,
    output logic [4:0] lcdb,

    output logic sdram_clk,
    output logic sdram_cke,
    output logic sdram_cs_n,
    output logic sdram_ras_n,
    output logic sdram_cas_n,
    output logic sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_a,
    output logic [1:0]  sdram_dqm,
    inout  logic [15:0] sdram_dq


);

logic doneTOP;
logic [23:0] sdramADDRESS = 0; // the faster clock

logic enable;
logic enableCAM2fifo;
logic [15:0] data;
logic [15:0] async2SDRAM;
logic ack;
logic PICOTriggerTOP;

// updated fpga sdram from allan knight 
logic locked;
wire reset = ~locked;
logic clk_100m;
logic resetEN;
logic [15:0] SDRAM_2_SPI;
logic NEXTpixel_ready;

SPI_Slave SPI_MISO (
    .clk(pclkTOP),
    .SCK(SCK),
    .CS(CSn),
    .dataFromFPGA(SDRAM_2_SPI),
    .MOSI(MOSI), // from pico
    .MISO(MISO), // to pico 
    .PICOTrigger(PICOTriggerTOP),
    .flag_next_pixel_ready(NEXTpixel_ready)
);


camera cameraMOD (

    //input into the cam
    .D_data(DataComeTOP),
    //.ack(ack),
    .clk(clkTOP),
    .vsync(vsyncTOP),
    .href(hrefTOP),
    .pclk(pclkTOP),
    .captureInstructonFromPico(Capturing),

    //in and out from the cam
    .siod(sio_dTOP),

    //output from the cam
    .xclk(xclkTOP),
    .reset(reset_TOP),
    .sioc(sio_cTOP),
    .pwdn(pwdn_TOP),
    .w_data(data),
    .w_en(enable),
    // .resetFirst().
    .w_address(address), // not needed
    .done1(doneTOP) //not needed 
);

logic asyncEMPTY;
logic enablefifo2sdram;

logic [15:0] ProcessesData;
logic [15:0] thresholdValue = 16'd32;
logic [1:0] modeChange = 0;
logic [16:0] counter = 0;
// logic [1:0] modeActive = 2'b00; 
always @(posedge pclkTOP) begin
    if (buttonInput) begin
        if (counter == 25000)        // fire ONCE, on the crossing
            modeChange <= modeChange + 1;
        if (counter <= 25000)        // stop at threshold: no re-fire, no wrap
            counter <= counter + 1;
    end else begin
        counter <= 0;          
    end
end
logic [4:0] red;
logic [5:0] green;
logic [4:0] blue;
logic [15:0] gray;

logic [5:0] red6;
logic [5:0] blue6;

logic [4:0] cartoonRed;
logic [5:0] cartoonGreen;
logic [4:0] cartoonBlue;

logic [6:0] redTemp;
logic [7:0] greenTemp;
logic [6:0] blueTemp;

logic [4:0] newRed;
logic [5:0] newGreen;
logic [4:0] newBlue;


always @(*) begin
    red = data[15:11];
    green = data[10:5];
    blue = data[4:0];
    ProcessesData = data;
    case (modeChange) 
        2'b00 : ProcessesData = data ;
        //grayscale
        2'b01 : begin
            red = (data >> 11) & 5'h1F; // red
            green = (data >> 5) & 6'h3F; // green
            blue = data & 5'h1F; // blue
            
            red6 = {red, red[4]};
            blue6 = {blue, blue[4]};

            gray = (red6 + (green << 1) + blue6) >> 2;

            ProcessesData = {gray[5:1], gray[5:0], gray[5:1]};
        end
        //cartoon
// cartoon / warm painterly filter
        2'b10 : begin
            red   = data[15:11];
            green = data[10:5];
            blue  = data[4:0];

            // Posterize: reduce smooth camera gradients into flatter color bands
            cartoonRed   = {red[4:2], red[4:3]};         // 5-bit
            cartoonGreen = {green[5:3], green[5:3]};     // 6-bit
            cartoonBlue  = {blue[4:2], blue[4:3]};       // 5-bit

            // Warm/pastel lift:
            // red and green lifted more, blue lifted less to avoid cold blue look
            redTemp   = (cartoonRed >> 1) + 7'd12;
            greenTemp = (cartoonGreen >> 1) + 8'd16;
            blueTemp  = (cartoonBlue >> 1) + 7'd10;

            // Saturate/clamp so values do not wrap around
            if (redTemp > 7'd31)
                newRed = 5'd31;
            else
                newRed = redTemp[4:0];

            if (greenTemp > 8'd63)
                newGreen = 6'd63;
            else
                newGreen = greenTemp[5:0];

            if (blueTemp > 7'd31)
                newBlue = 5'd31;
            else
                newBlue = blueTemp[4:0];

            ProcessesData = {newRed, newGreen, newBlue};
        end
        2'b11 : ProcessesData = ~data;
        default: ProcessesData = data;
    endcase 
end

// the camera module is blindly send pixel to this buffer
// and it would take care of everything
async_fifo mediator (
    // input to the fifo
    .wr_clk(pclkTOP),
    .wr_rst(reset),
    .wr_en(enable),
    .din(ProcessesData),
    .full(), // we probably wont need this because the camera
             // is way slower than the sdram 25 mhz vs 100mhz 

    // output to the fifo
    .rd_clk(clk_100m),
    .rd_rst(reset),      // Separate Read Reset
    .rd_en(enablefifo2sdram),
    .dout(async2SDRAM),
    .empty(asyncEMPTY)
    //.almost_empty() // dont think we need this seems useless to me
);

// add the filler before the async fifo so the pixel going into the thing is already changed 

logic wr_en = 0;
logic wr_ack;
logic [15:0] row;
logic [15:0] col;
assign enablefifo2sdram = !asyncEMPTY && !wr_en;

always @(posedge clk_100m) begin
    // the wr_en (write enable) should be 1 
    //until the write is received, which is when wr_ack is 1
    // wr_en needs to be 0 most of the time
    wr_en <= wr_en & ~wr_ack;
    if(enablefifo2sdram) begin // fifo has data and we are not writing to sdram
        //enablefifo2sdram = 1;
        wr_en <= 1; 
        if(col >= 319) begin
            col <= 0;
            if(row >= 239) begin 
                row <= 0;
                sdramADDRESS <= 0;
            end else begin 
                row <= row + 1;
                sdramADDRESS <= sdramADDRESS + 161; // the empty pixel for now 
            end
        end else begin 
            col <= col + 1;
            sdramADDRESS <= sdramADDRESS + 1;
        end 
        // if(sdramADDRESS >= 76799) begin
        //     sdramADDRESS <= 0;
        // end else begin
        // sdramADDRESS <= sdramADDRESS + 1; // new address counter because of speed difference
        // end
    end //else begin
    //     enablefifo2sdram = 0;
    // end
end

icesugar_pro_lcd_fb SDRAMWRITE (
    .clk_25m(clkTOP),
    // .rst(resetEN),
    .wr_en(wr_en),
    .wr_addr(sdramADDRESS),
    .wr_data(async2SDRAM),
    .sdram_clk(sdram_clk),
    .sdram_cke(sdram_cke),
    .sdram_cs_n(sdram_cs_n),
    .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n),
    .sdram_we_n(sdram_we_n),
    .sdram_ba(sdram_ba),
    .sdram_a(sdram_a),
    .sdram_dqm(sdram_dqm),
    .sdram_dq(sdram_dq),
    
    .lcd_r(lcdr),
    .lcd_g(lcdg),
    .lcd_b(lcdb),
    .lcd_clk(lcdCLK),
    .lcd_de(de),

    .lcd_hsync(hsync4SCREEN),
    .lcd_vsync(vsync4SCREEN),
    
    // new ack thing
    .wr_ack(wr_ack),
    .clk_100m(clk_100m), 
    .locked(locked),

    // sdram spi stuff
    .PICO_Trigger(PICOTriggerTOP),
    .ready4_NextPixel(NEXTpixel_ready),
    .dataGOING_2_SPI(SDRAM_2_SPI)
);

    // logic [7:0]  pixel_half;
    // logic [23:0] pixel_addr;
    // logic        pixel_wr_en;

endmodule
