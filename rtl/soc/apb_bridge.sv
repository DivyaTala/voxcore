// PicoRV32 native memory interface -> AMBA APB3 master, with address decode
// for up to 4 slaves (4 KB each) at 0x1000_0000 + 0x1000*n.
// APB timing: SETUP (psel=1, penable=0) -> ACCESS (penable=1) until pready.
module apb_bridge (
    input  logic        clk,
    input  logic        rst_n,
    // from CPU (already decoded as a peripheral access)
    input  logic        req,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    input  logic [3:0]  wstrb,
    output logic        ready,
    output logic [31:0] rdata,
    // APB master
    output logic [3:0]  psel,
    output logic        penable,
    output logic        pwrite,
    output logic [11:0] paddr,
    output logic [31:0] pwdata,
    input  logic [31:0] prdata [4],
    input  logic [3:0]  pready
);
    typedef enum logic [1:0] { IDLE, SETUP, ACCESS } st_t;
    st_t st;
    logic [1:0] slv;

    assign slv     = addr[13:12];
    assign paddr   = addr[11:0];
    assign pwdata  = wdata;
    assign pwrite  = |wstrb;
    assign penable = (st == ACCESS);
    always_comb begin
        psel = '0;
        if (st != IDLE) psel[slv] = 1'b1;
    end
    assign ready = (st == ACCESS) && pready[slv];
    assign rdata = prdata[slv];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= IDLE;
        else case (st)
            IDLE:   if (req) st <= SETUP;
            SETUP:  st <= ACCESS;
            ACCESS: if (pready[slv]) st <= IDLE;
            default: st <= IDLE;
        endcase
    end
endmodule
