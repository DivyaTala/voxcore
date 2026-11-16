// ============================================================================
// VoxCore SoC top
//
//   0x0000_0000  16 KB SRAM (firmware + data + stack)
//   0x1000_0000  UART      (APB slave 0)
//   0x1000_1000  GPIO      (APB slave 1)
//   0x1000_2000  VOICE     (APB slave 2: I2S + MFCC + NN)
//   custom-0     VC.MAC    (PCPI co-processor: vc.mac / vc.dot4 / ...)
// ============================================================================
module voxcore_top #(
    parameter string DATA_DIR = "../data/",
    parameter string FW_FILE  = "../fw/firmware.hex",
    parameter int    CPU_SEL  = 0,
    parameter bit    BP_EN    = 1'b1     // vc_rv32i branch prediction
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       i2s_sck,
    input  logic       i2s_ws,
    input  logic       i2s_sd,
    output logic       pdm_clk,    // PDM microphone clock (f_clk / PDM_DIV)
    input  logic       pdm_dat,    // PDM microphone data (1-bit sigma-delta stream)
    output logic       uart_tx,
    input  logic [7:0] gpio_in,
    output logic [7:0] gpio_out,
    output logic       trap
);
    // reset synchroniser (async assert, sync de-assert)
    logic [1:0] rst_sync;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) rst_sync <= '0; else rst_sync <= {rst_sync[0], 1'b1};
    wire srst_n = rst_sync[1];

    // ---- CPU: CPU_SEL = 0 -> vc_rv32i (own 5-stage pipeline, Harvard buses)
    //           CPU_SEL = 1 -> PicoRV32 (multi-cycle, single unified bus)
    // Both expose the same data bus (valid/ready) and the same PCPI port, so the
    // memory map, peripherals, VC.MAC unit and firmware binary are shared.
    logic        mem_valid, mem_ready;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic [3:0]  mem_wstrb;
    logic        imem_en; logic [31:0] imem_addr, imem_rdata;
    logic        pcpi_valid, pcpi_wr, pcpi_wait, pcpi_ready;
    logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2, pcpi_rd;
    logic        cpu_trap;

    generate if (CPU_SEL == 0) begin : g_vc_rv32i
        vc_rv32i #(.RESET_PC(32'h0000_0000), .BP_EN(BP_EN)) u_cpu (
            .clk, .rst_n(srst_n),
            .imem_en, .imem_addr, .imem_rdata,
            .dmem_valid(mem_valid), .dmem_addr(mem_addr), .dmem_wdata(mem_wdata),
            .dmem_wstrb(mem_wstrb), .dmem_ready(mem_ready), .dmem_rdata(mem_rdata),
            .pcpi_valid, .pcpi_insn, .pcpi_rs1, .pcpi_rs2, .pcpi_wr, .pcpi_rd, .pcpi_wait, .pcpi_ready,
            .trap(cpu_trap), .rvfi_valid(), .rvfi_pc(), .rvfi_insn(), .rvfi_rd(), .rvfi_rd_wdata());
    end else begin : g_picorv32
        assign imem_en = 1'b0; assign imem_addr = '0;
        picorv32 #(
            .ENABLE_COUNTERS(1), .ENABLE_REGS_DUALPORT(1), .BARREL_SHIFTER(1),
            .COMPRESSED_ISA(0), .ENABLE_MUL(0), .ENABLE_DIV(0), .ENABLE_IRQ(0),
            .ENABLE_PCPI(1),   // custom-0 instructions go to the VC.MAC co-processor
            .PROGADDR_RESET(32'h0000_0000), .STACKADDR(32'h0000_4000)
        ) u_cpu (
            .clk, .resetn(srst_n), .trap(cpu_trap),
            .mem_valid, .mem_instr(), .mem_ready, .mem_addr, .mem_wdata, .mem_wstrb, .mem_rdata,
            .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
            .pcpi_valid, .pcpi_insn, .pcpi_rs1, .pcpi_rs2,
            .pcpi_wr, .pcpi_rd, .pcpi_wait, .pcpi_ready,
            .irq(32'd0), .eoi(), .trace_valid(), .trace_data()
        );
    end endgenerate

    vc_mac_pcpi u_mac (.clk, .rst_n(srst_n), .pcpi_valid, .pcpi_insn, .pcpi_rs1, .pcpi_rs2,
                       .pcpi_wr, .pcpi_rd, .pcpi_wait, .pcpi_ready);

    wire is_ram    = mem_valid && (mem_addr[31:28] == 4'h0);
    wire is_periph = mem_valid && (mem_addr[31:28] == 4'h1);

    // ---- SRAM, dual port: A = instruction fetch (vc_rv32i), B = data (1-cycle latency)
    logic        ram_ready;
    logic [31:0] ram_rdata;
    vc_sram_dp_bw #(.DEPTH(4096), .INIT_FILE(FW_FILE)) u_ram (
        .clk,
        .en_a(imem_en), .addr_a(imem_addr[13:2]), .rdata_a(imem_rdata),
        .en_b(is_ram && !ram_ready), .wstrb_b(mem_wstrb), .addr_b(mem_addr[13:2]),
        .wdata_b(mem_wdata), .rdata_b(ram_rdata));
    always_ff @(posedge clk or negedge srst_n)
        if (!srst_n) ram_ready <= 1'b0; else ram_ready <= is_ram && !ram_ready;

    // ---- APB
    logic        apb_ready; logic [31:0] apb_rdata;
    logic [3:0]  psel; logic penable, pwrite; logic [11:0] paddr; logic [31:0] pwdata;
    logic [31:0] prdata [4]; logic [3:0] pready;
    apb_bridge u_bridge (
        .clk, .rst_n(srst_n), .req(is_periph && !apb_ready), .addr(mem_addr), .wdata(mem_wdata),
        .wstrb(mem_wstrb), .ready(apb_ready), .rdata(apb_rdata),
        .psel, .penable, .pwrite, .paddr, .pwdata, .prdata, .pready);

    uart_apb u_uart (.clk, .rst_n(srst_n), .psel(psel[0]), .penable, .pwrite, .paddr, .pwdata,
                     .prdata(prdata[0]), .pready(pready[0]), .uart_tx);
    gpio_apb u_gpio (.clk, .rst_n(srst_n), .psel(psel[1]), .penable, .pwrite, .paddr, .pwdata,
                     .prdata(prdata[1]), .pready(pready[1]), .gpio_in, .gpio_out);
    voice_apb #(.DATA_DIR(DATA_DIR)) u_voice (
        .clk, .rst_n(srst_n), .psel(psel[2]), .penable, .pwrite, .paddr, .pwdata,
        .prdata(prdata[2]), .pready(pready[2]), .i2s_sck, .i2s_ws, .i2s_sd, .pdm_clk, .pdm_dat);
    aes_apb u_aes (.clk, .rst_n(srst_n), .psel(psel[3]), .penable, .pwrite, .paddr, .pwdata,
                   .prdata(prdata[3]), .pready(pready[3]));   // AES-128 at 0x1000_3000

    assign trap      = cpu_trap;
    assign mem_ready = ram_ready || apb_ready;
    assign mem_rdata = ram_ready ? ram_rdata : apb_rdata;
endmodule
