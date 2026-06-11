

module icesugar_pro_lcd_fb (
    // iCESugar-Pro 25MHz onboard clock (Pin P6)
    input  logic        clk_25m,       

    // IS42S16160B SDRAM Interface
    output logic        sdram_clk,
    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_a,
    output logic [1:0]  sdram_dqm,
    inout  logic [15:0] sdram_dq,

    // RGB LCD Interface (480x272)
    output logic        lcd_clk,
    output logic        lcd_hsync,
    output logic        lcd_vsync,
    output logic        lcd_de,
    output logic [4:0]  lcd_r,
    output logic [5:0]  lcd_g,
    output logic [4:0]  lcd_b,
    
    // CPU/GPU Write Interface (To draw to the screen)
    input  logic        wr_en,
    input  logic [23:0] wr_addr,       
    input  logic [15:0] wr_data,
    output logic        wr_ack,
    output logic        clk_100m,
    output logic        locked,

    // output for the spi from the sdram to the spi slaves 
    input logic PICO_Trigger,
    input logic ready4_NextPixel, // means that all 16 bit of the one pixel has been sent to the pico
    output logic [15:0] dataGOING_2_SPI

    //image processing modes
    // input logic [1:0] ModeSelect = 2'b00
);

    logic clk_sys;     // 100 MHz for SDRAM
    logic clk_pixel;   // 9 MHz for LCD
    //logic locked;
    logic rst = ~locked; 
    
    assign clk_100m = clk_sys;
    
    // --------------------------------------------------------
    // 1. Clocks
    // --------------------------------------------------------
    pll pll_inst (
        .clkin(clk_25m),
        .clkout0(clk_sys),
        .clkout1(clk_pixel),
        .locked(locked)
    );

    // Forward system clock to SDRAM
    ODDRX1F sdram_clk_forward (
        .SCLK(clk_sys),
        .RST(1'b0),
        .D0(1'b0),
        .D1(1'b1),
        .Q(sdram_clk)
    );
    
    // Forward pixel clock to LCD panel
    ODDRX1F lcd_clk_forward (
        .SCLK(clk_pixel),
        .RST(1'b0),
        .D0(1'b1),
        .D1(1'b0),
        .Q(lcd_clk)
    );

    assign sdram_cke = 1'b1;

    // --------------------------------------------------------
    // 2. Video Timing & RGB Output
    // --------------------------------------------------------
    logic        new_frame;
    logic [15:0] pixel_data;

    lcd_timing_480x272 timing_inst (
        .clk_pixel(clk_pixel),
        .rst(rst),
        .hsync(lcd_hsync),
        .vsync(lcd_vsync),
        .de(lcd_de),
        .new_frame(new_frame)
    );

    // Map the 16-bit FIFO output to RGB565 physical pins
    // assign lcd_r = pixel_data[15:11];
    // assign lcd_g = pixel_data[10:5];
    // assign lcd_b = pixel_data[4:0];
    // assign lcd_r = 5'b00000;
    // assign lcd_g = 6'b111111;
    // assign lcd_b = 5'b00000;
    // logic red [23:0] = {pixel_data[15:11], 3'b000};
    // logic green [23:0] = {pixel_data[10:5],  2'b00};
    // logic blue [23:0] = {pixel_data[4:0],   3'b000};
    // logic lcdRED [23:0];
    // logic lcdGREEN [23:0];
    // logic lcdBLUE [23:0];

    // this is brigher because of the padding for the 8 bits color 
    // always @(posedge pclk) begin
    //     if(ModeSelect == 2'b00) begin 
    //         lcdRED = red;
    //         lcdGREEN = green;
    //         lcdBLUE = blue;
    //     end else if (ModeSelect == 2'b01) begin

    //         //grayscale
    //         logic [23:0] lcdGRAYSCALE_red = (red >> 14) & 0x1F;
    //         logic [23:0] lcdGRAYSCALE_green = (green >> 7) & 0x3F;
    //         logic [23:0] lcdGRAYSCALE_blue = (blue >> 3) & 0x1F;
    //         lcdRED = lcdGRAYSCALE_red << 3;
    //         lcdGREEN = lcdGRAYSCALE_green << 2;
    //         lcdBLUE = lcdGRAYSCALE_blue << 3;
    //     end else if (ModeSelect == 2'b10) begin

    //         //threshold
    //         logic [23:0] lcdTHRESHOLD_red = (red >> 14) & 0x1F;
    //         logic [23:0] lcdTHRESHOLD_green = (green >> 14) & 0x1F;
    //         logic [23:0] lcdTHRESHOLD_blue= (blue >> 14) & 0x1F;
            
    //     end else begin
    //         lcdRED = {pixel_data[15:11], 3'b000};
    //         lcdGREEN = {pixel_data[10:5], 2'b00};
    //         lcdBLUE = {pixel_data[4:0], 3'b000};
    //     end
    // end

    assign lcd_r = pixel_data[15:11];
    assign lcd_g = pixel_data[10:5];
    assign lcd_b = pixel_data[4:0];

    // --------------------------------------------------------
    // 3. Clock Domain Crossing FIFO
    // --------------------------------------------------------
    logic        rd_req;
    logic        rd_ack;
    logic [15:0] rd_data;
    logic        rd_data_valid;
    logic        fifo_almost_empty;
    

    async_fifo #(
        .DATA_WIDTH(16),
        .ADDR_WIDTH(9),            // 512 words
        .ALMOST_EMPTY_THRESH(64)   // Request data early to prevent underflow
    ) video_fifo (
        .wr_clk(clk_sys),
        .wr_rst(rst || new_frame_sys_2),
        .wr_en(rd_data_valid),
        .din(rd_data),

        .rd_clk(clk_pixel),
        .rd_rst(rst || new_frame),
        .rd_en(lcd_de),            // Pop a pixel from FIFO only when actively drawing
        .dout(pixel_data),
        .empty(),                  // Ignored, visually manifests as black screen if it occurs
        .almost_empty(fifo_almost_empty)
    );

    // --------------------------------------------------------
    // 4. SDRAM Read Address Generator
    // --------------------------------------------------------
    // We must track where we are in memory to supply the FIFO
    reg [23:0] sdram_rd_addr;
    
    // Cross the new_frame signal from clk_pixel to clk_sys domain
    reg new_frame_sys_1, new_frame_sys_2;
    always @(posedge clk_sys) begin
        new_frame_sys_1 <= new_frame;
        new_frame_sys_2 <= new_frame_sys_1;
    end

    always @(posedge clk_sys or posedge rst) begin
        if (rst) begin
            sdram_rd_addr <= 24'd0;
        end else begin
            // Reset address pointer at the start of a new frame
            if (new_frame_sys_2) begin
                sdram_rd_addr <= 24'd0;
            end 
            // Increment address pointer whenever the SDRAM accepts a read request
            else if (rd_ack) begin
                sdram_rd_addr <= sdram_rd_addr + 1'b1;
            end
        end
    end

    // --------------------------------------------------------
    // 5. SDRAM Controller Engine
    // --------------------------------------------------------
    // logic [23:0] LCD_Address_request;
    // logic [23:0] spi_Address_request;
    logic [23:0] SPI_rd_addr = 0;
    logic [23:0] rd_addr;
    // logic requestPixel;
    // condition ? expression_if_true : expression_if_false;

    logic [15:0] row;
    logic [15:0] col;
    logic JumpStart;
    // logic flag_next_pixel_ready;
    always @(posedge clk_100m) begin
        if(PICO_Trigger) begin
            JumpStart <= 1;
            if(rd_data_valid) begin 
                dataGOING_2_SPI <= rd_data;
            end
            if(ready4Pixel) begin
                if(col >= 319) begin
                col <= 0;
                if(row >= 239) begin 
                    row <= 0;
                    SPI_rd_addr <= 0;
                end else begin 
                    row <= row + 1;
                    // flag_next_pixel_ready = 1;
                    SPI_rd_addr <= SPI_rd_addr + 161; // the empty pixel for now 
                end
                end else begin 
                    col <= col + 1;
                    SPI_rd_addr <= SPI_rd_addr + 1;
                end 
            end
        end else begin
            SPI_rd_addr <= 0;
            row <= 0;
            col <= 0;
        end
    end
    // rd_valid is the data coming back. 
    // The controller asserts it a few cycles later when the pixel 
    // is actually on rd_data. SO its bascially a check saying that the 
    // pixel is on the rd_data ready to be sent 



    //so because the MISO is much slower than the sdram clk, 
    //we need a flag that tells us that when a pixel is sent to 
    //the pico before the next request

    logic R1;
    logic R2;
    logic ready4Pixel;
    logic [1:0] count;
    always @(posedge clk_sys) begin
        R1 <= ready4_NextPixel; // figure out how this two reg stablize (must learn)
        R2 <= R1; 
    end

    assign ready4Pixel = R1 & ~R2; // prevent metastabilty and 

    always @(posedge clk_100m) begin
        if (!PICO_Trigger) begin
            count <= 0;
        end else if(count < 1) begin
        count <= count + 1;
        end
    end


    always @(*) begin
        if(PICO_Trigger) begin
            rd_addr = SPI_rd_addr;
            rd_req  = (count < 1) ? 1 : ready4Pixel;   // first cycle kicks, then pace // request the 16 bit pixel at 100mhz clock rate 
        end else begin
            rd_addr = sdram_rd_addr;
            rd_req = fifo_almost_empty;
        end
    end

    // Request data from SDRAM when FIFO space is available
 

    sdram_controller sdram_ctrl_inst (
        .clk(clk_sys),
        .rst(rst),
        
        .wr_req(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .wr_ack(wr_ack),
        
        .rd_req(rd_req), // when we want a pixel
        .rd_addr(rd_addr),   // Continuous address stream
        .rd_data(rd_data), // the pixel data 
        .rd_valid(rd_data_valid), // the pixel is on the rd_data now  (Later pulse)
        .rd_ack(rd_ack), // request taken, advance your address (early pulse)

        .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba),
        .sdram_a(sdram_a),
        .sdram_dqm(sdram_dqm),
        .sdram_dq(sdram_dq)
    );

endmodule