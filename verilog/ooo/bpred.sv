// bpred.sv — 分支预测器 [A]（第 9 周接入，当前仅定义接口，顶层未例化）
// TODO: BTB + BHT（2-bit 计数器起步）；执行侧通过 update_* 回写真实结果。
module bpred
  import cpu_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // 预测查询（ifu）
  input  logic [31:0] pc,
  output logic        pred_taken,
  output logic [31:0] pred_target,

  // 结果回写（分支执行完成后）
  input  logic        update_valid,
  input  logic [31:0] update_pc,
  input  logic        update_taken,
  input  logic [31:0] update_target
);

  assign pred_taken  = 1'b0;
  assign pred_target = '0;

endmodule
