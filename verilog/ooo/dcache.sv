// dcache.sv — 数据缓存 [B]
// TODO: 数据/标签阵列用 sram_fakeram（WRITE_GRANULARITY=8 支持字节写）；
// 缺失时经 mem_* 向 axi_master 发起行读写。
// 当前骨架：输出空闲。
module dcache
  import cpu_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // lsu 侧
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  input  logic        req_write,
  output logic        resp_valid,
  output logic [31:0] resp_data,

  // axi_master 侧
  output logic        mem_req_valid,
  input  logic        mem_req_ready,
  output logic [31:0] mem_req_addr,
  output logic [31:0] mem_req_wdata,
  output logic [3:0]  mem_req_wstrb,
  output logic        mem_req_write,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  assign req_ready     = 1'b0;
  assign resp_valid    = 1'b0;
  assign resp_data     = '0;
  assign mem_req_valid = 1'b0;
  assign mem_req_addr  = '0;
  assign mem_req_wdata = '0;
  assign mem_req_wstrb = '0;
  assign mem_req_write = 1'b0;

endmodule
