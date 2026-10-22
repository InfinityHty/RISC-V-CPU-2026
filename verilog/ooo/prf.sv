// prf.sv — 物理寄存器堆 [A]
// TODO: PRF_SIZE 项寄存器堆；CDB 写端口；2 个组合读端口供 rs 发射时取操作数。
// 当前骨架：读数据恒 0。
module prf
  import cpu_pkg::*;
(
  input  logic              clk,
  input  logic              rst,

  // CDB 写回（cdb → prf）
  input  cdb_t              cdb,

  // 读端口（rs 发射时使用）
  input  logic [TAG_W-1:0]  raddr1,
  input  logic [TAG_W-1:0]  raddr2,
  output logic [31:0]       rdata1,
  output logic [31:0]       rdata2
);

  assign rdata1 = '0;
  assign rdata2 = '0;

endmodule
