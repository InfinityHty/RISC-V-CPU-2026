// cdb.sv — 公共数据总线仲裁 [B]
// 单 CDB：LSU > MULDIV > ALU，未选中的结果通过 ready 反压保持。
import cpu_pkg::*;

module cdb
(
  input  logic  clk,
  input  logic  rst,

  input  cpu_pkg::cdb_t  alu_result,
  output logic  alu_ready,
  input  cpu_pkg::cdb_t  mul_result,
  output logic  mul_ready,
  input  cpu_pkg::cdb_t  lsu_result,
  output logic  lsu_ready,

  output cpu_pkg::cdb_t  out
);

  always_comb begin
    out       = '0;
    alu_ready = 1'b0;
    mul_ready = 1'b0;
    lsu_ready = 1'b0;
    if (lsu_result.valid) begin
      out       = lsu_result;
      lsu_ready = 1'b1;
    end else if (mul_result.valid) begin
      out       = mul_result;
      mul_ready = 1'b1;
    end else if (alu_result.valid) begin
      out       = alu_result;
      alu_ready = 1'b1;
    end
  end

  wire unused_ok = &{1'b0, clk, rst};

endmodule
