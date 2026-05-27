module dp_buffer #(
    parameter DEPTH = 256,
    parameter WIDTH = 16,
    parameter ADDR_W = $clog2(DEPTH)
) (
    input  logic clk,

    // Write port
    input  logic we,
    input  logic [ADDR_W-1:0] waddr,
    input  logic [WIDTH-1:0]  wdata,

    // Read port
    input  logic [ADDR_W-1:0] raddr,
    output logic [WIDTH-1:0]  rdata
);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [ADDR_W-1:0] prev_waddr ;
    always_ff @(posedge clk ) begin
        if (prev_waddr != waddr && we)begin
            mem[waddr] <= wdata;
            prev_waddr <= waddr;
        end
        rdata <= mem[raddr];  // synchronous read → EBR
    end

endmodule