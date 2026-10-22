// student_top.sv — top level (course-fixed ports), wiring only.
// Instantiates axi_bus + ifetch + pipe_core for the 5-stage pipeline milestone.
module student_top (
    input  wire        clock,
    input  wire        reset,    // Active-high, held high for 5 cycles during initialization

    // AXI4-Lite Read Address Channel (AR)
    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,

    // AXI4-Lite Read Data Channel (R)
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,    // 2'b00 = OKAY, 2'b10 = SLVERR, 2'b11 = DECERR
    input  wire        rvalid,
    output wire        rready,

    // AXI4-Lite Write Address Channel (AW)
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,

    // AXI4-Lite Write Data Channel (W)
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,    // Byte write enable mask
    output wire        wvalid,
    input  wire        wready,

    // AXI4-Lite Write Response Channel (B)
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);

    logic clk, rst;
    assign clk = clock;
    assign rst = reset;

    // ifetch <-> axi_bus
    logic        if_req_valid, if_req_ready, if_epoch;
    logic [31:0] if_req_addr;
    logic        if_resp_valid;
    logic [31:0] if_resp_data;

    // pipe_core <-> axi_bus
    logic        ld_req_valid, ld_req_ready, ld_resp_valid;
    logic [31:0] ld_req_addr, ld_resp_data;
    logic        st_req_valid, st_req_ready, st_resp_valid;
    logic [31:0] st_req_addr, st_req_wdata;
    logic [3:0]  st_req_wstrb;

    // ifetch <-> pipe_core
    logic        if_out_valid, if_out_ready;
    logic [31:0] if_out_pc, if_out_instr;
    logic        redirect_valid;
    logic [31:0] redirect_pc;

    axi_bus u_axi_bus (
        .clk           (clk),
        .rst           (rst),
        .if_req_valid  (if_req_valid),
        .if_req_ready  (if_req_ready),
        .if_req_addr   (if_req_addr),
        .if_epoch      (if_epoch),
        .if_resp_valid (if_resp_valid),
        .if_resp_data  (if_resp_data),
        .ld_req_valid  (ld_req_valid),
        .ld_req_ready  (ld_req_ready),
        .ld_req_addr   (ld_req_addr),
        .ld_resp_valid (ld_resp_valid),
        .ld_resp_data  (ld_resp_data),
        .st_req_valid  (st_req_valid),
        .st_req_ready  (st_req_ready),
        .st_req_addr   (st_req_addr),
        .st_req_wdata  (st_req_wdata),
        .st_req_wstrb  (st_req_wstrb),
        .st_resp_valid (st_resp_valid),
        .araddr        (araddr),
        .arvalid       (arvalid),
        .arready       (arready),
        .rdata         (rdata),
        .rresp         (rresp),
        .rvalid        (rvalid),
        .rready        (rready),
        .awaddr        (awaddr),
        .awvalid       (awvalid),
        .awready       (awready),
        .wdata         (wdata),
        .wstrb         (wstrb),
        .wvalid        (wvalid),
        .wready        (wready),
        .bresp         (bresp),
        .bvalid        (bvalid),
        .bready        (bready)
    );

    ifetch u_ifetch (
        .clk            (clk),
        .rst            (rst),
        .redirect_valid (redirect_valid),
        .redirect_pc    (redirect_pc),
        .if_req_valid   (if_req_valid),
        .if_req_ready   (if_req_ready),
        .if_req_addr    (if_req_addr),
        .if_epoch       (if_epoch),
        .if_resp_valid  (if_resp_valid),
        .if_resp_data   (if_resp_data),
        .out_valid      (if_out_valid),
        .out_ready      (if_out_ready),
        .out_pc         (if_out_pc),
        .out_instr      (if_out_instr)
    );

    pipe_core u_pipe_core (
        .clk            (clk),
        .rst            (rst),
        .if_out_valid   (if_out_valid),
        .if_out_ready   (if_out_ready),
        .if_out_pc      (if_out_pc),
        .if_out_instr   (if_out_instr),
        .redirect_valid (redirect_valid),
        .redirect_pc    (redirect_pc),
        .ld_req_valid   (ld_req_valid),
        .ld_req_ready   (ld_req_ready),
        .ld_req_addr    (ld_req_addr),
        .ld_resp_valid  (ld_resp_valid),
        .ld_resp_data   (ld_resp_data),
        .st_req_valid   (st_req_valid),
        .st_req_ready   (st_req_ready),
        .st_req_addr    (st_req_addr),
        .st_req_wdata   (st_req_wdata),
        .st_req_wstrb   (st_req_wstrb),
        .st_resp_valid  (st_resp_valid)
    );

endmodule
