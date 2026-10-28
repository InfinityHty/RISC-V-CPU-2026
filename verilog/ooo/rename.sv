import cpu_pkg::*;

module rename
(
  input  logic clk,
  input  logic rst,

  input  logic [DISPATCH_WIDTH-1:0] dec_valid,
  output logic [WIDTH_CNT_W-1:0] dec_ready_count,
  input  cpu_pkg::dispatch_t [DISPATCH_WIDTH-1:0] dec_pkt,

  output logic [DISPATCH_WIDTH-1:0] rob_alloc_valid,
  input  logic [WIDTH_CNT_W-1:0] rob_alloc_ready_count,
  output cpu_pkg::dispatch_t [DISPATCH_WIDTH-1:0] rob_alloc_pkt,
  input  logic [DISPATCH_WIDTH-1:0][ROB_IDX_W-1:0] rob_alloc_idx,
  output logic [DISPATCH_WIDTH-1:0][TAG_W-1:0] rob_alloc_old_tag,

  output logic [DISPATCH_WIDTH-1:0] disp_valid,
  input  logic [WIDTH_CNT_W-1:0] disp_ready_count,
  output cpu_pkg::dispatch_t [DISPATCH_WIDTH-1:0] disp_pkt,

  input  cpu_pkg::cdb_t [CDB_WIDTH-1:0] cdb,
  input  logic [COMMIT_WIDTH-1:0] commit_valid,
  input  logic [COMMIT_WIDTH-1:0][TAG_W-1:0] commit_old_tag,
  input  cpu_pkg::flush_t flush,
  input  logic [CDB_WIDTH-1:0] ckpt_release_valid,
  input  logic [CDB_WIDTH-1:0][ROB_IDX_W-1:0] ckpt_release_rob_idx,

  output logic [DISPATCH_WIDTH-1:0] prf_alloc_valid,
  output logic [DISPATCH_WIDTH-1:0][TAG_W-1:0] prf_alloc_tag,
  output logic [DISPATCH_WIDTH-1:0][ROB_IDX_W-1:0] prf_alloc_rob_idx
);

  logic [TAG_W-1:0] rrat [32];
  logic [PRF_SIZE-1:0] free_bits, ready_bits;
  logic [ROB_IDX_W-1:0] tag_owner [PRF_SIZE];

  logic [CHECKPOINT_DEPTH-1:0] ckpt_valid;
  logic [ROB_IDX_W-1:0] ckpt_rob [CHECKPOINT_DEPTH];
  logic [TAG_W-1:0] ckpt_rrat [CHECKPOINT_DEPTH][32];
  logic [TAG_W-1:0] ckpt_map [DISPATCH_WIDTH][32];

  logic [TAG_W-1:0] map_work [32];
  logic [PRF_SIZE-1:0] free_work;
  logic [CHECKPOINT_DEPTH-1:0] ckpt_work;
  logic [DISPATCH_WIDTH-1:0][TAG_W-1:0] alloc_tag;
  logic [DISPATCH_WIDTH-1:0][CKPT_IDX_W-1:0] alloc_ckpt;
  logic accept_stop;

  function automatic logic cdb_has_tag(input logic [TAG_W-1:0] tag);
    begin
      cdb_has_tag = 1'b0;
      for (int c = 0; c < CDB_WIDTH; c++)
        if (cdb[c].valid && cdb[c].tag == tag)
          cdb_has_tag = 1'b1;
    end
  endfunction

  always_comb begin
    logic [PRF_SIZE-1:0] pending_work;
    for (int a = 0; a < 32; a++)
      map_work[a] = rrat[a];
    free_work = free_bits;
    pending_work = '0;
    ckpt_work = '0;
    for (int c = 0; c < CHECKPOINT_DEPTH; c++)
      ckpt_work[c] = ckpt_valid[c];

    dec_ready_count = '0;
    rob_alloc_valid = '0;
    disp_valid = '0;
    rob_alloc_old_tag = '0;
    prf_alloc_valid = '0;
    prf_alloc_tag = '0;
    prf_alloc_rob_idx = '0;
    alloc_tag = '0;
    alloc_ckpt = '0;
    accept_stop = flush.valid;
    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      rob_alloc_pkt[i] = '0;
      for (int a = 0; a < 32; a++)
        ckpt_map[i][a] = rrat[a];
    end

    for (int i = 0; i < DISPATCH_WIDTH; i++) begin
      logic found_free, found_ckpt;
      logic [TAG_W-1:0] new_tag;
      logic [CKPT_IDX_W-1:0] new_ckpt;
      logic [TAG_W-1:0] src1_tag, src2_tag, old_tag;
      logic can_accept;
      found_free = 1'b0;
      found_ckpt = 1'b0;
      new_tag = X0_TAG;
      new_ckpt = '0;
      src1_tag = X0_TAG;
      src2_tag = X0_TAG;
      old_tag = X0_TAG;
      for (int t = 1; t < PRF_SIZE; t++) begin
        if (!found_free && free_work[t]) begin
          found_free = 1'b1;
          new_tag = TAG_W'(t);
        end
      end
      for (int c = 0; c < CHECKPOINT_DEPTH; c++) begin
        if (!found_ckpt && !ckpt_work[c]) begin
          found_ckpt = 1'b1;
          new_ckpt = CKPT_IDX_W'(c);
        end
      end

      can_accept = !accept_stop && dec_valid[i]
                && i < rob_alloc_ready_count && i < disp_ready_count
                && (!dec_pkt[i].has_dest || found_free)
                && (!dec_pkt[i].is_branch || found_ckpt);
      if (can_accept) begin
        src1_tag = (dec_pkt[i].use_rs1 && dec_pkt[i].rs1_arch != 0)
                 ? map_work[dec_pkt[i].rs1_arch] : X0_TAG;
        src2_tag = (dec_pkt[i].use_rs2 && dec_pkt[i].rs2_arch != 0)
                 ? map_work[dec_pkt[i].rs2_arch] : X0_TAG;
        old_tag = dec_pkt[i].has_dest ? map_work[dec_pkt[i].rd_arch] : X0_TAG;

        rob_alloc_valid[i] = 1'b1;
        disp_valid[i] = 1'b1;
        rob_alloc_pkt[i] = dec_pkt[i];
        rob_alloc_pkt[i].rob_idx = rob_alloc_idx[i];
        rob_alloc_pkt[i].rs1_tag = src1_tag;
        rob_alloc_pkt[i].rs2_tag = src2_tag;
        rob_alloc_pkt[i].rs1_ready = src1_tag == X0_TAG ||
                                   (!pending_work[src1_tag] &&
                                    (ready_bits[src1_tag] || cdb_has_tag(src1_tag)));
        rob_alloc_pkt[i].rs2_ready = src2_tag == X0_TAG ||
                                   (!pending_work[src2_tag] &&
                                    (ready_bits[src2_tag] || cdb_has_tag(src2_tag)));
        rob_alloc_pkt[i].rd_tag = dec_pkt[i].has_dest ? new_tag : X0_TAG;
        rob_alloc_old_tag[i] = old_tag;
        dec_ready_count = dec_ready_count + 1'b1;

        if (dec_pkt[i].has_dest) begin
          prf_alloc_valid[i] = 1'b1;
          prf_alloc_tag[i] = new_tag;
          prf_alloc_rob_idx[i] = rob_alloc_idx[i];
          alloc_tag[i] = new_tag;
          map_work[dec_pkt[i].rd_arch] = new_tag;
          free_work[new_tag] = 1'b0;
          pending_work[new_tag] = 1'b1;
        end
        if (dec_pkt[i].is_branch) begin
          alloc_ckpt[i] = new_ckpt;
          ckpt_work[new_ckpt] = 1'b1;
          for (int a = 0; a < 32; a++)
            ckpt_map[i][a] = map_work[a];
        end
      end else begin
        accept_stop = 1'b1;
      end
    end
  end

  always_comb begin
    disp_pkt = rob_alloc_pkt;
  end

  int flush_ckpt_hit;
  always_comb begin
    flush_ckpt_hit = -1;
    for (int c = 0; c < CHECKPOINT_DEPTH; c++)
      if (ckpt_valid[c] && ckpt_rob[c] == flush.rob_idx)
        flush_ckpt_hit = c;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int a = 0; a < 32; a++)
        rrat[a] <= a == 0 ? X0_TAG : TAG_W'(a);
      for (int t = 0; t < PRF_SIZE; t++) begin
        free_bits[t] <= t >= 32;
        ready_bits[t] <= 1'b1;
        tag_owner[t] <= '0;
      end
      for (int c = 0; c < CHECKPOINT_DEPTH; c++) begin
        ckpt_valid[c] <= 1'b0;
        ckpt_rob[c] <= '0;
      end
    end else begin
      for (int c = 0; c < CDB_WIDTH; c++) begin
        if (cdb[c].valid && cdb[c].tag != X0_TAG
            && tag_owner[cdb[c].tag] == cdb[c].rob_idx)
          ready_bits[cdb[c].tag] <= 1'b1;
        if (ckpt_release_valid[c]) begin
          for (int k = 0; k < CHECKPOINT_DEPTH; k++)
            if (ckpt_valid[k] && ckpt_rob[k] == ckpt_release_rob_idx[c])
              ckpt_valid[k] <= 1'b0;
        end
      end

      for (int i = 0; i < COMMIT_WIDTH; i++)
        if (commit_valid[i] && commit_old_tag[i] != X0_TAG)
          free_bits[commit_old_tag[i]] <= 1'b1;

      for (int i = 0; i < DISPATCH_WIDTH; i++) begin
        if (rob_alloc_valid[i]) begin
          if (dec_pkt[i].has_dest) begin
            rrat[dec_pkt[i].rd_arch] <= alloc_tag[i];
            free_bits[alloc_tag[i]] <= 1'b0;
            ready_bits[alloc_tag[i]] <= 1'b0;
            tag_owner[alloc_tag[i]] <= rob_alloc_idx[i];
          end
          if (dec_pkt[i].is_branch) begin
            ckpt_valid[alloc_ckpt[i]] <= 1'b1;
            ckpt_rob[alloc_ckpt[i]] <= rob_alloc_idx[i];
            for (int a = 0; a < 32; a++)
              ckpt_rrat[alloc_ckpt[i]][a] <= ckpt_map[i][a];
          end
        end
      end

      if (flush.valid) begin
        if (flush_ckpt_hit >= 0) begin
          for (int a = 0; a < 32; a++)
            rrat[a] <= ckpt_rrat[flush_ckpt_hit][a];
          ckpt_valid[flush_ckpt_hit] <= 1'b0;
        end
        for (int c = 0; c < CHECKPOINT_DEPTH; c++) begin
          for (int r = 0; r < ROB_DEPTH; r++)
            if (ckpt_valid[c] && ckpt_rob[c] == ROB_IDX_W'(r) && flush.squash_mask[r])
              ckpt_valid[c] <= 1'b0;
        end
        free_bits <= free_bits | flush.free_mask;
        free_bits[0] <= 1'b0;
      end
    end
  end

endmodule
