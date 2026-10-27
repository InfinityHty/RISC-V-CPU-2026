// rob.sv — 重定序缓冲 [A]
//
// 执行时误预测恢复：
//   - 分支在 ALU 执行完当拍通过 CDB 返回 mispredict/correct_pc。
//   - ROB 立刻产生 flush：squash_mask 标出比该分支年轻的 ROB 项，
//     free_mask 给出这些项占用的 rd_tag。
//   - 分支本身保留在 ROB 中，之后正常按序提交。
//
// 提交：head 完成即退休；store 的 commit 只通知 LSU 可以真正写内存，
// ROB 不等待 store 完成（LSU 必须把已提交 store 放进不可冲刷的队列）。

import cpu_pkg::*;

module rob
(
  input  logic        clk,
  input  logic        rst,

  // 表项申请（rename → rob）
  input  logic        rob_alloc_valid,
  output logic        rob_alloc_ready,
  input  cpu_pkg::dispatch_t   rob_alloc_pkt,
  input  logic [TAG_W-1:0] rob_alloc_old_tag,
  output logic [ROB_IDX_W-1:0] rob_alloc_idx,

  // CDB 完成广播（cdb → rob）
  input  cpu_pkg::cdb_t        cdb,

  // 退休提交（rob → lsu）
  output cpu_pkg::commit_t     commit,

  // 内部提交信息（rob → rename）：只用于归还 old_tag
  output logic        commit_info_valid,
  output logic [TAG_W-1:0] commit_old_tag,

  // 误预测冲刷（rob → ifu / rename / rs / lsu）
  output cpu_pkg::flush_t      flush,

  // 正确预测的分支释放 checkpoint（rob → rename）
  output logic        ckpt_release_valid,
  output logic [ROB_IDX_W-1:0] ckpt_release_rob_idx,

  // 分支预测器更新（rob → bpred）：只对有效、未被 squash 的分支结果拉高
  output logic        branch_update_valid
);

  // ---------------- ROB 表项 ----------------
  logic                 valid     [ROB_DEPTH];
  logic                 completed [ROB_DEPTH];
  logic                 has_dest  [ROB_DEPTH];
  logic [TAG_W-1:0]     rd_tag    [ROB_DEPTH];
  logic [TAG_W-1:0]     old_tag   [ROB_DEPTH];
  logic                 is_store  [ROB_DEPTH];

  logic [ROB_IDX_W-1:0] head, tail;
  logic [ROB_CNT_W-1:0] count;

  // ---------------- 分配 ----------------
  wire full = (count == ROB_CNT_W'(ROB_DEPTH));

  assign rob_alloc_ready = !full && !flush.valid;
  assign rob_alloc_idx   = tail;

  wire alloc_fire = rob_alloc_valid && rob_alloc_ready;

  // ---------------- 分支解析 / 冲刷掩码 ----------------
  wire branch_resolve = cdb.valid && cdb.is_branch
                   && valid[cdb.rob_idx] && !completed[cdb.rob_idx];
  wire [ROB_IDX_W-1:0] b_age = cdb.rob_idx - head;

  logic [ROB_DEPTH-1:0] squash_mask;
  logic [PRF_SIZE-1:0]  free_mask;
  logic [ROB_IDX_W-1:0] age_i;

  always_comb begin
    squash_mask = '0;
    free_mask   = '0;
    age_i       = '0;
    if (branch_resolve) begin
      for (int i = 0; i < ROB_DEPTH; i = i + 1) begin
        age_i = ROB_IDX_W'(i) - head;
        if (valid[i] && ({1'b0, age_i} > {1'b0, b_age}) && ({1'b0, age_i} < count)) begin
          squash_mask[i] = 1'b1;
          if (has_dest[i] && rd_tag[i] != X0_TAG)
            free_mask[rd_tag[i]] = 1'b1;
        end
      end
    end
  end

  always_comb begin
    flush = '0;
    flush.valid        = branch_resolve && cdb.mispredict;
    flush.redirect_pc  = cdb.correct_pc;
    flush.rob_idx      = cdb.rob_idx;
    flush.squash_mask  = squash_mask;
    flush.free_mask    = free_mask;
  end

  assign ckpt_release_valid   = branch_resolve && !cdb.mispredict;
  assign ckpt_release_rob_idx = cdb.rob_idx;

  // ---------------- 提交 ----------------
  wire commit_fire = valid[head] && completed[head] && !flush.valid;

  assign commit.valid    = commit_fire;
  assign commit.rob_idx  = head;
  assign commit.is_store = is_store[head];

  assign commit_info_valid  = commit_fire;
  assign commit_old_tag     = old_tag[head];

  // ---------------- CDB 完成 ----------------
  wire cdb_hit = cdb.valid && valid[cdb.rob_idx] && !completed[cdb.rob_idx]
              && !squash_mask[cdb.rob_idx];

  // ---------------- 状态更新 ----------------
  always_ff @(posedge clk) begin
    if (rst) begin
      head  <= '0;
      tail  <= '0;
      count <= '0;
      for (int i = 0; i < ROB_DEPTH; i = i + 1) begin
        valid[i]      <= 1'b0;
        completed[i]  <= 1'b0;
        has_dest[i]   <= 1'b0;
        rd_tag[i]     <= '0;
        old_tag[i]    <= '0;
        is_store[i]   <= 1'b0;
      end
    end else begin
      if (alloc_fire) begin
        valid[tail]      <= 1'b1;
        completed[tail]  <= 1'b0;
        has_dest[tail]   <= rob_alloc_pkt.has_dest;
        rd_tag[tail]     <= rob_alloc_pkt.rd_tag;
        old_tag[tail]    <= rob_alloc_old_tag;
        is_store[tail]   <= rob_alloc_pkt.is_store;
        tail <= tail + 1'b1;
      end

      if (cdb_hit)
        completed[cdb.rob_idx] <= 1'b1;

      if (commit_fire) begin
        valid[head] <= 1'b0;
        head <= head + 1'b1;
      end

      if (flush.valid) begin
        for (int i = 0; i < ROB_DEPTH; i = i + 1)
          if (squash_mask[i])
            valid[i] <= 1'b0;
        count <= {1'b0, b_age} + 1'b1;
        tail  <= cdb.rob_idx + 1'b1;
      end else begin
        count <= count + (alloc_fire ? ROB_CNT_W'(1) : ROB_CNT_W'(0))
                       - (commit_fire ? ROB_CNT_W'(1) : ROB_CNT_W'(0));
      end
    end
  end

  assign branch_update_valid = cdb_hit && cdb.is_branch;

endmodule
