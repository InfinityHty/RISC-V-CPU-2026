// cpu_pkg.sv — 全局参数与跨模块接口契约（两人唯一共同修改的文件）
// 修改本文件中的类型/参数前必须先同步 docs/internal-interfaces.md 并通知对方。
package cpu_pkg;

  // ---------------- 微架构参数（调参/报告扫描只改这里） ----------------
  localparam int ISSUE_WIDTH = 2;    // 发射宽度
  localparam int ROB_DEPTH   = 64;   // ROB 容量
  localparam int ROB_IDX_W   = 6;    // $clog2(ROB_DEPTH)
  localparam int RS_DEPTH    = 32;   // 保留站深度
  localparam int PRF_SIZE    = 64;   // 物理寄存器数量
  localparam int TAG_W       = 6;    // $clog2(PRF_SIZE)
  localparam int ICACHE_SETS = 64;
  localparam int DCACHE_SETS = 64;

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
    logic [31:0]        pc;
    opcode_e            op;
    logic [31:0]        imm;
    logic [4:0]         rs1_arch;    // 架构寄存器号（decode 填）
    logic [4:0]         rs2_arch;
    logic [4:0]         rd_arch;
    logic [TAG_W-1:0]   rs1_tag;     // 物理寄存器号（rename 填）
    logic [TAG_W-1:0]   rs2_tag;
    logic               rs1_ready;   // 操作数是否已就绪
    logic               rs2_ready;
    logic [TAG_W-1:0]   rd_tag;      // 目的物理寄存器
    logic [ROB_IDX_W-1:0] rob_idx;   // ROB 项编号
    logic               pred_taken;  // 分支预测信息（供误预测检查）
    logic [31:0]        pred_target;
  } dispatch_t;

  // ---------------- B→执行端：发射到 FU 的包（rs → alu/muldiv/lsu） ----------------
  // dispatch 载荷 + RS 在发射时从 PRF 捕获的操作数数值。
  typedef struct packed {
    dispatch_t d;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
  } issue_t;

  // ---------------- ② B→A：CDB 完成包（FU/LSU → cdb → rs/rob/prf 广播） ----------------
  typedef struct packed {
    logic               valid;
    logic [TAG_W-1:0]   tag;         // 目的物理寄存器
    logic [31:0]        value;
    logic [ROB_IDX_W-1:0] rob_idx;
    logic               is_branch;
    logic               mispredict;
    logic [31:0]        correct_pc;  // 误预测时的正确地址
  } cdb_t;

  // ---------------- ③ A→B：提交信号（rob 退休时通知 lsu 放行 store） ----------------
  typedef struct packed {
    logic               valid;
    logic [ROB_IDX_W-1:0] rob_idx;
    logic               is_store;
  } commit_t;

  // ---------------- ④ A→全体：冲刷/重定向（误预测恢复） ----------------
  typedef struct packed {
    logic               valid;
    logic [31:0]        redirect_pc;
  } flush_t;

endpackage
