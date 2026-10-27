// muldiv.sv — M 扩展乘除法器 [B]
// TODO: MUL/MULH/MULHSU/MULHU（建议流水化），DIV/DIVU/REM/REMU（多周期迭代）。
// 当前骨架：输出空闲。
import cpu_pkg::*;

module muldiv
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
