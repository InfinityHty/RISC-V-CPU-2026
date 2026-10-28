import cpu_pkg::*;

module prf
(
  input  logic clk,
  input  logic rst,
  input  logic [DISPATCH_WIDTH-1:0] alloc_valid,
  input  logic [DISPATCH_WIDTH-1:0][TAG_W-1:0] alloc_tag,
  input  logic [DISPATCH_WIDTH-1:0][ROB_IDX_W-1:0] alloc_rob_idx,
  input  cpu_pkg::cdb_t [CDB_WIDTH-1:0] cdb,
  input  logic [PRF_READ_PORTS-1:0][TAG_W-1:0] raddr,
  output logic [PRF_READ_PORTS-1:0][31:0] rdata
);

  logic [31:0] data [PRF_SIZE];
  logic [ROB_IDX_W-1:0] owner [PRF_SIZE];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < PRF_SIZE; i++) begin
        data[i] <= '0;
        owner[i] <= '0;
      end
    end else begin
      for (int i = 0; i < DISPATCH_WIDTH; i++)
        if (alloc_valid[i] && alloc_tag[i] != X0_TAG)
          owner[alloc_tag[i]] <= alloc_rob_idx[i];
      for (int c = 0; c < CDB_WIDTH; c++)
        if (cdb[c].valid && cdb[c].tag != X0_TAG && owner[cdb[c].tag] == cdb[c].rob_idx)
          data[cdb[c].tag] <= cdb[c].value;
    end
  end

  always_comb begin
    for (int p = 0; p < PRF_READ_PORTS; p++) begin
      if (raddr[p] == X0_TAG)
        rdata[p] = 32'd0;
      else
        rdata[p] = data[raddr[p]];
      for (int c = 0; c < CDB_WIDTH; c++)
        if (cdb[c].valid && cdb[c].tag != X0_TAG && cdb[c].tag == raddr[p]
            && owner[raddr[p]] == cdb[c].rob_idx)
          rdata[p] = cdb[c].value;
    end
  end

endmodule
