// prf.sv — 物理寄存器堆 [A]
//
// - tag 0 固定给 x0，读恒 0，不参与分配。
// - CDB 写口：只有 cdb.rob_idx 与该物理寄存器的 alloc owner 匹配时才写，
//   防止被 squash 的年轻指令的迟到结果覆盖已经重新分配的 tag。
// - 2 个组合读口，带同周期 CDB 旁路（方便 RS 在发射当拍取值）。

import cpu_pkg::*;

module prf
(
  input  logic              clk,
  input  logic              rst,

  // rename 分配新物理寄存器（记录 owner）
  input  logic              alloc_valid,
  input  logic [TAG_W-1:0]  alloc_tag,
  input  logic [ROB_IDX_W-1:0] alloc_rob_idx,

  // CDB 写回（cdb → prf）
  input  cpu_pkg::cdb_t              cdb,

  // 读端口（rs 发射时使用）
  input  logic [TAG_W-1:0]  raddr1,
  input  logic [TAG_W-1:0]  raddr2,
  output logic [31:0]       rdata1,
  output logic [31:0]       rdata2
);

  logic [31:0]          data  [PRF_SIZE];
  logic [ROB_IDX_W-1:0] owner [PRF_SIZE];

  integer i;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < PRF_SIZE; i = i + 1) begin
        data[i]  <= 32'd0;
        owner[i] <= '0;
      end
    end else begin
      if (alloc_valid && alloc_tag != X0_TAG)
        owner[alloc_tag] <= alloc_rob_idx;

      if (cdb.valid && cdb.tag != X0_TAG && owner[cdb.tag] == cdb.rob_idx)
        data[cdb.tag] <= cdb.value;
    end
  end

  // 组合读 + 同周期 CDB 旁路。
  always_comb begin
    if (raddr1 == X0_TAG)
      rdata1 = 32'd0;
    else if (cdb.valid && cdb.tag == raddr1 && owner[raddr1] == cdb.rob_idx)
      rdata1 = cdb.value;
    else
      rdata1 = data[raddr1];

    if (raddr2 == X0_TAG)
      rdata2 = 32'd0;
    else if (cdb.valid && cdb.tag == raddr2 && owner[raddr2] == cdb.rob_idx)
      rdata2 = cdb.value;
    else
      rdata2 = data[raddr2];
  end

endmodule
