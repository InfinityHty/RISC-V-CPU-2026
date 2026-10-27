// icache.sv — 直接映射指令缓存 [A]
//
// 结构：
// - ICACHE_SETS 个 set，每行 ICACHE_LINE_WORDS 个 32-bit word（默认 128×4 = 2 KiB）。
// - 数据阵列用 sram_fakeram（1RW，同步 1 拍读延迟）；tag/valid 用触发器。
// - 访问命中：accept 后下一拍返回该 word。
// - 访问缺失：顺序 refill 整行（4 个 word，每个 word 一次 AXI 读），
//   refill 完成后返回原请求的 word。
// - flush：abandon 当前待返回请求；若正在 refill，则继续把行填完（方便
//   重定向后命中），但不再向 IFU 返回旧请求的 resp_valid。
//
// IFU 侧接口是“accept 一个请求，之后一拍 resp_valid 脉冲”的语义；
// 响应按请求顺序返回，因此 IFU 可以用一个小请求 FIFO 支持多 outstanding。

import cpu_pkg::*;

module icache
(
  input  logic        clk,
  input  logic        rst,

  // 误预测冲刷（rob → icache）
  input  cpu_pkg::flush_t      flush,

  // IFU 侧
  input  logic        fetch_valid,
  input  logic [31:0] fetch_addr,
  output logic        fetch_ready,
  output logic        resp_valid,
  output logic [31:0] resp_data,

  // axi_master 侧（只读）
  output logic        mem_req_valid,
  output logic [31:0] mem_req_addr,
  input  logic        mem_req_ready,
  input  logic        mem_resp_valid,
  input  logic [31:0] mem_resp_data
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_REFILL_REQ,
    ST_REFILL_WAIT,
    ST_RESPOND
  } state_t;

  state_t state;

  // tag / valid（用 packed vector，便于复位和综合）
  logic [ICACHE_SETS*ICACHE_TAG_W-1:0] tags;
  logic [ICACHE_SETS-1:0]              valid;

  // 待返回的命中请求（命中响应只用 req_hit/pending）
  logic                    req_pending;
  logic                    req_hit;

  // refill 状态
  logic [ICACHE_IDX_W-1:0] refill_idx;
  logic [ICACHE_TAG_W-1:0] refill_tag;
  logic [ICACHE_OFF_W-1:0] refill_off;
  logic [ICACHE_OFF_W-1:0] refill_word;
  logic [31:0]             refill_line_addr;
  logic                    refill_abandon;
  logic [31:0]             resp_data_reg;

  // 地址切分
  wire [ICACHE_OFF_W-1:0] q_off = fetch_addr[2 +: ICACHE_OFF_W];
  wire [ICACHE_IDX_W-1:0] q_idx = fetch_addr[2+ICACHE_OFF_W +: ICACHE_IDX_W];
  wire [ICACHE_TAG_W-1:0] q_tag = fetch_addr[31 -: ICACHE_TAG_W];
  wire [ICACHE_TAG_W-1:0] q_tag_stored =
      tags[q_idx*ICACHE_TAG_W +: ICACHE_TAG_W];
  wire q_hit = valid[q_idx] && (q_tag_stored == q_tag);

  // ICACHE_LINE_WORDS 为 2 的幂，{index, word_offset} 即 index*LINE_WORDS+offset。
  wire [ICACHE_ADDR_W-1:0] q_word_addr      = {q_idx, q_off};
  wire [ICACHE_ADDR_W-1:0] refill_word_addr = {refill_idx, refill_word};

  // ---------------- SRAM ----------------
  logic                    sram_en, sram_we;
  logic [ICACHE_ADDR_W-1:0] sram_addr;
  logic [31:0]             sram_wdata;
  logic [31:0]             sram_rdata;

  wire read_en  = (state == ST_IDLE || state == ST_RESPOND)
               && fetch_valid && fetch_ready;
  wire write_en = (state == ST_REFILL_WAIT) && mem_resp_valid;

  assign sram_en    = read_en || write_en;
  assign sram_we    = write_en;
  assign sram_addr  = write_en ? refill_word_addr : q_word_addr;
  assign sram_wdata = mem_resp_data;

  sram_fakeram #(
    .DEPTH             (ICACHE_DEPTH),
    .WIDTH             (32),
    .WRITE_GRANULARITY (32)
  ) data_ram (
    .clk   (clk),
    .en    (sram_en),
    .we    (sram_we),
    .wmask (1'b1),
    .addr  (sram_addr),
    .wdata (sram_wdata),
    .rdata (sram_rdata)
  );

  // ---------------- 握手 / 响应 ----------------
  // 命中响应那一拍也允许 accept 下一个请求（1 指令/拍吞吐）。
  assign fetch_ready = !flush.valid
                    && ((state == ST_RESPOND)
                        || (state == ST_IDLE && (!req_pending || req_hit)));

  wire abandon_now = refill_abandon || flush.valid;

  assign resp_valid = !flush.valid
                   && ((state == ST_IDLE && req_pending && req_hit)
                       || (state == ST_RESPOND && !abandon_now));

  assign resp_data = (state == ST_RESPOND) ? resp_data_reg : sram_rdata;

  wire accept = fetch_valid && fetch_ready;

  // ---------------- AXI refill ----------------
  assign mem_req_valid = (state == ST_REFILL_REQ);
  assign mem_req_addr  = refill_line_addr + ({{(30-ICACHE_OFF_W){1'b0}}, refill_word, 2'b00});

  wire last_refill_word = (refill_word == ICACHE_OFF_W'(ICACHE_LINE_WORDS - 1));

  // ---------------- 状态机 ----------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state           <= ST_IDLE;
      req_pending     <= 1'b0;
      req_hit         <= 1'b0;
      refill_idx      <= '0;
      refill_tag      <= '0;
      refill_off      <= '0;
      refill_word     <= '0;
      refill_line_addr<= '0;
      refill_abandon  <= 1'b0;
      resp_data_reg   <= '0;
      valid           <= '0;
      tags            <= '0;
    end else begin
      // flush：先标记/清除，但 refill 状态机仍要继续跑完。
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
              state       <= ST_IDLE;
            end else begin
              req_pending      <= 1'b0;
              refill_idx       <= q_idx;
              refill_tag       <= q_tag;
              refill_off       <= q_off;
              refill_word      <= '0;
              refill_line_addr <= {fetch_addr[31:2+ICACHE_OFF_W],
                                   {(ICACHE_OFF_W+2){1'b0}}};
              refill_abandon   <= 1'b0;
              state            <= ST_REFILL_REQ;
            end
          end else if (req_pending) begin
            req_pending <= 1'b0; // 命中的 resp_valid 已被 IFU 消费
          end
        end

        ST_RESPOND: begin
          state <= ST_IDLE;
          if (accept) begin
            req_hit <= q_hit;
            if (q_hit) begin
              req_pending <= 1'b1;
              state       <= ST_IDLE;
            end else begin
              req_pending      <= 1'b0;
              refill_idx       <= q_idx;
              refill_tag       <= q_tag;
              refill_off       <= q_off;
              refill_word      <= '0;
              refill_line_addr <= {fetch_addr[31:2+ICACHE_OFF_W],
                                   {(ICACHE_OFF_W+2){1'b0}}};
              refill_abandon   <= 1'b0;
              state            <= ST_REFILL_REQ;
            end
          end
        end

        ST_REFILL_REQ: begin
          if (mem_req_valid && mem_req_ready)
            state <= ST_REFILL_WAIT;
        end

        ST_REFILL_WAIT: begin
          if (mem_resp_valid) begin
            if (refill_word == refill_off)
              resp_data_reg <= mem_resp_data;

            if (last_refill_word) begin
              valid[refill_idx] <= 1'b1;
              tags[refill_idx*ICACHE_TAG_W +: ICACHE_TAG_W] <= refill_tag;
              refill_abandon    <= 1'b0;
              state             <= abandon_now ? ST_IDLE : ST_RESPOND;
            end else begin
              refill_word <= refill_word + 1'b1;
              state       <= ST_REFILL_REQ;
            end
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end


endmodule
