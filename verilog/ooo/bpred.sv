// bpred.sv — 分支预测器 [A]
//
// BTB + 2-bit BHT：
// - BTB 用完整 PC 匹配（index + tag 覆盖全部 PC 位），因此非分支指令
//   不会误命中某条分支的 BTB 项。
// - BHT 是 2-bit 饱和计数器，初值 2'b01（弱不跳转），MSB=1 预测 taken。
// - update_* 来自 ROB 的 branch_update_valid + CDB 的 pc/correct_pc：
//   实际 taken = (correct_pc != pc + 4)，对 JAL/JALR 也成立（B 的 ALU
//   必须对每条控制流结果都给出实际 next PC）。
// - 第一版在执行时更新，可能被少量错误路径分支污染；后续可改为提交时更新。

import cpu_pkg::*;

module bpred
(
  input  logic        clk,
  input  logic        rst,

  // 预测查询（ifu）
  input  logic [31:0] pc,
  output logic        pred_taken,
  output logic [31:0] pred_target,

  // 结果回写（分支执行完成后）
  input  logic        update_valid,
  input  logic [31:0] update_pc,
  input  logic        update_taken,
  input  logic [31:0] update_target
);

  logic                    btb_valid  [BPRED_ENTRIES];
  logic [BPRED_TAG_W-1:0]  btb_tag    [BPRED_ENTRIES];
  logic [31:0]             btb_target [BPRED_ENTRIES];
  logic [1:0]              bht        [BPRED_ENTRIES];

  // ---------------- 查询 ----------------
  wire [BPRED_IDX_W-1:0] q_idx = pc[BPRED_IDX_W+1:2];
  wire [BPRED_TAG_W-1:0] q_tag = pc[31:2+BPRED_IDX_W];

  wire q_hit = btb_valid[q_idx]
            && (btb_tag[q_idx] == q_tag)
            && bht[q_idx][1];

  assign pred_taken  = q_hit;
  assign pred_target = q_hit ? btb_target[q_idx] : (pc + 32'd4);

  // ---------------- 更新 ----------------
  wire [BPRED_IDX_W-1:0] u_idx = update_pc[BPRED_IDX_W+1:2];
  wire [BPRED_TAG_W-1:0] u_tag = update_pc[31:2+BPRED_IDX_W];

  integer i;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < BPRED_ENTRIES; i = i + 1) begin
        btb_valid[i]  <= 1'b0;
        btb_tag[i]    <= '0;
        btb_target[i] <= '0;
        bht[i]        <= 2'b01;
      end
    end else if (update_valid) begin
      if (update_taken) begin
        btb_valid[u_idx]  <= 1'b1;
        btb_tag[u_idx]    <= u_tag;
        btb_target[u_idx] <= update_target;
        if (bht[u_idx] != 2'b11)
          bht[u_idx] <= bht[u_idx] + 2'b01;
      end else begin
        if (bht[u_idx] != 2'b00)
          bht[u_idx] <= bht[u_idx] - 2'b01;
        // BTB 项保留：条件分支 target 静态；JALR 下次 taken 时刷新。
      end
    end
  end

endmodule
