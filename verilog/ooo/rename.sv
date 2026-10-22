// rename.sv — 寄存器重命名 [A]
// TODO: 重命名 RAT、free list；向 rob 申请表项、填物理寄存器号后发射到 rs；
// 冲刷时按 ROB 提交点恢复 RAT。
// 当前骨架：所有输出空闲。
module rename
  import cpu_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // 译码输入（decode → rename）
  input  logic        dec_valid,
  output logic        dec_ready,
  input  dispatch_t   dec_pkt,

  // ROB 表项申请（rename → rob）
  output logic        rob_alloc_valid,
  input  logic        rob_alloc_ready,
  output dispatch_t   rob_alloc_pkt,
  input  logic [ROB_IDX_W-1:0] rob_alloc_idx,

  // 发射输出（rename → rs）
  output logic        disp_valid,
  input  logic        disp_ready,
  output dispatch_t   disp_pkt,

  // 误预测冲刷（rob → rename）
  input  flush_t      flush
);

  assign dec_ready       = 1'b0;
  assign rob_alloc_valid = 1'b0;
  assign rob_alloc_pkt   = '0;
  assign disp_valid      = 1'b0;
  assign disp_pkt        = '0;

endmodule
