// icache.sv — 指令缓存 [A]（第 8 周接入，当前仅定义接口，顶层未例化）
// TODO: 数据/标签阵列用 sram_fakeram；缺失时通过 mem_* 向 axi_master 发起读。
module icache
  import cpu_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // ifu 侧
  input  logic        fetch_valid,
  input  logic [31:0] fetch_addr,
  output logic        fetch_ready,
  output logic        resp_valid,
  output logic [31:0] resp_data,

  // axi_master 侧（只读）
  output logic        mem_req_valid,
  output logic [31:0] mem_req_addr,
  input  logic        mem_req_ready,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  assign fetch_ready   = 1'b0;
  assign resp_valid    = 1'b0;
  assign resp_data     = '0;
  assign mem_req_valid = 1'b0;
  assign mem_req_addr  = '0;

endmodule
