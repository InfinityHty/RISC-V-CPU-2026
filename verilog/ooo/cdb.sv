// cdb.sv — 公共数据总线仲裁 [B]
// TODO: 在 alu / muldiv / lsu 三路结果间仲裁（建议固定优先级），
// 广播给 rs / rob / prf。
// 当前骨架：输出空闲。
import cpu_pkg::*;

module cdb
(
  input  logic  clk,
  input  logic  rst,

  input  cpu_pkg::cdb_t  alu_result,
  output logic  alu_ready,
  input  cpu_pkg::cdb_t  mul_result,
  output logic  mul_ready,
  input  cpu_pkg::cdb_t  lsu_result,
  output logic  lsu_ready,

  output cpu_pkg::cdb_t  out
);

  assign alu_ready = 1'b0;
  assign mul_ready = 1'b0;
  assign lsu_ready = 1'b0;
  assign out       = '0;

endmodule
