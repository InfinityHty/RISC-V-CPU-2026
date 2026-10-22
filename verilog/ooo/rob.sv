// rob.sv — 重定序缓冲 [A]
// TODO: 环形缓冲分配/退休，CDB 完成标记，按序提交（commit 给 lsu），
// 误预测时产生 flush 并计算 redirect_pc。
// 当前骨架：所有输出空闲。
module rob
  import cpu_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // 表项申请（rename → rob）
  input  logic        rob_alloc_valid,
  output logic        rob_alloc_ready,
  input  dispatch_t   rob_alloc_pkt,
  output logic [ROB_IDX_W-1:0] rob_alloc_idx,

  // CDB 完成广播（cdb → rob）
  input  cdb_t        cdb,

  // 退休提交（rob → lsu）
  output commit_t     commit,

  // 误预测冲刷（rob → ifu / rename / rs / lsu）
  output flush_t      flush
);

  assign rob_alloc_ready = 1'b0;
  assign rob_alloc_idx   = '0;
  assign commit          = '0;
  assign flush           = '0;

endmodule
