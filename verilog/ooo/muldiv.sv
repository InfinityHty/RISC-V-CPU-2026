// muldiv.sv — M 扩展乘除法器 [B]
// TODO: MUL/MULH/MULHSU/MULHU（建议流水化），DIV/DIVU/REM/REMU（多周期迭代）。
// 当前骨架：输出空闲。
module muldiv
  import cpu_pkg::*;
(
  input  logic   clk,
  input  logic   rst,

  input  logic   issue_valid,
  output logic   issue_ready,
  input  issue_t issue_pkt,

  output cdb_t   result_pkt,
  input  logic   result_ready
);

  assign issue_ready = 1'b0;
  assign result_pkt  = '0;

endmodule
