# RTL paths are relative to this file in verilog/.
# Default target: single-issue RV32IM out-of-order core with in-order commit.
# cpu_pkg.sv must remain first.

ooo/cpu_pkg.sv
ooo/decode.sv
ooo/prf.sv
ooo/rename.sv
ooo/rob.sv
ooo/ifu.sv
ooo/alu.sv
ooo/muldiv.sv
ooo/lsu.sv
ooo/rs.sv
ooo/cdb.sv
ooo/dcache.sv
ooo/axi_master.sv
ooo/icache.sv
ooo/bpred.sv
ooo/student_top_ooo.sv
