`timescale 1ns/1ps
module tb_axi_master;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic if_req_valid, if_req_ready;
  logic [31:0] if_req_addr;
  logic if_resp_valid;
  logic [31:0] if_resp_data;
  logic dm_req_valid, dm_req_ready;
  logic [31:0] dm_req_addr, dm_req_wdata;
  logic [3:0] dm_req_wstrb;
  logic dm_req_write, dm_resp_valid;
  logic [31:0] dm_resp_data;
  logic [31:0] araddr;
  logic arvalid, arready;
  logic [31:0] rdata;
  logic [1:0] rresp;
  logic rvalid, rready;
  logic [31:0] awaddr;
  logic awvalid, awready;
  logic [31:0] wdata;
  logic [3:0] wstrb;
  logic wvalid, wready;
  logic [1:0] bresp;
  logic bvalid, bready;

  axi_master dut (.*);

  task automatic check_read(input logic is_if, input logic [31:0] addr,
                            input logic [31:0] value);
    begin
      @(negedge clk);
      if_req_valid = is_if;
      if_req_addr = addr;
      dm_req_valid = !is_if;
      dm_req_addr = addr;
      dm_req_write = 0;
      if (is_if) while (!if_req_ready) @(negedge clk);
      else while (!dm_req_ready) @(negedge clk);
      @(posedge clk); @(negedge clk);
      if_req_valid = 0;
      dm_req_valid = 0;
      repeat (2) @(negedge clk);
      if (!arvalid || araddr !== {addr[31:2], 2'b00})
        $fatal(1, "bad AR valid/address");
      arready = 1;
      @(posedge clk); @(negedge clk);
      arready = 0;
      repeat (2) @(negedge clk);
      rdata = value;
      rvalid = 1;
      #1;
      if (!rready || if_resp_valid !== is_if || dm_resp_valid !== !is_if)
        $fatal(1, "read response routing failed");
      if (is_if && if_resp_data !== value) $fatal(1, "IF read data mismatch");
      if (!is_if && dm_resp_data !== value) $fatal(1, "DM read data mismatch");
      @(posedge clk); @(negedge clk);
      rvalid = 0;
      #1;
      if (if_resp_valid || dm_resp_valid) $fatal(1, "read response not a pulse");
    end
  endtask

  initial begin
    if_req_valid = 0; if_req_addr = 0;
    dm_req_valid = 0; dm_req_addr = 0; dm_req_wdata = 0;
    dm_req_wstrb = 0; dm_req_write = 0;
    arready = 0; rdata = 0; rresp = 0; rvalid = 0;
    awready = 0; wready = 0; bresp = 0; bvalid = 0;
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 0;

    check_read(1, 32'h0000_0103, 32'h1122_3344);
    check_read(0, 32'h0000_0201, 32'h5566_7788);

    @(negedge clk);
    dm_req_valid = 1;
    dm_req_addr = 32'h8000_0000;
    dm_req_wdata = 32'hdead_beef;
    dm_req_wstrb = 4'hf;
    dm_req_write = 1;
    while (!dm_req_ready) @(negedge clk);
    @(posedge clk); @(negedge clk);
    dm_req_valid = 0;
    if (!awvalid || !wvalid || awaddr !== 32'h8000_0000 ||
        wdata !== 32'hdead_beef || wstrb !== 4'hf)
      $fatal(1, "write payload missing");

    awready = 1;
    @(posedge clk); @(negedge clk);
    awready = 0;
    #1;
    if (awvalid || !wvalid || wdata !== 32'hdead_beef)
      $fatal(1, "AW/W independent handshake failed");
    repeat (2) begin
      @(posedge clk); @(negedge clk);
      if (!wvalid || wdata !== 32'hdead_beef)
        $fatal(1, "W payload changed while stalled");
    end
    wready = 1;
    @(posedge clk); @(negedge clk);
    wready = 0;
    repeat (2) @(negedge clk);
    if (!bready) $fatal(1, "B channel not ready");
    bvalid = 1;
    #1;
    if (!dm_resp_valid) $fatal(1, "write response missing");
    @(posedge clk); @(negedge clk);
    bvalid = 0;
    #1;
    if (dm_resp_valid) $fatal(1, "write response not a pulse");

    $display("TB_AXI_MASTER_PASS");
    $finish;
  end
endmodule
