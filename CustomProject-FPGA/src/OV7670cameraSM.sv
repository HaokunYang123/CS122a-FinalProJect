`include "OV7670MasterCommand.sv"

module camera
(
    input logic [7:0] D_data,
    input logic clk,
    input logic vsync,
    input logic href,
    input logic pclk,
    input logic captureInstructonFromPico,
    //input logic ready,

    // input logic ack,
    
    // input logic strobe, LED stuff
    inout logic siod,

    output logic xclk,
    output logic reset,
    output logic sioc,
    output logic pwdn,

    output logic [15:0] w_data,
    output logic w_en,
    output logic [23:0] w_address,
    output logic done1

);
    logic flagDone;
    logic [23:0] counter = 0;
    logic [1:0] counter2 = 0;
    logic [15:0] totalPixel;
    // logic sioc;
    // logic siod;
    logic ready;
    logic [7:0] row;
    logic [7:0] col;

    camera_configure cameraCONFIG(
        .clk(clk),
        .start(!ready),
        .sioc(sioc),
        .siod(siod),
        .done(ready)
    );

        typedef enum logic {Waiting, Capture} state_t;

        state_t state = Waiting;

    always @(posedge pclk) begin
        case (state)

        Waiting: begin
        
            w_en <= 0;
            flagDone <= 0;
            
            if(captureInstructonFromPico && ready) begin
                counter = 0;
                counter2 = 0;
                state <= Capture;
            end else begin
                // w_en <= 0;
                state <= Waiting; 
            end
        end

        Capture: begin 

            w_en <= 0;
            if(ready && href == 1 && vsync == 0) begin 
                // first we have to assemble the bytes.
                if(counter == 76800) begin
                    flagDone = 1; 
                    state <= Waiting;
                end else begin
                    flagDone = 0;
                    if(counter2 < 1) begin 
                        totalPixel[15:8] = D_data;
                        counter2 = counter2 + 1;
                    end else begin
                        totalPixel[7:0] = D_data;
                        counter2 = 0;
                        counter = counter + 1; 
                        w_en <= 1;
                        w_data <= totalPixel;
                    end
                end
            end
        end

        // bufferingLine:
        //     if(href == 1) begin
        //         state = Capture;
        //     end else begin
        //         state = Waiting;
        //     end
        default: begin
            w_en = 0;
            state <= Waiting;
            end
        endcase 
    end

    assign xclk = clk;
    assign w_address = counter;
    assign done1 = flagDone;
    assign reset = 1;
    assign pwdn = 0;

endmodule