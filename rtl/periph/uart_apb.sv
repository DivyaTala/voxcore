// UART transmitter (8N1) with an APB slave interface.
//   0x0 TXDATA  W  : write a byte to send (ignored while busy)
//   0x4 STATUS  R  : bit0 = tx busy
//   0x8 DIV     RW : clocks per bit
module uart_apb (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [11:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        uart_tx
);
    logic [15:0] div;
    logic [15:0] baud_cnt;
    logic [3:0]  bit_cnt;
    logic [9:0]  shifter;   // {stop, data[7:0], start}
    logic        busy;

    assign pready = 1'b1;
    wire wr = psel && penable && pwrite;

    always_comb begin
        case (paddr[3:2])
            2'd1:    prdata = {31'd0, busy};
            2'd2:    prdata = {16'd0, div};
            default: prdata = '0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div <= 16'd434; baud_cnt <= '0; bit_cnt <= '0; shifter <= '1; busy <= 1'b0; uart_tx <= 1'b1;
        end else begin
            if (wr && paddr[3:2] == 2'd2) div <= pwdata[15:0];
            if (!busy) begin
                if (wr && paddr[3:2] == 2'd0) begin
                    shifter <= {1'b1, pwdata[7:0], 1'b0};
                    busy <= 1'b1; bit_cnt <= '0; baud_cnt <= '0;
                end
            end else if (baud_cnt == 16'd0) begin
                uart_tx  <= shifter[0];
                shifter  <= {1'b1, shifter[9:1]};
                baud_cnt <= div - 16'd1;
                if (bit_cnt == 4'd10) begin busy <= 1'b0; uart_tx <= 1'b1; end
                bit_cnt  <= bit_cnt + 4'd1;
            end else begin
                baud_cnt <= baud_cnt - 16'd1;
            end
        end
    end
endmodule
