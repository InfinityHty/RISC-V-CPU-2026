`timescale 1ns/1ps
module tb_alu;
  import cpu_pkg::*;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic issue_valid, issue_ready, result_ready;
  issue_t issue_pkt;
  cdb_t result_pkt;

  alu dut (.*);

  task automatic check_op(
    input opcode_e op,
    input logic [31:0] pc,
    input logic [31:0] imm,
    input logic [31:0] a,
    input logic [31:0] b,
    input logic pred_taken,
    input logic [31:0] pred_target,
    input logic [31:0] exp_value,
    input logic exp_branch,
    input logic exp_mispredict,
    input logic [31:0] exp_pc
  );
    cdb_t held;
    begin
      @(negedge clk);
      issue_pkt = '0;
      issue_pkt.d.op = op;
      issue_pkt.d.pc = pc;
      issue_pkt.d.imm = imm;
      issue_pkt.d.rd_tag = 6'd17;
      issue_pkt.d.rob_idx = 6'd9;
      issue_pkt.d.is_branch = exp_branch;
      issue_pkt.d.pred_taken = pred_taken;
      issue_pkt.d.pred_target = pred_target;
      issue_pkt.rs1_val = a;
      issue_pkt.rs2_val = b;
      issue_valid = 1;
      result_ready = 0;
      while (!issue_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      issue_valid = 0;
      if (!result_pkt.valid) $fatal(1, "no result op=%0d", op);
      if (result_pkt.value !== exp_value || result_pkt.pc !== pc ||
          result_pkt.tag !== 6'd17 || result_pkt.rob_idx !== 6'd9 ||
          result_pkt.is_branch !== exp_branch ||
          result_pkt.mispredict !== exp_mispredict ||
          (exp_branch && result_pkt.correct_pc !== exp_pc))
        $fatal(1, "bad result op=%0d value=%h/%h branch=%b misp=%b pc=%h/%h",
               op, result_pkt.value, exp_value, result_pkt.is_branch,
               result_pkt.mispredict, result_pkt.correct_pc, exp_pc);
      held = result_pkt;
      repeat (2) begin
        @(posedge clk);
        @(negedge clk);
        if (result_pkt !== held) $fatal(1, "result changed under backpressure op=%0d", op);
      end
      result_ready = 1;
      @(posedge clk);
      @(negedge clk);
      result_ready = 0;
      if (result_pkt.valid) $fatal(1, "result not consumed op=%0d", op);
    end
  endtask

  initial begin
    issue_valid = 0;
    issue_pkt = '0;
    result_ready = 0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 0;

    check_op(OP_LUI,   32'h100, 32'h12345000, 0, 0, 0, 0, 32'h12345000, 0, 0, 0);
    check_op(OP_AUIPC, 32'h100, 32'h2000, 0, 0, 0, 0, 32'h2100, 0, 0, 0);
    check_op(OP_ADDI,  0, -1, 5, 0, 0, 0, 4, 0, 0, 0);
    check_op(OP_SLTI,  0, 0, -1, 0, 0, 0, 1, 0, 0, 0);
    check_op(OP_SLTIU, 0, 1, -1, 0, 0, 0, 0, 0, 0, 0);
    check_op(OP_XORI,  0, 32'h0f0f, 32'h00ff, 0, 0, 0, 32'h0ff0, 0, 0, 0);
    check_op(OP_ORI,   0, 32'h0f00, 32'h00ff, 0, 0, 0, 32'h0fff, 0, 0, 0);
    check_op(OP_ANDI,  0, 32'h0f0f, 32'h00ff, 0, 0, 0, 32'h000f, 0, 0, 0);
    check_op(OP_SLLI,  0, 31, 1, 0, 0, 0, 32'h80000000, 0, 0, 0);
    check_op(OP_SRLI,  0, 4, 32'h80000000, 0, 0, 0, 32'h08000000, 0, 0, 0);
    check_op(OP_SRAI,  0, 4, 32'h80000000, 0, 0, 0, 32'hf8000000, 0, 0, 0);
    check_op(OP_ADD,   0, 0, 7, 9, 0, 0, 16, 0, 0, 0);
    check_op(OP_SUB,   0, 0, 7, 9, 0, 0, -2, 0, 0, 0);
    check_op(OP_SLL,   0, 0, 3, 33, 0, 0, 6, 0, 0, 0);
    check_op(OP_SLT,   0, 0, -2, 1, 0, 0, 1, 0, 0, 0);
    check_op(OP_SLTU,  0, 0, -2, 1, 0, 0, 0, 0, 0, 0);
    check_op(OP_XOR,   0, 0, 32'haa55, 32'hffff, 0, 0, 32'h55aa, 0, 0, 0);
    check_op(OP_SRL,   0, 0, 32'h80000000, 8, 0, 0, 32'h00800000, 0, 0, 0);
    check_op(OP_SRA,   0, 0, 32'h80000000, 8, 0, 0, 32'hff800000, 0, 0, 0);
    check_op(OP_OR,    0, 0, 32'ha000, 32'h0a00, 0, 0, 32'haa00, 0, 0, 0);
    check_op(OP_AND,   0, 0, 32'haa55, 32'h0ff0, 0, 0, 32'h0a50, 0, 0, 0);

    check_op(OP_BEQ, 32'h200, 8, 4, 4, 0, 0, 0, 1, 1, 32'h208);
    check_op(OP_BNE, 32'h200, 8, 4, 5, 1, 32'h208, 0, 1, 0, 32'h208);
    check_op(OP_BLT, 32'h200, 8, -1, 0, 0, 0, 0, 1, 1, 32'h208);
    check_op(OP_BGE, 32'h200, 8, -1, 0, 0, 0, 0, 1, 0, 32'h204);
    check_op(OP_BLTU, 32'h200, 8, 1, 2, 1, 32'h999, 0, 1, 1, 32'h208);
    check_op(OP_BGEU, 32'h200, 8, 1, 2, 1, 32'h208, 0, 1, 1, 32'h204);
    check_op(OP_JAL, 32'h200, 32'h100, 0, 0, 0, 0, 32'h204, 1, 1, 32'h300);
    check_op(OP_JALR, 32'h200, 4, 32'h301, 0, 1, 32'h300, 32'h204, 1, 1, 32'h304);

    $display("TB_ALU_PASS");
    $finish;
  end
endmodule
