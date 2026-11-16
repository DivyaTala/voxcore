// 8-bit GPIO with an APB slave interface. Inputs are synchronised (async pins).
//   0x0 IN   R
//   0x4 OUT  RW
module gpio_apb (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    input  logic [7:0]  gpio_in,
    output logic [7:0]  gpio_out
);
    logic [7:0] in_s1, in_s2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin in_s1 <= '0; in_s2 <= '0; gpio_out <= '0; end
        else begin
            in_s1 <= gpio_in; in_s2 <= in_s1;
            if (psel && penable && pwrite && paddr[3:2] == 2'd1) gpio_out <= pwdata[7:0];
        end
    end
    assign pready = 1'b1;
    assign prdata = (paddr[3:2] == 2'd0) ? {24'd0, in_s2} : {24'd0, gpio_out};
endmodule
