`timescale 1ns/1ps
module tb_icache;
  import cpu_pkg::*;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  flush_t flush;
  logic        fetch_valid;
  logic [31:0] fetch_addr;
  logic        fetch_ready;
  logic        resp_valid;
  logic [31:0] resp_data;
  logic        mem_req_valid, mem_req_ready;
  logic [31:0] mem_req_addr;
  logic        mem_resp_valid;
  logic [31:0] mem_resp_data;

  icache dut (
    .clk(clk), .rst(rst), .flush(flush),
    .fetch_valid(fetch_valid), .fetch_addr(fetch_addr), .fetch_ready(fetch_ready),
    .resp_valid(resp_valid), .resp_data(resp_data),
    .mem_req_valid(mem_req_valid), .mem_req_addr(mem_req_addr),
    .mem_req_ready(mem_req_ready),
    .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data)
  );

  // Fake AXI read slave: one outstanding read, respond after 2 cycles.
  logic        pend_valid;
  logic [31:0] pend_addr;
  int          pend_delay;
  assign mem_req_ready = 1'b1;

  always_comb begin
    mem_resp_valid = pend_valid && (pend_delay == 0);
    mem_resp_data  = pend_addr + 32'h1000_0000;
  end

  always @(posedge clk) begin
    if (rst) begin
      pend_valid <= 0; pend_delay <= 0; pend_addr <= 0;
    end else begin
      if (mem_req_valid && mem_req_ready) begin
        if (pend_valid) $fatal(1, "fake AXI overlap: ICache issued while response pending");
        pend_valid <= 1; pend_addr <= mem_req_addr; pend_delay <= 2;
      end else if (pend_valid) begin
        if (pend_delay == 0) pend_valid <= 0;
        else pend_delay <= pend_delay - 1;
      end
    end
  end

  task automatic fetch_check(input [31:0] addr);
    begin
      @(negedge clk);
      fetch_valid = 1; fetch_addr = addr;
      while (!fetch_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      fetch_valid = 0;
      while (!resp_valid) @(negedge clk);
      if (resp_data !== (addr + 32'h1000_0000))
        $fatal(1, "addr=%h data got %h exp %h", addr, resp_data, addr + 32'h1000_0000);
    end
  endtask

  int timeout;
  initial begin
    flush = '0; fetch_valid = 0; fetch_addr = 0;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // miss + line refill
    fetch_check(32'h0000_0000);
    // same line hits
    fetch_check(32'h0000_0004);
    fetch_check(32'h0000_0008);
    fetch_check(32'h0000_000c);
    // next line miss
    fetch_check(32'h0000_0010);

    // flush during a miss: stale response must be suppressed, refill finishes.
    @(negedge clk);
    fetch_valid = 1; fetch_addr = 32'h0000_0100;
    while (!fetch_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    fetch_valid = 0;
    repeat (3) @(negedge clk);
    flush.valid = 1; flush.redirect_pc = 32'h200;
    @(posedge clk);
    @(negedge clk);
    flush.valid = 0;

    // No stale resp_valid may appear before the next fetch is accepted.
    timeout = 0;
    while (timeout < 50) begin
      @(negedge clk);
      if (resp_valid) $fatal(1, "stale resp after flush: %h", resp_data);
      if (fetch_ready) timeout = 50; else timeout = timeout + 1;
    end
    if (!fetch_ready) $fatal(1, "icache not ready after abandoned refill");

    fetch_check(32'h0000_0200);
    // hit the line that was refilled during the abandoned request
    fetch_check(32'h0000_0104);

    $display("TB_ICACHE_PASS");
    $finish;
  end
endmodule
