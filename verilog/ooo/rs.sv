// rs.sv — 统一保留站 [B]
// CDB 同拍唤醒，单发射；最老就绪指令优先，访存额外保持程序序。
import cpu_pkg::*;

module rs
(
  input  logic        clk,
  input  logic        rst,

  input  logic        disp_valid,
  output logic        disp_ready,
  input  cpu_pkg::dispatch_t   disp_pkt,

  input  cpu_pkg::cdb_t        cdb,
  input  cpu_pkg::flush_t      flush,

  output logic [TAG_W-1:0] prf_raddr1,
  output logic [TAG_W-1:0] prf_raddr2,
  input  logic [31:0]      prf_rdata1,
  input  logic [31:0]      prf_rdata2,

  output logic        alu_issue_valid,
  input  logic        alu_issue_ready,
  output cpu_pkg::issue_t      alu_issue_pkt,
  output logic        mul_issue_valid,
  input  logic        mul_issue_ready,
  output cpu_pkg::issue_t      mul_issue_pkt,
  output logic        lsu_issue_valid,
  input  logic        lsu_issue_ready,
  output cpu_pkg::issue_t      lsu_issue_pkt
);

  localparam int RS_IDX_W = $clog2(RS_DEPTH);

  logic [$bits(disp_pkt)-1:0] entries [RS_DEPTH];
  logic [TAG_W-1:0] rs1_tags [RS_DEPTH];
  logic [TAG_W-1:0] rs2_tags [RS_DEPTH];
  logic [ROB_IDX_W-1:0] rob_indices [RS_DEPTH];
  cpu_pkg::opcode_e ops [RS_DEPTH];
  logic [RS_DEPTH-1:0] valid;
  logic [RS_DEPTH-1:0] src1_ready;
  logic [RS_DEPTH-1:0] src2_ready;
  logic [RS_DEPTH-1:0][RS_DEPTH-1:0] older;

  function automatic logic is_mem(input cpu_pkg::opcode_e op);
    is_mem = (op >= cpu_pkg::OP_LB && op <= cpu_pkg::OP_SW);
  endfunction

  function automatic logic is_muldiv(input cpu_pkg::opcode_e op);
    is_muldiv = (op >= cpu_pkg::OP_MUL && op <= cpu_pkg::OP_REMU);
  endfunction

  logic [RS_IDX_W-1:0] alloc_idx;
  logic alloc_found;
  int valid_count;
  always_comb begin
    alloc_idx   = '0;
    alloc_found = 1'b0;
    valid_count = 0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (valid[i])
        valid_count++;
      else if (!alloc_found) begin
        alloc_idx   = RS_IDX_W'(i);
        alloc_found = 1'b1;
      end
    end
  end

  assign disp_ready = (valid_count < RS_DEPTH) && !flush.valid;
  wire disp_fire = disp_valid && disp_ready;

  logic [RS_DEPTH-1:0] ready_vec;
  always_comb begin
    for (int i = 0; i < RS_DEPTH; i++)
      ready_vec[i] = valid[i]
                  && (src1_ready[i] ||
                      (cdb.valid && cdb.tag == rs1_tags[i]))
                  && (src2_ready[i] ||
                      (cdb.valid && cdb.tag == rs2_tags[i]));
  end

  logic candidate_valid;
  logic [RS_IDX_W-1:0] candidate_idx;
  logic scan_blocked;
  always_comb begin
    candidate_valid = 1'b0;
    candidate_idx   = '0;
    scan_blocked    = 1'b0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      scan_blocked = 1'b0;
      for (int j = 0; j < RS_DEPTH; j++) begin
        if (valid[j] && ready_vec[j] && older[j][i])
          scan_blocked = 1'b1;
        if (is_mem(ops[i]) && valid[j] &&
            is_mem(ops[j]) && older[j][i])
          scan_blocked = 1'b1;
      end
      if (!candidate_valid && ready_vec[i] && !scan_blocked) begin
        candidate_valid = 1'b1;
        candidate_idx   = RS_IDX_W'(i);
      end
    end
  end

  wire select_valid = candidate_valid;
  wire [RS_IDX_W-1:0] select_idx = candidate_idx;
  cpu_pkg::dispatch_t selected_entry;
  logic [TAG_W-1:0] selected_rs1_tag, selected_rs2_tag;
  logic [ROB_IDX_W-1:0] selected_rob_idx;
  cpu_pkg::opcode_e selected_op;
  always_comb begin
    selected_entry   = '0;
    selected_rs1_tag = '0;
    selected_rs2_tag = '0;
    selected_rob_idx = '0;
    selected_op      = cpu_pkg::OP_ADDI;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (select_idx == RS_IDX_W'(i)) begin
        selected_entry   = entries[i];
        selected_rs1_tag = rs1_tags[i];
        selected_rs2_tag = rs2_tags[i];
        selected_rob_idx = rob_indices[i];
        selected_op      = ops[i];
      end
    end
  end

  wire select_squashed = flush.valid && flush.squash_mask[selected_rob_idx];
  wire issue_valid = select_valid && !select_squashed;

  assign prf_raddr1 = selected_rs1_tag;
  assign prf_raddr2 = selected_rs2_tag;

  cpu_pkg::issue_t selected_pkt;
  always_comb begin
    selected_pkt         = '0;
    selected_pkt.d       = selected_entry;
    selected_pkt.rs1_val = prf_rdata1;
    selected_pkt.rs2_val = prf_rdata2;
  end

  assign alu_issue_pkt = selected_pkt;
  assign mul_issue_pkt = selected_pkt;
  assign lsu_issue_pkt = selected_pkt;
  assign alu_issue_valid = issue_valid && !is_muldiv(selected_op)
                                      && !is_mem(selected_op);
  assign mul_issue_valid = issue_valid && is_muldiv(selected_op);
  assign lsu_issue_valid = issue_valid && is_mem(selected_op);

  wire issue_fire = (alu_issue_valid && alu_issue_ready)
                 || (mul_issue_valid && mul_issue_ready)
                 || (lsu_issue_valid && lsu_issue_ready);

  logic [RS_DEPTH-1:0] remove_vec;
  always_comb begin
    remove_vec = '0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (valid[i] && flush.valid && flush.squash_mask[rob_indices[i]])
        remove_vec[i] = 1'b1;
      if (issue_fire && select_idx == RS_IDX_W'(i))
        remove_vec[i] = 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      valid      <= '0;
      src1_ready <= '0;
      src2_ready <= '0;
      older      <= '0;
    end else begin
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (remove_vec[i]) begin
          valid[i] <= 1'b0;
        end else if (valid[i] && cdb.valid) begin
          if (!src1_ready[i] && cdb.tag == rs1_tags[i])
            src1_ready[i] <= 1'b1;
          if (!src2_ready[i] && cdb.tag == rs2_tags[i])
            src2_ready[i] <= 1'b1;
        end
        for (int j = 0; j < RS_DEPTH; j++)
          if (remove_vec[i] || remove_vec[j])
            older[i][j] <= 1'b0;
      end

      if (disp_fire) begin
        valid[alloc_idx] <= 1'b1;
        entries[alloc_idx] <= disp_pkt;
        rs1_tags[alloc_idx] <= disp_pkt.rs1_tag;
        rs2_tags[alloc_idx] <= disp_pkt.rs2_tag;
        rob_indices[alloc_idx] <= disp_pkt.rob_idx;
        ops[alloc_idx] <= disp_pkt.op;
        src1_ready[alloc_idx] <= disp_pkt.rs1_ready ||
          (cdb.valid && cdb.tag == disp_pkt.rs1_tag);
        src2_ready[alloc_idx] <= disp_pkt.rs2_ready ||
          (cdb.valid && cdb.tag == disp_pkt.rs2_tag);
        for (int j = 0; j < RS_DEPTH; j++) begin
          older[alloc_idx][j] <= 1'b0;
          older[j][alloc_idx] <= valid[j] && !remove_vec[j];
        end
      end
    end
  end

endmodule
