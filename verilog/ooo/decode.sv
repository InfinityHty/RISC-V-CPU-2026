// decode.sv — RV32IM 译码 [A]
//
// 纯组合译码：把 32 位指令译成 dispatch_t。
// 只填 pc/op/imm/arch 寄存器号/控制标志/预测信息；物理寄存器字段和
// rob_idx 由 rename 填写。
//
// 非法指令（包括 FENCE/SYSTEM/全零）统一当作 OP_NOP，不写回、不访存。

import cpu_pkg::*;

module decode
(
  input  logic        clk,
  input  logic        rst,

  // 取指输入（ifu → decode）
  input  logic        instr_valid,
  output logic        instr_ready,
  input  logic [31:0] instr_pc,
  input  logic [31:0] instr_data,

  // 当前指令的分支预测（ifu/bpred → decode）
  input  logic        pred_taken_i,
  input  logic [31:0] pred_target_i,

  // 译码输出（decode → rename）
  output logic        dec_valid,
  input  logic        dec_ready,
  output cpu_pkg::dispatch_t dec_pkt
);

  // 字段切片
  wire [6:0]  opcode = instr_data[6:0];
  wire [2:0]  funct3 = instr_data[14:12];
  wire [6:0]  funct7 = instr_data[31:25];
  wire [4:0]  rs1    = instr_data[19:15];
  wire [4:0]  rs2    = instr_data[24:20];
  wire [4:0]  rd     = instr_data[11:7];

  // 立即数
  wire [31:0] imm_i = {{20{instr_data[31]}}, instr_data[31:20]};
  wire [31:0] imm_s = {{20{instr_data[31]}}, instr_data[31:25], instr_data[11:7]};
  wire [31:0] imm_b = {{19{instr_data[31]}}, instr_data[31], instr_data[7],
                       instr_data[30:25], instr_data[11:8], 1'b0};
  wire [31:0] imm_u = {instr_data[31:12], 12'b0};
  wire [31:0] imm_j = {{11{instr_data[31]}}, instr_data[31], instr_data[19:12],
                       instr_data[20], instr_data[30:21], 1'b0};

  // 译码中间结果
  logic [31:0] d_imm;
  cpu_pkg::opcode_e     d_op;
  logic        d_wb_en;
  logic        d_use_rs1;
  logic        d_use_rs2;
  logic        d_is_branch;
  logic        d_is_store;

  always_comb begin
    d_imm        = 32'd0;
    d_op         = cpu_pkg::OP_NOP;
    d_wb_en      = 1'b0;
    d_use_rs1    = 1'b0;
    d_use_rs2    = 1'b0;
    d_is_branch  = 1'b0;
    d_is_store   = 1'b0;

    case (opcode)
      // ---------------- U type ----------------
      7'b0110111: begin // LUI
        d_op    = cpu_pkg::OP_LUI;
        d_wb_en = 1'b1;
        d_imm   = imm_u;
      end
      7'b0010111: begin // AUIPC
        d_op    = cpu_pkg::OP_AUIPC;
        d_wb_en = 1'b1;
        d_imm   = imm_u;
      end

      // ---------------- Jumps ----------------
      7'b1101111: begin // JAL
        d_op        = cpu_pkg::OP_JAL;
        d_wb_en     = 1'b1;
        d_imm       = imm_j;
        d_is_branch = 1'b1;
      end
      7'b1100111: begin // JALR
        d_op        = cpu_pkg::OP_JALR;
        d_wb_en     = 1'b1;
        d_use_rs1   = 1'b1;
        d_imm       = imm_i;
        d_is_branch = 1'b1;
      end

      // ---------------- Conditional branches ----------------
      7'b1100011: begin // BEQ/BNE/BLT/BGE/BLTU/BGEU
        d_use_rs1   = 1'b1;
        d_use_rs2   = 1'b1;
        d_imm       = imm_b;
        d_is_branch = 1'b1;
        case (funct3)
          3'b000: d_op = cpu_pkg::OP_BEQ;
          3'b001: d_op = cpu_pkg::OP_BNE;
          3'b100: d_op = cpu_pkg::OP_BLT;
          3'b101: d_op = cpu_pkg::OP_BGE;
          3'b110: d_op = cpu_pkg::OP_BLTU;
          3'b111: d_op = cpu_pkg::OP_BGEU;
          default: begin
            d_op        = cpu_pkg::OP_NOP;
            d_is_branch = 1'b0;
            d_use_rs1   = 1'b0;
            d_use_rs2   = 1'b0;
          end
        endcase
      end

      // ---------------- Loads ----------------
      7'b0000011: begin
        d_wb_en   = 1'b1;
        d_use_rs1 = 1'b1;
        d_imm     = imm_i;
        case (funct3)
          3'b000: d_op = cpu_pkg::OP_LB;
          3'b001: d_op = cpu_pkg::OP_LH;
          3'b010: d_op = cpu_pkg::OP_LW;
          3'b100: d_op = cpu_pkg::OP_LBU;
          3'b101: d_op = cpu_pkg::OP_LHU;
          default: d_op = cpu_pkg::OP_NOP;
        endcase
        if (d_op == cpu_pkg::OP_NOP) begin
          d_wb_en   = 1'b0;
          d_use_rs1 = 1'b0;
        end
      end

      // ---------------- Stores ----------------
      7'b0100011: begin
        d_use_rs1 = 1'b1;
        d_use_rs2 = 1'b1;
        d_imm     = imm_s;
        d_is_store = 1'b1;
        case (funct3)
          3'b000: d_op = cpu_pkg::OP_SB;
          3'b001: d_op = cpu_pkg::OP_SH;
          3'b010: d_op = cpu_pkg::OP_SW;
          default: begin
            d_op       = cpu_pkg::OP_NOP;
            d_is_store = 1'b0;
            d_use_rs1  = 1'b0;
            d_use_rs2  = 1'b0;
          end
        endcase
      end

      // ---------------- OP-IMM ----------------
      7'b0010011: begin
        d_wb_en   = 1'b1;
        d_use_rs1 = 1'b1;
        d_imm     = imm_i;
        case (funct3)
          3'b000: d_op = cpu_pkg::OP_ADDI;
          3'b010: d_op = cpu_pkg::OP_SLTI;
          3'b011: d_op = cpu_pkg::OP_SLTIU;
          3'b100: d_op = cpu_pkg::OP_XORI;
          3'b110: d_op = cpu_pkg::OP_ORI;
          3'b111: d_op = cpu_pkg::OP_ANDI;
          3'b001: d_op = cpu_pkg::OP_SLLI;
          3'b101: begin
            if (instr_data[30]) d_op = cpu_pkg::OP_SRAI;
            else                d_op = cpu_pkg::OP_SRLI;
          end
          default: begin
            d_op    = cpu_pkg::OP_NOP;
            d_wb_en = 1'b0;
            d_use_rs1 = 1'b0;
          end
        endcase
      end

      // ---------------- OP (base + M extension) ----------------
      7'b0110011: begin
        d_wb_en   = 1'b1;
        d_use_rs1 = 1'b1;
        d_use_rs2 = 1'b1;
        if (funct7 == 7'b0000001) begin
          case (funct3)
            3'b000: d_op = cpu_pkg::OP_MUL;
            3'b001: d_op = cpu_pkg::OP_MULH;
            3'b010: d_op = cpu_pkg::OP_MULHSU;
            3'b011: d_op = cpu_pkg::OP_MULHU;
            3'b100: d_op = cpu_pkg::OP_DIV;
            3'b101: d_op = cpu_pkg::OP_DIVU;
            3'b110: d_op = cpu_pkg::OP_REM;
            3'b111: d_op = cpu_pkg::OP_REMU;
            default: d_op = cpu_pkg::OP_NOP;
          endcase
        end else if (funct7 == 7'b0000000 || funct7 == 7'b0100000) begin
          case (funct3)
            3'b000: begin
              if (instr_data[30]) d_op = cpu_pkg::OP_SUB;
              else                d_op = cpu_pkg::OP_ADD;
            end
            3'b001: d_op = cpu_pkg::OP_SLL;
            3'b010: d_op = cpu_pkg::OP_SLT;
            3'b011: d_op = cpu_pkg::OP_SLTU;
            3'b100: d_op = cpu_pkg::OP_XOR;
            3'b101: begin
              if (instr_data[30]) d_op = cpu_pkg::OP_SRA;
              else                d_op = cpu_pkg::OP_SRL;
            end
            3'b110: d_op = cpu_pkg::OP_OR;
            3'b111: d_op = cpu_pkg::OP_AND;
            default: d_op = cpu_pkg::OP_NOP;
          endcase
        end else begin
          d_op = cpu_pkg::OP_NOP;
        end
        if (d_op == cpu_pkg::OP_NOP) begin
          d_wb_en   = 1'b0;
          d_use_rs1 = 1'b0;
          d_use_rs2 = 1'b0;
        end
      end

      // FENCE / SYSTEM / 非法 / 全零：NOP
      default: begin
        d_op = cpu_pkg::OP_NOP;
      end
    endcase
  end

  always_comb begin
    dec_pkt           = '0;
    dec_pkt.pc        = instr_pc;
    dec_pkt.op        = d_op;
    dec_pkt.imm       = d_imm;
    dec_pkt.rs1_arch  = rs1;
    dec_pkt.rs2_arch  = rs2;
    dec_pkt.rd_arch   = rd;
    dec_pkt.pred_taken  = pred_taken_i;
    dec_pkt.pred_target = pred_target_i;
    dec_pkt.use_rs1   = d_use_rs1;
    dec_pkt.use_rs2   = d_use_rs2;
    dec_pkt.has_dest  = d_wb_en && (rd != 5'd0);
    dec_pkt.is_branch = d_is_branch;
    dec_pkt.is_store  = d_is_store;
  end

  // 非法/全零指令当作 NOP：直接让 IFU 消费掉，不占 ROB/RS 资源。
  assign dec_valid    = instr_valid && (d_op != cpu_pkg::OP_NOP);
  assign instr_ready  = dec_ready;

  // clk/rst 当前不需要，保留端口以便后续插入译码寄存器。
  wire unused_ok = &{1'b0, clk, rst};

endmodule
