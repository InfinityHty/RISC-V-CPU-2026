// dcache.sv — 直接映射、写穿、no-write-allocate 数据缓存 [B]
// 64 set × 4 word；LSU 侧每次一个对齐字请求，响应为单拍脉冲。
import cpu_pkg::*;

module dcache
(
  input  logic        clk,
  input  logic        rst,

  input  logic        req_valid,
  output logic        req_ready,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  input  logic        req_write,
  output logic        resp_valid,
  output logic [31:0] resp_data,

  output logic        mem_req_valid,
  input  logic        mem_req_ready,
  output logic [31:0] mem_req_addr,
  output logic [31:0] mem_req_wdata,
  output logic [3:0]  mem_req_wstrb,
  output logic        mem_req_write,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_LOOKUP,
    ST_READ_REQ,
    ST_READ_WAIT,
    ST_WRITE_REQ,
    ST_WRITE_WAIT,
    ST_RESPOND
  } state_t;
  state_t state;

  logic [DCACHE_SETS*DCACHE_TAG_W-1:0] tags;
  logic [DCACHE_SETS-1:0] valid;

  logic [31:0] saved_addr;
  logic [31:0] saved_wdata;
  logic [3:0]  saved_wstrb;
  logic        lookup_hit;
  logic        refill_cacheable;
  logic [DCACHE_OFF_W-1:0] refill_word;
  logic [31:0] resp_data_reg;

  wire [DCACHE_OFF_W-1:0] req_off = req_addr[2 +: DCACHE_OFF_W];
  wire [DCACHE_IDX_W-1:0] req_idx = req_addr[2+DCACHE_OFF_W +: DCACHE_IDX_W];
  wire [DCACHE_TAG_W-1:0] req_tag = req_addr[31 -: DCACHE_TAG_W];
  wire [DCACHE_TAG_W-1:0] stored_tag = tags[req_idx*DCACHE_TAG_W +: DCACHE_TAG_W];
  wire req_hit = valid[req_idx] && stored_tag == req_tag;
  wire req_cacheable = (req_addr[31:28] == 4'h0);

  wire [DCACHE_OFF_W-1:0] saved_off = saved_addr[2 +: DCACHE_OFF_W];
  wire [DCACHE_IDX_W-1:0] saved_idx = saved_addr[2+DCACHE_OFF_W +: DCACHE_IDX_W];
  wire [DCACHE_TAG_W-1:0] saved_tag = saved_addr[31 -: DCACHE_TAG_W];
  wire [DCACHE_ADDR_W-1:0] req_ram_addr = {req_idx, req_off};
  wire [DCACHE_ADDR_W-1:0] refill_ram_addr = {saved_idx, refill_word};

  assign req_ready = (state == ST_IDLE);
  wire accept = req_valid && req_ready;

  logic                    sram_en, sram_we;
  logic [DCACHE_ADDR_W-1:0] sram_addr;
  logic [31:0]             sram_wdata;
  logic [3:0]              sram_wmask;
  logic [31:0]             sram_rdata;

  wire read_lookup = accept && !req_write && req_cacheable;
  wire write_hit = accept && req_write && req_cacheable && req_hit;
  wire refill_write = (state == ST_READ_WAIT) && mem_resp_valid && refill_cacheable;

  always_comb begin
    sram_en    = read_lookup || write_hit || refill_write;
    sram_we    = write_hit || refill_write;
    sram_addr  = req_ram_addr;
    sram_wdata = req_wdata;
    sram_wmask = req_wstrb;
    if (refill_write) begin
      sram_addr  = refill_ram_addr;
      sram_wdata = mem_resp_data;
      sram_wmask = 4'b1111;
    end
  end

  sram_fakeram #(
    .DEPTH             (DCACHE_DEPTH),
    .WIDTH             (32),
    .WRITE_GRANULARITY (8)
  ) data_ram (
    .clk   (clk),
    .en    (sram_en),
    .we    (sram_we),
    .wmask (sram_wmask),
    .addr  (sram_addr),
    .wdata (sram_wdata),
    .rdata (sram_rdata)
  );

  assign resp_valid = ((state == ST_LOOKUP) && lookup_hit) || (state == ST_RESPOND);
  assign resp_data  = (state == ST_LOOKUP) ? sram_rdata : resp_data_reg;

  assign mem_req_valid = (state == ST_READ_REQ) || (state == ST_WRITE_REQ);
  assign mem_req_addr  = (state == ST_WRITE_REQ) ? saved_addr :
                         (refill_cacheable
                           ? {saved_addr[31:2+DCACHE_OFF_W], refill_word, 2'b00}
                           : saved_addr);
  assign mem_req_wdata = saved_wdata;
  assign mem_req_wstrb = (state == ST_WRITE_REQ) ? saved_wstrb : 4'b0000;
  assign mem_req_write = (state == ST_WRITE_REQ);

  wire refill_last = !refill_cacheable ||
                     (refill_word == DCACHE_OFF_W'(DCACHE_LINE_WORDS - 1));

  always_ff @(posedge clk) begin
    if (rst) begin
      state             <= ST_IDLE;
      tags              <= '0;
      valid             <= '0;
      saved_addr        <= '0;
      saved_wdata       <= '0;
      saved_wstrb       <= '0;
      lookup_hit        <= 1'b0;
      refill_cacheable  <= 1'b0;
      refill_word       <= '0;
      resp_data_reg     <= '0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (accept) begin
            saved_addr   <= {req_addr[31:2], 2'b00};
            saved_wdata  <= req_wdata;
            saved_wstrb  <= req_wstrb;
            refill_word  <= '0;
            refill_cacheable <= req_cacheable;
            if (req_write) begin
              state <= ST_WRITE_REQ;
            end else if (req_cacheable) begin
              lookup_hit <= req_hit;
              state <= ST_LOOKUP;
            end else begin
              state <= ST_READ_REQ;
            end
          end
        end

        ST_LOOKUP: begin
          if (lookup_hit)
            state <= ST_IDLE;
          else
            state <= ST_READ_REQ;
        end

        ST_READ_REQ: begin
          if (mem_req_valid && mem_req_ready)
            state <= ST_READ_WAIT;
        end

        ST_READ_WAIT: begin
          if (mem_resp_valid) begin
            if (!refill_cacheable || refill_word == saved_off)
              resp_data_reg <= mem_resp_data;
            if (refill_last) begin
              if (refill_cacheable) begin
                valid[saved_idx] <= 1'b1;
                tags[saved_idx*DCACHE_TAG_W +: DCACHE_TAG_W] <= saved_tag;
              end
              state <= ST_RESPOND;
            end else begin
              refill_word <= refill_word + 1'b1;
              state <= ST_READ_REQ;
            end
          end
        end

        ST_WRITE_REQ: begin
          if (mem_req_valid && mem_req_ready)
            state <= ST_WRITE_WAIT;
        end

        ST_WRITE_WAIT: begin
          if (mem_resp_valid) begin
            resp_data_reg <= 32'd0;
            state <= ST_RESPOND;
          end
        end

        ST_RESPOND: state <= ST_IDLE;
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
