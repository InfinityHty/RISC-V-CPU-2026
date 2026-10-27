`timescale 1ns/1ps
module tb_ifu;
  import cpu_pkg::*;
  logic clk=0, rst=1;
  always #5 clk=~clk;

  flush_t flush;
  logic instr_valid, instr_ready;
  logic [31:0] instr_pc, instr_data;
  logic instr_pred_taken;
  logic [31:0] instr_pred_target;
  logic pred_taken;
  logic [31:0] pred_target;
  logic mem_req_valid, mem_req_ready;
  logic [31:0] mem_req_addr;
  logic mem_resp_valid;
  logic [31:0] mem_resp_data;

  ifu dut (
    .clk(clk), .rst(rst), .flush(flush),
    .instr_valid(instr_valid), .instr_ready(instr_ready),
    .instr_pc(instr_pc), .instr_data(instr_data),
    .instr_pred_taken(instr_pred_taken), .instr_pred_target(instr_pred_target),
    .pred_taken(pred_taken), .pred_target(pred_target),
    .mem_req_valid(mem_req_valid), .mem_req_addr(mem_req_addr),
    .mem_req_ready(mem_req_ready),
    .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data)
  );

  // Fake AXI slave: one outstanding read, respond after 2 cycles.
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
    end else if (flush.valid) begin
      // I-Cache contract: flushed requests are abandoned, no stale response.
      pend_valid <= 0; pend_delay <= 0;
    end else if (mem_req_valid && mem_req_ready) begin
      pend_valid <= 1; pend_addr <= mem_req_addr; pend_delay <= 2;
    end else if (pend_valid) begin
      if (pend_delay == 0) pend_valid <= 0;
      else pend_delay <= pend_delay - 1;
    end
  end

  int timeout;
  int seen;
  initial begin
    flush = '0; instr_ready = 0; pred_taken = 0; pred_target = 0;
    repeat (3) @(posedge clk); rst=0; @(posedge clk);

    // Let FIFO fill; then pop 3 instructions sequentially from 0.
    timeout=0;
    while (!instr_valid && timeout<50) begin @(negedge clk); timeout++; end
    if (!instr_valid) $fatal(1, "no instr after reset");
    instr_ready=0;
    seen=0;
    while (seen<3 && timeout<100) begin
      @(negedge clk);
      if (instr_valid) begin
        if (instr_pc !== seen*4) $fatal(1, "seq pc got %h exp %h", instr_pc, seen*4);
        if (instr_data !== (seen*4 + 32'h1000_0000)) $fatal(1, "seq data got %h pc %h", instr_data, instr_pc);
        seen++;
        instr_ready = 1;
        @(posedge clk);
        @(negedge clk);
        instr_ready = 0;
      end
      timeout++;
    end
    if (seen != 3) $fatal(1, "only popped %0d", seen);
    $display("sequential fetch OK");

    // Wait until there is an outstanding request (pc will be > 12), then flush to 0x100.
    timeout=0;
    while (timeout<20) begin @(posedge clk); timeout++; end
    @(negedge clk);
    flush.valid = 1; flush.redirect_pc = 32'h100;
    @(posedge clk);
    @(negedge clk);
    flush.valid = 0;

    // Only accept instructions from 0x100 onward, never old pc 12/16/...
    seen=0;
    timeout=0;
    while (seen<3 && timeout<100) begin
      @(negedge clk);
      if (instr_valid) begin
        if (instr_pc !== 32'h100 + seen*4)
          $fatal(1, "after flush pc got %h exp %h", instr_pc, 32'h100+seen*4);
        if (instr_data !== (instr_pc + 32'h1000_0000))
          $fatal(1, "after flush data got %h pc %h", instr_data, instr_pc);
        seen++;
        instr_ready = 1;
        @(posedge clk);
        @(negedge clk);
        instr_ready = 0;
      end
      timeout++;
    end
    if (seen != 3) $fatal(1, "after flush only popped %0d", seen);
    $display("TB_IFU_PASS");
    $finish;
  end
endmodule
