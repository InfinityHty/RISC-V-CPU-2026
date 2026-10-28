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

  input  logic        store_valid,
  output logic        store_ready,
  input  logic [31:0] store_addr,
  input  logic [31:0] store_wdata,
  input  logic [3:0]  store_wstrb,

  output logic        mem_req_valid,
  input  logic        mem_req_ready,
  output logic [31:0] mem_req_addr,
  output logic [31:0] mem_req_wdata,
  output logic [3:0]  mem_req_wstrb,
  output logic        mem_req_write,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  localparam int WRITE_DEPTH = 8;
  localparam int WRITE_PTR_W = $clog2(WRITE_DEPTH);
  localparam int WRITE_CNT_W = $clog2(WRITE_DEPTH + 1);

  typedef enum logic [2:0] {
    L_IDLE, L_LOOKUP, L_READ_REQ, L_READ_WAIT, L_RESPOND,
    L_EVICT_READ, L_EVICT_REQ, L_EVICT_WAIT
  } load_state_t;
  typedef enum logic [1:0] {W_IDLE, W_REQ, W_WAIT} write_state_t;
  load_state_t load_state;
  write_state_t write_state;

  logic [DCACHE_SETS*DCACHE_TAG_W-1:0] tags;
  logic [DCACHE_SETS-1:0] valid, dirty;

  logic [31:0] saved_addr;
  logic lookup_hit;
  logic refill_cacheable;
  logic [DCACHE_OFF_W-1:0] refill_word, evict_word;
  logic [31:0] resp_data_reg;
  logic store_resp_valid;

  logic [31:0] wq_addr [WRITE_DEPTH];
  logic [31:0] wq_wdata [WRITE_DEPTH];
  logic [3:0] wq_wstrb [WRITE_DEPTH];
  logic [WRITE_PTR_W-1:0] wq_head, wq_tail;
  logic [WRITE_CNT_W-1:0] wq_count;

  wire [DCACHE_OFF_W-1:0] req_off = req_addr[2 +: DCACHE_OFF_W];
  wire [DCACHE_IDX_W-1:0] req_idx = req_addr[2+DCACHE_OFF_W +: DCACHE_IDX_W];
  wire [DCACHE_TAG_W-1:0] req_tag = req_addr[31 -: DCACHE_TAG_W];
  wire [DCACHE_TAG_W-1:0] stored_tag = tags[req_idx*DCACHE_TAG_W +: DCACHE_TAG_W];
  wire req_hit = valid[req_idx] && stored_tag == req_tag;
  wire req_cacheable = (req_addr[31:28] == 4'h0);

  wire [DCACHE_OFF_W-1:0] saved_off = saved_addr[2 +: DCACHE_OFF_W];
  wire [DCACHE_IDX_W-1:0] saved_idx = saved_addr[2+DCACHE_OFF_W +: DCACHE_IDX_W];
  wire [DCACHE_TAG_W-1:0] saved_tag = saved_addr[31 -: DCACHE_TAG_W];
  wire [DCACHE_TAG_W-1:0] evict_tag = tags[saved_idx*DCACHE_TAG_W +: DCACHE_TAG_W];
  wire [DCACHE_ADDR_W-1:0] req_ram_addr = {req_idx, req_off};
  wire [DCACHE_ADDR_W-1:0] refill_ram_addr = {saved_idx, refill_word};

  logic wq_match, wq_full_cover;
  logic [31:0] wq_forward_data;
  logic [31:0] sram_rdata;
  always_comb begin
    wq_match = 1'b0;
    wq_full_cover = 1'b0;
    wq_forward_data = sram_rdata;
    for (int i = 0; i < WRITE_DEPTH; i++) begin
      if (i < wq_count && wq_addr[WRITE_PTR_W'(wq_head + i)] == saved_addr) begin
        wq_match = 1'b1;
        for (int b = 0; b < 4; b++) begin
          if (wq_wstrb[WRITE_PTR_W'(wq_head + i)][b])
            wq_forward_data[b*8 +: 8] = wq_wdata[WRITE_PTR_W'(wq_head + i)][b*8 +: 8];
        end
      end
    end
    if (wq_match) begin
      wq_full_cover = 1'b1;
      for (int b = 0; b < 4; b++) begin
        logic covered;
        covered = 1'b0;
        for (int i = 0; i < WRITE_DEPTH; i++)
          if (i < wq_count && wq_addr[WRITE_PTR_W'(wq_head + i)] == saved_addr
              && wq_wstrb[WRITE_PTR_W'(wq_head + i)][b])
            covered = 1'b1;
        if (!covered)
          wq_full_cover = 1'b0;
      end
    end
  end

  wire [31:0] write_addr = wq_addr[wq_head];
  wire [DCACHE_IDX_W-1:0] write_idx = write_addr[2+DCACHE_OFF_W +: DCACHE_IDX_W];
  wire [DCACHE_TAG_W-1:0] write_tag = write_addr[31 -: DCACHE_TAG_W];
  wire write_cacheable = write_addr[31:28] == 4'h0;
  wire write_hit = write_cacheable && valid[write_idx]
                && tags[write_idx*DCACHE_TAG_W +: DCACHE_TAG_W] == write_tag;
  wire write_local = write_state == W_IDLE && wq_count != 0 && write_hit
                  && load_state == L_IDLE;
  wire write_bus_pop = write_state == W_WAIT && mem_resp_valid;
  wire write_pop = write_local || write_bus_pop;
  wire cache_write = write_pop && write_hit;
  wire refill_write = load_state == L_READ_WAIT && mem_resp_valid && refill_cacheable;
  wire evict_read = load_state == L_EVICT_READ;
  wire writes_pending = wq_count != 0 || write_state != W_IDLE;
  wire load_bus_active = load_state inside {L_READ_REQ, L_READ_WAIT,
                                            L_EVICT_READ, L_EVICT_REQ, L_EVICT_WAIT};

  assign req_ready = req_write ? (wq_count < WRITE_DEPTH && !load_bus_active)
                   : ((load_state == L_IDLE || (load_state == L_LOOKUP && load_forward))
                      && !cache_write && !writes_pending);
  wire accept = req_valid && req_ready;
  assign store_ready = wq_count < WRITE_DEPTH && load_state == L_IDLE && !accept;
  wire store_fire = store_valid && store_ready;
  wire read_lookup = accept && !req_write && req_cacheable;

  logic sram_en, sram_we;
  logic [DCACHE_ADDR_W-1:0] sram_addr;
  logic [31:0] sram_wdata;
  logic [3:0] sram_wmask;
  always_comb begin
    sram_en = read_lookup || cache_write || refill_write || evict_read;
    sram_we = cache_write || refill_write;
    sram_addr = req_ram_addr;
    sram_wdata = req_wdata;
    sram_wmask = req_wstrb;
    if (cache_write) begin
      sram_addr = {write_idx, write_addr[2 +: DCACHE_OFF_W]};
      sram_wdata = wq_wdata[wq_head];
      sram_wmask = wq_wstrb[wq_head];
    end else if (refill_write) begin
      sram_addr = refill_ram_addr;
      sram_wdata = mem_resp_data;
      sram_wmask = 4'b1111;
    end else if (evict_read) begin
      sram_addr = {saved_idx, evict_word};
      sram_wmask = 4'b0000;
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

  wire load_forward = load_state == L_LOOKUP && (lookup_hit || wq_full_cover);
  assign resp_valid = store_resp_valid || load_forward || load_state == L_RESPOND;
  assign resp_data = store_resp_valid ? 32'd0
                   : (load_forward ? wq_forward_data : resp_data_reg);

  wire write_bus_req = write_state == W_REQ;
  wire evict_bus_req = load_state == L_EVICT_REQ && !writes_pending;
  assign mem_req_valid = write_bus_req
                      || (load_state == L_READ_REQ && !writes_pending)
                      || evict_bus_req;
  assign mem_req_write = write_bus_req || evict_bus_req;
  assign mem_req_addr = write_bus_req ? write_addr
                      : (evict_bus_req
                        ? {evict_tag, saved_idx, evict_word, 2'b00}
                        : (refill_cacheable
                          ? {saved_addr[31:2+DCACHE_OFF_W], refill_word, 2'b00}
                          : saved_addr));
  assign mem_req_wdata = write_bus_req ? wq_wdata[wq_head] : sram_rdata;
  assign mem_req_wstrb = write_bus_req ? wq_wstrb[wq_head]
                       : (evict_bus_req ? 4'b1111 : 4'b0000);
  wire refill_last = !refill_cacheable
                  || refill_word == DCACHE_OFF_W'(DCACHE_LINE_WORDS - 1);
  wire evict_last = evict_word == DCACHE_OFF_W'(DCACHE_LINE_WORDS - 1);
  wire dirty_miss = valid[saved_idx] && dirty[saved_idx]
                 && tags[saved_idx*DCACHE_TAG_W +: DCACHE_TAG_W] != saved_tag;

  always_ff @(posedge clk) begin
    if (rst) begin
      load_state <= L_IDLE;
      write_state <= W_IDLE;
      tags <= '0;
      valid <= '0;
      dirty <= '0;
      saved_addr <= '0;
      lookup_hit <= 1'b0;
      refill_cacheable <= 1'b0;
      refill_word <= '0;
      evict_word <= '0;
      resp_data_reg <= '0;
      store_resp_valid <= 1'b0;
      wq_head <= '0;
      wq_tail <= '0;
      wq_count <= '0;
    end else begin
      store_resp_valid <= accept && req_write;
      if ((accept && req_write) || store_fire) begin
        wq_addr[wq_tail] <= {(accept && req_write) ? req_addr[31:2] : store_addr[31:2], 2'b00};
        wq_wdata[wq_tail] <= (accept && req_write) ? req_wdata : store_wdata;
        wq_wstrb[wq_tail] <= (accept && req_write) ? req_wstrb : store_wstrb;
        wq_tail <= wq_tail + 1'b1;
      end
      if (write_pop) begin
        wq_head <= wq_head + 1'b1;
        if (write_hit)
          dirty[write_idx] <= 1'b1;
      end
      wq_count <= wq_count + (((accept && req_write) || store_fire) ? 1 : 0)
                           - (write_pop ? 1 : 0);

      case (write_state)
        W_IDLE: begin
          if (wq_count != 0 && !write_hit
              && load_state != L_READ_WAIT && load_state != L_EVICT_WAIT)
            write_state <= W_REQ;
        end
        W_REQ: if (write_bus_req && mem_req_ready)
          write_state <= W_WAIT;
        W_WAIT: if (mem_resp_valid)
          write_state <= W_IDLE;
        default: write_state <= W_IDLE;
      endcase

      case (load_state)
        L_IDLE: begin
          if (accept && !req_write) begin
            saved_addr <= {req_addr[31:2], 2'b00};
            refill_word <= '0;
            evict_word <= '0;
            refill_cacheable <= req_cacheable;
            if (req_cacheable) begin
              lookup_hit <= req_hit;
              load_state <= L_LOOKUP;
            end else begin
              load_state <= L_READ_REQ;
            end
          end
        end
        L_LOOKUP: begin
          if (accept && !req_write) begin
            saved_addr <= {req_addr[31:2], 2'b00};
            refill_word <= '0;
            evict_word <= '0;
            refill_cacheable <= req_cacheable;
            if (req_cacheable) begin
              lookup_hit <= req_hit;
              load_state <= L_LOOKUP;
            end else begin
              load_state <= L_READ_REQ;
            end
          end else if (lookup_hit || wq_full_cover)
            load_state <= L_IDLE;
          else if (dirty_miss)
            load_state <= L_EVICT_READ;
          else
            load_state <= L_READ_REQ;
        end
        L_EVICT_READ: load_state <= L_EVICT_REQ;
        L_EVICT_REQ: begin
          if (evict_bus_req && mem_req_ready)
            load_state <= L_EVICT_WAIT;
        end
        L_EVICT_WAIT: begin
          if (mem_resp_valid) begin
            if (evict_last) begin
              dirty[saved_idx] <= 1'b0;
              load_state <= L_READ_REQ;
            end else begin
              evict_word <= evict_word + 1'b1;
              load_state <= L_EVICT_READ;
            end
          end
        end
        L_READ_REQ: begin
          if (mem_req_valid && mem_req_ready && !mem_req_write)
            load_state <= L_READ_WAIT;
        end
        L_READ_WAIT: begin
          if (mem_resp_valid) begin
            if (!refill_cacheable || refill_word == saved_off)
              resp_data_reg <= mem_resp_data;
            if (refill_last) begin
              if (refill_cacheable) begin
                valid[saved_idx] <= 1'b1;
                dirty[saved_idx] <= 1'b0;
                tags[saved_idx*DCACHE_TAG_W +: DCACHE_TAG_W] <= saved_tag;
              end
              load_state <= L_RESPOND;
            end else begin
              refill_word <= refill_word + 1'b1;
              load_state <= L_READ_REQ;
            end
          end
        end
        L_RESPOND: load_state <= L_IDLE;
        default: load_state <= L_IDLE;
      endcase
    end
  end

endmodule
