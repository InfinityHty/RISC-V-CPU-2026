import cpu_pkg::*;

// dcache.sv — 直接映射、写穿、no-write-allocate 数据缓存 [B]
//
// 写路径：
// - committed store 先进入 8 项写队列，store 命中的行同时更新数据阵列；
// - 写队列用独立状态机逐条写穿到 AXI，store 不再逐条阻塞 LSU；
// - 没有脏行/回写，因此不会出现旧脏行回写覆盖新 store 的问题。
//
// 读路径：
// - load 只有在写队列为空时才被接受（简单保证 store->load 顺序）；
// - 命中直接返回；缺失顺序 refill 整行。
//
// 这是一个以正确性优先的实现，后续可在此基础上加 store-to-load 转发/
// 多 outstanding load 来继续提升 IPC。

module dcache
(
  input  logic        clk,
  input  logic        rst,

  // load 侧
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  input  logic        req_write,
  output logic        resp_valid,
  output logic [31:0] resp_data,

  // committed store 侧
  input  logic        store_valid,
  output logic        store_ready,
  input  logic [31:0] store_addr,
  input  logic [31:0] store_wdata,
  input  logic [3:0]  store_wstrb,

  // AXI
  output logic        mem_req_valid,
  input  logic        mem_req_ready,
  output logic [31:0] mem_req_addr,
  output logic [31:0] mem_req_wdata,
  output logic [3:0]  mem_req_wstrb,
  output logic        mem_req_write,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  localparam int WQ_DEPTH = 8;
  localparam int WQ_PTR_W = $clog2(WQ_DEPTH);
  localparam int WQ_CNT_W = $clog2(WQ_DEPTH + 1);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_LOOKUP,
    ST_READ_REQ,
    ST_READ_WAIT,
    ST_RESPOND
  } load_state_t;
  typedef enum logic [1:0] {W_IDLE, W_REQ, W_WAIT} write_state_t;

  load_state_t load_state;
  write_state_t write_state;

  logic [DCACHE_SETS*DCACHE_TAG_W-1:0] tags;
  logic [DCACHE_SETS-1:0] valid;

  logic [31:0] saved_addr;
  logic [31:0] saved_wdata;
  logic [3:0]  saved_wstrb;
  logic        lookup_hit;
  logic        refill_cacheable;
  logic [DCACHE_OFF_W-1:0] refill_word;
  logic [31:0] resp_data_reg;

  logic [31:0] wq_addr [WQ_DEPTH];
  logic [31:0] wq_wdata [WQ_DEPTH];
  logic [3:0]  wq_wstrb [WQ_DEPTH];
  logic [WQ_PTR_W-1:0] wq_head, wq_tail;
  logic [WQ_CNT_W-1:0] wq_count;

  // ---------------- load 地址译码 ----------------
  wire [DCACHE_OFF_W-1:0] req_off = req_addr[2 +: DCACHE_OFF_W];
  wire [DCACHE_IDX_W-1:0] req_idx = req_addr[2+DCACHE_OFF_W +: DCACHE_IDX_W];
  wire [DCACHE_TAG_W-1:0] req_tag = req_addr[31 -: DCACHE_TAG_W];
  wire [DCACHE_TAG_W-1:0] stored_tag = tags[req_idx*DCACHE_TAG_W +: DCACHE_TAG_W];
  wire req_hit = valid[req_idx] && stored_tag == req_tag;
  wire req_cacheable = (req_addr[31:28] == 4'h0);
  wire [DCACHE_ADDR_W-1:0] req_ram_addr = {req_idx, req_off};

  // ---------------- store 地址译码 ----------------
  wire [DCACHE_OFF_W-1:0] store_off = store_addr[2 +: DCACHE_OFF_W];
  wire [DCACHE_IDX_W-1:0] store_idx = store_addr[2+DCACHE_OFF_W +: DCACHE_IDX_W];
  wire [DCACHE_TAG_W-1:0] store_tag = store_addr[31 -: DCACHE_TAG_W];
  wire [DCACHE_TAG_W-1:0] store_stored_tag = tags[store_idx*DCACHE_TAG_W +: DCACHE_TAG_W];
  wire store_hit = valid[store_idx] && store_stored_tag == store_tag;
  wire store_cacheable = (store_addr[31:28] == 4'h0);
  wire [DCACHE_ADDR_W-1:0] store_ram_addr = {store_idx, store_off};

  wire [DCACHE_OFF_W-1:0] saved_off = saved_addr[2 +: DCACHE_OFF_W];
  wire [DCACHE_IDX_W-1:0] saved_idx = saved_addr[2+DCACHE_OFF_W +: DCACHE_IDX_W];
  wire [DCACHE_TAG_W-1:0] saved_tag = saved_addr[31 -: DCACHE_TAG_W];
  wire [DCACHE_ADDR_W-1:0] refill_ram_addr = {saved_idx, refill_word};

  // ---------------- 握手 ----------------
  wire load_accept = req_valid && req_ready;
  wire store_accept = store_valid && store_ready;
  assign store_ready = (load_state == ST_IDLE) && (wq_count < WQ_CNT_W'(WQ_DEPTH));
  assign req_ready = (load_state == ST_IDLE) && (wq_count == 0) && !store_valid;

  // ---------------- SRAM ----------------
  logic sram_en, sram_we;
  logic [DCACHE_ADDR_W-1:0] sram_addr;
  logic [31:0] sram_wdata;
  logic [3:0] sram_wmask;
  logic [31:0] sram_rdata;

  wire read_lookup = load_accept && !req_write && req_cacheable;
  wire store_cache_write = store_accept && store_cacheable && store_hit;
  wire refill_write = (load_state == ST_READ_WAIT) && mem_resp_valid && refill_cacheable;

  always_comb begin
    sram_en = read_lookup || store_cache_write || refill_write;
    sram_we = store_cache_write || refill_write;
    sram_addr = read_lookup ? req_ram_addr : store_ram_addr;
    sram_wdata = store_wdata;
    sram_wmask = store_wstrb;
    if (refill_write) begin
      sram_addr = refill_ram_addr;
      sram_wdata = mem_resp_data;
      sram_wmask = 4'b1111;
    end
  end

  sram_fakeram #(
    .DEPTH(DCACHE_DEPTH),
    .WIDTH(32),
    .WRITE_GRANULARITY(8)
  ) data_ram (
    .clk(clk), .en(sram_en), .we(sram_we), .wmask(sram_wmask),
    .addr(sram_addr), .wdata(sram_wdata), .rdata(sram_rdata)
  );

  // ---------------- 响应 ----------------
  assign resp_valid = (load_state == ST_LOOKUP && lookup_hit) || (load_state == ST_RESPOND);
  assign resp_data = (load_state == ST_LOOKUP) ? sram_rdata : resp_data_reg;

  // ---------------- AXI ----------------
  wire write_bus_req = (write_state == W_REQ);
  wire read_bus_req  = (load_state == ST_READ_REQ);
  assign mem_req_valid = write_bus_req || read_bus_req;
  assign mem_req_write = write_bus_req;
  assign mem_req_addr = write_bus_req ? wq_addr[wq_head]
                      : (refill_cacheable
                         ? {saved_addr[31:2+DCACHE_OFF_W], refill_word, 2'b00}
                         : saved_addr);
  assign mem_req_wdata = write_bus_req ? wq_wdata[wq_head] : saved_wdata;
  assign mem_req_wstrb = write_bus_req ? wq_wstrb[wq_head] : 4'b0000;

  wire wq_pop = (write_state == W_WAIT) && mem_resp_valid;
  wire refill_last = !refill_cacheable
                  || (refill_word == DCACHE_OFF_W'(DCACHE_LINE_WORDS - 1));

  always_ff @(posedge clk) begin
    if (rst) begin
      load_state <= ST_IDLE;
      write_state <= W_IDLE;
      valid <= '0;
      saved_addr <= '0;
      saved_wdata <= '0;
      saved_wstrb <= '0;
      lookup_hit <= 1'b0;
      refill_cacheable <= 1'b0;
      refill_word <= '0;
      resp_data_reg <= '0;
      wq_head <= '0;
      wq_tail <= '0;
      wq_count <= '0;
    end else begin
      // ---------------- store 入队 ----------------
      if (store_accept) begin
        wq_addr[wq_tail] <= {store_addr[31:2], 2'b00};
        wq_wdata[wq_tail] <= store_wdata;
        wq_wstrb[wq_tail] <= store_wstrb;
        wq_tail <= wq_tail + 1'b1;
      end

      // ---------------- 写队列状态机 ----------------
      case (write_state)
        W_IDLE: begin
          if (wq_count != 0 && load_state == ST_IDLE)
            write_state <= W_REQ;
        end
        W_REQ: if (mem_req_valid && mem_req_ready)
          write_state <= W_WAIT;
        W_WAIT: if (mem_resp_valid) begin
          wq_head <= wq_head + 1'b1;
          write_state <= W_IDLE;
        end
        default: write_state <= W_IDLE;
      endcase
      wq_count <= wq_count + (store_accept ? WQ_CNT_W'(1) : WQ_CNT_W'(0))
                           - (wq_pop ? WQ_CNT_W'(1) : WQ_CNT_W'(0));

      // ---------------- load 状态机 ----------------
      case (load_state)
        ST_IDLE: begin
          if (load_accept) begin
            saved_addr <= {req_addr[31:2], 2'b00};
            saved_wdata <= req_wdata;
            saved_wstrb <= req_wstrb;
            refill_word <= '0;
            refill_cacheable <= req_cacheable;
            if (!req_write && req_cacheable) begin
              lookup_hit <= req_hit;
              load_state <= ST_LOOKUP;
            end else begin
              load_state <= ST_READ_REQ;
            end
          end
        end
        ST_LOOKUP: begin
          if (lookup_hit) load_state <= ST_IDLE;
          else            load_state <= ST_READ_REQ;
        end
        ST_READ_REQ: begin
          if (mem_req_valid && mem_req_ready)
            load_state <= ST_READ_WAIT;
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
              load_state <= ST_RESPOND;
            end else begin
              refill_word <= refill_word + 1'b1;
              load_state <= ST_READ_REQ;
            end
          end
        end
        ST_RESPOND: load_state <= ST_IDLE;
        default: load_state <= ST_IDLE;
      endcase
    end
  end

  wire unused_ok = &{1'b0, req_off, req_wstrb, store_off};

endmodule
