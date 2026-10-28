import cpu_pkg::*;

module muldiv
(
  input  logic clk,
  input  logic rst,
  input  cpu_pkg::flush_t flush,
  input  logic issue_valid,
  output logic issue_ready,
  input  cpu_pkg::issue_t issue_pkt,
  output cpu_pkg::cdb_t result_pkt,
  input  logic result_ready
);

  localparam int DIV_STEPS = 32 / DIV_BITS_PER_CYCLE;
  typedef enum logic {ST_IDLE, ST_DIV} state_t;
  state_t state;

  cpu_pkg::issue_t op_reg;
  logic [31:0] dividend, divisor;
  logic [32:0] remainder;
  logic [5:0] div_count;
  logic div_neg_quotient, div_neg_remainder;

  // 除法缓存必须区分 signed/unsigned；否则 DIV 与 DIVU 相同操作数会串用结果。
  logic cache_valid, cache_signed;
  logic [31:0] cache_lhs, cache_rhs, cache_quotient, cache_remainder;

  logic signed [32:0] mul_lhs, mul_rhs;
  logic signed [65:0] mul_product;
  logic [31:0] mul_value;

  always_comb begin
    mul_lhs = $signed({1'b0, issue_pkt.rs1_val});
    mul_rhs = $signed({1'b0, issue_pkt.rs2_val});
    case (issue_pkt.d.op)
      cpu_pkg::OP_MUL, cpu_pkg::OP_MULH: begin
        mul_lhs = $signed({issue_pkt.rs1_val[31], issue_pkt.rs1_val});
        mul_rhs = $signed({issue_pkt.rs2_val[31], issue_pkt.rs2_val});
      end
      cpu_pkg::OP_MULHSU:
        mul_lhs = $signed({issue_pkt.rs1_val[31], issue_pkt.rs1_val});
      default: begin end
    endcase
    mul_product = mul_lhs * mul_rhs;
    mul_value = issue_pkt.d.op == cpu_pkg::OP_MUL ? mul_product[31:0] : mul_product[63:32];
  end

  wire issue_squashed = flush.valid && flush.squash_mask[issue_pkt.d.rob_idx];
  assign issue_ready = state == ST_IDLE && (!result_pkt.valid || result_ready);
  wire issue_fire = issue_valid && issue_ready && !issue_squashed;
  wire issue_div_signed = issue_pkt.d.op == cpu_pkg::OP_DIV || issue_pkt.d.op == cpu_pkg::OP_REM;
  wire issue_div_zero = issue_pkt.rs2_val == 0;
  wire cache_hit = cache_valid && cache_signed == issue_div_signed
                && cache_lhs == issue_pkt.rs1_val && cache_rhs == issue_pkt.rs2_val;

  logic [31:0] div_work_quotient;
  logic [32:0] div_work_remainder;
  always_comb begin
    logic [32:0] shifted;
    logic subtract;
    div_work_quotient = dividend;
    div_work_remainder = remainder;
    for (int i = 0; i < DIV_BITS_PER_CYCLE; i++) begin
      shifted = {div_work_remainder[31:0], div_work_quotient[31]};
      subtract = shifted >= {1'b0, divisor};
      div_work_remainder = subtract ? shifted - {1'b0, divisor} : shifted;
      div_work_quotient = {div_work_quotient[30:0], subtract};
    end
  end

  wire div_last = div_count == DIV_STEPS-1;
  wire [31:0] div_signed_quotient = div_neg_quotient
                                  ? ~div_work_quotient + 1'b1 : div_work_quotient;
  wire [31:0] div_signed_remainder = div_neg_remainder
                                   ? ~div_work_remainder[31:0] + 1'b1
                                   : div_work_remainder[31:0];

  function automatic cpu_pkg::cdb_t make_result(
    input cpu_pkg::issue_t pkt,
    input logic [31:0] value
  );
    cpu_pkg::cdb_t result;
    begin
      result = '0;
      result.valid = 1'b1;
      result.tag = pkt.d.rd_tag;
      result.value = value;
      result.rob_idx = pkt.d.rob_idx;
      result.pc = pkt.d.pc;
      result.correct_pc = pkt.d.pc + 32'd4;
      make_result = result;
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= ST_IDLE;
      op_reg <= '0;
      dividend <= '0;
      divisor <= '0;
      remainder <= '0;
      div_count <= '0;
      div_neg_quotient <= 1'b0;
      div_neg_remainder <= 1'b0;
      cache_valid <= 1'b0;
      cache_signed <= 1'b0;
      cache_lhs <= '0;
      cache_rhs <= '0;
      cache_quotient <= '0;
      cache_remainder <= '0;
      result_pkt <= '0;
    end else begin
      if (result_pkt.valid && result_ready)
        result_pkt.valid <= 1'b0;
      if (flush.valid && result_pkt.valid && flush.squash_mask[result_pkt.rob_idx])
        result_pkt.valid <= 1'b0;

      case (state)
        ST_IDLE: begin
          if (issue_fire) begin
            if (issue_pkt.d.op >= cpu_pkg::OP_MUL && issue_pkt.d.op <= cpu_pkg::OP_MULHU) begin
              result_pkt <= make_result(issue_pkt, mul_value);
            end else if (issue_div_zero) begin
              if (issue_pkt.d.op == cpu_pkg::OP_DIV || issue_pkt.d.op == cpu_pkg::OP_DIVU)
                result_pkt <= make_result(issue_pkt, 32'hffff_ffff);
              else
                result_pkt <= make_result(issue_pkt, issue_pkt.rs1_val);
            end else if (cache_hit) begin
              if (issue_pkt.d.op == cpu_pkg::OP_DIV || issue_pkt.d.op == cpu_pkg::OP_DIVU)
                result_pkt <= make_result(issue_pkt, cache_quotient);
              else
                result_pkt <= make_result(issue_pkt, cache_remainder);
            end else begin
              op_reg <= issue_pkt;
              dividend <= issue_div_signed && issue_pkt.rs1_val[31]
                        ? ~issue_pkt.rs1_val + 1'b1 : issue_pkt.rs1_val;
              divisor <= issue_div_signed && issue_pkt.rs2_val[31]
                       ? ~issue_pkt.rs2_val + 1'b1 : issue_pkt.rs2_val;
              remainder <= '0;
              div_count <= '0;
              div_neg_quotient <= issue_div_signed
                                && (issue_pkt.rs1_val[31] ^ issue_pkt.rs2_val[31]);
              div_neg_remainder <= issue_div_signed && issue_pkt.rs1_val[31];
              state <= ST_DIV;
            end
          end
        end

        ST_DIV: begin
          if (flush.valid && flush.squash_mask[op_reg.d.rob_idx]) begin
            state <= ST_IDLE;
          end else begin
            dividend <= div_work_quotient;
            remainder <= div_work_remainder;
            div_count <= div_count + 1'b1;
            if (div_last) begin
              if (op_reg.d.op == cpu_pkg::OP_DIV || op_reg.d.op == cpu_pkg::OP_DIVU)
                result_pkt <= make_result(op_reg, div_signed_quotient);
              else
                result_pkt <= make_result(op_reg, div_signed_remainder);
              cache_valid <= 1'b1;
              cache_signed <= op_reg.d.op == cpu_pkg::OP_DIV || op_reg.d.op == cpu_pkg::OP_REM;
              cache_lhs <= op_reg.rs1_val;
              cache_rhs <= op_reg.rs2_val;
              cache_quotient <= div_signed_quotient;
              cache_remainder <= div_signed_remainder;
              state <= ST_IDLE;
            end
          end
        end
      endcase
    end
  end

endmodule
