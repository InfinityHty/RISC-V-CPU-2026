// cpu_pkg.sv — 全局参数与跨模块接口契约（两人唯一共同修改的文件）
// 修改本文件中的类型/参数前必须先同步 docs/internal-interfaces.md 并通知对方。
//
// 第一版 OoO 参数：1 宽发射/提交/单 CDB，先把 A 侧（取指/译码/重命名/ROB/PRF）
// 跑通，再按报告需要扩展多宽。
package cpu_pkg;

  // ---------------- 微架构参数（调参/报告扫描只改这里） ----------------
  localparam int FETCH_WIDTH    = 4;
  localparam int ISSUE_WIDTH    = 4;
  localparam int DISPATCH_WIDTH = 4;
  localparam int COMMIT_WIDTH   = 4;
  localparam int CDB_WIDTH      = 4;
  localparam int ALU_COUNT      = 4;
  localparam int WIDTH_CNT_W    = $clog2(FETCH_WIDTH + 1);
  localparam int PRF_READ_PORTS = 2 * (ISSUE_WIDTH + 2);
  localparam int DIV_BITS_PER_CYCLE = 16;
  localparam int ROB_DEPTH      = 64;   // ROB 容量
  localparam int ROB_IDX_W      = $clog2(ROB_DEPTH);
  localparam int ROB_CNT_W      = $clog2(ROB_DEPTH + 1);
  localparam int RS_DEPTH       = 32;   // 保留站深度
  localparam int PRF_SIZE       = 64;   // 物理寄存器数量（tag 0 保留给 x0）
  localparam int TAG_W          = $clog2(PRF_SIZE);
  localparam int CHECKPOINT_DEPTH = 16;
  localparam int CKPT_IDX_W     = $clog2(CHECKPOINT_DEPTH);
  localparam int ICACHE_SETS       = 128;
  localparam int ICACHE_LINE_WORDS = 4;
  localparam int ICACHE_OFF_W      = $clog2(ICACHE_LINE_WORDS);
  localparam int ICACHE_IDX_W      = $clog2(ICACHE_SETS);
  localparam int ICACHE_DEPTH      = ICACHE_SETS * ICACHE_LINE_WORDS;
  localparam int ICACHE_ADDR_W     = $clog2(ICACHE_DEPTH);
  localparam int ICACHE_TAG_W      = 32 - ICACHE_IDX_W - ICACHE_OFF_W - 2;
  localparam int DCACHE_SETS       = 1024;
  localparam int DCACHE_LINE_WORDS = 4;
  localparam int DCACHE_OFF_W      = $clog2(DCACHE_LINE_WORDS);
  localparam int DCACHE_IDX_W      = $clog2(DCACHE_SETS);
  localparam int DCACHE_DEPTH      = DCACHE_SETS * DCACHE_LINE_WORDS;
  localparam int DCACHE_ADDR_W     = $clog2(DCACHE_DEPTH);
  localparam int DCACHE_TAG_W      = 32 - DCACHE_IDX_W - DCACHE_OFF_W - 2;

  // 分支预测器：BTB + 2-bit BHT，BTB 用完整 PC 匹配，避免非分支误预测。
  localparam int BPRED_ENTRIES = 64;
  localparam int BPRED_IDX_W   = $clog2(BPRED_ENTRIES);
  localparam int BPRED_TAG_W   = 32 - BPRED_IDX_W - 2;

  // x0 固定映射到物理 tag 0，PRF[0] 恒为 0。
  localparam logic [TAG_W-1:0] X0_TAG = '0;

  // ---------------- 内部操作码（RV32IM 全覆盖） ----------------
  typedef enum logic [5:0] {
    OP_NOP,
    OP_LUI, OP_AUIPC,
    OP_JAL, OP_JALR,
    OP_BEQ, OP_BNE, OP_BLT, OP_BGE, OP_BLTU, OP_BGEU,
    OP_LB, OP_LH, OP_LW, OP_LBU, OP_LHU,
    OP_SB, OP_SH, OP_SW,
    OP_ADDI, OP_SLTI, OP_SLTIU, OP_XORI, OP_ORI, OP_ANDI,
    OP_SLLI, OP_SRLI, OP_SRAI,
    OP_ADD, OP_SUB, OP_SLL, OP_SLT, OP_SLTU,
    OP_XOR, OP_SRL, OP_SRA, OP_OR, OP_AND,
    OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU,
    OP_DIV, OP_DIVU, OP_REM, OP_REMU
  } opcode_e;

  // ---------------- ① A→B：发射包（rename → rob / rs） ----------------
  // valid 由独立握手信号携带；本结构体是纯负载。
  typedef struct packed {
    logic [31:0]          pc;
    opcode_e              op;
    logic [31:0]          imm;
    logic [4:0]           rs1_arch;    // 架构寄存器号（decode 填）
    logic [4:0]           rs2_arch;
    logic [4:0]           rd_arch;
    logic [TAG_W-1:0]     rs1_tag;     // 物理寄存器号（rename 填）
    logic [TAG_W-1:0]     rs2_tag;
    logic                 rs1_ready;   // 操作数是否已就绪
    logic                 rs2_ready;
    logic [TAG_W-1:0]     rd_tag;      // 目的物理寄存器
    logic [ROB_IDX_W-1:0] rob_idx;     // ROB 项编号
    logic                 pred_taken;  // 分支预测信息（供误预测检查）
    logic [31:0]          pred_target;
    // ---- 显式控制标志，避免各模块从 op 猜语义 ----
    logic                 use_rs1;
    logic                 use_rs2;
    logic                 has_dest;    // rd != x0 时写回
    logic                 is_branch;   // 任何可能重定向的控制流（branch/jal/jalr）
    logic                 is_store;
  } dispatch_t;

  // ---------------- B→执行端：发射到 FU 的包（rs → alu/muldiv/lsu） ----------------
  // dispatch 载荷 + RS 在发射时从 PRF 捕获的操作数数值。
  typedef struct packed {
    dispatch_t d;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
  } issue_t;

  // ---------------- ② B→A：CDB 完成包（FU/LSU → cdb → rs/rob/prf） ----------------
  typedef struct packed {
    logic                 valid;
    logic [TAG_W-1:0]     tag;         // 目的物理寄存器（无目的时置 0）
    logic [31:0]          value;
    logic [ROB_IDX_W-1:0] rob_idx;
    logic [31:0]          pc;          // 产生结果的指令 PC（分支预测更新用）
    logic                 is_branch;
    logic                 mispredict;
    logic [31:0]          correct_pc;  // 误预测时的正确地址
  } cdb_t;

  // ---------------- ③ A→B：提交信号（rob 退休时通知 lsu 放行 store） ----------------
  typedef struct packed {
    logic                 valid;
    logic [ROB_IDX_W-1:0] rob_idx;
    logic                 is_store;
  } commit_t;

  // ---------------- ④ A→全体：冲刷/重定向（执行时误预测恢复） ----------------
  // 语义：只有 squash_mask[rob_idx] == 1 的项属于“比误预测分支更年轻”的指令，
  // 必须被清除；squash_mask[rob_idx] == 0 的项（更老指令 + 分支本身）必须保留。
  // free_mask 是这些被清除项占用的物理寄存器 tag 位图，供 rename 归还 free list。
  typedef struct packed {
    logic                 valid;
    logic [31:0]          redirect_pc;
    logic [ROB_IDX_W-1:0] rob_idx;      // 触发 flush 的分支在 ROB 中的位置
    logic [ROB_DEPTH-1:0] squash_mask;  // 1 = 比该分支年轻、需要清除
    logic [PRF_SIZE-1:0]  free_mask;    // 被清除项的目的物理寄存器
  } flush_t;

endpackage
