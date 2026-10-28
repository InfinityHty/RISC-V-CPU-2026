import cpu_pkg::*;

module cdb
(
  input  logic clk,
  input  logic rst,
  input  cpu_pkg::cdb_t [ALU_COUNT-1:0] alu_result,
  output logic [ALU_COUNT-1:0] alu_ready,
  input  cpu_pkg::cdb_t mul_result,
  output logic mul_ready,
  input  cpu_pkg::cdb_t lsu_result,
  output logic lsu_ready,
  output cpu_pkg::cdb_t [CDB_WIDTH-1:0] out
);

  always_comb begin
    int slot;
    slot = 0;
    for (int i = 0; i < CDB_WIDTH; i++)
      out[i] = '0;
    alu_ready = '0;
    mul_ready = 1'b0;
    lsu_ready = 1'b0;

    if (lsu_result.valid && slot < CDB_WIDTH) begin
      out[slot] = lsu_result;
      lsu_ready = 1'b1;
      slot++;
    end
    if (mul_result.valid && slot < CDB_WIDTH) begin
      out[slot] = mul_result;
      mul_ready = 1'b1;
      slot++;
    end
    for (int i = 0; i < ALU_COUNT; i++) begin
      if (alu_result[i].valid && slot < CDB_WIDTH) begin
        out[slot] = alu_result[i];
        alu_ready[i] = 1'b1;
        slot++;
      end
    end
  end

  wire unused_ok = &{1'b0, clk, rst};

endmodule
