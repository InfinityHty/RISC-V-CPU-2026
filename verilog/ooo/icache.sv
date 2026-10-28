import cpu_pkg::*;

module icache
(
  input  logic        clk,
  input  logic        rst,
  input  cpu_pkg::flush_t flush,

  input  logic        fetch_valid,
  input  logic [31:0] fetch_addr,
  output logic        fetch_ready,
  output logic        resp_valid,
  output logic [ICACHE_LINE_WORDS*32-1:0] resp_data,

  output logic        mem_req_valid,
  output logic [31:0] mem_req_addr,
  input  logic        mem_req_ready,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  typedef enum logic [1:0] {ST_IDLE, ST_REFILL_REQ, ST_REFILL_WAIT, ST_RESPOND} state_t;
  state_t state;

  logic [ICACHE_SETS*ICACHE_TAG_W-1:0] tags;
  logic [ICACHE_SETS-1:0] valid;
  logic req_pending, req_hit;

  logic [ICACHE_IDX_W-1:0] refill_idx;
  logic [ICACHE_TAG_W-1:0] refill_tag;
  logic [ICACHE_OFF_W-1:0] refill_word;
  logic [31:0] refill_line_addr;
  logic refill_abandon;
  logic [ICACHE_LINE_WORDS*32-1:0] resp_data_reg;

  wire [ICACHE_IDX_W-1:0] q_idx = fetch_addr[2+ICACHE_OFF_W +: ICACHE_IDX_W];
  wire [ICACHE_TAG_W-1:0] q_tag = fetch_addr[31 -: ICACHE_TAG_W];
  wire [ICACHE_TAG_W-1:0] q_tag_stored = tags[q_idx*ICACHE_TAG_W +: ICACHE_TAG_W];
  wire q_hit = valid[q_idx] && q_tag_stored == q_tag;

  logic sram_en, sram_we;
  logic [ICACHE_IDX_W-1:0] sram_addr;
  logic [ICACHE_LINE_WORDS*32-1:0] sram_wdata, sram_rdata;
  logic [ICACHE_LINE_WORDS-1:0] sram_wmask;

  wire read_en = (state == ST_IDLE || state == ST_RESPOND) && fetch_valid && fetch_ready;
  wire write_en = (state == ST_REFILL_WAIT) && mem_resp_valid;

  always_comb begin
    sram_en = read_en || write_en;
    sram_we = write_en;
    sram_addr = write_en ? refill_idx : q_idx;
    sram_wdata = '0;
    sram_wmask = '0;
    if (write_en) begin
      sram_wdata[refill_word*32 +: 32] = mem_resp_data;
      sram_wmask[refill_word] = 1'b1;
    end
  end

  sram_fakeram #(
    .DEPTH(ICACHE_SETS),
    .WIDTH(ICACHE_LINE_WORDS*32),
    .WRITE_GRANULARITY(32)
  ) data_ram (
    .clk(clk), .en(sram_en), .we(sram_we), .wmask(sram_wmask),
    .addr(sram_addr), .wdata(sram_wdata), .rdata(sram_rdata)
  );

  assign fetch_ready = !flush.valid
                    && ((state == ST_RESPOND)
                        || (state == ST_IDLE && (!req_pending || req_hit)));
  wire abandon_now = refill_abandon || flush.valid;
  assign resp_valid = !flush.valid
                   && ((state == ST_IDLE && req_pending && req_hit)
                       || (state == ST_RESPOND && !abandon_now));
  assign resp_data = (state == ST_RESPOND) ? resp_data_reg : sram_rdata;
  wire accept = fetch_valid && fetch_ready;

  assign mem_req_valid = (state == ST_REFILL_REQ);
  assign mem_req_addr = refill_line_addr + (refill_word * 4);
  wire last_refill_word = refill_word == ICACHE_OFF_W'(ICACHE_LINE_WORDS-1);

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= ST_IDLE;
      req_pending <= 1'b0;
      req_hit <= 1'b0;
      refill_idx <= '0;
      refill_tag <= '0;
      refill_word <= '0;
      refill_line_addr <= '0;
      refill_abandon <= 1'b0;
      resp_data_reg <= '0;
      valid <= '0;
      tags <= '0;
    end else begin
      if (flush.valid) begin
        req_pending <= 1'b0;
        if (state == ST_REFILL_REQ || state == ST_REFILL_WAIT)
          refill_abandon <= 1'b1;
        if (state == ST_RESPOND)
          state <= ST_IDLE;
      end

      case (state)
        ST_IDLE: begin
          if (accept) begin
            req_hit <= q_hit;
            if (q_hit) begin
              req_pending <= 1'b1;
            end else begin
              req_pending <= 1'b0;
              refill_idx <= q_idx;
              refill_tag <= q_tag;
              refill_word <= '0;
              refill_line_addr <= {fetch_addr[31:2+ICACHE_OFF_W], {(ICACHE_OFF_W+2){1'b0}}};
              refill_abandon <= 1'b0;
              state <= ST_REFILL_REQ;
            end
          end else if (req_pending) begin
            req_pending <= 1'b0;
          end
        end

        ST_RESPOND: begin
          state <= ST_IDLE;
          if (accept) begin
            req_hit <= q_hit;
            if (q_hit) begin
              req_pending <= 1'b1;
              state <= ST_IDLE;
            end else begin
              req_pending <= 1'b0;
              refill_idx <= q_idx;
              refill_tag <= q_tag;
              refill_word <= '0;
              refill_line_addr <= {fetch_addr[31:2+ICACHE_OFF_W], {(ICACHE_OFF_W+2){1'b0}}};
              refill_abandon <= 1'b0;
              state <= ST_REFILL_REQ;
            end
          end
        end

        ST_REFILL_REQ: begin
          if (mem_req_valid && mem_req_ready)
            state <= ST_REFILL_WAIT;
        end

        ST_REFILL_WAIT: begin
          if (mem_resp_valid) begin
            resp_data_reg[refill_word*32 +: 32] <= mem_resp_data;
            if (last_refill_word) begin
              valid[refill_idx] <= 1'b1;
              tags[refill_idx*ICACHE_TAG_W +: ICACHE_TAG_W] <= refill_tag;
              refill_abandon <= 1'b0;
              state <= abandon_now ? ST_IDLE : ST_RESPOND;
            end else begin
              refill_word <= refill_word + 1'b1;
              state <= ST_REFILL_REQ;
            end
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
