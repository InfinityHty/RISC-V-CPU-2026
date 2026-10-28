`timescale 1ns/1ps
module tb_cdb;
  import cpu_pkg::*;
  logic clk = 0, rst = 1;
  cdb_t alu_result, mul_result, lsu_result, out;
  logic alu_ready, mul_ready, lsu_ready;
  cdb dut (.*);

  task automatic check(input int expected);
    begin
      #1;
      case (expected)
        0: if (!alu_ready || mul_ready || lsu_ready || out.rob_idx != 6'd10)
             $fatal(1, "ALU arbitration failed");
        1: if (alu_ready || !mul_ready || lsu_ready || out.rob_idx != 6'd11)
             $fatal(1, "MUL arbitration failed");
        2: if (alu_ready || mul_ready || !lsu_ready || out.rob_idx != 6'd12)
             $fatal(1, "LSU arbitration failed");
        default: if (out.valid || alu_ready || mul_ready || lsu_ready)
             $fatal(1, "idle arbitration failed");
      endcase
    end
  endtask

  initial begin
    alu_result = '0; mul_result = '0; lsu_result = '0;
    alu_result.valid = 1; alu_result.rob_idx = 10;
    mul_result.valid = 1; mul_result.rob_idx = 11;
    lsu_result.valid = 1; lsu_result.rob_idx = 12;
    check(2);
    lsu_result.valid = 0;
    check(1);
    mul_result.valid = 0;
    check(0);
    alu_result.valid = 0;
    check(3);
    $display("TB_CDB_PASS");
    $finish;
  end
endmodule
