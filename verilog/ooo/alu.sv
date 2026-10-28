// alu.sv — 整数 ALU [B]
// 单周期运算，结果寄存器支持 CDB 反压和背靠背接收。
import cpu_pkg::*;

module alu
(
  input  logic   clk,
  input  logic   rst,
  input  cpu_pkg::flush_t flush,

  input  logic   issue_valid,
  output logic   issue_ready,
  input  cpu_pkg::issue_t issue_pkt,

  output cpu_pkg::cdb_t   result_pkt,
  input  logic   result_ready
);

  cpu_pkg::cdb_t computed;
  logic actual_taken;
  logic [31:0] actual_pc;

  always_comb begin
    computed     = '0;
    actual_taken = 1'b0;
    actual_pc    = issue_pkt.d.pc + 32'd4;

    computed.valid   = 1'b1;
    computed.tag     = issue_pkt.d.rd_tag;
    computed.rob_idx = issue_pkt.d.rob_idx;
    computed.pc      = issue_pkt.d.pc;
    computed.is_branch = issue_pkt.d.is_branch;

    case (issue_pkt.d.op)
      cpu_pkg::OP_LUI:   computed.value = issue_pkt.d.imm;
      cpu_pkg::OP_AUIPC: computed.value = issue_pkt.d.pc + issue_pkt.d.imm;
      cpu_pkg::OP_ADDI:  computed.value = issue_pkt.rs1_val + issue_pkt.d.imm;
      cpu_pkg::OP_SLTI:  computed.value = {31'd0, $signed(issue_pkt.rs1_val) < $signed(issue_pkt.d.imm)};
      cpu_pkg::OP_SLTIU: computed.value = {31'd0, issue_pkt.rs1_val < issue_pkt.d.imm};
      cpu_pkg::OP_XORI:  computed.value = issue_pkt.rs1_val ^ issue_pkt.d.imm;
      cpu_pkg::OP_ORI:   computed.value = issue_pkt.rs1_val | issue_pkt.d.imm;
      cpu_pkg::OP_ANDI:  computed.value = issue_pkt.rs1_val & issue_pkt.d.imm;
      cpu_pkg::OP_SLLI:  computed.value = issue_pkt.rs1_val << issue_pkt.d.imm[4:0];
      cpu_pkg::OP_SRLI:  computed.value = issue_pkt.rs1_val >> issue_pkt.d.imm[4:0];
      cpu_pkg::OP_SRAI:  computed.value = $signed(issue_pkt.rs1_val) >>> issue_pkt.d.imm[4:0];
      cpu_pkg::OP_ADD:   computed.value = issue_pkt.rs1_val + issue_pkt.rs2_val;
      cpu_pkg::OP_SUB:   computed.value = issue_pkt.rs1_val - issue_pkt.rs2_val;
      cpu_pkg::OP_SLL:   computed.value = issue_pkt.rs1_val << issue_pkt.rs2_val[4:0];
      cpu_pkg::OP_SLT:   computed.value = {31'd0, $signed(issue_pkt.rs1_val) < $signed(issue_pkt.rs2_val)};
      cpu_pkg::OP_SLTU:  computed.value = {31'd0, issue_pkt.rs1_val < issue_pkt.rs2_val};
      cpu_pkg::OP_XOR:   computed.value = issue_pkt.rs1_val ^ issue_pkt.rs2_val;
      cpu_pkg::OP_SRL:   computed.value = issue_pkt.rs1_val >> issue_pkt.rs2_val[4:0];
      cpu_pkg::OP_SRA:   computed.value = $signed(issue_pkt.rs1_val) >>> issue_pkt.rs2_val[4:0];
      cpu_pkg::OP_OR:    computed.value = issue_pkt.rs1_val | issue_pkt.rs2_val;
      cpu_pkg::OP_AND:   computed.value = issue_pkt.rs1_val & issue_pkt.rs2_val;
      default:           computed.value = 32'd0;
    endcase

    case (issue_pkt.d.op)
      cpu_pkg::OP_BEQ:  actual_taken = (issue_pkt.rs1_val == issue_pkt.rs2_val);
      cpu_pkg::OP_BNE:  actual_taken = (issue_pkt.rs1_val != issue_pkt.rs2_val);
      cpu_pkg::OP_BLT:  actual_taken = ($signed(issue_pkt.rs1_val) < $signed(issue_pkt.rs2_val));
      cpu_pkg::OP_BGE:  actual_taken = ($signed(issue_pkt.rs1_val) >= $signed(issue_pkt.rs2_val));
      cpu_pkg::OP_BLTU: actual_taken = (issue_pkt.rs1_val < issue_pkt.rs2_val);
      cpu_pkg::OP_BGEU: actual_taken = (issue_pkt.rs1_val >= issue_pkt.rs2_val);
      cpu_pkg::OP_JAL, cpu_pkg::OP_JALR: actual_taken = 1'b1;
      default: actual_taken = 1'b0;
    endcase

    if (issue_pkt.d.op == cpu_pkg::OP_JALR)
      actual_pc = (issue_pkt.rs1_val + issue_pkt.d.imm) & 32'hffff_fffe;
    else if (actual_taken)
      actual_pc = issue_pkt.d.pc + issue_pkt.d.imm;

    if (issue_pkt.d.op == cpu_pkg::OP_JAL || issue_pkt.d.op == cpu_pkg::OP_JALR)
      computed.value = issue_pkt.d.pc + 32'd4;

    computed.correct_pc = actual_pc;
    computed.mispredict = issue_pkt.d.is_branch &&
                          (actual_taken ? (!issue_pkt.d.pred_taken ||
                                           issue_pkt.d.pred_target != actual_pc)
                                        : issue_pkt.d.pred_taken);
  end

  assign issue_ready = !result_pkt.valid || result_ready;
  wire issue_fire = issue_valid && issue_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      result_pkt <= '0;
    end else begin
      if (result_pkt.valid && result_ready)
        result_pkt.valid <= 1'b0;
      if (flush.valid && result_pkt.valid && flush.squash_mask[result_pkt.rob_idx])
        result_pkt.valid <= 1'b0;
      if (issue_fire)
        result_pkt <= computed;
    end
  end

endmodule
