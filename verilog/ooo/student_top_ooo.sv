// student_top.sv — 顶层模块（两人共管，只做连线，不写逻辑）
// 端口为课程固定接口，禁止修改。
// 集成纪律：新增模块在这里例化并连线；跨模块信号命名见 docs/internal-interfaces.md。
module student_top
  import cpu_pkg::*;
(
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

  // ---------------- 跨模块信号 ----------------
  cdb_t    cdb_bus;       // cdb → rs / rob / lsu / prf 广播
  commit_t commit_bus;    // rob → lsu
  flush_t  flush_bus;     // rob → ifu / rename / rs / lsu

  // ifu → decode
  logic        if_instr_valid, if_instr_ready;
  logic [31:0] if_instr_pc, if_instr_data;
  // decode → rename
  logic      dec_valid, dec_ready;
  dispatch_t dec_pkt;
  // rename → rob
  logic                  rn_rob_valid, rn_rob_ready;
  dispatch_t             rn_rob_pkt;
  logic [ROB_IDX_W-1:0]  rob_alloc_idx;
  // rename → rs
  logic      rn_disp_valid, rs_disp_ready;
  dispatch_t rn_disp_pkt;
  // rs ↔ prf
  logic [TAG_W-1:0] rs_prf_raddr1, rs_prf_raddr2;
  logic [31:0]      prf_rdata1, prf_rdata2;
  // rs → FU
  logic   rs_alu_issue_valid, alu_issue_ready;
  issue_t rs_alu_issue_pkt;
  logic   rs_mul_issue_valid, mul_issue_ready;
  issue_t rs_mul_issue_pkt;
  logic   rs_lsu_issue_valid, lsu_issue_ready;
  issue_t rs_lsu_issue_pkt;
  // FU → cdb
  cdb_t  alu_result, mul_result, lsu_result;
  logic  alu_result_ready, mul_result_ready, lsu_result_ready;
  // lsu → dcache
  logic        lsu_mem_req_valid, lsu_mem_req_ready;
  logic [31:0] lsu_mem_req_addr, lsu_mem_req_wdata;
  logic [3:0]  lsu_mem_req_wstrb;
  logic        lsu_mem_req_write, lsu_mem_resp_valid;
  logic [31:0] lsu_mem_resp_data;
  // dcache → axi_master
  logic        dc_mem_req_valid, dc_mem_req_ready;
  logic [31:0] dc_mem_req_addr, dc_mem_req_wdata;
  logic [3:0]  dc_mem_req_wstrb;
  logic        dc_mem_req_write, dc_mem_resp_valid;
  logic [31:0] dc_mem_resp_data;
  // ifu → axi_master（只读）
  logic        if_mem_req_valid, if_mem_req_ready;
  logic [31:0] if_mem_req_addr, if_mem_resp_data;
  logic        if_mem_resp_valid;

  // ---------------- A 侧：前端 + 按序提交 ----------------
  ifu u_ifu (
    .clk           (clk),
    .rst           (rst),
    .flush         (flush_bus),
    .instr_valid   (if_instr_valid),
    .instr_ready   (if_instr_ready),
    .instr_pc      (if_instr_pc),
    .instr_data    (if_instr_data),
    .mem_req_valid (if_mem_req_valid),
    .mem_req_addr  (if_mem_req_addr),
    .mem_req_ready (if_mem_req_ready),
    .mem_resp_valid(if_mem_resp_valid),
    .mem_resp_data (if_mem_resp_data)
  );

  decode u_decode (
    .clk        (clk),
    .rst        (rst),
    .instr_valid(if_instr_valid),
    .instr_ready(if_instr_ready),
    .instr_pc   (if_instr_pc),
    .instr_data (if_instr_data),
    .dec_valid  (dec_valid),
    .dec_ready  (dec_ready),
    .dec_pkt    (dec_pkt)
  );

  rename u_rename (
    .clk            (clk),
    .rst            (rst),
    .dec_valid      (dec_valid),
    .dec_ready      (dec_ready),
    .dec_pkt        (dec_pkt),
    .rob_alloc_valid(rn_rob_valid),
    .rob_alloc_ready(rn_rob_ready),
    .rob_alloc_pkt  (rn_rob_pkt),
    .rob_alloc_idx  (rob_alloc_idx),
    .disp_valid     (rn_disp_valid),
    .disp_ready     (rs_disp_ready),
    .disp_pkt       (rn_disp_pkt),
    .flush          (flush_bus)
  );

  rob u_rob (
    .clk            (clk),
    .rst            (rst),
    .rob_alloc_valid(rn_rob_valid),
    .rob_alloc_ready(rn_rob_ready),
    .rob_alloc_pkt  (rn_rob_pkt),
    .rob_alloc_idx  (rob_alloc_idx),
    .cdb            (cdb_bus),
    .commit         (commit_bus),
    .flush          (flush_bus)
  );

  prf u_prf (
    .clk   (clk),
    .rst   (rst),
    .cdb   (cdb_bus),
    .raddr1(rs_prf_raddr1),
    .raddr2(rs_prf_raddr2),
    .rdata1(prf_rdata1),
    .rdata2(prf_rdata2)
  );

  // ---------------- B 侧：乱序执行 + 访存 ----------------
  rs u_rs (
    .clk            (clk),
    .rst            (rst),
    .disp_valid     (rn_disp_valid),
    .disp_ready     (rs_disp_ready),
    .disp_pkt       (rn_disp_pkt),
    .cdb            (cdb_bus),
    .flush          (flush_bus),
    .prf_raddr1     (rs_prf_raddr1),
    .prf_raddr2     (rs_prf_raddr2),
    .prf_rdata1     (prf_rdata1),
    .prf_rdata2     (prf_rdata2),
    .alu_issue_valid(rs_alu_issue_valid),
    .alu_issue_ready(alu_issue_ready),
    .alu_issue_pkt  (rs_alu_issue_pkt),
    .mul_issue_valid(rs_mul_issue_valid),
    .mul_issue_ready(mul_issue_ready),
    .mul_issue_pkt  (rs_mul_issue_pkt),
    .lsu_issue_valid(rs_lsu_issue_valid),
    .lsu_issue_ready(lsu_issue_ready),
    .lsu_issue_pkt  (rs_lsu_issue_pkt)
  );

  alu u_alu (
    .clk         (clk),
    .rst         (rst),
    .issue_valid (rs_alu_issue_valid),
    .issue_ready (alu_issue_ready),
    .issue_pkt   (rs_alu_issue_pkt),
    .result_pkt  (alu_result),
    .result_ready(alu_result_ready)
  );

  muldiv u_muldiv (
    .clk         (clk),
    .rst         (rst),
    .issue_valid (rs_mul_issue_valid),
    .issue_ready (mul_issue_ready),
    .issue_pkt   (rs_mul_issue_pkt),
    .result_pkt  (mul_result),
    .result_ready(mul_result_ready)
  );

  lsu u_lsu (
    .clk           (clk),
    .rst           (rst),
    .issue_valid   (rs_lsu_issue_valid),
    .issue_ready   (lsu_issue_ready),
    .issue_pkt     (rs_lsu_issue_pkt),
    .cdb           (cdb_bus),
    .commit        (commit_bus),
    .flush         (flush_bus),
    .result_pkt    (lsu_result),
    .result_ready  (lsu_result_ready),
    .mem_req_valid (lsu_mem_req_valid),
    .mem_req_ready (lsu_mem_req_ready),
    .mem_req_addr  (lsu_mem_req_addr),
    .mem_req_wdata (lsu_mem_req_wdata),
    .mem_req_wstrb (lsu_mem_req_wstrb),
    .mem_req_write (lsu_mem_req_write),
    .mem_resp_valid(lsu_mem_resp_valid),
    .mem_resp_data (lsu_mem_resp_data)
  );

  cdb u_cdb (
    .clk       (clk),
    .rst       (rst),
    .alu_result(alu_result),
    .alu_ready (alu_result_ready),
    .mul_result(mul_result),
    .mul_ready (mul_result_ready),
    .lsu_result(lsu_result),
    .lsu_ready (lsu_result_ready),
    .out       (cdb_bus)
  );

  dcache u_dcache (
    .clk           (clk),
    .rst           (rst),
    .req_valid     (lsu_mem_req_valid),
    .req_ready     (lsu_mem_req_ready),
    .req_addr      (lsu_mem_req_addr),
    .req_wdata     (lsu_mem_req_wdata),
    .req_wstrb     (lsu_mem_req_wstrb),
    .req_write     (lsu_mem_req_write),
    .resp_valid    (lsu_mem_resp_valid),
    .resp_data     (lsu_mem_resp_data),
    .mem_req_valid (dc_mem_req_valid),
    .mem_req_ready (dc_mem_req_ready),
    .mem_req_addr  (dc_mem_req_addr),
    .mem_req_wdata (dc_mem_req_wdata),
    .mem_req_wstrb (dc_mem_req_wstrb),
    .mem_req_write (dc_mem_req_write),
    .mem_resp_valid(dc_mem_resp_valid),
    .mem_resp_data (dc_mem_resp_data)
  );

  axi_master u_axi_master (
    .clk          (clk),
    .rst          (rst),
    .if_req_valid (if_mem_req_valid),
    .if_req_ready (if_mem_req_ready),
    .if_req_addr  (if_mem_req_addr),
    .if_resp_valid(if_mem_resp_valid),
    .if_resp_data (if_mem_resp_data),
    .dm_req_valid (dc_mem_req_valid),
    .dm_req_ready (dc_mem_req_ready),
    .dm_req_addr  (dc_mem_req_addr),
    .dm_req_wdata (dc_mem_req_wdata),
    .dm_req_wstrb (dc_mem_req_wstrb),
    .dm_req_write (dc_mem_req_write),
    .dm_resp_valid(dc_mem_resp_valid),
    .dm_resp_data (dc_mem_resp_data),
    .araddr (araddr),
    .arvalid(arvalid),
    .arready(arready),
    .rdata  (rdata),
    .rresp  (rresp),
    .rvalid (rvalid),
    .rready (rready),
    .awaddr (awaddr),
    .awvalid(awvalid),
    .awready(awready),
    .wdata  (wdata),
    .wstrb  (wstrb),
    .wvalid (wvalid),
    .wready (wready),
    .bresp  (bresp),
    .bvalid (bvalid),
    .bready (bready)
  );

endmodule
