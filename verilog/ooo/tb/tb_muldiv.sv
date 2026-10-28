`timescale 1ns/1ps
module tb_muldiv;
  import cpu_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  flush_t flush;
  logic issue_valid, issue_ready, result_ready;
  issue_t issue_pkt;
  cdb_t result_pkt;
  muldiv dut (.*);

  task automatic drive_issue(input opcode_e op, input logic [31:0] a,
                             input logic [31:0] b, input logic [5:0] rob);
    begin
      @(negedge clk);
      issue_pkt = '0;
      issue_pkt.d.op = op;
      issue_pkt.d.pc = 32'h100;
      issue_pkt.d.rd_tag = 17;
      issue_pkt.d.rob_idx = rob;
      issue_pkt.rs1_val = a;
      issue_pkt.rs2_val = b;
      issue_valid = 1;
      while (!issue_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      issue_valid = 0;
    end
  endtask

  task automatic check_op(input opcode_e op, input logic [31:0] a,
                          input logic [31:0] b, input logic [31:0] expected);
    cdb_t held;
    int timeout;
    begin
      drive_issue(op, a, b, 9);
      timeout = 0;
      while (!result_pkt.valid && timeout < 50) begin
        @(negedge clk);
        timeout++;
      end
      if (!result_pkt.valid || result_pkt.value !== expected ||
          result_pkt.tag !== 17 || result_pkt.rob_idx !== 9)
        $fatal(1, "op=%0d a=%h b=%h got=%h expected=%h", op, a, b,
               result_pkt.value, expected);
      held = result_pkt;
      repeat (2) begin
        @(posedge clk); @(negedge clk);
        if (result_pkt !== held) $fatal(1, "result changed under backpressure");
      end
      result_ready = 1;
      @(posedge clk); @(negedge clk);
      result_ready = 0;
      if (result_pkt.valid) $fatal(1, "result not consumed");
    end
  endtask

  initial begin
    flush = '0;
    issue_valid = 0;
    issue_pkt = '0;
    result_ready = 0;
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 0;

    check_op(OP_MUL,    -7, 9, -63);
    check_op(OP_MULH,   -1, 2, -1);
    check_op(OP_MULHSU, -1, 2, -1);
    check_op(OP_MULHU,  32'hffff_ffff, 2, 1);
    check_op(OP_DIV,    -7, 2, -3);
    check_op(OP_DIVU,   32'hffff_ffff, 2, 32'h7fff_ffff);
    check_op(OP_REM,    -7, 2, -1);
    check_op(OP_REMU,   32'hffff_ffff, 2, 1);
    check_op(OP_DIV,    7, 0, -1);
    check_op(OP_REM,    7, 0, 7);
    check_op(OP_DIV,    32'h8000_0000, -1, 32'h8000_0000);
    check_op(OP_REM,    32'h8000_0000, -1, 0);

    drive_issue(OP_DIVU, 32'hffff_ffff, 3, 10);
    repeat (4) @(negedge clk);
    flush.valid = 1;
    flush.squash_mask[10] = 1;
    @(posedge clk); @(negedge clk);
    flush = '0;
    repeat (38) begin
      @(posedge clk); @(negedge clk);
      if (result_pkt.valid) $fatal(1, "squashed division produced a result");
    end

    drive_issue(OP_MUL, 6, 7, 12);
    if (!result_pkt.valid || result_pkt.value != 42)
      $fatal(1, "multiply result missing before flush");
    flush.valid = 1;
    flush.squash_mask[12] = 1;
    @(posedge clk); @(negedge clk);
    flush = '0;
    if (result_pkt.valid) $fatal(1, "pending squashed result survived");

    check_op(OP_MUL, 6, 7, 42);
    $display("TB_MULDIV_PASS");
    $finish;
  end
endmodule
