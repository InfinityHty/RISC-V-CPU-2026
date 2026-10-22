// pipe_core.sv — 5-stage in-order RV32IM pipeline (IF/ID/EX/MEM/WB).
//
// - Branches/jumps resolve in EX (static not-taken prediction); a mispredict
//   or jump flushes IF/ID and ID/EX and redirects ifetch.
// - Forwarding: EX/MEM (non-load result) and MEM/WB to both EX operands.
// - Load-use: a consumer stalls in ID while the producing load is in EX;
//   the load blocks in MEM until the bus responds, and its data reaches the
//   consumer through MEM/WB forwarding.
// - MEM stage issues blocking load/store requests to axi_bus.
// - M extension: single-cycle 64-bit multiply; combinational divide with
//   RISC-V divide-by-zero / overflow semantics handled explicitly.

module pipe_core (
    input  wire        clk,
    input  wire        rst,

    // instruction stream from ifetch
    input  wire        if_out_valid,
    output logic       if_out_ready,
    input  wire [31:0] if_out_pc,
    input  wire [31:0] if_out_instr,

    // branch redirect to ifetch
    output logic       redirect_valid,
    output logic [31:0] redirect_pc,

    // data load (axi_bus)
    output logic       ld_req_valid,
    input  wire        ld_req_ready,
    output logic [31:0] ld_req_addr,
    input  wire        ld_resp_valid,
    input  wire [31:0] ld_resp_data,

    // data store (axi_bus)
    output logic       st_req_valid,
    input  wire        st_req_ready,
    output logic [31:0] st_req_addr,
    output logic [31:0] st_req_wdata,
    output logic [3:0]  st_req_wstrb,
    input  wire        st_resp_valid
);

    // ALU operations
    localparam logic [3:0] ALU_ADD = 4'd0, ALU_SUB = 4'd1, ALU_SLL = 4'd2,
                           ALU_SLT = 4'd3, ALU_SLTU = 4'd4, ALU_XOR = 4'd5,
                           ALU_SRL = 4'd6, ALU_SRA = 4'd7, ALU_OR  = 4'd8,
                           ALU_AND = 4'd9, ALU_PASS_B = 4'd10;
    // EX result select
    localparam logic [1:0] RES_ALU = 2'd0, RES_LINK = 2'd1, RES_MD = 2'd2;

    // ------------------------------------------------------------------
    // Pipeline registers
    // ------------------------------------------------------------------
    // IF/ID
    logic        if_id_valid;
    logic [31:0] if_id_pc;
    logic [31:0] if_id_instr;

    // ID/EX
    logic        id_ex_valid;
    logic [31:0] id_ex_pc;
    logic [31:0] id_ex_rs1_val, id_ex_rs2_val;
    logic [4:0]  id_ex_rs1_idx, id_ex_rs2_idx, id_ex_rd;
    logic [31:0] id_ex_imm;
    logic [3:0]  id_ex_alu_op;
    logic        id_ex_op_a_is_pc, id_ex_op_b_is_imm;
    logic [1:0]  id_ex_res_sel;
    logic        id_ex_is_branch, id_ex_is_jal, id_ex_is_jalr;
    logic        id_ex_is_load, id_ex_is_store;
    logic        id_ex_wb_en;
    logic [2:0]  id_ex_funct3;

    // EX/MEM
    logic        ex_mem_valid;
    logic        ex_mem_is_load, ex_mem_is_store;
    logic        ex_mem_wb_en;
    logic [2:0]  ex_mem_funct3;
    logic [31:0] ex_mem_result;      // ALU/MD/link result; address for loads/stores
    logic [31:0] ex_mem_store_data;
    logic [4:0]  ex_mem_rd;

    // MEM/WB
    logic        mem_wb_valid;
    logic        mem_wb_wb_en;
    logic [4:0]  mem_wb_rd;
    logic [31:0] mem_wb_wb_data;

    // architectural register file, x0 enforced as zero on read/write
    logic [31:0] rf [32];

    // set once the MEM-stage bus request has been accepted
    logic        mem_req_sent;

    // ------------------------------------------------------------------
    // ID: decode (combinational, from if_id)
    // ------------------------------------------------------------------
    wire [6:0] d_opcode = if_id_instr[6:0];
    wire [2:0] d_funct3 = if_id_instr[14:12];
    wire [4:0] d_rs1    = if_id_instr[19:15];
    wire [4:0] d_rs2    = if_id_instr[24:20];
    wire [4:0] d_rd     = if_id_instr[11:7];

    wire [31:0] imm_i = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
    wire [31:0] imm_s = {{20{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
    wire [31:0] imm_b = {{19{if_id_instr[31]}}, if_id_instr[31], if_id_instr[7],
                         if_id_instr[30:25], if_id_instr[11:8], 1'b0};
    wire [31:0] imm_u = {if_id_instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{if_id_instr[31]}}, if_id_instr[31], if_id_instr[19:12],
                         if_id_instr[20], if_id_instr[30:21], 1'b0};

    logic [31:0] d_imm;
    logic [3:0]  d_alu_op;
    logic        d_op_a_is_pc, d_op_b_is_imm;
    logic [1:0]  d_res_sel;
    logic        d_is_branch, d_is_jal, d_is_jalr;
    logic        d_is_load, d_is_store;
    logic        d_wb_en, d_use_rs1, d_use_rs2;

    always_comb begin
        d_imm         = 32'd0;
        d_alu_op      = ALU_ADD;
        d_op_a_is_pc  = 1'b0;
        d_op_b_is_imm = 1'b0;
        d_res_sel     = RES_ALU;
        d_is_branch   = 1'b0;
        d_is_jal      = 1'b0;
        d_is_jalr     = 1'b0;
        d_is_load     = 1'b0;
        d_is_store    = 1'b0;
        d_wb_en       = 1'b0;
        d_use_rs1     = 1'b0;
        d_use_rs2     = 1'b0;

        case (d_opcode)
            7'b0110111: begin // LUI
                d_wb_en       = 1'b1;
                d_alu_op      = ALU_PASS_B;
                d_op_b_is_imm = 1'b1;
                d_imm         = imm_u;
            end
            7'b0010111: begin // AUIPC
                d_wb_en       = 1'b1;
                d_alu_op      = ALU_ADD;
                d_op_a_is_pc  = 1'b1;
                d_op_b_is_imm = 1'b1;
                d_imm         = imm_u;
            end
            7'b1101111: begin // JAL
                d_wb_en   = 1'b1;
                d_res_sel = RES_LINK;
                d_is_jal  = 1'b1;
                d_imm     = imm_j;
            end
            7'b1100111: begin // JALR
                d_wb_en   = 1'b1;
                d_res_sel = RES_LINK;
                d_is_jalr = 1'b1;
                d_imm     = imm_i;
                d_use_rs1 = 1'b1;
            end
            7'b1100011: begin // conditional branches
                d_is_branch = 1'b1;
                d_imm       = imm_b;
                d_use_rs1   = 1'b1;
                d_use_rs2   = 1'b1;
            end
            7'b0000011: begin // loads
                d_wb_en       = 1'b1;
                d_is_load     = 1'b1;
                d_alu_op      = ALU_ADD;
                d_op_b_is_imm = 1'b1;
                d_imm         = imm_i;
                d_use_rs1     = 1'b1;
            end
            7'b0100011: begin // stores
                d_is_store    = 1'b1;
                d_alu_op      = ALU_ADD;
                d_op_b_is_imm = 1'b1;
                d_imm         = imm_s;
                d_use_rs1     = 1'b1;
                d_use_rs2     = 1'b1;
            end
            7'b0010011: begin // OP-IMM
                d_wb_en       = 1'b1;
                d_op_b_is_imm = 1'b1;
                d_imm         = imm_i;
                d_use_rs1     = 1'b1;
                case (d_funct3)
                    3'b000:  d_alu_op = ALU_ADD;
                    3'b010:  d_alu_op = ALU_SLT;
                    3'b011:  d_alu_op = ALU_SLTU;
                    3'b100:  d_alu_op = ALU_XOR;
                    3'b110:  d_alu_op = ALU_OR;
                    3'b111:  d_alu_op = ALU_AND;
                    3'b001:  d_alu_op = ALU_SLL;
                    3'b101:  d_alu_op = if_id_instr[30] ? ALU_SRA : ALU_SRL;
                    default: d_alu_op = ALU_ADD;
                endcase
            end
            7'b0110011: begin // OP (base + M extension)
                d_wb_en   = 1'b1;
                d_use_rs1 = 1'b1;
                d_use_rs2 = 1'b1;
                if (if_id_instr[31:25] == 7'b0000001) begin
                    d_res_sel = RES_MD;
                end else begin
                    case (d_funct3)
                        3'b000:  d_alu_op = if_id_instr[30] ? ALU_SUB : ALU_ADD;
                        3'b001:  d_alu_op = ALU_SLL;
                        3'b010:  d_alu_op = ALU_SLT;
                        3'b011:  d_alu_op = ALU_SLTU;
                        3'b100:  d_alu_op = ALU_XOR;
                        3'b101:  d_alu_op = if_id_instr[30] ? ALU_SRA : ALU_SRL;
                        3'b110:  d_alu_op = ALU_OR;
                        3'b111:  d_alu_op = ALU_AND;
                        default: d_alu_op = ALU_ADD;
                    endcase
                end
            end
            default: ; // FENCE / SYSTEM / all-zero padding: NOP
        endcase
    end

    // ------------------------------------------------------------------
    // Register file: WB write at the clock edge; ID reads combinationally
    // with a WB -> ID bypass for same-cycle write/read.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (mem_wb_valid && mem_wb_wb_en && mem_wb_rd != 5'd0)
            rf[mem_wb_rd] <= mem_wb_wb_data;
    end

    function automatic logic [31:0] rf_read(input logic [4:0] idx);
        if (idx == 5'd0)
            rf_read = 32'd0;
        else if (mem_wb_valid && mem_wb_wb_en && mem_wb_rd == idx)
            rf_read = mem_wb_wb_data;
        else
            rf_read = rf[idx];
    endfunction

    wire [31:0] id_rs1_val = rf_read(d_rs1);
    wire [31:0] id_rs2_val = rf_read(d_rs2);

    // ------------------------------------------------------------------
    // Hazard detection: load-use stall (consumer held in ID while the
    // load is in EX; the load blocks in MEM until its response arrives).
    // ------------------------------------------------------------------
    wire ld_hazard = if_id_valid && id_ex_valid && id_ex_is_load && id_ex_rd != 5'd0
                  && ((d_use_rs1 && id_ex_rd == d_rs1) || (d_use_rs2 && id_ex_rd == d_rs2));

    // ------------------------------------------------------------------
    // EX: operand forwarding, ALU, M extension, branch resolution
    // ------------------------------------------------------------------
    function automatic logic [31:0] fwd(input logic [4:0] idx, input logic [31:0] val);
        if (ex_mem_valid && ex_mem_wb_en && !ex_mem_is_load
                && ex_mem_rd != 5'd0 && ex_mem_rd == idx)
            fwd = ex_mem_result;
        else if (mem_wb_valid && mem_wb_wb_en && mem_wb_rd != 5'd0 && mem_wb_rd == idx)
            fwd = mem_wb_wb_data;
        else
            fwd = val;
    endfunction

    wire [31:0] ex_rs1_fwd = fwd(id_ex_rs1_idx, id_ex_rs1_val);
    wire [31:0] ex_rs2_fwd = fwd(id_ex_rs2_idx, id_ex_rs2_val);

    wire [31:0] alu_a = id_ex_op_a_is_pc ? id_ex_pc : ex_rs1_fwd;
    wire [31:0] alu_b = id_ex_op_b_is_imm ? id_ex_imm : ex_rs2_fwd;

    logic [31:0] alu_out;
    always_comb begin
        case (id_ex_alu_op)
            ALU_ADD:    alu_out = alu_a + alu_b;
            ALU_SUB:    alu_out = alu_a - alu_b;
            ALU_SLL:    alu_out = alu_a << alu_b[4:0];
            ALU_SLT:    alu_out = {31'd0, $signed(alu_a) < $signed(alu_b)};
            ALU_SLTU:   alu_out = {31'd0, alu_a < alu_b};
            ALU_XOR:    alu_out = alu_a ^ alu_b;
            ALU_SRL:    alu_out = alu_a >> alu_b[4:0];
            ALU_SRA:    alu_out = $signed(alu_a) >>> alu_b[4:0];
            ALU_OR:     alu_out = alu_a | alu_b;
            ALU_AND:    alu_out = alu_a & alu_b;
            ALU_PASS_B: alu_out = alu_b;
            default:    alu_out = 32'd0;
        endcase
    end

    // M extension
    logic signed [63:0] mul_ss, mul_su;
    logic        [63:0] mul_uu;
    logic        [31:0] div_q, div_r, divu_q, divu_r;
    logic        [31:0] md_result;

    always_comb begin
        mul_ss = $signed({{32{ex_rs1_fwd[31]}}, ex_rs1_fwd})
               * $signed({{32{ex_rs2_fwd[31]}}, ex_rs2_fwd});
        mul_su = $signed({{32{ex_rs1_fwd[31]}}, ex_rs1_fwd})
               * $signed({32'b0, ex_rs2_fwd});
        mul_uu = {32'b0, ex_rs1_fwd} * {32'b0, ex_rs2_fwd};

        // signed divide: RISC-V divide-by-zero and INT_MIN/-1 semantics
        if (ex_rs2_fwd == 32'd0) begin
            div_q = 32'hffffffff;
            div_r = ex_rs1_fwd;
        end else if (ex_rs1_fwd == 32'h80000000 && ex_rs2_fwd == 32'hffffffff) begin
            div_q = 32'h80000000;
            div_r = 32'd0;
        end else begin
            div_q = $signed(ex_rs1_fwd) / $signed(ex_rs2_fwd);
            div_r = $signed(ex_rs1_fwd) % $signed(ex_rs2_fwd);
        end

        // unsigned divide
        if (ex_rs2_fwd == 32'd0) begin
            divu_q = 32'hffffffff;
            divu_r = ex_rs1_fwd;
        end else begin
            divu_q = ex_rs1_fwd / ex_rs2_fwd;
            divu_r = ex_rs1_fwd % ex_rs2_fwd;
        end

        case (id_ex_funct3)
            3'b000:  md_result = mul_ss[31:0];   // MUL
            3'b001:  md_result = mul_ss[63:32];  // MULH
            3'b010:  md_result = mul_su[63:32];  // MULHSU
            3'b011:  md_result = mul_uu[63:32];  // MULHU
            3'b100:  md_result = div_q;          // DIV
            3'b101:  md_result = divu_q;         // DIVU
            3'b110:  md_result = div_r;          // REM
            3'b111:  md_result = divu_r;         // REMU
            default: md_result = 32'd0;
        endcase
    end

    logic [31:0] ex_result;
    always_comb begin
        case (id_ex_res_sel)
            RES_LINK: ex_result = id_ex_pc + 32'd4;
            RES_MD:   ex_result = md_result;
            default:  ex_result = alu_out;
        endcase
    end

    // branch resolution
    wire br_eq  = (ex_rs1_fwd == ex_rs2_fwd);
    wire br_lt  = ($signed(ex_rs1_fwd) < $signed(ex_rs2_fwd));
    wire br_ltu = (ex_rs1_fwd < ex_rs2_fwd);

    logic br_taken;
    always_comb begin
        case (id_ex_funct3)
            3'b000:  br_taken = br_eq;    // BEQ
            3'b001:  br_taken = !br_eq;   // BNE
            3'b100:  br_taken = br_lt;    // BLT
            3'b101:  br_taken = !br_lt;   // BGE
            3'b110:  br_taken = br_ltu;   // BLTU
            3'b111:  br_taken = !br_ltu;  // BGEU
            default: br_taken = 1'b0;
        endcase
    end

    assign redirect_valid = id_ex_valid && !mem_stall
                         && (id_ex_is_jal || id_ex_is_jalr
                             || (id_ex_is_branch && br_taken));
    assign redirect_pc    = id_ex_is_jalr ? ((ex_rs1_fwd + id_ex_imm) & 32'hfffffffe)
                                          : (id_ex_pc + id_ex_imm);

    // ------------------------------------------------------------------
    // MEM: blocking load/store through axi_bus
    // ------------------------------------------------------------------
    wire        mem_is_mem  = ex_mem_is_load || ex_mem_is_store;
    wire        mem_resp    = ex_mem_is_load ? ld_resp_valid : st_resp_valid;
    wire        mem_stall   = ex_mem_valid && mem_is_mem && !mem_resp;

    wire [31:0] mem_addr    = {ex_mem_result[31:2], 2'b00};
    wire [1:0]  mem_byteoff = ex_mem_result[1:0];

    assign ld_req_valid = ex_mem_valid && ex_mem_is_load && !mem_req_sent;
    assign ld_req_addr  = mem_addr;

    logic [31:0] st_wdata_s;
    logic [3:0]  st_wstrb_s;
    always_comb begin
        case (ex_mem_funct3[1:0])
            2'b00: begin // SB
                st_wstrb_s = 4'b0001 << mem_byteoff;
                st_wdata_s = {4{ex_mem_store_data[7:0]}};
            end
            2'b01: begin // SH
                st_wstrb_s = 4'b0011 << {mem_byteoff[1], 1'b0};
                st_wdata_s = {2{ex_mem_store_data[15:0]}};
            end
            default: begin // SW
                st_wstrb_s = 4'b1111;
                st_wdata_s = ex_mem_store_data;
            end
        endcase
    end

    assign st_req_valid = ex_mem_valid && ex_mem_is_store && !mem_req_sent;
    assign st_req_addr  = mem_addr;
    assign st_req_wdata = st_wdata_s;
    assign st_req_wstrb = st_wstrb_s;

    // sub-word load extraction from the aligned response word
    wire [31:0] ld_byte = ld_resp_data >> {mem_byteoff, 3'b000};
    wire [31:0] ld_half = ld_resp_data >> {mem_byteoff[1], 4'b0000};

    // intentionally discarded product/shift lanes
    wire unused_ok = &{1'b0, mul_su[31:0], mul_uu[31:0], ld_byte[31:8], ld_half[31:16]};

    logic [31:0] load_ext;
    always_comb begin
        case (ex_mem_funct3)
            3'b000:  load_ext = {{24{ld_byte[7]}}, ld_byte[7:0]};    // LB
            3'b001:  load_ext = {{16{ld_half[15]}}, ld_half[15:0]};  // LH
            3'b100:  load_ext = {24'd0, ld_byte[7:0]};               // LBU
            3'b101:  load_ext = {16'd0, ld_half[15:0]};              // LHU
            default: load_ext = ld_resp_data;                        // LW
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst)
            mem_req_sent <= 1'b0;
        else if (!mem_stall)
            mem_req_sent <= 1'b0;
        else if ((ld_req_valid && ld_req_ready) || (st_req_valid && st_req_ready))
            mem_req_sent <= 1'b1;
    end

    // ------------------------------------------------------------------
    // Pipeline register update
    // ------------------------------------------------------------------
    assign if_out_ready = !mem_stall && !redirect_valid && !ld_hazard;

    always_ff @(posedge clk) begin
        if (rst) begin
            if_id_valid  <= 1'b0;
            id_ex_valid  <= 1'b0;
            ex_mem_valid <= 1'b0;
            mem_wb_valid <= 1'b0;
        end else if (!mem_stall) begin
            // MEM -> WB
            mem_wb_valid   <= ex_mem_valid;
            mem_wb_wb_en   <= ex_mem_wb_en;
            mem_wb_rd      <= ex_mem_rd;
            mem_wb_wb_data <= ex_mem_is_load ? load_ext : ex_mem_result;

            // EX -> MEM
            ex_mem_valid      <= id_ex_valid;
            ex_mem_is_load    <= id_ex_is_load;
            ex_mem_is_store   <= id_ex_is_store;
            ex_mem_wb_en      <= id_ex_wb_en;
            ex_mem_funct3     <= id_ex_funct3;
            ex_mem_result     <= ex_result;
            ex_mem_store_data <= ex_rs2_fwd;
            ex_mem_rd         <= id_ex_rd;

            if (redirect_valid) begin
                // branch/jump resolved in EX: flush IF and ID
                id_ex_valid <= 1'b0;
                if_id_valid <= 1'b0;
            end else if (ld_hazard) begin
                // load-use: bubble into EX, hold IF/ID
                id_ex_valid <= 1'b0;
            end else begin
                // ID -> EX
                id_ex_valid      <= if_id_valid;
                id_ex_pc         <= if_id_pc;
                id_ex_rs1_val    <= id_rs1_val;
                id_ex_rs2_val    <= id_rs2_val;
                id_ex_rs1_idx    <= d_rs1;
                id_ex_rs2_idx    <= d_rs2;
                id_ex_rd         <= d_rd;
                id_ex_imm        <= d_imm;
                id_ex_alu_op     <= d_alu_op;
                id_ex_op_a_is_pc <= d_op_a_is_pc;
                id_ex_op_b_is_imm <= d_op_b_is_imm;
                id_ex_res_sel    <= d_res_sel;
                id_ex_is_branch  <= d_is_branch;
                id_ex_is_jal     <= d_is_jal;
                id_ex_is_jalr    <= d_is_jalr;
                id_ex_is_load    <= d_is_load;
                id_ex_is_store   <= d_is_store;
                id_ex_wb_en      <= d_wb_en;
                id_ex_funct3     <= d_funct3;

                // IF -> ID
                if_id_valid <= if_out_valid;
                if_id_pc    <= if_out_pc;
                if_id_instr <= if_out_instr;
            end
        end
    end

`ifdef DEBUG
    always_ff @(posedge clk) begin
        if (!rst && mem_wb_valid)
            $display("[%0t] WB rd=%0d data=%h", $time, mem_wb_rd, mem_wb_wb_data);
    end
`endif

endmodule
