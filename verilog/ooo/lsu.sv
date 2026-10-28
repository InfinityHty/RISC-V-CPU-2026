// lsu.sv — Load/Store 单元 [B]
// 单在途访存：load 不越过尚未落盘的旧 store。store 先完成 CDB，等待 ROB
// commit 后才进入不可冲刷的写事务，从而兼顾按序提交与错误路径恢复。
import cpu_pkg::*;

module lsu
(
  input  logic        clk,
  input  logic        rst,

  input  logic        issue_valid,
  output logic        issue_ready,
  input  cpu_pkg::issue_t      issue_pkt,

  input  cpu_pkg::cdb_t        cdb,
  input  cpu_pkg::commit_t     commit,
  input  cpu_pkg::flush_t      flush,

  output cpu_pkg::cdb_t        result_pkt,
  input  logic        result_ready,

  output logic        mem_req_valid,
  input  logic        mem_req_ready,
  output logic [31:0] mem_req_addr,
  output logic [31:0] mem_req_wdata,
  output logic [3:0]  mem_req_wstrb,
  output logic        mem_req_write,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_STORE_COMMIT,
    ST_LOAD_REQ,
    ST_LOAD_WAIT,
    ST_STORE_REQ,
    ST_STORE_WAIT
  } state_t;
  state_t state;

  cpu_pkg::opcode_e load_op;
  logic [1:0]       load_byte_offset;
  logic [TAG_W-1:0] load_tag;
  logic [ROB_IDX_W-1:0] load_rob_idx;
  logic [31:0]      load_pc;
  logic             load_killed;

  logic [31:0]      store_addr;
  logic [31:0]      store_wdata;
  logic [3:0]       store_wstrb;
  logic [ROB_IDX_W-1:0] store_rob_idx;

  wire [31:0] issue_ea = issue_pkt.rs1_val + issue_pkt.d.imm;
  wire issue_squashed = flush.valid && flush.squash_mask[issue_pkt.d.rob_idx];
  assign issue_ready = (state == ST_IDLE) && !result_pkt.valid && !flush.valid;
  wire issue_fire = issue_valid && issue_ready && !issue_squashed;

  logic [31:0] issue_store_data;
  logic [3:0]  issue_store_strb;
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

  logic [31:0] shifted_load_data;
  logic [31:0] extended_load_data;
  always_comb begin
    shifted_load_data = mem_resp_data >> {load_byte_offset, 3'b000};
    extended_load_data = shifted_load_data;
    case (load_op)
      cpu_pkg::OP_LB:
        extended_load_data = {{24{shifted_load_data[7]}}, shifted_load_data[7:0]};
      cpu_pkg::OP_LBU:
        extended_load_data = {24'd0, shifted_load_data[7:0]};
      cpu_pkg::OP_LH:
        extended_load_data = {{16{shifted_load_data[15]}}, shifted_load_data[15:0]};
      cpu_pkg::OP_LHU:
        extended_load_data = {16'd0, shifted_load_data[15:0]};
      default: begin end
    endcase
  end

  assign mem_req_valid = (state == ST_LOAD_REQ) || (state == ST_STORE_REQ);
  assign mem_req_addr  = (state == ST_STORE_REQ) ? store_addr : load_addr_aligned;
  assign mem_req_wdata = store_wdata;
  assign mem_req_wstrb = (state == ST_STORE_REQ) ? store_wstrb : 4'b0000;
  assign mem_req_write = (state == ST_STORE_REQ);

  logic [31:0] load_addr_aligned;
  always_comb load_addr_aligned = {load_addr_saved[31:2], 2'b00};
  logic [31:0] load_addr_saved;

  always_ff @(posedge clk) begin
    if (rst) begin
      state            <= ST_IDLE;
      load_op          <= cpu_pkg::OP_LW;
      load_byte_offset <= '0;
      load_tag         <= '0;
      load_rob_idx     <= '0;
      load_pc          <= '0;
      load_killed      <= 1'b0;
      load_addr_saved  <= '0;
      store_addr       <= '0;
      store_wdata      <= '0;
      store_wstrb      <= '0;
      store_rob_idx    <= '0;
      result_pkt       <= '0;
    end else begin
      if (result_pkt.valid && result_ready)
        result_pkt.valid <= 1'b0;

      if (flush.valid && result_pkt.valid &&
          flush.squash_mask[result_pkt.rob_idx])
        result_pkt.valid <= 1'b0;

      case (state)
        ST_IDLE: begin
          if (issue_fire) begin
            if (issue_pkt.d.is_store) begin
              store_addr    <= {issue_ea[31:2], 2'b00};
              store_wdata   <= issue_store_data;
              store_wstrb   <= issue_store_strb;
              store_rob_idx <= issue_pkt.d.rob_idx;
              result_pkt    <= '0;
              result_pkt.valid   <= 1'b1;
              result_pkt.tag     <= X0_TAG;
              result_pkt.rob_idx <= issue_pkt.d.rob_idx;
              result_pkt.pc      <= issue_pkt.d.pc;
              result_pkt.correct_pc <= issue_pkt.d.pc + 32'd4;
              state <= ST_STORE_COMMIT;
            end else begin
              load_op          <= issue_pkt.d.op;
              load_byte_offset <= issue_ea[1:0];
              load_addr_saved  <= issue_ea;
              load_tag         <= issue_pkt.d.rd_tag;
              load_rob_idx     <= issue_pkt.d.rob_idx;
              load_pc          <= issue_pkt.d.pc;
              load_killed      <= 1'b0;
              state            <= ST_LOAD_REQ;
            end
          end
        end

        ST_STORE_COMMIT: begin
          if (flush.valid && flush.squash_mask[store_rob_idx]) begin
            result_pkt.valid <= 1'b0;
            state <= ST_IDLE;
          end else if (commit.valid && commit.is_store &&
                       commit.rob_idx == store_rob_idx) begin
            state <= ST_STORE_REQ;
          end
        end

        ST_LOAD_REQ: begin
          if (flush.valid && flush.squash_mask[load_rob_idx])
            load_killed <= 1'b1;
          if (mem_req_valid && mem_req_ready)
            state <= ST_LOAD_WAIT;
        end

        ST_LOAD_WAIT: begin
          if (flush.valid && flush.squash_mask[load_rob_idx])
            load_killed <= 1'b1;
          if (mem_resp_valid) begin
            if (!load_killed &&
                !(flush.valid && flush.squash_mask[load_rob_idx])) begin
              result_pkt    <= '0;
              result_pkt.valid   <= 1'b1;
              result_pkt.tag     <= load_tag;
              result_pkt.value   <= extended_load_data;
              result_pkt.rob_idx <= load_rob_idx;
              result_pkt.pc      <= load_pc;
              result_pkt.correct_pc <= load_pc + 32'd4;
            end
            state <= ST_IDLE;
          end
        end

        ST_STORE_REQ: begin
          if (mem_req_valid && mem_req_ready)
            state <= ST_STORE_WAIT;
        end

        ST_STORE_WAIT: begin
          if (mem_resp_valid)
            state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  wire unused_ok = &{1'b0, cdb.valid};

endmodule
