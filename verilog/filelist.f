# RTL paths are relative to this file in verilog/.
# The top-level module must be named student_top.
#
# Milestone: RV32IM 5-stage in-order pipeline (IF/ID/EX/MEM/WB).
# The out-of-order skeleton is preserved under verilog/ooo/ and is NOT built.

axi_bus.sv      # AXI4-Lite master: read arbiter (load > ifetch) + store channel
ifetch.sv       # sequential prefetch FIFO (depth 4), epoch-based redirect discard
pipe_core.sv    # 5-stage pipeline: decode, hazard/forwarding, blocking MEM, RV32M
student_top.sv  # top level, wiring only (course-fixed ports)
