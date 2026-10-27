`timescale 1ns/1ps
module tb_bpred;
  import cpu_pkg::*;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic [31:0] pc;
  logic        pred_taken;
  logic [31:0] pred_target;
  logic        update_valid;
  logic [31:0] update_pc;
  logic        update_taken;
  logic [31:0] update_target;

  bpred dut (
    .clk(clk), .rst(rst),
    .pc(pc), .pred_taken(pred_taken), .pred_target(pred_target),
    .update_valid(update_valid), .update_pc(update_pc),
    .update_taken(update_taken), .update_target(update_target)
  );

  task automatic query(input [31:0] qpc, input logic etaken, input [31:0] etarget);
    begin
      @(negedge clk);
      pc = qpc;
      #1;
      if (pred_taken !== etaken) $fatal(1, "pc=%h pred_taken got %0b exp %0b", qpc, pred_taken, etaken);
      if (pred_target !== etarget) $fatal(1, "pc=%h pred_target got %h exp %h", qpc, pred_target, etarget);
    end
  endtask

  task automatic update(input [31:0] upc, input logic taken, input [31:0] target);
    begin
      @(negedge clk);
      update_valid = 1; update_pc = upc; update_taken = taken; update_target = target;
      @(posedge clk);
      @(negedge clk);
      update_valid = 0;
    end
  endtask

  initial begin
    pc = 0; update_valid = 0; update_pc = 0; update_taken = 0; update_target = 0;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    query(32'h1000, 0, 32'h1004);
    update(32'h1000, 1, 32'h2000);
    query(32'h1000, 1, 32'h2000);
    query(32'h1004, 0, 32'h1008);

    update(32'h1000, 0, 32'h1004);
    query(32'h1000, 0, 32'h1004);

    update(32'h1000, 1, 32'h2000);
    update(32'h1000, 1, 32'h2000);
    query(32'h1000, 1, 32'h2000);

    update(32'h1000, 0, 32'h1004);
    query(32'h1000, 1, 32'h2000);  // 2-bit counter 11 -> 10, still taken
    update(32'h1000, 0, 32'h1004);
    query(32'h1000, 0, 32'h1004);  // 10 -> 01, not taken

    update(32'h3000, 1, 32'h4000);
    query(32'h3000, 1, 32'h4000);
    update(32'h3000, 1, 32'h5000);
    query(32'h3000, 1, 32'h5000);

    query(32'h3100, 0, 32'h3104);
    $display("TB_BPRED_PASS");
    $finish;
  end
endmodule
