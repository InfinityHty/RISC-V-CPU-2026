`timescale 1ns/1ps
module tb_lsu;
  import cpu_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic issue_valid, issue_ready;
  issue_t issue_pkt;
  cdb_t cdb;
  commit_t commit;
  flush_t flush;
  cdb_t result_pkt;
  logic result_ready;
  logic mem_req_valid, mem_req_ready;
  logic [31:0] mem_req_addr, mem_req_wdata;
  logic [3:0] mem_req_wstrb;
  logic mem_req_write, mem_resp_valid;
  logic [31:0] mem_resp_data;

  lsu dut (.*);

  task automatic send_issue(input opcode_e op, input logic [31:0] base,
                            input logic [31:0] imm, input logic [31:0] data,
                            input logic [5:0] rob);
    begin
      @(negedge clk);
      issue_pkt = '0;
      issue_pkt.d.op = op;
      issue_pkt.d.pc = 32'h200;
      issue_pkt.d.imm = imm;
      issue_pkt.d.rd_tag = 18;
      issue_pkt.d.rob_idx = rob;
      issue_pkt.d.is_store = (op >= OP_SB && op <= OP_SW);
      issue_pkt.rs1_val = base;
      issue_pkt.rs2_val = data;
      issue_valid = 1;
      while (!issue_ready) @(negedge clk);
      @(posedge clk); @(negedge clk);
      issue_valid = 0;
    end
  endtask

  task automatic consume_result(input logic [31:0] expected);
    cdb_t held;
    begin
      if (!result_pkt.valid || result_pkt.value !== expected)
        $fatal(1, "bad LSU result valid=%b got=%h expected=%h",
               result_pkt.valid, result_pkt.value, expected);
      held = result_pkt;
      repeat (2) begin
        @(posedge clk); @(negedge clk);
        if (result_pkt !== held) $fatal(1, "LSU result changed under backpressure");
      end
      result_ready = 1;
      @(posedge clk); @(negedge clk);
      result_ready = 0;
    end
  endtask

  task automatic check_load(input opcode_e op, input logic [31:0] addr,
                            input logic [31:0] mem_word,
                            input logic [31:0] expected);
    int timeout;
    begin
      send_issue(op, addr, 0, 0, 7);
      timeout = 0;
      while (!mem_req_valid && timeout < 10) begin
        @(negedge clk); timeout++;
      end
      if (!mem_req_valid || mem_req_write || mem_req_addr !== {addr[31:2], 2'b00})
        $fatal(1, "bad load request");
      @(posedge clk); @(negedge clk);
      repeat (2) @(negedge clk);
      mem_resp_data = mem_word;
      mem_resp_valid = 1;
      @(posedge clk); @(negedge clk);
      mem_resp_valid = 0;
      consume_result(expected);
    end
  endtask

  task automatic check_store(input opcode_e op, input logic [31:0] addr,
                             input logic [31:0] data,
                             input logic [31:0] expected_data,
                             input logic [3:0] expected_strb);
    int timeout;
    begin
      mem_req_ready = 0;
      send_issue(op, addr, 0, data, 8);
      consume_result(0);
      repeat (2) begin
        @(posedge clk); @(negedge clk);
        if (mem_req_valid) $fatal(1, "store wrote before commit");
      end
      commit.valid = 1;
      commit.is_store = 1;
      commit.rob_idx = 8;
      @(posedge clk); @(negedge clk);
      commit = '0;
      flush.valid = 1;
      flush.squash_mask[8] = 1;
      @(posedge clk); @(negedge clk);
      flush = '0;
      timeout = 0;
      while (!mem_req_valid && timeout < 10) begin
        @(negedge clk); timeout++;
      end
      if (!mem_req_valid || !mem_req_write ||
          mem_req_addr !== {addr[31:2], 2'b00} ||
          mem_req_wdata !== expected_data || mem_req_wstrb !== expected_strb)
        $fatal(1, "bad store request addr=%h data=%h/%h strb=%b/%b",
               mem_req_addr, mem_req_wdata, expected_data,
               mem_req_wstrb, expected_strb);
      mem_req_ready = 1;
      @(posedge clk); @(negedge clk);
      repeat (2) @(negedge clk);
      mem_resp_valid = 1;
      mem_resp_data = 0;
      @(posedge clk); @(negedge clk);
      mem_resp_valid = 0;
      if (result_pkt.valid) $fatal(1, "store produced a second CDB result");
    end
  endtask

  initial begin
    issue_valid = 0; issue_pkt = '0; cdb = '0; commit = '0; flush = '0;
    result_ready = 0; mem_req_ready = 1; mem_resp_valid = 0; mem_resp_data = 0;
    repeat (3) @(posedge clk);
    @(negedge clk); rst = 0;

    check_load(OP_LB,  32'h0000_0101, 32'h0000_8000, 32'hffff_ff80);
    check_load(OP_LBU, 32'h0000_0101, 32'h0000_8000, 32'h0000_0080);
    check_load(OP_LH,  32'h0000_0102, 32'h8001_0001, 32'hffff_8001);
    check_load(OP_LHU, 32'h0000_0102, 32'h8001_0001, 32'h0000_8001);
    check_load(OP_LW,  32'h0000_0100, 32'h89ab_cdef, 32'h89ab_cdef);

    check_store(OP_SB, 32'h0000_0101, 32'h0000_00aa, 32'h0000_aa00, 4'b0010);
    check_store(OP_SH, 32'h0000_0102, 32'h0000_beef, 32'hbeef_0000, 4'b1100);
    check_store(OP_SW, 32'h0000_0100, 32'h1234_5678, 32'h1234_5678, 4'hf);

    send_issue(OP_SW, 32'h0000_0200, 0, 32'h55, 9);
    consume_result(0);
    flush.valid = 1;
    flush.squash_mask[9] = 1;
    @(posedge clk); @(negedge clk);
    flush = '0;
    repeat (4) begin
      @(posedge clk); @(negedge clk);
      if (mem_req_valid) $fatal(1, "squashed store reached memory");
    end

    send_issue(OP_LW, 32'h0000_0300, 0, 0, 10);
    while (!mem_req_valid) @(negedge clk);
    @(posedge clk); @(negedge clk);
    flush.valid = 1;
    flush.squash_mask[10] = 1;
    @(posedge clk); @(negedge clk);
    flush = '0;
    mem_resp_data = 32'h1234;
    mem_resp_valid = 1;
    @(posedge clk); @(negedge clk);
    mem_resp_valid = 0;
    repeat (3) begin
      @(posedge clk); @(negedge clk);
      if (result_pkt.valid) $fatal(1, "squashed load produced a result");
    end

    $display("TB_LSU_PASS");
    $finish;
  end
endmodule
