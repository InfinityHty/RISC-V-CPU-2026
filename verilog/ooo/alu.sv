// alu.sv — 整数 ALU [B]
// TODO: 全部整数算术/逻辑/移位、分支条件判断与误预测检测，
// LUI/AUIPC/JAL/JALR 地址计算，单周期完成。
// 当前骨架：输出空闲。
import cpu_pkg::*;

module alu
(
  input  logic   clk,
  input  logic   rst,

  input  logic   issue_valid,
  output logic   issue_ready,
  input  cpu_pkg::issue_t issue_pkt,

  output cpu_pkg::cdb_t   result_pkt,
  input  logic   result_ready
);

  assign issue_ready = 1'b0;
  assign result_pkt  = '0;

endmodule
