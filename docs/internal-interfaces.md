# 内部接口契约

本文档与 `verilog/ooo/cpu_pkg.sv` 一一对应，是 A/B 两人协作（OoO 阶段）的唯一接口事实来源。
**任何接口改动：先改本文档和 `cpu_pkg.sv` → 通知对方 → 再改各自模块。禁止单方面改接口。**

## 通用约定

1. **时钟/复位**：内部统一 `clk` / `rst`，复位高电平有效（顶层 `clock`/`reset` 直接透传）。
2. **握手**：跨模块一律 valid/ready。事务在 `valid && ready` 的时钟沿生效。
3. **防组合环**：发送方 `valid` 的组合逻辑不得依赖接收方 `ready`；数据通路同理。
4. **结构体负载**：`cdb_t` / `commit_t` / `flush_t` 自带 `valid`，无独立 ready（广播型，接收方当拍消费）；`dispatch_t` / `issue_t` 是纯负载，配独立 valid/ready。
5. **命名**：`student_top.sv` 中的跨模块线网名 = `前模块_信号含义`（如 `rn_disp_pkt`）。
6. **参数**：一律引用 `cpu_pkg` 中的 localparam，模块内禁止硬编码宽度/深度。调参只改 `cpu_pkg.sv`。

## 第一版参数

```systemverilog
ISSUE_WIDTH = 1;       // 第一版 1 宽
ROB_DEPTH   = 64;
RS_DEPTH    = 32;
PRF_SIZE    = 64;      // tag 0 固定给 x0
CHECKPOINT_DEPTH = 8;
ICACHE_SETS = 128;     // 每行 4 word => 2 KiB
ICACHE_LINE_WORDS = 4;
BPRED_ENTRIES = 64;    // BTB/BHT 项数
```

后续冲 Tier 2/3 时再扩双发射/双提交/双 CDB；接口字段先按单口实现。

## 分工

- **A（前端 + 提交端）**：`ifu`、`decode`、`rename`、`rob`、`prf`、`icache`、`bpred`。
- **B（执行 + 访存）**：`rs`、`alu`、`muldiv`、`lsu`、`dcache`、`cdb`、`axi_master`。

A 的模块全部按程序序工作，B 的模块全部按数据就绪工作。交汇面只有三个：**发射入口、CDB 回写、提交/冲刷**。

## ① A→B：发射入口

`rename → rs`：

```systemverilog
disp_valid / disp_ready / disp_pkt(dispatch_t)
```

`rename → rob`：

```systemverilog
rob_alloc_valid / rob_alloc_ready / rob_alloc_pkt(dispatch_t) / rob_alloc_idx
rob_alloc_old_tag   // rd_arch 原来的物理 tag，提交时归还 free list
```

`dispatch_t` 关键字段：

| 字段 | 含义 |
|---|---|
| `pc/op/imm` | decode 填 |
| `rs1_arch/rs2_arch/rd_arch` | 架构寄存器号 |
| `use_rs1/use_rs2` | 是否真的读该源（x0/未使用源可忽略） |
| `has_dest` | `rd != x0` 时写回 |
| `is_branch` | 任何可能重定向的控制流：条件分支/JAL/JALR |
| `is_store` | store 指令 |
| `rs1_tag/rs2_tag/rs1_ready/rs2_ready` | rename 填 |
| `rd_tag` | rename 分配的目的物理 tag；无目的时为 0 |
| `rob_idx` | ROB 返回，rename 回填 |
| `pred_taken/pred_target` | 预测信息；IFU 从 bpred 取得、经 FIFO 传给 decode，decode 原样填入 |

**tag 约定**：物理 tag 0 固定给 x0；`PRF[0]` 读恒 0；无目的指令的 `rd_tag=0`。

**握手注意**：rename 需要同时拿到 ROB 表项和 RS 空位才接收译码结果，因此
`disp_valid` 与 `disp_ready` 是同拍原子握手。B 的 `rs_disp_ready` 必须是纯占用率信号，
**不得组合依赖 `disp_valid` 或 `disp_pkt`**，否则会形成组合环。

## ② B→A：CDB 完成广播

`FU/LSU → cdb`：各自 `result_pkt(cdb_t)` + `result_ready`
`cdb → rs / rob / prf / lsu`：`cdb_bus(cdb_t)`，valid 在结构体内。

`cdb_t` 语义：

- `tag` 是目的物理寄存器；无目的（store、branch）时置 0。
- `value` 写入 `PRF[tag]`；PRF 只在 `tag != 0` 且 `owner[tag] == rob_idx` 时写，
  防止被 squash 的年轻指令的迟到结果覆盖已重新分配的 tag。
- `pc` 是产生该结果的指令 PC；分支预测器更新需要它。
- `is_branch` 表示这是一条控制流指令的结果；`mispredict/correct_pc` 由 ALU 计算。
- **对每条控制流结果，`correct_pc` 都必须给出实际 next PC**（taken 时是目标，
  不 taken 时是 `pc+4`），不能只在误预测时给。bpred 用
  `update_taken = (correct_pc != pc + 4)`。
- ALU 对 `issue_pkt.d.pred_taken/pred_target` 做比较：实际 taken/target 与预测不一致时
  置 `mispredict=1`；非控制流指令不置 `is_branch`。JAL/JALR 也按控制流处理。
- 单 CDB：每拍最多完成一条指令。B 的 `cdb.sv` 在 ALU/MUL/LSU 之间固定优先级仲裁。

## ③ A→B：提交

`rob → lsu`：

```systemverilog
commit_bus(commit_t)
```

- ROB **每条退休指令都拉高** `commit.valid`；LSU 只看 `commit.valid && commit.is_store`。
- store 必须等到对应 `commit` 出现后才真正发往 D-Cache。
- **已提交 store 不可被后续 flush 清除**：LSU 需要 committed store queue。ROB 在发出 commit 后即退休该 store，并释放物理寄存器；LSU 必须已经保存地址和数据。

## ④ A→全体：执行时误预测冲刷

`rob → ifu / rename / rs / lsu`：`flush_bus(flush_t)`

```systemverilog
typedef struct packed {
  logic                 valid;
  logic [31:0]          redirect_pc;
  logic [ROB_IDX_W-1:0] rob_idx;      // 触发 flush 的分支
  logic [ROB_DEPTH-1:0] squash_mask;  // 1 = 比该分支年轻、需要清除
  logic [PRF_SIZE-1:0]  free_mask;    // 被清除项的目的物理 tag
} flush_t;
```

**这是执行时 flush（不是提交时 flush）**：

- 分支在 ALU 执行完当拍通过 CDB 返回 `mispredict`，ROB 立刻产生 `flush.valid`。
- `squash_mask[rob_idx]==1` 的项才是“比该分支年轻”的指令，必须清除；
  `squash_mask[rob_idx]==0` 的项（更老指令 + 分支本身）必须保留。
- **B 的 RS/LSU 不得无脑清空**：只能丢弃 `squash_mask[pkt.rob_idx]==1` 的项。
  更老的指令可能在分支执行时仍在 RS/LSU 中，必须继续执行。
- IFU：清空取指队列/请求 FIFO 并重定向到 `redirect_pc`，同时清掉 outstanding；
  I-Cache 必须**放弃**旧请求并抑制它的 `resp_valid`（迟到响应由 IFU 的空请求 FIFO 忽略）。
- I-Cache：若正在 refill，继续把当前行填完（方便重定向后命中），但不再返回旧请求；
  **AXI master 不能因为 flush 丢弃已经接受的 refill 请求**，否则 I-Cache 会卡死。
- RS：清除被 squash 的发射项；更老项保留。
- LSU：清除未提交的年轻 store；已提交 store 保留。
- ROB：清除 `squash_mask` 覆盖的 ROB 项；分支本身保留，之后正常提交。
- rename：见下节，恢复 RAT 快照并归还 `free_mask` 的 tag。

## ⑤ A 内部：rename / ROB / PRF

这些不是 A/B 契约，但 `student_top_ooo.sv` 已连线，接口变更时一起改：

```systemverilog
// rob → rename：提交时归还 old_tag
commit_info_valid
commit_old_tag[tag]

// rob → rename：分支预测正确，释放 checkpoint
ckpt_release_valid
ckpt_release_rob_idx

// rename → prf：记录物理寄存器 owner（防止迟到 CDB）
prf_alloc_valid / prf_alloc_tag / prf_alloc_rob_idx

// rs ↔ prf
prf_raddr1/2, prf_rdata1/2
```

### rename 的 checkpoint 方案

- `rRAT[32]`：当前重命名映射；**不需要 cRAT**。
- 每条控制流指令（`is_branch`）在 rename 时拍一张 `rRAT` 快照，
  存到 8 项 checkpoint pool，用 `rob_idx` 标识。
- 快照在**该分支自己的 rd 映射更新之后**拍摄，因此 JAL/JALR 的 link rd 在 flush 后仍然保留。
- 分支预测正确：ROB 发 `ckpt_release_valid`，rename 释放对应快照。
- 分支误预测：ROB 发 `flush`；rename：
  1. 用 `flush.rob_idx` 找到快照，`rRAT <= 快照`；
  2. 用 `squash_mask` 作废更年轻的 checkpoint；
  3. `free_bits |= flush.free_mask`，把被 squash 的年轻指令 tag 归还。
- **不需要恢复 free bitmap 快照**：当前 free bitmap 已包含更老指令提交释放的 tag，
  只需把年轻指令的 `rd_tag` 并行置回即可。
- `ready_bits[tag]` 在分配时清零、CDB 完成时置 1；配 `tag_owner[tag]` 防止迟到 CDB 误唤醒。

### PRF 读口

PRF 只有 2 个组合读口。B 的 RS 有 ALU/MUL/LSU 三个发射端口，但**同一拍最多只能选一条指令读 PRF**；
B 必须在 RS 内做发射仲裁，或后续把 PRF/RS 接口扩成多读口。

## ⑥ 访存内部链路

`ifu → icache → axi_master`（只读）与 `lsu → dcache → axi_master`：

```systemverilog
req_valid/req_ready/req_addr[/req_wdata/req_wstrb/req_write] + resp_valid/resp_data
```

- AXI 从机握手后最早下一拍响应，默认延迟 10 拍；地址 4 字节对齐。
- 响应 `resp_valid` 必须是**单拍脉冲**。
- I-Cache 对 AXI 只保持一个 outstanding 行 refill；对 IFU 支持每拍 accept 一个请求，
  IFU 内部用 4 项请求 FIFO 保存 PC/预测信息，响应按请求顺序返回。
- 停机约定：向 `0x80000000` 写 32 位（WSTRB=4'hf），WDATA 即返回码。

## ⑦ 分支预测与 I-Cache（A 内部）

### bpred

- BTB + 2-bit BHT，`BPRED_ENTRIES=64`。
- BTB 的 index+tag 覆盖完整 PC，因此非分支指令不会误命中某条分支的 BTB 项。
- BHT 初值 `2'b01`；MSB=1 时预测 taken。
- 查询：IFU 用当前 `fetch_pc` 组合查询 `pred_taken/pred_target`；
  `pred_taken=0` 时 `pred_target = pc+4`。
- 更新：ROB 输出 `branch_update_valid = cdb_hit && cdb.is_branch`；
  顶层用 CDB 的 `pc/correct_pc` 驱动 bpred。第一版在执行时更新，可能被少量
  错误路径分支污染，后续可改为提交时更新。

### I-Cache

- `ICACHE_SETS` 和 `ICACHE_LINE_WORDS` 都必须是 2 的幂（当前 128 × 4），
  SRAM 地址用 `{index, word_offset}` 拼接；`BPRED_ENTRIES` 也建议取 2 的幂。
- 直接映射，128 set × 4 word = 2 KiB；数据阵列用 `sram_fakeram`，
  tag/valid 用触发器。
- 命中：accept 后下一拍返回；命中响应那一拍可以继续 accept 下一个请求。
- 缺失：顺序 refill 整行（4 个 word，每个 word 一次 AXI 读），完成后返回原请求 word。
- flush：放弃当前待返回请求；若正在 refill，继续填完当前行但抑制 `resp_valid`。
- 接口：`fetch_valid/fetch_addr/fetch_ready/resp_valid/resp_data` +
  `mem_req_*/mem_resp_*`，并新增 `flush_t flush` 输入。

## 综合兼容性

课程 AppImage 的 Yosys 0.63 不支持 `module m import cpu_pkg::*; (...)` 这种
模块头 import，也不支持在模块体内使用未限定的 package typedef/enum。OoO RTL 的写法是：

- 每个文件在 module 之前放 `import cpu_pkg::*;`（参数名可直接用）；
- **port 声明和局部变量里的 package 类型必须写全限定名**，如
  `cpu_pkg::dispatch_t`、`cpu_pkg::cdb_t`、`cpu_pkg::opcode_e`；
- enum 字面量写 `cpu_pkg::OP_ADDI`。

Verilator 和 Icarus 也接受这种写法。

## 调试与验证

- 统一用 `make run PROGRAM=... EXPECTED=... LOG=run.log` + `$display` 打日志。
- 日志格式：`[%0t] [模块名] 事件 关键字段`。
- 本地 correctness 长用例需要提高周期上限：`make test MAX_CYCLES=100000000`。
  默认 1,000,000 会让 `correctness_pi` / `qsort` / `tak` 等被误判超时。

## 当前状态

- **基线（main）**：`verilog/filelist.f` 仍是五级顺序流水线，19/19 correctness 通过；
  `make perf` GEOMEAN ≈ 0.1381；`make synth` 面积 ≈ 2,969 µm²、频率 ≈ 50.86 MHz。
- **OoO（`verilog/ooo/`）**：A 侧核心已实现并通过单元测试：
  - `decode.sv`：RV32IM 全译码，非法指令当 NOP（不产生 `dec_valid`，由 IFU 直接消费）；
  - `prf.sv`：x0、CDB 写、owner 保护、2 读口；
  - `rename.sv`：RAT、free/ready bitmap、checkpoint、flush 恢复；
  - `rob.sv`：分配/完成/按序提交/store commit/执行时 flush；
  - `ifu.sv`：IFU → I-Cache，4 项请求 FIFO + 4 项指令 FIFO，支持多 outstanding；
    bpred 预测 taken 时请求 PC 直接跳 target；
  - `icache.sv`：2 KiB 直接映射 I-Cache，sram_fakeram 数据阵列，行 refill，
    flush 时抑制旧响应；
  - `bpred.sv`：BTB + 2-bit BHT，完整 PC 匹配，ROB/CDB 驱动更新。
- A 侧定向单元测试在 `verilog/ooo/tb/`（`tb_decode` / `tb_core` / `tb_ifu` /
  `tb_bpred` / `tb_icache` / `tb_ifu_pred` / `tb_frontend`），运行方法见
  `verilog/ooo/tb/README.md`。
- `verilog/ooo/filelist.f` 可用于 OoO 编译检查：

```sh
make build FILELIST=verilog/ooo/filelist.f BUILD=build/ooo
```

- B 侧模块仍是空壳（输出空闲），所以 OoO 顶层目前只能编译，不能跑通程序。
- `make synth FILELIST=verilog/ooo/filelist.f` 已能被 Yosys 解析；但由于 B 是空壳，
  优化会把 A 侧逻辑剪掉，当前面积/频率数据无参考意义。
- `icache.sv` / `bpred.sv` 已在顶层例化并接入 IFU/decode；A 侧前端联调测试
  `tb_frontend` 通过。
- 切到 OoO 主构建时，把 `verilog/filelist.f` 换成 OoO 文件列表（注意 `cpu_pkg.sv` 必须排在最前），
  并移除基线 `student_top.sv`，避免两个 `student_top` 模块冲突。