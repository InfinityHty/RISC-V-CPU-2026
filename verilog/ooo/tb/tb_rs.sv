`timescale 1ns/1ps
module tb_rs;
  import cpu_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic disp_valid, disp_ready;
  dispatch_t disp_pkt;
  cdb_t cdb;
  flush_t flush;
  logic [TAG_W-1:0] prf_raddr1, prf_raddr2;
  logic [31:0] prf_rdata1, prf_rdata2;
  logic alu_issue_valid, alu_issue_ready;
  logic mul_issue_valid, mul_issue_ready;
  logic lsu_issue_valid, lsu_issue_ready;
  issue_t alu_issue_pkt, mul_issue_pkt, lsu_issue_pkt;

  rs dut (.*);

  logic [31:0] prf [PRF_SIZE];
  always_comb begin
    prf_rdata1 = (prf_raddr1 == 0) ? 0 :
      ((cdb.valid && cdb.tag == prf_raddr1) ? cdb.value : prf[prf_raddr1]);
    prf_rdata2 = (prf_raddr2 == 0) ? 0 :
      ((cdb.valid && cdb.tag == prf_raddr2) ? cdb.value : prf[prf_raddr2]);
  end

  task automatic send(input opcode_e op, input logic [31:0] pc,
                      input logic [5:0] rob_idx, input logic [5:0] tag1,
                      input logic ready1, input logic [5:0] tag2,
                      input logic ready2);
    begin
      @(negedge clk);
      disp_pkt = '0;
      disp_pkt.op = op;
      disp_pkt.pc = pc;
      disp_pkt.rob_idx = rob_idx;
      disp_pkt.rs1_tag = tag1;
      disp_pkt.rs2_tag = tag2;
      disp_pkt.rs1_ready = ready1;
      disp_pkt.rs2_ready = ready2;
      disp_pkt.use_rs1 = 1;
      disp_pkt.use_rs2 = 1;
      disp_valid = 1;
      while (!disp_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      disp_valid = 0;
    end
  endtask

  task automatic wait_alu(input logic [31:0] pc, input logic [31:0] value);
    int timeout;
    begin
      timeout = 0;
      while (!alu_issue_valid && timeout < 30) begin
        @(negedge clk); timeout++;
      end
      if (!alu_issue_valid || alu_issue_pkt.d.pc !== pc)
        $fatal(1, "ALU issue pc got=%h valid=%b expected=%h",
               alu_issue_pkt.d.pc, alu_issue_valid, pc);
      if (alu_issue_pkt.rs1_val !== value)
        $fatal(1, "ALU operand got=%h expected=%h", alu_issue_pkt.rs1_val, value);
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  issue_t held;
  initial begin
    disp_valid = 0; disp_pkt = '0; cdb = '0; flush = '0;
    alu_issue_ready = 1; mul_issue_ready = 1; lsu_issue_ready = 1;
    for (int i = 0; i < PRF_SIZE; i++) prf[i] = 32'h1000 + i;
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 0;

    send(OP_ADD, 32'h100, 1, 5, 0, 0, 1);
    send(OP_ADDI, 32'h104, 2, 0, 1, 0, 1);
    wait_alu(32'h104, 0);
    @(negedge clk);
    cdb.valid = 1; cdb.tag = 5; cdb.value = 32'hdeadbeef;
    #1;
    if (!alu_issue_valid || alu_issue_pkt.d.pc != 32'h100 ||
        alu_issue_pkt.rs1_val != 32'hdeadbeef)
      $fatal(1, "same-cycle CDB wakeup/bypass failed");
    @(posedge clk);
    @(negedge clk); cdb = '0;

    alu_issue_ready = 0;
    send(OP_ADDI, 32'h200, 3, 0, 1, 0, 1);
    while (!alu_issue_valid) @(negedge clk);
    held = alu_issue_pkt;
    repeat (3) begin
      @(posedge clk); @(negedge clk);
      if (!alu_issue_valid || alu_issue_pkt !== held)
        $fatal(1, "stalled issue changed");
    end
    alu_issue_ready = 1;
    @(posedge clk); @(negedge clk);

    send(OP_ADD, 32'h300, 4, 8, 0, 0, 1);
    send(OP_ADD, 32'h304, 5, 9, 0, 0, 1);
    @(negedge clk);
    flush.valid = 1; flush.squash_mask[5] = 1;
    @(posedge clk);
    @(negedge clk); flush = '0;
    cdb.valid = 1; cdb.tag = 8; cdb.value = 8;
    #1;
    wait_alu(32'h300, 8);
    cdb.tag = 9; cdb.value = 9;
    repeat (4) begin
      @(posedge clk); @(negedge clk);
      if (alu_issue_valid && alu_issue_pkt.d.pc == 32'h304)
        $fatal(1, "squashed entry issued");
    end
    cdb = '0;

    lsu_issue_ready = 0;
    send(OP_LW, 32'h400, 6, 0, 1, 0, 1);
    send(OP_LW, 32'h404, 7, 0, 1, 0, 1);
    @(negedge clk); lsu_issue_ready = 1;
    if (!lsu_issue_valid || lsu_issue_pkt.d.pc != 32'h400)
      $fatal(1, "oldest memory did not issue first");
    @(posedge clk); @(negedge clk);
    if (!lsu_issue_valid || lsu_issue_pkt.d.pc != 32'h404)
      $fatal(1, "second memory did not issue second");
    @(posedge clk); @(negedge clk);

    $display("TB_RS_PASS");
    $finish;
  end
endmodule
