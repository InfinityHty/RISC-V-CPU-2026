import cpu_pkg::*;

module bpred
(
  input  logic clk,
  input  logic rst,
  input  logic [FETCH_WIDTH-1:0][31:0] pc,
  output logic [FETCH_WIDTH-1:0] pred_taken,
  output logic [FETCH_WIDTH-1:0][31:0] pred_target,
  input  logic [CDB_WIDTH-1:0] update_valid,
  input  logic [CDB_WIDTH-1:0][31:0] update_pc,
  input  logic [CDB_WIDTH-1:0] update_taken,
  input  logic [CDB_WIDTH-1:0][31:0] update_target
);

  logic btb_valid [BPRED_ENTRIES];
  logic [BPRED_TAG_W-1:0] btb_tag [BPRED_ENTRIES];
  logic [31:0] btb_target [BPRED_ENTRIES];
  logic [1:0] bht [BPRED_ENTRIES];

  always_comb begin
    for (int p = 0; p < FETCH_WIDTH; p++) begin
      logic [BPRED_IDX_W-1:0] idx;
      logic [BPRED_TAG_W-1:0] tag;
      logic hit;
      idx = pc[p][BPRED_IDX_W+1:2];
      tag = pc[p][31:2+BPRED_IDX_W];
      hit = btb_valid[idx] && btb_tag[idx] == tag && bht[idx][1];
      pred_taken[p] = hit;
      pred_target[p] = hit ? btb_target[idx] : pc[p] + 32'd4;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < BPRED_ENTRIES; i++) begin
        btb_valid[i] <= 1'b0;
        btb_tag[i] <= '0;
        btb_target[i] <= '0;
        bht[i] <= 2'b01;
      end
    end else begin
      for (int u = 0; u < CDB_WIDTH; u++) begin
        if (update_valid[u]) begin
          automatic logic [BPRED_IDX_W-1:0] idx;
          automatic logic [BPRED_TAG_W-1:0] tag;
          idx = update_pc[u][BPRED_IDX_W+1:2];
          tag = update_pc[u][31:2+BPRED_IDX_W];
          if (update_taken[u]) begin
            btb_valid[idx] <= 1'b1;
            btb_tag[idx] <= tag;
            btb_target[idx] <= update_target[u];
            if (bht[idx] != 2'b11)
              bht[idx] <= bht[idx] + 1'b1;
          end else begin
            if (bht[idx] != 2'b00)
              bht[idx] <= bht[idx] - 1'b1;
          end
        end
      end
    end
  end

endmodule
