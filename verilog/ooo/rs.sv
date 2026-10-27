// rs.sv — 保留站 [B]
// TODO: 接收 dispatch_t，监听 CDB 唤醒操作数，就绪后经 prf 取值，
// 按 FU 类型发射 issue_t；冲刷时清空。
// 当前骨架：所有输出空闲。
import cpu_pkg::*;

module rs
(
  input  logic        clk,
  input  logic        rst,

  // 发射输入（rename → rs）
  input  logic        disp_valid,
  output logic        disp_ready,
  input  cpu_pkg::dispatch_t   disp_pkt,

  // CDB 唤醒（cdb → rs）
  input  cpu_pkg::cdb_t        cdb,

  // 误预测冲刷（rob → rs）
  input  cpu_pkg::flush_t      flush,

  // PRF 读端口（发射时取操作数）
  output logic [TAG_W-1:0] prf_raddr1,
  output logic [TAG_W-1:0] prf_raddr2,
  input  logic [31:0]      prf_rdata1,
  input  logic [31:0]      prf_rdata2,

  // 发射到各 FU
  output logic        alu_issue_valid,
  input  logic        alu_issue_ready,
  output cpu_pkg::issue_t      alu_issue_pkt,
  output logic        mul_issue_valid,
  input  logic        mul_issue_ready,
  output cpu_pkg::issue_t      mul_issue_pkt,
  output logic        lsu_issue_valid,
  input  logic        lsu_issue_ready,
  output cpu_pkg::issue_t      lsu_issue_pkt
);

  assign disp_ready      = 1'b0;
  assign prf_raddr1      = '0;
  assign prf_raddr2      = '0;
  assign alu_issue_valid = 1'b0;
  assign alu_issue_pkt   = '0;
  assign mul_issue_valid = 1'b0;
  assign mul_issue_pkt   = '0;
  assign lsu_issue_valid = 1'b0;
  assign lsu_issue_pkt   = '0;

endmodule
