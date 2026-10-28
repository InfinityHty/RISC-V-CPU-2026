import cpu_pkg::*;

module ifu
(
  input  logic        clk,
  input  logic        rst,
  input  cpu_pkg::flush_t flush,

  input  logic [FETCH_WIDTH-1:0] pred_taken,
  input  logic [FETCH_WIDTH-1:0][31:0] pred_target,

  output logic [FETCH_WIDTH-1:0] instr_valid,
  input  logic [WIDTH_CNT_W-1:0] instr_ready_count,
  output logic [FETCH_WIDTH-1:0][31:0] instr_pc,
  output logic [FETCH_WIDTH-1:0][31:0] instr_data,
  output logic [FETCH_WIDTH-1:0] instr_pred_taken,
  output logic [FETCH_WIDTH-1:0][31:0] instr_pred_target,

  output logic        mem_req_valid,
  output logic [31:0] mem_req_addr,
  input  logic        mem_req_ready,
  input  logic        mem_resp_valid,
  input  logic [ICACHE_LINE_WORDS*32-1:0] mem_resp_data
);

  localparam int REQ_DEPTH = 4;
  localparam int FIFO_DEPTH = 16;
  localparam int FIFO_PTR_W = $clog2(FIFO_DEPTH);
  localparam int FIFO_CNT_W = $clog2(FIFO_DEPTH + 1);

  logic [31:0] reqq_pc [REQ_DEPTH];
  logic [ICACHE_OFF_W-1:0] reqq_off [REQ_DEPTH];
  logic [FETCH_WIDTH-1:0] reqq_valid [REQ_DEPTH];
  logic [FETCH_WIDTH-1:0] reqq_pred_taken [REQ_DEPTH];
  logic [FETCH_WIDTH-1:0][31:0] reqq_pred_target [REQ_DEPTH];
  logic [1:0] reqq_rptr, reqq_wptr;
  logic [2:0] reqq_count;

  logic [31:0] fifo_pc [FIFO_DEPTH];
  logic [31:0] fifo_data [FIFO_DEPTH];
  logic fifo_pred_taken [FIFO_DEPTH];
  logic [31:0] fifo_pred_target [FIFO_DEPTH];
  logic [FIFO_PTR_W-1:0] rptr, wptr;
  logic [FIFO_CNT_W-1:0] count;

  logic [31:0] fetch_pc;
  logic [FETCH_WIDTH-1:0] request_lanes;
  logic [31:0] request_next_pc;
  logic request_stop;

  always_comb begin
    request_lanes = '0;
    request_stop = 1'b0;
    request_next_pc = {fetch_pc[31:2+ICACHE_OFF_W], {(ICACHE_OFF_W+2){1'b0}}}
                    + (ICACHE_LINE_WORDS * 4);
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      if (!request_stop && i < ICACHE_LINE_WORDS - fetch_pc[2 +: ICACHE_OFF_W]) begin
        request_lanes[i] = 1'b1;
        if (pred_taken[i]) begin
          request_stop = 1'b1;
          request_next_pc = pred_target[i];
        end
      end
    end
  end

  wire [FIFO_CNT_W-1:0] pop_count =
      (instr_ready_count > count) ? count : FIFO_CNT_W'(instr_ready_count);
  wire [6:0] fifo_used = count + reqq_count * FETCH_WIDTH;
  wire can_req = !flush.valid && (reqq_count < REQ_DEPTH)
              && (fifo_used + FETCH_WIDTH <= FIFO_DEPTH + pop_count)
              && (fetch_pc < 32'h1000_0000);

  assign mem_req_valid = can_req;
  assign mem_req_addr = fetch_pc;
  wire req_fire = mem_req_valid && mem_req_ready;
  wire resp_push = mem_resp_valid && (reqq_count != 0) && !flush.valid;

  logic [WIDTH_CNT_W-1:0] push_count;
  always_comb begin
    push_count = '0;
    for (int i = 0; i < FETCH_WIDTH; i++)
      push_count = push_count + reqq_valid[reqq_rptr][i];
  end

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      instr_valid[i] = count > i;
      instr_pc[i] = fifo_pc[rptr + FIFO_PTR_W'(i)];
      instr_data[i] = fifo_data[rptr + FIFO_PTR_W'(i)];
      instr_pred_taken[i] = fifo_pred_taken[rptr + FIFO_PTR_W'(i)];
      instr_pred_target[i] = fifo_pred_target[rptr + FIFO_PTR_W'(i)];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      reqq_rptr <= '0;
      reqq_wptr <= '0;
      reqq_count <= '0;
      rptr <= '0;
      wptr <= '0;
      count <= '0;
      fetch_pc <= '0;
    end else if (flush.valid) begin
      reqq_rptr <= '0;
      reqq_wptr <= '0;
      reqq_count <= '0;
      rptr <= '0;
      wptr <= '0;
      count <= '0;
      fetch_pc <= flush.redirect_pc;
    end else begin
      if (req_fire) begin
        reqq_pc[reqq_wptr] <= fetch_pc;
        reqq_off[reqq_wptr] <= fetch_pc[2 +: ICACHE_OFF_W];
        reqq_valid[reqq_wptr] <= request_lanes;
        reqq_pred_taken[reqq_wptr] <= pred_taken;
        reqq_pred_target[reqq_wptr] <= pred_target;
        reqq_wptr <= reqq_wptr + 1'b1;
        fetch_pc <= request_next_pc;
      end

      if (resp_push) begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
          if (reqq_valid[reqq_rptr][i]) begin
            fifo_pc[wptr + FIFO_PTR_W'(i)] <= reqq_pc[reqq_rptr] + i * 4;
            fifo_data[wptr + FIFO_PTR_W'(i)] <=
                mem_resp_data[(reqq_off[reqq_rptr] + i) * 32 +: 32];
            fifo_pred_taken[wptr + FIFO_PTR_W'(i)] <= reqq_pred_taken[reqq_rptr][i];
            fifo_pred_target[wptr + FIFO_PTR_W'(i)] <= reqq_pred_target[reqq_rptr][i];
          end
        end
        reqq_rptr <= reqq_rptr + 1'b1;
        wptr <= wptr + FIFO_PTR_W'(push_count);
      end

      if (pop_count != 0)
        rptr <= rptr + FIFO_PTR_W'(pop_count);

      reqq_count <= reqq_count + (req_fire ? 1 : 0) - (resp_push ? 1 : 0);
      count <= count + (resp_push ? push_count : 0) - pop_count;
    end
  end

endmodule
