import cpu_pkg::*;

module student_top
(
  input  wire clock,
  input  wire reset,
  output wire [31:0] araddr,
  output wire arvalid,
  input  wire arready,
  input  wire [31:0] rdata,
  input  wire [1:0] rresp,
  input  wire rvalid,
  output wire rready,
  output wire [31:0] awaddr,
  output wire awvalid,
  input  wire awready,
  output wire [31:0] wdata,
  output wire [3:0] wstrb,
  output wire wvalid,
  input  wire wready,
  input  wire [1:0] bresp,
  input  wire bvalid,
  output wire bready
);

  logic clk, rst;
  assign clk = clock;
  assign rst = reset;

  cpu_pkg::cdb_t [CDB_WIDTH-1:0] cdb_bus;
  cpu_pkg::commit_t [COMMIT_WIDTH-1:0] commit_bus;
  cpu_pkg::flush_t flush_bus;

  logic [FETCH_WIDTH-1:0] if_instr_valid;
  logic [WIDTH_CNT_W-1:0] if_instr_ready_count;
  logic [FETCH_WIDTH-1:0][31:0] if_instr_pc, if_instr_data;
  logic [FETCH_WIDTH-1:0] if_instr_pred_taken;
  logic [FETCH_WIDTH-1:0][31:0] if_instr_pred_target;
  logic if_req_valid, if_req_ready;
  logic [31:0] if_req_addr;
  logic if_resp_valid;
  logic [ICACHE_LINE_WORDS*32-1:0] if_resp_data;
  logic ic_mem_req_valid, ic_mem_req_ready;
  logic [31:0] ic_mem_req_addr;
  logic ic_mem_resp_valid;
  logic [31:0] ic_mem_resp_data;

  logic [FETCH_WIDTH-1:0][31:0] bp_query_pc;
  logic [FETCH_WIDTH-1:0] bp_pred_taken;
  logic [FETCH_WIDTH-1:0][31:0] bp_pred_target;
  logic [CDB_WIDTH-1:0] rob_branch_update_valid;
  logic [CDB_WIDTH-1:0][31:0] bp_update_pc, bp_update_target;
  logic [CDB_WIDTH-1:0] bp_update_taken;

  logic [DISPATCH_WIDTH-1:0] dec_valid;
  logic [WIDTH_CNT_W-1:0] dec_ready_count;
  cpu_pkg::dispatch_t [DISPATCH_WIDTH-1:0] dec_pkt;
  logic [DISPATCH_WIDTH-1:0] rn_rob_valid;
  logic [WIDTH_CNT_W-1:0] rn_rob_ready_count;
  cpu_pkg::dispatch_t [DISPATCH_WIDTH-1:0] rn_rob_pkt;
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_W-1:0] rob_alloc_idx;
  logic [DISPATCH_WIDTH-1:0][TAG_W-1:0] rob_alloc_old_tag;
  logic [COMMIT_WIDTH-1:0] rob_commit_info_valid;
  logic [COMMIT_WIDTH-1:0][TAG_W-1:0] rob_commit_old_tag;
  logic [CDB_WIDTH-1:0] rob_ckpt_release_valid;
  logic [CDB_WIDTH-1:0][ROB_IDX_W-1:0] rob_ckpt_release_idx;
  logic [DISPATCH_WIDTH-1:0] rn_prf_alloc_valid;
  logic [DISPATCH_WIDTH-1:0][TAG_W-1:0] rn_prf_alloc_tag;
  logic [DISPATCH_WIDTH-1:0][ROB_IDX_W-1:0] rn_prf_alloc_rob_idx;
  logic [DISPATCH_WIDTH-1:0] rn_disp_valid;
  logic [WIDTH_CNT_W-1:0] rs_disp_ready_count;
  cpu_pkg::dispatch_t [DISPATCH_WIDTH-1:0] rn_disp_pkt;

  logic [PRF_READ_PORTS-1:0][TAG_W-1:0] rs_prf_raddr;
  logic [PRF_READ_PORTS-1:0][31:0] prf_rdata;
  logic [ALU_COUNT-1:0] rs_alu_issue_valid, alu_issue_ready;
  cpu_pkg::issue_t [ALU_COUNT-1:0] rs_alu_issue_pkt;
  logic rs_mul_issue_valid, mul_issue_ready;
  cpu_pkg::issue_t rs_mul_issue_pkt;
  logic rs_lsu_issue_valid, lsu_issue_ready;
  cpu_pkg::issue_t rs_lsu_issue_pkt;
  cpu_pkg::cdb_t [ALU_COUNT-1:0] alu_result;
  cpu_pkg::cdb_t mul_result, lsu_result;
  logic [ALU_COUNT-1:0] alu_result_ready;
  logic mul_result_ready, lsu_result_ready;

  logic lsu_mem_req_valid, lsu_mem_req_ready;
  logic [31:0] lsu_mem_req_addr, lsu_mem_req_wdata;
  logic [3:0] lsu_mem_req_wstrb;
  logic lsu_mem_req_write, lsu_mem_resp_valid;
  logic [31:0] lsu_mem_resp_data;
  logic lsu_store_req_valid, lsu_store_req_ready;
  logic [31:0] lsu_store_req_addr, lsu_store_req_wdata;
  logic [3:0] lsu_store_req_wstrb;
  logic dc_mem_req_valid, dc_mem_req_ready;
  logic [31:0] dc_mem_req_addr, dc_mem_req_wdata;
  logic [3:0] dc_mem_req_wstrb;
  logic dc_mem_req_write, dc_mem_resp_valid;
  logic [31:0] dc_mem_resp_data;

  ifu u_ifu (
    .clk(clk), .rst(rst), .flush(flush_bus),
    .instr_valid(if_instr_valid), .instr_ready_count(if_instr_ready_count),
    .instr_pc(if_instr_pc), .instr_data(if_instr_data),
    .instr_pred_taken(if_instr_pred_taken), .instr_pred_target(if_instr_pred_target),
    .pred_taken(bp_pred_taken), .pred_target(bp_pred_target),
    .mem_req_valid(if_req_valid), .mem_req_addr(if_req_addr), .mem_req_ready(if_req_ready),
    .mem_resp_valid(if_resp_valid), .mem_resp_data(if_resp_data)
  );

  icache u_icache (
    .clk(clk), .rst(rst), .flush(flush_bus),
    .fetch_valid(if_req_valid), .fetch_addr(if_req_addr), .fetch_ready(if_req_ready),
    .resp_valid(if_resp_valid), .resp_data(if_resp_data),
    .mem_req_valid(ic_mem_req_valid), .mem_req_addr(ic_mem_req_addr),
    .mem_req_ready(ic_mem_req_ready), .mem_resp_valid(ic_mem_resp_valid),
    .mem_resp_data(ic_mem_resp_data)
  );

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      bp_query_pc[i] = if_req_addr + i * 4;
      bp_update_pc[i] = cdb_bus[i].pc;
      bp_update_taken[i] = cdb_bus[i].correct_pc != cdb_bus[i].pc + 32'd4;
      bp_update_target[i] = cdb_bus[i].correct_pc;
    end
  end

  bpred u_bpred (
    .clk(clk), .rst(rst), .pc(bp_query_pc),
    .pred_taken(bp_pred_taken), .pred_target(bp_pred_target),
    .update_valid(rob_branch_update_valid), .update_pc(bp_update_pc),
    .update_taken(bp_update_taken), .update_target(bp_update_target)
  );

  assign if_instr_ready_count = dec_ready_count;
  generate
    for (genvar g = 0; g < DISPATCH_WIDTH; g++) begin : g_decode
      logic unused_instr_ready;
      decode u_decode (
        .clk(clk), .rst(rst),
        .instr_valid(if_instr_valid[g]), .instr_ready(unused_instr_ready),
        .instr_pc(if_instr_pc[g]), .instr_data(if_instr_data[g]),
        .pred_taken_i(if_instr_pred_taken[g]), .pred_target_i(if_instr_pred_target[g]),
        .dec_valid(dec_valid[g]), .dec_ready(dec_ready_count > g), .dec_pkt(dec_pkt[g])
      );
    end
  endgenerate

  rename u_rename (
    .clk(clk), .rst(rst), .dec_valid(dec_valid), .dec_ready_count(dec_ready_count),
    .dec_pkt(dec_pkt), .rob_alloc_valid(rn_rob_valid),
    .rob_alloc_ready_count(rn_rob_ready_count), .rob_alloc_pkt(rn_rob_pkt),
    .rob_alloc_idx(rob_alloc_idx), .rob_alloc_old_tag(rob_alloc_old_tag),
    .disp_valid(rn_disp_valid), .disp_ready_count(rs_disp_ready_count), .disp_pkt(rn_disp_pkt),
    .cdb(cdb_bus), .commit_valid(rob_commit_info_valid), .commit_old_tag(rob_commit_old_tag),
    .flush(flush_bus), .ckpt_release_valid(rob_ckpt_release_valid),
    .ckpt_release_rob_idx(rob_ckpt_release_idx),
    .prf_alloc_valid(rn_prf_alloc_valid), .prf_alloc_tag(rn_prf_alloc_tag),
    .prf_alloc_rob_idx(rn_prf_alloc_rob_idx)
  );

  rob u_rob (
    .clk(clk), .rst(rst), .rob_alloc_valid(rn_rob_valid),
    .rob_alloc_ready_count(rn_rob_ready_count), .rob_alloc_pkt(rn_rob_pkt),
    .rob_alloc_old_tag(rob_alloc_old_tag), .rob_alloc_idx(rob_alloc_idx),
    .cdb(cdb_bus), .commit(commit_bus),
    .commit_info_valid(rob_commit_info_valid), .commit_old_tag(rob_commit_old_tag),
    .flush(flush_bus), .ckpt_release_valid(rob_ckpt_release_valid),
    .ckpt_release_rob_idx(rob_ckpt_release_idx), .branch_update_valid(rob_branch_update_valid)
  );

  prf u_prf (
    .clk(clk), .rst(rst), .alloc_valid(rn_prf_alloc_valid), .alloc_tag(rn_prf_alloc_tag),
    .alloc_rob_idx(rn_prf_alloc_rob_idx), .cdb(cdb_bus),
    .raddr(rs_prf_raddr), .rdata(prf_rdata)
  );

  rs u_rs (
    .clk(clk), .rst(rst), .disp_valid(rn_disp_valid),
    .disp_ready_count(rs_disp_ready_count), .disp_pkt(rn_disp_pkt),
    .cdb(cdb_bus), .flush(flush_bus), .prf_raddr(rs_prf_raddr), .prf_rdata(prf_rdata),
    .alu_issue_valid(rs_alu_issue_valid), .alu_issue_ready(alu_issue_ready),
    .alu_issue_pkt(rs_alu_issue_pkt), .mul_issue_valid(rs_mul_issue_valid),
    .mul_issue_ready(mul_issue_ready), .mul_issue_pkt(rs_mul_issue_pkt),
    .lsu_issue_valid(rs_lsu_issue_valid), .lsu_issue_ready(lsu_issue_ready),
    .lsu_issue_pkt(rs_lsu_issue_pkt)
  );

  generate
    for (genvar a = 0; a < ALU_COUNT; a++) begin : g_alu
      alu u_alu (
        .clk(clk), .rst(rst), .flush(flush_bus), .issue_valid(rs_alu_issue_valid[a]),
        .issue_ready(alu_issue_ready[a]), .issue_pkt(rs_alu_issue_pkt[a]),
        .result_pkt(alu_result[a]), .result_ready(alu_result_ready[a])
      );
    end
  endgenerate

  muldiv u_muldiv (
    .clk(clk), .rst(rst), .flush(flush_bus), .issue_valid(rs_mul_issue_valid),
    .issue_ready(mul_issue_ready), .issue_pkt(rs_mul_issue_pkt),
    .result_pkt(mul_result), .result_ready(mul_result_ready)
  );

  lsu u_lsu (
    .clk(clk), .rst(rst), .issue_valid(rs_lsu_issue_valid), .issue_ready(lsu_issue_ready),
    .issue_pkt(rs_lsu_issue_pkt), .cdb(cdb_bus), .commit(commit_bus), .flush(flush_bus),
    .result_pkt(lsu_result), .result_ready(lsu_result_ready),
    .mem_req_valid(lsu_mem_req_valid), .mem_req_ready(lsu_mem_req_ready),
    .mem_req_addr(lsu_mem_req_addr), .mem_req_wdata(lsu_mem_req_wdata),
    .mem_req_wstrb(lsu_mem_req_wstrb), .mem_req_write(lsu_mem_req_write),
    .mem_resp_valid(lsu_mem_resp_valid), .mem_resp_data(lsu_mem_resp_data),
    .store_req_valid(lsu_store_req_valid), .store_req_ready(lsu_store_req_ready),
    .store_req_addr(lsu_store_req_addr), .store_req_wdata(lsu_store_req_wdata),
    .store_req_wstrb(lsu_store_req_wstrb)
  );

  cdb u_cdb (
    .clk(clk), .rst(rst), .alu_result(alu_result), .alu_ready(alu_result_ready),
    .mul_result(mul_result), .mul_ready(mul_result_ready),
    .lsu_result(lsu_result), .lsu_ready(lsu_result_ready), .out(cdb_bus)
  );

  dcache u_dcache (
    .clk(clk), .rst(rst), .req_valid(lsu_mem_req_valid), .req_ready(lsu_mem_req_ready),
    .req_addr(lsu_mem_req_addr), .req_wdata(lsu_mem_req_wdata),
    .req_wstrb(lsu_mem_req_wstrb), .req_write(lsu_mem_req_write),
    .resp_valid(lsu_mem_resp_valid), .resp_data(lsu_mem_resp_data),
    .store_valid(lsu_store_req_valid), .store_ready(lsu_store_req_ready),
    .store_addr(lsu_store_req_addr), .store_wdata(lsu_store_req_wdata),
    .store_wstrb(lsu_store_req_wstrb),
    .mem_req_valid(dc_mem_req_valid), .mem_req_ready(dc_mem_req_ready),
    .mem_req_addr(dc_mem_req_addr), .mem_req_wdata(dc_mem_req_wdata),
    .mem_req_wstrb(dc_mem_req_wstrb), .mem_req_write(dc_mem_req_write),
    .mem_resp_valid(dc_mem_resp_valid), .mem_resp_data(dc_mem_resp_data)
  );

  axi_master u_axi_master (
    .clk(clk), .rst(rst),
    .if_req_valid(ic_mem_req_valid), .if_req_ready(ic_mem_req_ready),
    .if_req_addr(ic_mem_req_addr), .if_resp_valid(ic_mem_resp_valid),
    .if_resp_data(ic_mem_resp_data), .dm_req_valid(dc_mem_req_valid),
    .dm_req_ready(dc_mem_req_ready), .dm_req_addr(dc_mem_req_addr),
    .dm_req_wdata(dc_mem_req_wdata), .dm_req_wstrb(dc_mem_req_wstrb),
    .dm_req_write(dc_mem_req_write), .dm_resp_valid(dc_mem_resp_valid),
    .dm_resp_data(dc_mem_resp_data), .araddr(araddr), .arvalid(arvalid),
    .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata),
    .wstrb(wstrb), .wvalid(wvalid), .wready(wready), .bresp(bresp),
    .bvalid(bvalid), .bready(bready)
  );



endmodule
