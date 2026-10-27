// lsu.sv — Load/Store 单元 [B]
// TODO: 地址计算、store buffer（等 commit 后才真正写内存）、
// load 乱序执行的访存排序检查、store-to-load 转发。
// 结束约定：向 0x80000000 的 32 位 store（WSTRB=4'hf）即停机返回码。
// 当前骨架：输出空闲。
import cpu_pkg::*;

module lsu
(
  input  logic        clk,
  input  logic        rst,

  input  logic        issue_valid,
  output logic        issue_ready,
  input  cpu_pkg::issue_t      issue_pkt,

  // CDB 广播（store 数据唤醒）
  input  cpu_pkg::cdb_t        cdb,

  // ROB 退休提交（store 放行）
  input  cpu_pkg::commit_t     commit,

  // 误预测冲刷
  input  cpu_pkg::flush_t      flush,

  output cpu_pkg::cdb_t        result_pkt,
  input  logic        result_ready,

  // 数据访存请求（lsu → dcache）
  output logic        mem_req_valid,
  input  logic        mem_req_ready,
  output logic [31:0] mem_req_addr,
  output logic [31:0] mem_req_wdata,
  output logic [3:0]  mem_req_wstrb,
  output logic        mem_req_write,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  assign issue_ready   = 1'b0;
  assign result_pkt    = '0;
  assign mem_req_valid = 1'b0;
  assign mem_req_addr  = '0;
  assign mem_req_wdata = '0;
  assign mem_req_wstrb = '0;
  assign mem_req_write = 1'b0;

endmodule
