`timescale 1ns/1ps
module tb_dcache;
  import cpu_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic req_valid, req_ready;
  logic [31:0] req_addr, req_wdata;
  logic [3:0] req_wstrb;
  logic req_write, resp_valid;
  logic [31:0] resp_data;
  logic mem_req_valid, mem_req_ready;
  logic [31:0] mem_req_addr, mem_req_wdata;
  logic [3:0] mem_req_wstrb;
  logic mem_req_write, mem_resp_valid;
  logic [31:0] mem_resp_data;

  dcache dut (.*);

  logic [31:0] memory [0:255];
  logic pending;
  logic pending_write;
  logic [31:0] pending_addr, pending_wdata;
  logic [3:0] pending_wstrb;
  integer pending_delay;
  integer mem_req_count;
  assign mem_req_ready = !pending;

  always @(posedge clk) begin
    if (rst) begin
      pending <= 0;
      mem_resp_valid <= 0;
      mem_req_count <= 0;
    end else begin
      mem_resp_valid <= 0;
      if (pending) begin
        if (pending_delay == 0) begin
          mem_resp_valid <= 1;
          mem_resp_data <= pending_write ? 0 : memory[pending_addr[9:2]];
          if (pending_write && pending_addr[31:28] == 0)
            for (int b = 0; b < 4; b++)
              if (pending_wstrb[b])
                memory[pending_addr[9:2]][b*8 +: 8] <= pending_wdata[b*8 +: 8];
          pending <= 0;
        end else begin
          pending_delay <= pending_delay - 1;
        end
      end
      if (mem_req_valid && mem_req_ready) begin
        pending <= 1;
        pending_write <= mem_req_write;
        pending_addr <= mem_req_addr;
        pending_wdata <= mem_req_wdata;
        pending_wstrb <= mem_req_wstrb;
        pending_delay <= 2;
        mem_req_count <= mem_req_count + 1;
      end
    end
  end

  task automatic access(input logic write, input logic [31:0] addr,
                        input logic [31:0] wdata_i, input logic [3:0] strb,
                        input logic [31:0] expected);
    int timeout;
    begin
      @(negedge clk);
      req_valid = 1;
      req_write = write;
      req_addr = addr;
      req_wdata = wdata_i;
      req_wstrb = strb;
      while (!req_ready) @(negedge clk);
      @(posedge clk); @(negedge clk);
      req_valid = 0;
      timeout = 0;
      while (!resp_valid && timeout < 100) begin
        @(negedge clk);
        timeout++;
      end
      if (!resp_valid || resp_data !== expected)
        $fatal(1, "write=%b addr=%h got=%h expected=%h", write, addr,
               resp_data, expected);
      @(posedge clk); @(negedge clk);
      if (resp_valid) $fatal(1, "response not a pulse");
    end
  endtask

  integer before_count;
  initial begin
    req_valid = 0; req_addr = 0; req_wdata = 0; req_wstrb = 0; req_write = 0;
    mem_resp_data = 0;
    for (int i = 0; i < 256; i++) memory[i] = 0;
    memory[4] = 32'h1122_3344;
    memory[5] = 32'h5566_7788;
    memory[64] = 32'hcafe_babe;
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 0;

    before_count = mem_req_count;
    access(0, 32'h0000_0010, 0, 0, 32'h1122_3344);
    if (mem_req_count - before_count != DCACHE_LINE_WORDS)
      $fatal(1, "read miss did not refill one full line");

    before_count = mem_req_count;
    access(0, 32'h0000_0010, 0, 0, 32'h1122_3344);
    access(0, 32'h0000_0014, 0, 0, 32'h5566_7788);
    if (mem_req_count != before_count) $fatal(1, "read hit reached AXI");

    access(1, 32'h0000_0010, 32'haa_bb_cc_dd, 4'hf, 0);
    access(0, 32'h0000_0010, 0, 0, 32'haa_bb_cc_dd);
    access(1, 32'h0000_0010, 32'h0000_0077, 4'b0001, 0);
    access(0, 32'h0000_0010, 0, 0, 32'haa_bb_cc_77);

    access(1, 32'h0000_0100, 32'h1234_5678, 4'hf, 0);
    access(0, 32'h0000_0100, 0, 0, 32'h1234_5678);
    access(1, 32'h8000_0000, 32'h0000_0058, 4'hf, 0);

    $display("TB_DCACHE_PASS");
    $finish;
  end
endmodule
