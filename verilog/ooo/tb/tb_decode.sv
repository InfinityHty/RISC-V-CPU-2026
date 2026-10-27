`timescale 1ns/1ps
module tb_decode;
  import cpu_pkg::*;

  logic        clk = 0;
  logic        rst = 1;
  logic        instr_valid;
  logic        instr_ready;
  logic [31:0] instr_pc, instr_data;
  logic        pred_taken_i;
  logic [31:0] pred_target_i;
  logic        dec_valid, dec_ready;
  dispatch_t   dec_pkt;

  decode dut (
    .clk(clk), .rst(rst),
    .instr_valid(instr_valid), .instr_ready(instr_ready),
    .instr_pc(instr_pc), .instr_data(instr_data),
    .pred_taken_i(pred_taken_i), .pred_target_i(pred_target_i),
    .dec_valid(dec_valid), .dec_ready(dec_ready), .dec_pkt(dec_pkt)
  );

  always #5 clk = ~clk;

  task automatic check_insn(
    input [31:0] word,
    input [31:0] pc,
    input opcode_e exp_op,
    input logic exp_dest,
    input logic exp_use1,
    input logic exp_use2,
    input logic exp_branch,
    input logic exp_store,
    input [31:0] exp_imm,
    input string name
  );
    begin
      @(negedge clk);
      instr_valid = 1'b1;
      instr_data  = word;
      instr_pc    = pc;
      dec_ready   = 1'b1;
      #1;
      if (dec_pkt.op !== exp_op)       $fatal(1, "%s: op got %0d exp %0d", name, dec_pkt.op, exp_op);
      if (dec_pkt.has_dest !== exp_dest) $fatal(1, "%s: has_dest got %0b exp %0b", name, dec_pkt.has_dest, exp_dest);
      if (dec_pkt.use_rs1 !== exp_use1)  $fatal(1, "%s: use_rs1 got %0b exp %0b", name, dec_pkt.use_rs1, exp_use1);
      if (dec_pkt.use_rs2 !== exp_use2)  $fatal(1, "%s: use_rs2 got %0b exp %0b", name, dec_pkt.use_rs2, exp_use2);
      if (dec_pkt.is_branch !== exp_branch) $fatal(1, "%s: is_branch got %0b exp %0b", name, dec_pkt.is_branch, exp_branch);
      if (dec_pkt.is_store !== exp_store)   $fatal(1, "%s: is_store got %0b exp %0b", name, dec_pkt.is_store, exp_store);
      if (dec_pkt.imm !== exp_imm)      $fatal(1, "%s: imm got %h exp %h", name, dec_pkt.imm, exp_imm);
      @(posedge clk);
      @(negedge clk);
      instr_valid = 1'b0;
    end
  endtask

  initial begin
    instr_valid = 0; instr_data = 0; instr_pc = 0; dec_ready = 0;
    pred_taken_i = 0; pred_target_i = 0;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // addi x1, x0, 5
    check_insn(32'h00500093, 32'h1000, OP_ADDI, 1, 1, 0, 0, 0, 32'd5, "addi");
    // lui x2, 0x12345
    check_insn(32'h12345137, 32'h1004, OP_LUI, 1, 0, 0, 0, 0, 32'h12345000, "lui");
    // auipc x2, 0x1
    check_insn(32'h00001117, 32'h1008, OP_AUIPC, 1, 0, 0, 0, 0, 32'h1000, "auipc");
    // jal x3, 8
    check_insn(32'h008001ef, 32'h100c, OP_JAL, 1, 0, 0, 1, 0, 32'd8, "jal");
    // jalr x4, 4(x5)
    check_insn(32'h00428267, 32'h1010, OP_JALR, 1, 1, 0, 1, 0, 32'd4, "jalr");
    // beq x1, x2, 8
    check_insn(32'h00208463, 32'h1014, OP_BEQ, 0, 1, 1, 1, 0, 32'd8, "beq");
    // bne x1, x2, -4
    check_insn(32'hfe209ee3, 32'h1018, OP_BNE, 0, 1, 1, 1, 0, 32'hfffffffc, "bne");
    // lw x6, 12(x7)
    check_insn(32'h00c3a303, 32'h101c, OP_LW, 1, 1, 0, 0, 0, 32'd12, "lw");
    // sw x3, 8(x4)
    check_insn(32'h00322423, 32'h1020, OP_SW, 0, 1, 1, 0, 1, 32'd8, "sw");
    // add x8, x9, x10
    check_insn(32'h00a40433, 32'h1024, OP_ADD, 1, 1, 1, 0, 0, 32'd0, "add");
    // sub x8, x9, x10
    check_insn(32'h40a40433, 32'h1028, OP_SUB, 1, 1, 1, 0, 0, 32'd0, "sub");
    // mul x8, x9, x10
    check_insn(32'h02a40433, 32'h102c, OP_MUL, 1, 1, 1, 0, 0, 32'd0, "mul");
    // divu x8, x9, x10
    check_insn(32'h02a45433, 32'h1030, OP_DIVU, 1, 1, 1, 0, 0, 32'd0, "divu");
    // srai x1, x2, 3
    check_insn(32'h40315093, 32'h1034, OP_SRAI, 1, 1, 0, 0, 0, 32'h403, "srai");
    // fence -> nop
    check_insn(32'h0ff0000f, 32'h1038, OP_NOP, 0, 0, 0, 0, 0, 32'd0, "fence");
    // zero -> nop
    check_insn(32'h00000000, 32'h103c, OP_NOP, 0, 0, 0, 0, 0, 32'd0, "zero");

    $display("TB_DECODE_PASS");
    $finish;
  end
endmodule
