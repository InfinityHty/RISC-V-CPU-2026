// ifu.sv — 取指单元 [A]
// TODO: PC 生成、对接分支预测与 icache、冲刷时重定向。
// 当前骨架：所有输出空闲。
module ifu
  import cpu_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // 误预测冲刷（rob → ifu）
  input  flush_t      flush,

  // 取出的指令（ifu → decode）
  output logic        instr_valid,
  input  logic        instr_ready,
  output logic [31:0] instr_pc,
  output logic [31:0] instr_data,

  // 取指访存请求（ifu → axi_master，只读；接入 icache 后改为对 icache）
  output logic        mem_req_valid,
  output logic [31:0] mem_req_addr,
  input  logic        mem_req_ready,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  assign instr_valid  = 1'b0;
  assign instr_pc     = '0;
  assign instr_data   = '0;
  assign mem_req_valid = 1'b0;
  assign mem_req_addr  = '0;

endmodule
