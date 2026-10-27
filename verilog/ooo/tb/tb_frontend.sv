`timescale 1ns/1ps
module tb_frontend;
  import cpu_pkg::*;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  flush_t flush;

  // bpred
  logic        bp_pred_taken;
  logic [31:0] bp_pred_target;

  // ifu ↔ icache
  logic        if_req_valid, if_req_ready;
  logic [31:0] if_req_addr;
  logic        if_resp_valid;
  logic [31:0] if_resp_data;

  // ifu → consumer
  logic        instr_valid, instr_ready;
  logic [31:0] instr_pc, instr_data;
  logic        instr_pred_taken;
  logic [31:0] instr_pred_target;

  // icache → fake axi
  logic        mem_req_valid, mem_req_ready;
  logic [31:0] mem_req_addr;
  logic        mem_resp_valid;
  logic [31:0] mem_resp_data;

  bpred u_bpred (
    .clk(clk), .rst(rst),
    .pc(if_req_addr), .pred_taken(bp_pred_taken), .pred_target(bp_pred_target),
    .update_valid(1'b0), .update_pc(32'd0), .update_taken(1'b0), .update_target(32'd0)
  );

  ifu u_ifu (
    .clk(clk), .rst(rst), .flush(flush),
    .pred_taken(bp_pred_taken), .pred_target(bp_pred_target),
    .instr_valid(instr_valid), .instr_ready(instr_ready),
    .instr_pc(instr_pc), .instr_data(instr_data),
    .instr_pred_taken(instr_pred_taken), .instr_pred_target(instr_pred_target),
    .mem_req_valid(if_req_valid), .mem_req_addr(if_req_addr),
    .mem_req_ready(if_req_ready),
    .mem_resp_valid(if_resp_valid), .mem_resp_data(if_resp_data)
  );

  icache u_icache (
    .clk(clk), .rst(rst), .flush(flush),
    .fetch_valid(if_req_valid), .fetch_addr(if_req_addr), .fetch_ready(if_req_ready),
    .resp_valid(if_resp_valid), .resp_data(if_resp_data),
    .mem_req_valid(mem_req_valid), .mem_req_addr(mem_req_addr),
    .mem_req_ready(mem_req_ready),
    .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data)
  );

  // Fake AXI: one outstanding, response after 2 cycles.
  logic        pend_valid;
  logic [31:0] pend_addr;
  int          pend_delay;
  assign mem_req_ready = !pend_valid;

  always_comb begin
    mem_resp_valid = pend_valid && (pend_delay == 0);
    mem_resp_data  = pend_addr + 32'h1000_0000;
  end

  always @(posedge clk) begin
    if (rst) begin
      pend_valid <= 0; pend_delay <= 0; pend_addr <= 0;
    end else if (mem_req_valid && mem_req_ready) begin
      pend_valid <= 1; pend_addr <= mem_req_addr; pend_delay <= 2;
    end else if (pend_valid) begin
      if (pend_delay == 0) pend_valid <= 0;
      else pend_delay <= pend_delay - 1;
    end
  end

  task automatic pop_check(input [31:0] exp_pc);
    begin
      @(negedge clk);
      while (!instr_valid) @(negedge clk);
      if (instr_pc !== exp_pc)
        $fatal(1, "instr_pc got %h exp %h", instr_pc, exp_pc);
      if (instr_data !== (exp_pc + 32'h1000_0000))
        $fatal(1, "instr_data got %h pc %h", instr_data, exp_pc);
      if (instr_pred_taken !== 1'b0)
        $fatal(1, "unexpected pred_taken at pc %h", exp_pc);
      instr_ready = 1;
      @(posedge clk);
      @(negedge clk);
      instr_ready = 0;
    end
  endtask

  initial begin
    flush = '0; instr_ready = 0;
    repeat (3) @(posedge clk); rst = 0; @(posedge clk);

    // Let the front-end prefetch while the consumer is stalled, filling both FIFOs.
    repeat (30) @(negedge clk);

    pop_check(32'h0000_0000);
    pop_check(32'h0000_0004);
    pop_check(32'h0000_0008);
    pop_check(32'h0000_000c);
    pop_check(32'h0000_0010);
    pop_check(32'h0000_0014);

    // Flush while IFU/ICache likely have in-flight work.
    @(negedge clk);
    flush.valid = 1; flush.redirect_pc = 32'h0000_0100;
    @(posedge clk);
    @(negedge clk);
    flush.valid = 0;

    pop_check(32'h0000_0100);
    pop_check(32'h0000_0104);
    pop_check(32'h0000_0108);
    pop_check(32'h0000_010c);

    $display("TB_FRONTEND_PASS");
    $finish;
  end
endmodule
