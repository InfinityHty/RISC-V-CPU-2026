# 内部接口契约

本文档与 `verilog/ooo/cpu_pkg.sv` 一一对应，是两人协作（OoO 阶段）的唯一接口事实来源。
**任何接口改动：先改本文档和 `cpu_pkg.sv` → 通知对方 → 再改各自模块。禁止单方面改接口。**

## 通用约定

1. **时钟/复位**：内部统一 `clk` / `rst`，复位**高电平有效**（顶层 `clock`/`reset` 直接透传）。
2. **握手**：跨模块一律 valid/ready。事务在 `valid && ready` 的时钟沿生效。
3. **防组合环**：发送方 `valid` 的组合逻辑**不得依赖**接收方 `ready`；数据通路同理（先寄存再应答）。
4. **结构体负载**：`cdb_t` / `commit_t` / `flush_t` 自带 `valid` 字段，无独立 ready（广播型信号，接收方必须当拍消费）；`dispatch_t` / `issue_t` 是纯负载，配独立 valid/ready。
5. **命名**：`student_top.sv` 中的跨模块线网名 = `前模块_信号含义`（如 `rn_disp_pkt`、`lsu_mem_req_addr`）。
6. **参数**：一律引用 `cpu_pkg` 中的 localparam，模块内禁止硬编码宽度/深度。调参只改 `cpu_pkg.sv`。

## 接口分组

### ① 发射（A → B）
`rename → rs`：`disp_valid / disp_ready / disp_pkt(dispatch_t)`
`rename → rob`：`rob_alloc_valid / rob_alloc_ready / rob_alloc_pkt(dispatch_t) / rob_alloc_idx`
- rename 负责填 `rs1_tag/rs2_tag/rs1_ready/rs2_ready/rd_tag`；decode 负责填 `pc/op/imm/*_arch`；`rob_idx` 由 rob 返回、rename 回填。

### ② 完成回写（B → A，广播）
`FU/LSU → cdb`：各自 `result_pkt(cdb_t)` + `result_ready`
`cdb → rs / rob / prf / lsu`：`cdb_bus(cdb_t)`，valid 在结构体内
- `cdb.value` 写入 `cdb.tag` 对应物理寄存器；分支结果置 `is_branch`，误预测置 `mispredict` 并给 `correct_pc`。

### ③ 提交（A → B）
`rob → lsu`：`commit_bus(commit_t)`，valid 在结构体内
- store 必须等到对应 `commit.is_store` 出现后才真正发往 dcache。

### ④ 冲刷（A → 全体，广播）
`rob → ifu / rename / rs / lsu`：`flush_bus(flush_t)`，valid 在结构体内
- 当拍有效：ifu 重定向到 `redirect_pc`，rs/lsu 清空在途项，rename 回滚 RAT。

### ⑤ 访存内部链路
`ifu → axi_master`（只读）与 `lsu → dcache → axi_master`：
`req_valid/req_ready/req_addr[/req_wdata/req_wstrb/req_write]` + `resp_valid/resp_data`
- AXI 从机握手后最早下一拍响应，默认延迟 10 拍；地址 4 字节对齐；协议细节见 `docs/axi4-lite.md`。
- 停机约定：向 `0x80000000` 写 32 位（WSTRB=4'hf），WDATA 即返回码。

## 调试规范

- 统一用 `make run PROGRAM=... EXPECTED=... LOG=run.log` + `$display` 打日志。
- 日志格式：`[%0t] [模块名] 事件 关键字段`，例：`[1250] [ROB] commit idx=7 tag=12`。
- 尽量不用波形调 bug。

## 当前状态

- **里程碑 1（已完成）**：`verilog/` 下为五级流水线实现（`axi_bus.sv` / `ifetch.sv` / `pipe_core.sv` / `student_top.sv`），`filelist.f` 只列这 4 个文件；19/19 correctness 全部 PASS。
- OoO 骨架已整体移至 `verilog/ooo/`（原 `student_top.sv` → `student_top_ooo.sv`），不参与构建；OoO 阶段开始时再移回或重新接入 `filelist.f`。
- 骨架模块仍为空壳（输出空闲），顶层已连线。`icache.sv` / `bpred.sv` 已定义接口但未在顶层例化（第 8~9 周接入，接入时先更新本文档）。
