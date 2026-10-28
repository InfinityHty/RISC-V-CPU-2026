import cpu_pkg::*;

module rs
(
  input  logic clk,
  input  logic rst,

  input  logic [DISPATCH_WIDTH-1:0] disp_valid,
  output logic [WIDTH_CNT_W-1:0] disp_ready_count,
  input  cpu_pkg::dispatch_t [DISPATCH_WIDTH-1:0] disp_pkt,

  input  cpu_pkg::cdb_t [CDB_WIDTH-1:0] cdb,
  input  cpu_pkg::flush_t flush,

  output logic [PRF_READ_PORTS-1:0][TAG_W-1:0] prf_raddr,
  input  logic [PRF_READ_PORTS-1:0][31:0] prf_rdata,

  output logic [ALU_COUNT-1:0] alu_issue_valid,
  input  logic [ALU_COUNT-1:0] alu_issue_ready,
  output cpu_pkg::issue_t [ALU_COUNT-1:0] alu_issue_pkt,
  output logic mul_issue_valid,
  input  logic mul_issue_ready,
  output cpu_pkg::issue_t mul_issue_pkt,
  output logic lsu_issue_valid,
  input  logic lsu_issue_ready,
  output cpu_pkg::issue_t lsu_issue_pkt
);

  localparam int RS_IDX_W = $clog2(RS_DEPTH);

  logic [$bits(cpu_pkg::dispatch_t)-1:0] entries [RS_DEPTH];
  logic [TAG_W-1:0] rs1_tags [RS_DEPTH];
  logic [TAG_W-1:0] rs2_tags [RS_DEPTH];
  logic [ROB_IDX_W-1:0] rob_indices [RS_DEPTH];
  cpu_pkg::opcode_e ops [RS_DEPTH];
  logic [RS_DEPTH-1:0] valid, src1_ready, src2_ready;
  logic [RS_DEPTH-1:0][RS_DEPTH-1:0] older;

  function automatic logic is_mem(input cpu_pkg::opcode_e op);
    is_mem = op >= cpu_pkg::OP_LB && op <= cpu_pkg::OP_SW;
  endfunction
  function automatic logic is_muldiv(input cpu_pkg::opcode_e op);
    is_muldiv = op >= cpu_pkg::OP_MUL && op <= cpu_pkg::OP_REMU;
  endfunction
  function automatic logic cdb_has_tag(input logic [TAG_W-1:0] tag);
    begin
      cdb_has_tag = 1'b0;
      for (int c = 0; c < CDB_WIDTH; c++)
        if (cdb[c].valid && cdb[c].tag == tag)
          cdb_has_tag = 1'b1;
    end
  endfunction

  logic [DISPATCH_WIDTH-1:0][RS_IDX_W-1:0] alloc_idx;
  logic [RS_DEPTH-1:0] alloc_used;
  int free_count;

  always_comb begin
    alloc_used = valid;
    free_count = 0;
    alloc_idx = '0;
    for (int i = 0; i < RS_DEPTH; i++)
      if (!valid[i])
        free_count++;
    disp_ready_count = flush.valid ? 0 :
        (free_count >= DISPATCH_WIDTH ? DISPATCH_WIDTH : free_count);
    for (int lane = 0; lane < DISPATCH_WIDTH; lane++) begin
      logic found;
      found = 1'b0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (!found && !alloc_used[i]) begin
          alloc_idx[lane] = RS_IDX_W'(i);
          alloc_used[i] = 1'b1;
          found = 1'b1;
        end
      end
    end
  end

  logic [RS_DEPTH-1:0] ready_vec;
  always_comb begin
    for (int i = 0; i < RS_DEPTH; i++)
      ready_vec[i] = valid[i]
                  && (src1_ready[i] || cdb_has_tag(rs1_tags[i]))
                  && (src2_ready[i] || cdb_has_tag(rs2_tags[i]));
  end

  logic [RS_DEPTH-1:0][$clog2(ALU_COUNT+1)-1:0] alu_rank;
  logic [RS_DEPTH-1:0] mul_candidate, lsu_candidate;
  logic [RS_DEPTH-1:0][ALU_COUNT-1:0] alu_selected;

  always_comb begin
    alu_selected = '0;
    mul_candidate = '0;
    lsu_candidate = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      int rank;
      logic mul_blocked, mem_blocked;
      rank = 0;
      mul_blocked = 1'b0;
      mem_blocked = 1'b0;
      for (int j = 0; j < RS_DEPTH; j++) begin
        if (valid[j] && older[j][i] && ready_vec[j]
            && !is_mem(ops[j]) && !is_muldiv(ops[j]))
          rank++;
        if (valid[j] && older[j][i] && ready_vec[j] && is_muldiv(ops[j]))
          mul_blocked = 1'b1;
        if (valid[j] && older[j][i] && is_mem(ops[j]))
          mem_blocked = 1'b1;
      end
      alu_rank[i] = rank;
      if (valid[i] && ready_vec[i] && !is_mem(ops[i]) && !is_muldiv(ops[i])
          && rank < ALU_COUNT)
        alu_selected[i][rank] = 1'b1;
      mul_candidate[i] = valid[i] && ready_vec[i] && is_muldiv(ops[i]) && !mul_blocked;
      lsu_candidate[i] = valid[i] && ready_vec[i] && is_mem(ops[i]) && !mem_blocked;
    end
  end

  always_comb begin
    alu_issue_valid = '0;
    prf_raddr = '0;
    for (int lane = 0; lane < ALU_COUNT; lane++) begin
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (alu_selected[i][lane]) begin
          alu_issue_valid[lane] = !(flush.valid && flush.squash_mask[rob_indices[i]]);
          prf_raddr[lane*2] = rs1_tags[i];
          prf_raddr[lane*2+1] = rs2_tags[i];
        end
      end
    end

    mul_issue_valid = 1'b0;
    lsu_issue_valid = 1'b0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (mul_candidate[i]) begin
        mul_issue_valid = !(flush.valid && flush.squash_mask[rob_indices[i]]);
        prf_raddr[ALU_COUNT*2] = rs1_tags[i];
        prf_raddr[ALU_COUNT*2+1] = rs2_tags[i];
      end
      if (lsu_candidate[i]) begin
        lsu_issue_valid = !(flush.valid && flush.squash_mask[rob_indices[i]]);
        prf_raddr[ALU_COUNT*2+2] = rs1_tags[i];
        prf_raddr[ALU_COUNT*2+3] = rs2_tags[i];
      end
    end
  end

  always_comb begin
    for (int lane = 0; lane < ALU_COUNT; lane++) begin
      alu_issue_pkt[lane] = '0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (alu_selected[i][lane]) begin
          alu_issue_pkt[lane].d = entries[i];
          alu_issue_pkt[lane].rs1_val = prf_rdata[lane*2];
          alu_issue_pkt[lane].rs2_val = prf_rdata[lane*2+1];
        end
      end
    end
    mul_issue_pkt = '0;
    lsu_issue_pkt = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (mul_candidate[i]) begin
        mul_issue_pkt.d = entries[i];
        mul_issue_pkt.rs1_val = prf_rdata[ALU_COUNT*2];
        mul_issue_pkt.rs2_val = prf_rdata[ALU_COUNT*2+1];
      end
      if (lsu_candidate[i]) begin
        lsu_issue_pkt.d = entries[i];
        lsu_issue_pkt.rs1_val = prf_rdata[ALU_COUNT*2+2];
        lsu_issue_pkt.rs2_val = prf_rdata[ALU_COUNT*2+3];
      end
    end
  end

  logic [RS_DEPTH-1:0] remove_vec;
  always_comb begin
    remove_vec = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (valid[i] && flush.valid && flush.squash_mask[rob_indices[i]])
        remove_vec[i] = 1'b1;
      for (int lane = 0; lane < ALU_COUNT; lane++)
        if (alu_selected[i][lane] && alu_issue_valid[lane] && alu_issue_ready[lane])
          remove_vec[i] = 1'b1;
      if (mul_candidate[i] && mul_issue_valid && mul_issue_ready)
        remove_vec[i] = 1'b1;
      if (lsu_candidate[i] && lsu_issue_valid && lsu_issue_ready)
        remove_vec[i] = 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      valid <= '0;
      src1_ready <= '0;
      src2_ready <= '0;
      older <= '0;
    end else begin
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (remove_vec[i]) begin
          valid[i] <= 1'b0;
        end else if (valid[i]) begin
          for (int c = 0; c < CDB_WIDTH; c++) begin
            if (cdb[c].valid) begin
              if (!src1_ready[i] && cdb[c].tag == rs1_tags[i])
                src1_ready[i] <= 1'b1;
              if (!src2_ready[i] && cdb[c].tag == rs2_tags[i])
                src2_ready[i] <= 1'b1;
            end
          end
        end
        for (int j = 0; j < RS_DEPTH; j++)
          if (remove_vec[i] || remove_vec[j])
            older[i][j] <= 1'b0;
      end

      for (int lane = 0; lane < DISPATCH_WIDTH; lane++) begin
        if (disp_valid[lane]) begin
          valid[alloc_idx[lane]] <= 1'b1;
          entries[alloc_idx[lane]] <= disp_pkt[lane];
          rs1_tags[alloc_idx[lane]] <= disp_pkt[lane].rs1_tag;
          rs2_tags[alloc_idx[lane]] <= disp_pkt[lane].rs2_tag;
          rob_indices[alloc_idx[lane]] <= disp_pkt[lane].rob_idx;
          ops[alloc_idx[lane]] <= disp_pkt[lane].op;
          src1_ready[alloc_idx[lane]] <= disp_pkt[lane].rs1_ready
                                      || cdb_has_tag(disp_pkt[lane].rs1_tag);
          src2_ready[alloc_idx[lane]] <= disp_pkt[lane].rs2_ready
                                      || cdb_has_tag(disp_pkt[lane].rs2_tag);
          for (int j = 0; j < RS_DEPTH; j++) begin
            older[alloc_idx[lane]][j] <= 1'b0;
            older[j][alloc_idx[lane]] <= valid[j] && !remove_vec[j];
          end
          for (int prior = 0; prior < DISPATCH_WIDTH; prior++) begin
            if (prior < lane && disp_valid[prior]) begin
              older[alloc_idx[prior]][alloc_idx[lane]] <= 1'b1;
              older[alloc_idx[lane]][alloc_idx[prior]] <= 1'b0;
            end
          end
        end
      end
    end
  end

endmodule
