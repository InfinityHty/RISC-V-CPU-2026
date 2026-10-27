// rename.sv — 寄存器重命名 [A]
//
// 方案：执行时误预测恢复 + RAT 快照（checkpoint）。
//
// - rRAT：正在重命名的映射；checkpoint 保存每条分支点的 rRAT 快照。
// - 不需要 cRAT：execute-time flush 直接从快照恢复 rRAT。
// - free list 用 PRF_SIZE 位 bitmap；tag 0 固定给 x0。
// - 每条控制流指令（branch/jal/jalr）在 rename 时拍一张 rRAT 快照，
//   存到 checkpoint pool，并用 rob_idx 标识。
// - 分支在 ALU 执行完就通过 CDB 返回 mispredict；ROB 当拍产生 flush，
//   rename 找到对应 rob_idx 的快照恢复 rRAT，并把 squash_mask 覆盖的
//   年轻指令占用的 rd_tag 并行归还 free bitmap。
// - 当前 free bitmap 已包含更老指令提交释放的 tag；年轻指令的 tag 由 ROB 的
//   flush.free_mask 精确给出，因此不需要恢复 free bitmap 快照。

import cpu_pkg::*;

module rename
(
  input  logic        clk,
  input  logic        rst,

  // 译码输入（decode → rename）
  input  logic        dec_valid,
  output logic        dec_ready,
  input  cpu_pkg::dispatch_t   dec_pkt,

  // ROB 表项申请（rename → rob）
  output logic        rob_alloc_valid,
  input  logic        rob_alloc_ready,
  output cpu_pkg::dispatch_t   rob_alloc_pkt,
  input  logic [ROB_IDX_W-1:0] rob_alloc_idx,
  output logic [TAG_W-1:0]     rob_alloc_old_tag,

  // 发射输出（rename → rs）
  output logic        disp_valid,
  input  logic        disp_ready,
  output cpu_pkg::dispatch_t   disp_pkt,

  // CDB 完成广播（用于把 ready bitmap 置位）
  input  cpu_pkg::cdb_t        cdb,

  // ROB 提交信息（归还 old_tag）
  input  logic        commit_valid,
  input  logic [TAG_W-1:0] commit_old_tag,

  // 误预测冲刷（rob → rename）
  input  cpu_pkg::flush_t      flush,

  // 正确预测的分支释放其 checkpoint
  input  logic        ckpt_release_valid,
  input  logic [ROB_IDX_W-1:0] ckpt_release_rob_idx,

  // PRF 分配端口（记录物理寄存器 owner，防止迟到 CDB 覆盖）
  output logic        prf_alloc_valid,
  output logic [TAG_W-1:0] prf_alloc_tag,
  output logic [ROB_IDX_W-1:0] prf_alloc_rob_idx
);

  // ---------------- 架构/物理映射状态 ----------------
  logic [TAG_W-1:0] rrat [32];
  logic [PRF_SIZE-1:0] free_bits;
  logic [PRF_SIZE-1:0] ready_bits;
  logic [ROB_IDX_W-1:0] tag_owner [PRF_SIZE];

  // ---------------- checkpoint pool ----------------
  logic                     ckpt_valid [CHECKPOINT_DEPTH];
  logic [ROB_IDX_W-1:0]     ckpt_rob   [CHECKPOINT_DEPTH];
  logic [TAG_W-1:0]         ckpt_rrat  [CHECKPOINT_DEPTH][32];

  // ---------------- 组合分配 ----------------
  wire need_dest = dec_pkt.has_dest && (dec_pkt.rd_arch != 5'd0);
  wire need_ckpt = dec_pkt.is_branch;

  logic [PRF_SIZE-1:0] free_vec;
  logic [CHECKPOINT_DEPTH-1:0] ckpt_free_vec;
  always_comb begin
    free_vec = free_bits;
    for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
      ckpt_free_vec[c] = ~ckpt_valid[c];
  end

  function automatic logic [TAG_W-1:0] pick_free_tag(input logic [PRF_SIZE-1:0] bits);
    logic found;
    begin
      found = 1'b0;
      pick_free_tag = X0_TAG;
      for (int i = 0; i < PRF_SIZE; i = i + 1) begin
        if (!found && bits[i]) begin
          pick_free_tag = TAG_W'(i);
          found = 1'b1;
        end
      end
    end
  endfunction

  function automatic logic [CKPT_IDX_W-1:0] pick_free_ckpt(input logic [CHECKPOINT_DEPTH-1:0] bits);
    logic found;
    begin
      found = 1'b0;
      pick_free_ckpt = '0;
      for (int i = 0; i < CHECKPOINT_DEPTH; i = i + 1) begin
        if (!found && bits[i]) begin
          pick_free_ckpt = CKPT_IDX_W'(i);
          found = 1'b1;
        end
      end
    end
  endfunction

  wire [TAG_W-1:0] free_tag   = pick_free_tag(free_vec);
  wire             free_avail = |free_vec;
  wire [CKPT_IDX_W-1:0] ckpt_slot = pick_free_ckpt(ckpt_free_vec);
  wire             ckpt_avail = |ckpt_free_vec;

  // 源操作数 tag/ready
  wire [TAG_W-1:0] rs1_sel_tag = (dec_pkt.use_rs1 && dec_pkt.rs1_arch != 5'd0)
                                 ? rrat[dec_pkt.rs1_arch] : X0_TAG;
  wire [TAG_W-1:0] rs2_sel_tag = (dec_pkt.use_rs2 && dec_pkt.rs2_arch != 5'd0)
                                 ? rrat[dec_pkt.rs2_arch] : X0_TAG;
  wire rs1_sel_ready = (rs1_sel_tag == X0_TAG) ? 1'b1 : ready_bits[rs1_sel_tag];
  wire rs2_sel_ready = (rs2_sel_tag == X0_TAG) ? 1'b1 : ready_bits[rs2_sel_tag];

  wire [TAG_W-1:0] old_tag = need_dest ? rrat[dec_pkt.rd_arch] : X0_TAG;

  // 同时满足 ROB/RS/PRF/checkpoint 资源才接收译码结果。
  assign dec_ready = !flush.valid
                  && (!need_dest || free_avail)
                  && (!need_ckpt || ckpt_avail)
                  && rob_alloc_ready
                  && disp_ready;

  wire fire = dec_valid && dec_ready;

  assign rob_alloc_valid = fire;
  assign disp_valid      = fire;
  assign rob_alloc_old_tag = old_tag;

  always_comb begin
    rob_alloc_pkt           = dec_pkt;
    rob_alloc_pkt.rob_idx   = rob_alloc_idx;
    rob_alloc_pkt.rs1_tag   = rs1_sel_tag;
    rob_alloc_pkt.rs2_tag   = rs2_sel_tag;
    rob_alloc_pkt.rs1_ready = rs1_sel_ready;
    rob_alloc_pkt.rs2_ready = rs2_sel_ready;
    rob_alloc_pkt.rd_tag    = need_dest ? free_tag : X0_TAG;
  end
  assign disp_pkt = rob_alloc_pkt;

  assign prf_alloc_valid  = fire && need_dest;
  assign prf_alloc_tag    = free_tag;
  assign prf_alloc_rob_idx = rob_alloc_idx;

  // ---------------- 找 flush 对应的 checkpoint ----------------
  int flush_ckpt_hit;
  always_comb begin
    flush_ckpt_hit = -1;
    for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
      if (ckpt_valid[c] && ckpt_rob[c] == flush.rob_idx)
        flush_ckpt_hit = c;
  end

  // 被本次 flush squash 的年轻 checkpoint（供 always_ff 使用，避免
  // 在时序块里做动态位选，Icarus 对那种写法支持较差）。
  logic ckpt_kill [CHECKPOINT_DEPTH];
  logic [ROB_DEPTH-1:0] flush_squash_mask;
  always_comb flush_squash_mask = flush.squash_mask;
  always_comb begin
    for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1) begin
      ckpt_kill[c] = 1'b0;
      for (int r = 0; r < ROB_DEPTH; r = r + 1)
        if (ckpt_rob[c] == ROB_IDX_W'(r) && flush_squash_mask[r])
          ckpt_kill[c] = 1'b1;
    end
  end

  // ---------------- 状态更新 ----------------
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int a = 0; a < 32; a = a + 1)
        rrat[a] <= (a == 0) ? X0_TAG : TAG_W'(a);
      for (int t = 0; t < PRF_SIZE; t = t + 1) begin
        // tag 0..31 初始映射给 x0..x31；其余 tag 空闲。
        free_bits[t]  <= (t >= 32);
        ready_bits[t] <= 1'b1;
        tag_owner[t]  <= '0;
      end
      for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1) begin
        ckpt_valid[c] <= 1'b0;
        ckpt_rob[c]   <= '0;
      end
    end else begin
      // CDB 完成：只对 owner 匹配的 tag 置 ready，防止迟到结果误唤醒。
      if (cdb.valid && cdb.tag != X0_TAG && tag_owner[cdb.tag] == cdb.rob_idx)
        ready_bits[cdb.tag] <= 1'b1;

      // 提交：释放 old_tag（execute-time flush 只恢复 rRAT，不需要 cRAT）。
      if (commit_valid && commit_old_tag != X0_TAG)
        free_bits[commit_old_tag] <= 1'b1;

      // 正常重命名分配。
      if (fire && need_dest) begin
        rrat[dec_pkt.rd_arch] <= free_tag;
        free_bits[free_tag]   <= 1'b0;
        ready_bits[free_tag]  <= 1'b0;
        tag_owner[free_tag]   <= rob_alloc_idx;
      end

      // 控制流指令拍快照（包含它自己的 rd 映射）。
      if (fire && need_ckpt) begin
        ckpt_valid[ckpt_slot] <= 1'b1;
        ckpt_rob[ckpt_slot]   <= rob_alloc_idx;
        for (int a = 0; a < 32; a = a + 1)
          ckpt_rrat[ckpt_slot][a] <= (need_dest && (a[4:0] == dec_pkt.rd_arch))
                                      ? free_tag : rrat[a];
      end

      // 正确预测的分支：释放快照。
      if (ckpt_release_valid) begin
        for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
          if (ckpt_valid[c] && ckpt_rob[c] == ckpt_release_rob_idx)
            ckpt_valid[c] <= 1'b0;
      end

      // 误预测冲刷：恢复 rRAT，释放被 squash 的年轻指令 tag，清理快照。
      if (flush.valid) begin
        if (flush_ckpt_hit >= 0) begin
          for (int a = 0; a < 32; a = a + 1)
            rrat[a] <= ckpt_rrat[flush_ckpt_hit][a];
          ckpt_valid[flush_ckpt_hit] <= 1'b0;
        end
        for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
          if (ckpt_kill[c])
            ckpt_valid[c] <= 1'b0;
        free_bits <= free_bits | flush.free_mask;
        free_bits[0] <= 1'b0;
      end
    end
  end

endmodule
