

module SPI_Slave(

input logic clk,
input logic SCK, 
input logic CS,
input logic MOSI,
input logic [15:0] dataFromFPGA,

output logic PICOTrigger,
output logic MISO,
output logic flag_next_pixel_ready
);



 
//CS = CS
// sync SCK to the FPGA clock using a 3-bit shift register
reg [2:0] SCKr;  always @(posedge clk) SCKr <= {SCKr[1:0], SCK};
wire SCK_risingedge = (SCKr[2:1]==2'b01);  // now we can detect SCK rising edges
wire SCK_fallingedge = (SCKr[2:1]==2'b10);  // and falling edges

// same thing for CS which is CS
reg [2:0] CSr;  always @(posedge clk) CSr <= {CSr[1:0], CS};
wire CS_active = ~CSr[1];  // CS is active low
wire CS_startmessage = (CSr[2:1]==2'b10);  // message starts at falling edge
wire CS_endmessage = (CSr[2:1]==2'b01);  // message stops at rising edge

// and for MOSI
reg [1:0] MOSIr;  always @(posedge clk) MOSIr <= {MOSIr[0], MOSI};
wire MOSI_data = MOSIr[1];

// we handle SPI in 8-bit format, so we need a 3 bits counter to count the bits as they come in
reg [2:0] bitcnt;



logic byte_received;  // high when a byte has been received
logic [7:0] byte_data_received;

//RX this is the part that receives from pico 

//0x01 lands → ON
//holds itself ON the whole send
//CS goes high after image → OFF
logic TRigger = 0;
always @(posedge clk)
begin
  if(~CS_active)  // CS High
    bitcnt <= 3'b000;
  else if(SCK_risingedge)
  begin
    bitcnt <= bitcnt + 3'b001;
    // implement a shift-left register (since we receive the data MSB first)
    byte_data_received <= {byte_data_received[6:0], MOSI_data}; //shift register
  end
end


logic still_going;
always @(posedge clk) begin
  byte_received <= CS_active && SCK_risingedge && (bitcnt==3'b111); // bitcnt goes up the 0-7 to count how many bits we received 
  // byte data is the actual data we got which it should be one
  if (byte_received && byte_data_received == 8'h01) begin
    TRigger <= 1; 
  end else if (TRigger && flag_next_pixel_ready) begin
    still_going <= 1;
  end
  if(CS_endmessage && still_going) begin
    still_going <= 0;
    TRigger <= 0;
  end
end 
assign PICOTrigger = TRigger;
// we use the LSB of the data received to control an LED
// reg LED;
// always @(posedge clk) if(byte_received) LED <= byte_data_received[0];

// so we load data from the fpga as the input and then we do 
// like shifting register and send it out 1 by 1 via the MISO

reg [15:0] byte_data_sent;
reg [15:0] cnt;
// always @(posedge clk) if(CS_startmessage) cnt<=cnt+8'h1;  // count the messages
// sending the image back to the pico, 


//spi slave also have to count to 16 so that once we are done we have to send a next pixel ready  


always @(posedge clk) begin
    flag_next_pixel_ready <= 0;
    if(~CS_active) begin //inital pixel loading
      byte_data_sent <= dataFromFPGA;
      cnt <= 0;
      flag_next_pixel_ready <= 0;
    end else if(SCK_fallingedge) begin
      if(cnt <= 14) begin // 14 because before first edge 15 is already loaded
        byte_data_sent <= byte_data_sent << 1;
        flag_next_pixel_ready <= 0;
        cnt <= cnt + 1;
      end else begin
        flag_next_pixel_ready <= 1;
        byte_data_sent <= dataFromFPGA;
        cnt <= 0;
      end 
   end
end
// byte_data_sent[14:0] — takes the bottom 15 bits of the 16-bit register 
// (bits 14 down to 0). Drops bit 15 (the old MSB).
// Everything moves up one position. The old MSB (b15) falls off and is lost. 
// A 0 fills in at the bottom (LSB). 
// That's a shift left by 1, with 0 padding in.
// 1'b0 — a single 0 bit.
// { ... , ... } — concatenates them: 15 bits + 1 bit = 16 bits. The 15 bits go on top, the 0 goes at the bottom.

// miso only sends either 0 or 1 at a time


assign MISO = byte_data_sent[15];  // send MSB first

// we assume that there is only one slave on the SPI bus
// so we don't bother with a tri-state buffer for MISO
// otherwise we would need to tri-state MISO when CS is inactive

endmodule