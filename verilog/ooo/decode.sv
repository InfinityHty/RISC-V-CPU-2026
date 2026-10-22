// decode.sv — RV32IM 译码 [A]
// TODO: 把 32 位指令译成 dispatch_t（填 pc/op/imm/rs1_arch/rs2_arch/rd_arch，
// 物理寄存器字段留给 rename）。
// 当前骨架：所有输出空闲。
module decode
  import cpu_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // 取指输入（ifu → decode）
  input  logic        instr_valid,
  output logic        instr_ready,
  input  logic [31:0] instr_pc,
  input  logic [31:0] instr_data,

  // 译码输出（decode → rename）
  output logic        dec_valid,
  input  logic        dec_ready,
  output dispatch_t   dec_pkt
);

  assign instr_ready = 1'b0;
  assign dec_valid   = 1'b0;
  assign dec_pkt     = '0;

endmodule
