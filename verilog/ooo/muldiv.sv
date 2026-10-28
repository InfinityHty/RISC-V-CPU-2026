// muldiv.sv — M 扩展乘除法器 [B]
// 乘法单周期完成；除法使用 32 拍恢复余数迭代。结果寄存器支持 CDB 反压。
import cpu_pkg::*;

module muldiv
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

  typedef enum logic {ST_IDLE, ST_DIV} state_t;
  state_t state;

  cpu_pkg::issue_t op_reg;
  logic [31:0] dividend;
  logic [31:0] divisor;
  logic [32:0] remainder;
  logic [5:0]  div_count;
  logic        div_neg_quotient;
  logic        div_neg_remainder;

  logic signed [32:0] mul_lhs;
  logic signed [32:0] mul_rhs;
  logic signed [65:0] mul_product;
  logic [31:0]        mul_value;

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
    if (issue_pkt.d.op == cpu_pkg::OP_MUL)
      mul_value = mul_product[31:0];
    else
      mul_value = mul_product[63:32];
  end

  wire issue_squashed = flush.valid && flush.squash_mask[issue_pkt.d.rob_idx];
  assign issue_ready = (state == ST_IDLE) && (!result_pkt.valid || result_ready);
  wire issue_fire = issue_valid && issue_ready && !issue_squashed;

  wire div_signed = (op_reg.d.op == cpu_pkg::OP_DIV) ||
                    (op_reg.d.op == cpu_pkg::OP_REM);
  wire issue_div_signed = (issue_pkt.d.op == cpu_pkg::OP_DIV) ||
                          (issue_pkt.d.op == cpu_pkg::OP_REM);
  wire issue_div_zero = (issue_pkt.rs2_val == 32'd0);

  wire [32:0] div_shifted_remainder = {remainder[31:0], dividend[31]};
  wire        div_subtract = div_shifted_remainder >= {1'b0, divisor};
  wire [32:0] div_next_remainder = div_subtract
                                 ? div_shifted_remainder - {1'b0, divisor}
                                 : div_shifted_remainder;
  wire [31:0] div_next_quotient = {dividend[30:0], div_subtract};
  wire        div_last = (div_count == 6'd31);
  wire [31:0] div_signed_quotient = div_neg_quotient
                                  ? (~div_next_quotient + 32'd1) : div_next_quotient;
  wire [31:0] div_signed_remainder = div_neg_remainder
                                   ? (~div_next_remainder[31:0] + 32'd1)
                                   : div_next_remainder[31:0];

  function automatic cpu_pkg::cdb_t make_result(
    input cpu_pkg::issue_t pkt,
    input logic [31:0] value
  );
    cpu_pkg::cdb_t result;
    begin
      result          = '0;
      result.valid    = 1'b1;
      result.tag      = pkt.d.rd_tag;
      result.value    = value;
      result.rob_idx  = pkt.d.rob_idx;
      result.pc       = pkt.d.pc;
      result.correct_pc = pkt.d.pc + 32'd4;
      make_result = result;
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      state             <= ST_IDLE;
      op_reg            <= '0;
      dividend          <= '0;
      divisor           <= '0;
      remainder         <= '0;
      div_count         <= '0;
      div_neg_quotient  <= 1'b0;
      div_neg_remainder <= 1'b0;
      result_pkt        <= '0;
    end else begin
      if (result_pkt.valid && result_ready)
        result_pkt.valid <= 1'b0;

      if (flush.valid && result_pkt.valid &&
          flush.squash_mask[result_pkt.rob_idx])
        result_pkt.valid <= 1'b0;

      case (state)
        ST_IDLE: begin
          if (issue_fire) begin
            if (issue_pkt.d.op >= cpu_pkg::OP_MUL &&
                issue_pkt.d.op <= cpu_pkg::OP_MULHU) begin
              result_pkt <= make_result(issue_pkt, mul_value);
            end else if (issue_div_zero) begin
              if (issue_pkt.d.op == cpu_pkg::OP_DIV ||
                  issue_pkt.d.op == cpu_pkg::OP_DIVU)
                result_pkt <= make_result(issue_pkt, 32'hffff_ffff);
              else
                result_pkt <= make_result(issue_pkt, issue_pkt.rs1_val);
            end else begin
              op_reg <= issue_pkt;
              dividend <= issue_div_signed && issue_pkt.rs1_val[31]
                        ? (~issue_pkt.rs1_val + 32'd1) : issue_pkt.rs1_val;
              divisor <= issue_div_signed && issue_pkt.rs2_val[31]
                       ? (~issue_pkt.rs2_val + 32'd1) : issue_pkt.rs2_val;
              remainder         <= '0;
              div_count         <= '0;
              div_neg_quotient  <= issue_div_signed &&
                                   (issue_pkt.rs1_val[31] ^ issue_pkt.rs2_val[31]);
              div_neg_remainder <= issue_div_signed && issue_pkt.rs1_val[31];
              state             <= ST_DIV;
            end
          end
        end

        ST_DIV: begin
          if (flush.valid && flush.squash_mask[op_reg.d.rob_idx]) begin
            state <= ST_IDLE;
          end else begin
            dividend  <= div_next_quotient;
            remainder <= div_next_remainder;
            div_count <= div_count + 1'b1;
            if (div_last) begin
              if (op_reg.d.op == cpu_pkg::OP_DIV ||
                  op_reg.d.op == cpu_pkg::OP_DIVU)
                result_pkt <= make_result(op_reg, div_signed_quotient);
              else
                result_pkt <= make_result(op_reg, div_signed_remainder);
              state <= ST_IDLE;
            end
          end
        end
      endcase
    end
  end

  wire unused_ok = &{1'b0, div_signed};

endmodule
