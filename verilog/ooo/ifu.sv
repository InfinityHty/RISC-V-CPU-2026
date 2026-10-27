// ifu.sv — 取指单元 [A]
//
// 第一版：IFU → I-Cache（icache）→ axi_master。
// - 请求 FIFO 支持多 outstanding：ICache 命中时可以每拍 accept 一个请求，
//   响应按请求顺序返回，所以 IFU 用 4 项请求 FIFO 保存每条请求的 PC/预测信息。
// - 取指 PC 在“请求被 accept”时前进：bpred 预测 taken 时直接跳到 pred_target，
//   预测错误由 ROB flush 重定向。
// - flush：清空请求 FIFO 和指令 FIFO，重定向 fetch_pc；I-Cache 保证之后
//   不再返回旧请求的响应；IFU 在 reqq_count==0 时也会忽略任何迟到响应。
// - ICache 响应是单拍脉冲；resp_valid 时按请求顺序出队。

import cpu_pkg::*;

module ifu
(
  input  logic        clk,
  input  logic        rst,

  // 误预测冲刷（rob → ifu）
  input  cpu_pkg::flush_t      flush,

  // 当前 fetch_pc 的分支预测（bpred 组合查询）
  input  logic        pred_taken,
  input  logic [31:0] pred_target,

  // 取出的指令（ifu → decode）
  output logic        instr_valid,
  input  logic        instr_ready,
  output logic [31:0] instr_pc,
  output logic [31:0] instr_data,
  output logic        instr_pred_taken,
  output logic [31:0] instr_pred_target,

  // 取指请求（ifu → icache）
  output logic        mem_req_valid,
  output logic [31:0] mem_req_addr,
  input  logic        mem_req_ready,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  localparam int REQ_DEPTH  = 4;
  localparam int FIFO_DEPTH = 4;

  // ---------------- 请求 FIFO：保存尚未返回的取指 PC/预测 ----------------
  logic [31:0] reqq_pc          [REQ_DEPTH];
  logic        reqq_pred_taken  [REQ_DEPTH];
  logic [31:0] reqq_pred_target [REQ_DEPTH];
  logic [1:0]  reqq_rptr, reqq_wptr;
  logic [2:0]  reqq_count;

  // ---------------- 指令 FIFO ----------------
  logic [31:0] fifo_pc          [FIFO_DEPTH];
  logic [31:0] fifo_data        [FIFO_DEPTH];
  logic        fifo_pred_taken  [FIFO_DEPTH];
  logic [31:0] fifo_pred_target [FIFO_DEPTH];
  logic [1:0]  rptr, wptr;
  logic [2:0]  count;

  logic [31:0] fetch_pc;

  wire pop = instr_valid && instr_ready;

  assign instr_valid       = (count != 3'd0);
  assign instr_pc          = fifo_pc[rptr];
  assign instr_data        = fifo_data[rptr];
  assign instr_pred_taken  = fifo_pred_taken[rptr];
  assign instr_pred_target = fifo_pred_target[rptr];

  // ---------------- 请求生成 ----------------
  // 不变量：count + reqq_count <= FIFO_DEPTH，保证每个 outstanding 响应
  // 都能在指令 FIFO 中找到位置。pop 当拍可以腾出一个位置。
  wire [3:0] fifo_used = {1'b0, count} + {1'b0, reqq_count};
  wire can_req = !flush.valid
              && (reqq_count < 3'(REQ_DEPTH))
              && ((fifo_used < 4'(FIFO_DEPTH))
                  || (fifo_used == 4'(FIFO_DEPTH) && pop))
              && (fetch_pc < 32'h1000_0000);

  assign mem_req_valid = can_req;
  assign mem_req_addr  = fetch_pc;

  wire req_fire = mem_req_valid && mem_req_ready;

  // 只有请求 FIFO 非空时，响应才有效；flush 后的迟到响应会被忽略。
  wire resp_push = mem_resp_valid && (reqq_count != 3'd0) && !flush.valid;

  wire [31:0] next_pc = pred_taken ? pred_target : (fetch_pc + 32'd4);

  always_ff @(posedge clk) begin
    if (rst) begin
      reqq_rptr <= 2'd0;
      reqq_wptr <= 2'd0;
      reqq_count <= 3'd0;
      rptr      <= 2'd0;
      wptr      <= 2'd0;
      count     <= 3'd0;
      fetch_pc  <= 32'd0;
    end else if (flush.valid) begin
      reqq_rptr <= 2'd0;
      reqq_wptr <= 2'd0;
      reqq_count <= 3'd0;
      rptr      <= 2'd0;
      wptr      <= 2'd0;
      count     <= 3'd0;
      fetch_pc  <= flush.redirect_pc;
    end else begin
      if (req_fire) begin
        reqq_pc[reqq_wptr]          <= fetch_pc;
        reqq_pred_taken[reqq_wptr]  <= pred_taken;
        reqq_pred_target[reqq_wptr] <= pred_target;
        reqq_wptr                   <= reqq_wptr + 2'd1;
        fetch_pc                    <= next_pc;
      end

      if (resp_push) begin
        fifo_pc[wptr]          <= reqq_pc[reqq_rptr];
        fifo_data[wptr]        <= mem_resp_data;
        fifo_pred_taken[wptr]  <= reqq_pred_taken[reqq_rptr];
        fifo_pred_target[wptr] <= reqq_pred_target[reqq_rptr];
        reqq_rptr              <= reqq_rptr + 2'd1;
        wptr                   <= wptr + 2'd1;
      end

      if (pop)
        rptr <= rptr + 2'd1;

      reqq_count <= reqq_count
                  + (req_fire ? 3'd1 : 3'd0)
                  - (resp_push ? 3'd1 : 3'd0);
      count      <= count
                  + (resp_push ? 3'd1 : 3'd0)
                  - (pop ? 3'd1 : 3'd0);
    end
  end

endmodule
