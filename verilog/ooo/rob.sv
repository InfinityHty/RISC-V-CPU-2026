import cpu_pkg::*;

module rob
(
  input  logic clk,
  input  logic rst,

  input  logic [DISPATCH_WIDTH-1:0] rob_alloc_valid,
  output logic [WIDTH_CNT_W-1:0] rob_alloc_ready_count,
  input  cpu_pkg::dispatch_t [DISPATCH_WIDTH-1:0] rob_alloc_pkt,
  input  logic [DISPATCH_WIDTH-1:0][TAG_W-1:0] rob_alloc_old_tag,
  output logic [DISPATCH_WIDTH-1:0][ROB_IDX_W-1:0] rob_alloc_idx,

  input  cpu_pkg::cdb_t [CDB_WIDTH-1:0] cdb,
  output cpu_pkg::commit_t [COMMIT_WIDTH-1:0] commit,
  output logic [COMMIT_WIDTH-1:0] commit_info_valid,
  output logic [COMMIT_WIDTH-1:0][TAG_W-1:0] commit_old_tag,
  output cpu_pkg::flush_t flush,
  output logic [CDB_WIDTH-1:0] ckpt_release_valid,
  output logic [CDB_WIDTH-1:0][ROB_IDX_W-1:0] ckpt_release_rob_idx,
  output logic [CDB_WIDTH-1:0] branch_update_valid
);

  logic valid [ROB_DEPTH];
  logic completed [ROB_DEPTH];
  logic has_dest [ROB_DEPTH];
  logic [TAG_W-1:0] rd_tag [ROB_DEPTH];
  logic [TAG_W-1:0] old_tag [ROB_DEPTH];
  logic is_store [ROB_DEPTH];
  logic [ROB_IDX_W-1:0] head, tail;
  logic [ROB_CNT_W-1:0] count;

  logic [WIDTH_CNT_W-1:0] alloc_count, commit_count;
  logic commit_stop;

  always_comb begin
    rob_alloc_ready_count = flush.valid ? 0 :
        ((ROB_DEPTH - count) >= DISPATCH_WIDTH ? DISPATCH_WIDTH : ROB_DEPTH - count);
    for (int i = 0; i < DISPATCH_WIDTH; i++)
      rob_alloc_idx[i] = tail + ROB_IDX_W'(i);
    alloc_count = '0;
    for (int i = 0; i < DISPATCH_WIDTH; i++)
      alloc_count = alloc_count + rob_alloc_valid[i];
  end

  logic [ROB_DEPTH-1:0] squash_mask;
  logic [PRF_SIZE-1:0] free_mask;
  logic flush_found;
  logic [ROB_IDX_W-1:0] flush_idx;
  logic [ROB_IDX_W-1:0] flush_age;
  logic [ROB_IDX_W-1:0] entry_age;

  always_comb begin
    flush_found = 1'b0;
    flush_idx = '0;
    flush_age = '1;
    for (int c = 0; c < CDB_WIDTH; c++) begin
      if (cdb[c].valid && cdb[c].is_branch && cdb[c].mispredict
          && valid[cdb[c].rob_idx] && !completed[cdb[c].rob_idx]) begin
        if (!flush_found || (cdb[c].rob_idx - head) < flush_age) begin
          flush_found = 1'b1;
          flush_idx = cdb[c].rob_idx;
          flush_age = cdb[c].rob_idx - head;
        end
      end
    end

    squash_mask = '0;
    free_mask = '0;
    entry_age = '0;
    if (flush_found) begin
      for (int i = 0; i < ROB_DEPTH; i++) begin
        entry_age = ROB_IDX_W'(i) - head;
        if (valid[i] && {1'b0, entry_age} > {1'b0, flush_age}
            && {1'b0, entry_age} < count) begin
          squash_mask[i] = 1'b1;
          if (has_dest[i] && rd_tag[i] != X0_TAG)
            free_mask[rd_tag[i]] = 1'b1;
        end
      end
    end

    flush = '0;
    flush.valid = flush_found;
    flush.redirect_pc = '0;
    flush.rob_idx = flush_idx;
    flush.squash_mask = squash_mask;
    flush.free_mask = free_mask;
    for (int c = 0; c < CDB_WIDTH; c++)
      if (cdb[c].valid && cdb[c].rob_idx == flush_idx)
        flush.redirect_pc = cdb[c].correct_pc;
  end

  always_comb begin
    commit_count = '0;
    commit_stop = flush.valid;
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      commit[i] = '0;
      commit_info_valid[i] = 1'b0;
      commit_old_tag[i] = '0;
      if (!commit_stop && valid[head + ROB_IDX_W'(i)]
          && completed[head + ROB_IDX_W'(i)]) begin
        commit[i].valid = 1'b1;
        commit[i].rob_idx = head + ROB_IDX_W'(i);
        commit[i].is_store = is_store[head + ROB_IDX_W'(i)];
        commit_info_valid[i] = 1'b1;
        commit_old_tag[i] = old_tag[head + ROB_IDX_W'(i)];
        commit_count = commit_count + 1'b1;
      end else begin
        commit_stop = 1'b1;
      end
    end
  end

  always_comb begin
    for (int c = 0; c < CDB_WIDTH; c++) begin
      ckpt_release_valid[c] = cdb[c].valid && cdb[c].is_branch && !cdb[c].mispredict
                           && valid[cdb[c].rob_idx] && !completed[cdb[c].rob_idx]
                           && !squash_mask[cdb[c].rob_idx];
      ckpt_release_rob_idx[c] = cdb[c].rob_idx;
      branch_update_valid[c] = cdb[c].valid && cdb[c].is_branch
                            && valid[cdb[c].rob_idx] && !completed[cdb[c].rob_idx]
                            && !squash_mask[cdb[c].rob_idx];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      head <= '0;
      tail <= '0;
      count <= '0;
      for (int i = 0; i < ROB_DEPTH; i++) begin
        valid[i] <= 1'b0;
        completed[i] <= 1'b0;
        has_dest[i] <= 1'b0;
        rd_tag[i] <= '0;
        old_tag[i] <= '0;
        is_store[i] <= 1'b0;
      end
    end else begin
      for (int i = 0; i < DISPATCH_WIDTH; i++) begin
        if (rob_alloc_valid[i]) begin
          valid[rob_alloc_idx[i]] <= 1'b1;
          completed[rob_alloc_idx[i]] <= 1'b0;
          has_dest[rob_alloc_idx[i]] <= rob_alloc_pkt[i].has_dest;
          rd_tag[rob_alloc_idx[i]] <= rob_alloc_pkt[i].rd_tag;
          old_tag[rob_alloc_idx[i]] <= rob_alloc_old_tag[i];
          is_store[rob_alloc_idx[i]] <= rob_alloc_pkt[i].is_store;
        end
      end

      for (int c = 0; c < CDB_WIDTH; c++)
        if (cdb[c].valid && valid[cdb[c].rob_idx] && !completed[cdb[c].rob_idx]
            && !squash_mask[cdb[c].rob_idx])
          completed[cdb[c].rob_idx] <= 1'b1;

      for (int i = 0; i < COMMIT_WIDTH; i++)
        if (commit[i].valid)
          valid[commit[i].rob_idx] <= 1'b0;

      if (flush.valid) begin
        for (int i = 0; i < ROB_DEPTH; i++)
          if (squash_mask[i])
            valid[i] <= 1'b0;
        count <= {1'b0, flush_age} + 1'b1;
        tail <= flush_idx + 1'b1;
      end else begin
        tail <= tail + ROB_IDX_W'(alloc_count);
        head <= head + ROB_IDX_W'(commit_count);
        count <= count + alloc_count - commit_count;
      end
    end
  end

endmodule
