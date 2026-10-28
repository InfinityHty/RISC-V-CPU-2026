import cpu_pkg::*;

module lsu
(
  input  logic clk,
  input  logic rst,
  input  logic issue_valid,
  output logic issue_ready,
  input  cpu_pkg::issue_t issue_pkt,
  input  cpu_pkg::cdb_t [CDB_WIDTH-1:0] cdb,
  input  cpu_pkg::commit_t [COMMIT_WIDTH-1:0] commit,
  input  cpu_pkg::flush_t flush,
  output cpu_pkg::cdb_t result_pkt,
  input  logic result_ready,
  output logic mem_req_valid,
  input  logic mem_req_ready,
  output logic [31:0] mem_req_addr,
  output logic [31:0] mem_req_wdata,
  output logic [3:0] mem_req_wstrb,
  output logic mem_req_write,
  input  logic mem_resp_valid,
  input  logic [31:0] mem_resp_data,
  output logic store_req_valid,
  input  logic store_req_ready,
  output logic [31:0] store_req_addr,
  output logic [31:0] store_req_wdata,
  output logic [3:0] store_req_wstrb
);

  localparam int STORE_DEPTH = 16;
  localparam int LOAD_DEPTH = 8;
  localparam int STORE_PTR_W = $clog2(STORE_DEPTH);
  localparam int STORE_CNT_W = $clog2(STORE_DEPTH + 1);
  localparam int LOAD_PTR_W = $clog2(LOAD_DEPTH);
  localparam int LOAD_CNT_W = $clog2(LOAD_DEPTH + 1);

  logic [31:0] sq_addr [STORE_DEPTH];
  logic [31:0] sq_wdata [STORE_DEPTH];
  logic [3:0] sq_wstrb [STORE_DEPTH];
  logic [ROB_IDX_W-1:0] sq_rob [STORE_DEPTH];
  logic sq_committed [STORE_DEPTH];
  logic sq_killed [STORE_DEPTH];
  logic [STORE_PTR_W-1:0] sq_head, sq_tail;
  logic [STORE_CNT_W-1:0] sq_count;

  cpu_pkg::opcode_e load_op [LOAD_DEPTH];
  logic [1:0] load_offset [LOAD_DEPTH];
  logic [TAG_W-1:0] load_tag [LOAD_DEPTH];
  logic [ROB_IDX_W-1:0] load_rob [LOAD_DEPTH];
  logic [31:0] load_pc [LOAD_DEPTH];
  logic [31:0] load_addr [LOAD_DEPTH];
  logic load_requested [LOAD_DEPTH];
  logic load_killed [LOAD_DEPTH];
  logic [LOAD_PTR_W-1:0] load_head, load_req_ptr, load_tail;
  logic [LOAD_CNT_W-1:0] load_count;

  wire [31:0] issue_ea = issue_pkt.rs1_val + issue_pkt.d.imm;
  logic [31:0] issue_store_data;
  logic [3:0] issue_store_strb;
  always_comb begin
    issue_store_data = issue_pkt.rs2_val;
    issue_store_strb = 4'b1111;
    case (issue_pkt.d.op)
      cpu_pkg::OP_SB: begin
        issue_store_data = issue_pkt.rs2_val << {issue_ea[1:0], 3'b000};
        issue_store_strb = 4'b0001 << issue_ea[1:0];
      end
      cpu_pkg::OP_SH: begin
        issue_store_data = issue_pkt.rs2_val << {issue_ea[1], 4'b0000};
        issue_store_strb = issue_ea[1] ? 4'b1100 : 4'b0011;
      end
      default: begin end
    endcase
  end

  wire issue_squashed = flush.valid && flush.squash_mask[issue_pkt.d.rob_idx];
  wire store_result_blocked = mem_resp_valid || (result_pkt.valid && !result_ready);
  assign issue_ready = !flush.valid && (issue_pkt.d.is_store
                     ? (sq_count < STORE_DEPTH && !store_result_blocked)
                     : (load_count < LOAD_DEPTH && sq_count == 0
                        && (!result_pkt.valid || result_ready)));
  wire issue_fire = issue_valid && issue_ready && !issue_squashed;
  wire store_fire = issue_fire && issue_pkt.d.is_store;
  wire load_fire = issue_fire && !issue_pkt.d.is_store;

  assign store_req_valid = sq_count != 0 && sq_committed[sq_head] && !sq_killed[sq_head];
  assign store_req_addr = sq_addr[sq_head];
  assign store_req_wdata = sq_wdata[sq_head];
  assign store_req_wstrb = sq_wstrb[sq_head];
  wire sq_drop = sq_count != 0 && sq_killed[sq_head];
  wire sq_drain = store_req_valid && store_req_ready;
  wire sq_pop = sq_drop || sq_drain;

  // load_req_ptr == load_tail 在队列满（count==LOAD_DEPTH）时也可能成立；
  // 此时仍有尚未发出的请求，必须用 count 区分“满”和“空”。
  wire load_req_pending = (load_req_ptr != load_tail)
                       || (load_count == LOAD_CNT_W'(LOAD_DEPTH));
  assign mem_req_valid = load_count != 0 && load_req_pending
                      && !load_requested[load_req_ptr]
                      && (!result_pkt.valid || result_ready);
  assign mem_req_addr = {load_addr[load_req_ptr][31:2], 2'b00};
  assign mem_req_wdata = 32'd0;
  assign mem_req_wstrb = 4'b0000;
  assign mem_req_write = 1'b0;
  wire load_req_fire = mem_req_valid && mem_req_ready;
  wire load_resp_fire = mem_resp_valid && load_count != 0;

  logic [31:0] shifted_load_data, extended_load_data;
  always_comb begin
    shifted_load_data = mem_resp_data >> {load_offset[load_head], 3'b000};
    extended_load_data = shifted_load_data;
    case (load_op[load_head])
      cpu_pkg::OP_LB: extended_load_data = {{24{shifted_load_data[7]}}, shifted_load_data[7:0]};
      cpu_pkg::OP_LBU: extended_load_data = {24'd0, shifted_load_data[7:0]};
      cpu_pkg::OP_LH: extended_load_data = {{16{shifted_load_data[15]}}, shifted_load_data[15:0]};
      cpu_pkg::OP_LHU: extended_load_data = {16'd0, shifted_load_data[15:0]};
      default: begin end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      sq_head <= '0;
      sq_tail <= '0;
      sq_count <= '0;
      load_head <= '0;
      load_req_ptr <= '0;
      load_tail <= '0;
      load_count <= '0;
      result_pkt <= '0;
    end else begin
      if (result_pkt.valid && result_ready)
        result_pkt.valid <= 1'b0;
      if (flush.valid && result_pkt.valid && flush.squash_mask[result_pkt.rob_idx])
        result_pkt.valid <= 1'b0;

      if (store_fire) begin
        sq_addr[sq_tail] <= {issue_ea[31:2], 2'b00};
        sq_wdata[sq_tail] <= issue_store_data;
        sq_wstrb[sq_tail] <= issue_store_strb;
        sq_rob[sq_tail] <= issue_pkt.d.rob_idx;
        sq_committed[sq_tail] <= 1'b0;
        sq_killed[sq_tail] <= 1'b0;
        sq_tail <= sq_tail + 1'b1;
        result_pkt <= '0;
        result_pkt.valid <= 1'b1;
        result_pkt.tag <= X0_TAG;
        result_pkt.rob_idx <= issue_pkt.d.rob_idx;
        result_pkt.pc <= issue_pkt.d.pc;
        result_pkt.correct_pc <= issue_pkt.d.pc + 32'd4;
      end
      if (sq_pop) begin
        sq_head <= sq_head + 1'b1;
      end
      sq_count <= sq_count + (store_fire ? 1 : 0) - (sq_pop ? 1 : 0);

      for (int c = 0; c < COMMIT_WIDTH; c++) begin
        if (commit[c].valid && commit[c].is_store) begin
          for (int i = 0; i < STORE_DEPTH; i++)
            if (i < sq_count && sq_rob[STORE_PTR_W'(sq_head + i)] == commit[c].rob_idx)
              sq_committed[STORE_PTR_W'(sq_head + i)] <= 1'b1;
        end
      end

      if (load_fire) begin
        load_op[load_tail] <= issue_pkt.d.op;
        load_offset[load_tail] <= issue_ea[1:0];
        load_tag[load_tail] <= issue_pkt.d.rd_tag;
        load_rob[load_tail] <= issue_pkt.d.rob_idx;
        load_pc[load_tail] <= issue_pkt.d.pc;
        load_addr[load_tail] <= issue_ea;
        load_requested[load_tail] <= 1'b0;
        load_killed[load_tail] <= 1'b0;
        load_tail <= load_tail + 1'b1;
      end
      if (load_req_fire) begin
        load_requested[load_req_ptr] <= 1'b1;
        load_req_ptr <= load_req_ptr + 1'b1;
      end
      if (load_resp_fire)
        load_head <= load_head + 1'b1;
      load_count <= load_count + (load_fire ? 1 : 0) - (load_resp_fire ? 1 : 0);

      if (mem_resp_valid) begin
        if (!load_killed[load_head]
            && !(flush.valid && flush.squash_mask[load_rob[load_head]])) begin
          result_pkt <= '0;
          result_pkt.valid <= 1'b1;
          result_pkt.tag <= load_tag[load_head];
          result_pkt.value <= extended_load_data;
          result_pkt.rob_idx <= load_rob[load_head];
          result_pkt.pc <= load_pc[load_head];
          result_pkt.correct_pc <= load_pc[load_head] + 32'd4;
        end
      end

      if (flush.valid) begin
        // 已提交 store 不可被后续 flush 清除；否则 rob_idx 复用后可能
        // 把一条已经提交、尚未落盘的 store 误杀。
        for (int i = 0; i < STORE_DEPTH; i++)
          if (i < sq_count
              && !sq_committed[STORE_PTR_W'(sq_head + i)]
              && flush.squash_mask[sq_rob[STORE_PTR_W'(sq_head + i)]]) begin
            sq_killed[STORE_PTR_W'(sq_head + i)] <= 1'b1;
          end
        for (int i = 0; i < LOAD_DEPTH; i++)
          if (i < load_count && flush.squash_mask[load_rob[LOAD_PTR_W'(load_head + i)]])
            load_killed[LOAD_PTR_W'(load_head + i)] <= 1'b1;
      end
    end
  end

  wire unused_ok = &{1'b0, cdb[0].valid};

endmodule
