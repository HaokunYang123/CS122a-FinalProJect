`include "asych_fifo.sv"
`include "lcd_fb.sv"
`include "lcd_timing.sv"
`include "ecspll.sv"
`include "SDRAM.sv"
`include "OV7670cameraSM.sv"
module top (

    input logic clkTOP,
    input logic PICOTriggerTOP,
    
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
logic [23:0] sdramADDRESS; // the faster clock

logic enable;
logic enableCAM2fifo;
logic [15:0] data;
logic [15:0] async2SDRAM;
logic ack;

// updated fpga sdram from allan knight 
logic locked;
wire reset = ~locked;
logic clk_100m;
camera cameraMOD (

    //input into the cam
    .D_data(DataComeTOP),
    //.ack(ack),
    .clk(clkTOP),
    .vsync(vsyncTOP),
    .href(hrefTOP),
    .pclk(pclkTOP),
    .captureInstructonFromPico(PICOTriggerTOP),

    //in and out from the cam
    .siod(sio_dTOP),

    //output from the cam
    .xclk(xclkTOP),
    .reset(reset_TOP),
    .sioc(sio_cTOP),
    .pwdn(pwdn_TOP),
    .w_data(data),
    .w_en(enable),
    .w_address(address), // not needed
    .done1(doneTOP) //not needed 
);

logic asyncEMPTY;
logic enablefifo2sdram;


// the camera module is blindly send pixel to this buffer
// and it would take care of everything
async_fifo mediator (
    // input to the fifo
    .wr_clk(pclkTOP),
    .wr_rst(reset),
    .wr_en(enable),
    .din(data),
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
logic wr_en = 0;
logic wr_ack;
assign enablefifo2sdram = !asyncEMPTY && !wr_en;
always @(posedge clk_100m) begin
    // the wr_en (write enable) should be 1 
    //until the write is received, which is when wr_ack is 1
    // wr_en needs to be 0 most of the time
    wr_en <= wr_en & ~wr_ack;
    if(enablefifo2sdram) begin // fifo has data and we are not writing to sdram
        //enablefifo2sdram = 1;
        wr_en <= 1; 
        if(sdramADDRESS >= 76799) begin
            sdramADDRESS <= 0;
        end else begin
        
        sdramADDRESS <= sdramADDRESS + 1; // new address counter because of speed difference
        end
    end //else begin
    //     enablefifo2sdram = 0;

    // end

end

icesugar_pro_lcd_fb SDRAMWRITE (
    .clk_25m(clkTOP),
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
    .locked(locked)
);
    // logic [7:0]  pixel_half;
    // logic [23:0] pixel_addr;
    // logic        pixel_wr_en;

endmodule