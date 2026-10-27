`timescale 1ns/1ps
module tb_ifu_pred;
  import cpu_pkg::*;

  logic clk = 0, rst_ifu = 1, rst_bp = 1;
  always #5 clk = ~clk;

  flush_t flush;
  logic        pred_taken;
  logic [31:0] pred_target;
  logic        update_valid;
  logic [31:0] update_pc;
  logic        update_taken;
  logic [31:0] update_target;

  logic        instr_valid, instr_ready;
  logic [31:0] instr_pc, instr_data;
  logic        instr_pred_taken;
  logic [31:0] instr_pred_target;
  logic        mem_req_valid, mem_req_ready;
  logic [31:0] mem_req_addr;
  logic        mem_resp_valid;
  logic [31:0] mem_resp_data;

  bpred u_bpred (
    .clk(clk), .rst(rst_bp),
    .pc(mem_req_addr), .pred_taken(pred_taken), .pred_target(pred_target),
    .update_valid(update_valid), .update_pc(update_pc),
    .update_taken(update_taken), .update_target(update_target)
  );

  ifu u_ifu (
    .clk(clk), .rst(rst_ifu), .flush(flush),
    .pred_taken(pred_taken), .pred_target(pred_target),
    .instr_valid(instr_valid), .instr_ready(instr_ready),
    .instr_pc(instr_pc), .instr_data(instr_data),
    .instr_pred_taken(instr_pred_taken), .instr_pred_target(instr_pred_target),
    .mem_req_valid(mem_req_valid), .mem_req_addr(mem_req_addr),
    .mem_req_ready(mem_req_ready),
    .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data)
  );

  logic        pend_valid;
  logic [31:0] pend_addr;
  int          pend_delay;
  assign mem_req_ready = !pend_valid;

  always_comb begin
    mem_resp_valid = pend_valid && (pend_delay == 0);
    mem_resp_data  = pend_addr + 32'h1000_0000;
  end

  always @(posedge clk) begin
    if (rst_ifu) begin
      pend_valid <= 0; pend_delay <= 0; pend_addr <= 0;
    end else if (mem_req_valid && mem_req_ready) begin
      pend_valid <= 1; pend_addr <= mem_req_addr; pend_delay <= 2;
    end else if (pend_valid) begin
      if (pend_delay == 0) pend_valid <= 0;
      else pend_delay <= pend_delay - 1;
    end
  end

  task automatic do_update(input [31:0] p, input logic taken, input [31:0] target);
    begin
      @(negedge clk);
      update_valid = 1; update_pc = p; update_taken = taken; update_target = target;
      @(posedge clk);
      @(negedge clk);
      update_valid = 0;
    end
  endtask

  task automatic pop_check(input [31:0] exp_pc, input logic exp_pred_taken, input [31:0] exp_pred_target);
    begin
      @(negedge clk);
      while (!instr_valid) @(negedge clk);
      if (instr_pc !== exp_pc) $fatal(1, "pc got %h exp %h", instr_pc, exp_pc);
      if (instr_data !== (exp_pc + 32'h1000_0000)) $fatal(1, "data got %h pc %h", instr_data, exp_pc);
      if (instr_pred_taken !== exp_pred_taken) $fatal(1, "pred_taken got %0b exp %0b pc %h", instr_pred_taken, exp_pred_taken, exp_pc);
      if (instr_pred_target !== exp_pred_target) $fatal(1, "pred_target got %h exp %h pc %h", instr_pred_target, exp_pred_target, exp_pc);
      instr_ready = 1;
      @(posedge clk);
      @(negedge clk);
      instr_ready = 0;
    end
  endtask

  initial begin
    flush = '0; instr_ready = 0;
    update_valid = 0; update_pc = 0; update_taken = 0; update_target = 0;
    // Bring bpred out of reset first, train pc=0 as taken -> target 0x100.
    repeat (3) @(posedge clk);
    rst_bp = 0;
    @(posedge clk);
    do_update(32'h0000_0000, 1'b1, 32'h0000_0100);

    // Now release IFU: first fetch 0 must be predicted taken to 0x100.
    rst_ifu = 0;
    @(posedge clk);

    pop_check(32'h0000_0000, 1'b1, 32'h0000_0100);
    pop_check(32'h0000_0100, 1'b0, 32'h0000_0104);
    pop_check(32'h0000_0104, 1'b0, 32'h0000_0108);

    $display("TB_IFU_PRED_PASS");
    $finish;
  end
endmodule
