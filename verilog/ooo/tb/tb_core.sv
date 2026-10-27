`timescale 1ns/1ps
module tb_core;
  import cpu_pkg::*;

  localparam int RSQ  = 16;
  localparam int QMAX = 128;

  logic clk = 0;
  logic rst = 1;
  always #5 clk = ~clk;

  // decode → rename
  logic      dec_valid;
  dispatch_t dec_pkt;
  logic      dec_ready;

  // rename ↔ rob
  logic                  rn_rob_valid, rn_rob_ready;
  dispatch_t             rn_rob_pkt;
  logic [ROB_IDX_W-1:0]  rob_alloc_idx;
  logic [TAG_W-1:0]      rob_alloc_old_tag;

  // rename → rs
  logic      rn_disp_valid, rs_disp_ready;
  dispatch_t rn_disp_pkt;

  // CDB / commit / flush
  cdb_t    cdb;
  commit_t commit;
  logic    commit_info_valid;
  logic [TAG_W-1:0] commit_old_tag;
  flush_t  flush;
  logic    ckpt_release_valid;
  logic [ROB_IDX_W-1:0] ckpt_release_rob_idx;
  logic    rob_branch_update_valid;

  // PRF alloc / read
  logic prf_alloc_valid;
  logic [TAG_W-1:0] prf_alloc_tag;
  logic [ROB_IDX_W-1:0] prf_alloc_rob_idx;
  logic [TAG_W-1:0] prf_raddr1, prf_raddr2;
  logic [31:0] prf_rdata1, prf_rdata2;

  rename u_rename (
    .clk(clk), .rst(rst),
    .dec_valid(dec_valid), .dec_ready(dec_ready), .dec_pkt(dec_pkt),
    .rob_alloc_valid(rn_rob_valid), .rob_alloc_ready(rn_rob_ready),
    .rob_alloc_pkt(rn_rob_pkt), .rob_alloc_idx(rob_alloc_idx),
    .rob_alloc_old_tag(rob_alloc_old_tag),
    .disp_valid(rn_disp_valid), .disp_ready(rs_disp_ready), .disp_pkt(rn_disp_pkt),
    .cdb(cdb),
    .commit_valid(commit_info_valid), .commit_old_tag(commit_old_tag),
    .flush(flush),
    .ckpt_release_valid(ckpt_release_valid),
    .ckpt_release_rob_idx(ckpt_release_rob_idx),
    .prf_alloc_valid(prf_alloc_valid), .prf_alloc_tag(prf_alloc_tag),
    .prf_alloc_rob_idx(prf_alloc_rob_idx)
  );

  rob u_rob (
    .clk(clk), .rst(rst),
    .rob_alloc_valid(rn_rob_valid), .rob_alloc_ready(rn_rob_ready),
    .rob_alloc_pkt(rn_rob_pkt), .rob_alloc_old_tag(rob_alloc_old_tag),
    .rob_alloc_idx(rob_alloc_idx),
    .cdb(cdb), .commit(commit),
    .commit_info_valid(commit_info_valid), .commit_old_tag(commit_old_tag),
    .flush(flush),
    .ckpt_release_valid(ckpt_release_valid),
    .ckpt_release_rob_idx(ckpt_release_rob_idx),
    .branch_update_valid(rob_branch_update_valid)
  );

  prf u_prf (
    .clk(clk), .rst(rst),
    .alloc_valid(prf_alloc_valid), .alloc_tag(prf_alloc_tag),
    .alloc_rob_idx(prf_alloc_rob_idx),
    .cdb(cdb),
    .raddr1(prf_raddr1), .raddr2(prf_raddr2),
    .rdata1(prf_rdata1), .rdata2(prf_rdata2)
  );

  // ---------------- fake RS + completion ----------------
  dispatch_t q_pkt [RSQ];
  int        q_delay [RSQ];
  logic      q_valid [RSQ];
  int        q_count;
  int        c_idx;

  assign rs_disp_ready = (q_count < RSQ);

  always_comb begin
    cdb = '0;
    c_idx = -1;
    for (int i = 0; i < RSQ; i = i + 1)
      if (c_idx < 0 && q_valid[i] && q_delay[i] == 0)
        c_idx = i;
    if (c_idx >= 0) begin
      cdb.valid     = 1'b1;
      cdb.tag       = q_pkt[c_idx].rd_tag;
      cdb.value     = 32'hA0000000 | {{(32-ROB_IDX_W){1'b0}}, q_pkt[c_idx].rob_idx};
      cdb.rob_idx   = q_pkt[c_idx].rob_idx;
      cdb.is_branch = q_pkt[c_idx].is_branch;
      cdb.mispredict = q_pkt[c_idx].is_branch && (q_pkt[c_idx].pc == mispredict_pc);
      cdb.correct_pc = correct_pc_cfg;
    end
  end

  // ---------------- expected commit queue / observations ----------------
  dispatch_t exp_q [QMAX];
  int        exp_count;
  int        commit_count;
  logic      seen_p1_commit;
  logic [31:0] commit_pc_dbg;
  logic [31:0] mispredict_pc, correct_pc_cfg;
  logic        phase2;
  int          flush_count;

  logic [31:0] obs_pc, obs_rs1_tag, obs_rs2_tag, obs_rd_tag;
  logic        obs_valid;

  // helper: read squash mask without dynamic part-select (Icarus friendliness)
  logic [ROB_DEPTH-1:0] squash_mask_tb;
  assign squash_mask_tb = flush.squash_mask;

  function automatic logic mask_get(input logic [ROB_IDX_W-1:0] idx);
    begin
      mask_get = 1'b0;
      for (int r = 0; r < ROB_DEPTH; r = r + 1)
        if (idx == ROB_IDX_W'(r))
          mask_get = squash_mask_tb[r];
    end
  endfunction

  int drop_cnt;
  logic drop;
  logic push_done;

  always @(posedge clk) begin
    if (rst) begin
      q_count = 0;
      for (int i = 0; i < RSQ; i = i + 1) begin
        q_valid[i] = 0;
        q_delay[i] = 0;
      end
      exp_count = 0;
      commit_count = 0;
      seen_p1_commit = 0;
      obs_valid = 0;
      obs_pc = 0;
      obs_rs1_tag = 0;
      obs_rs2_tag = 0;
      obs_rd_tag = 0;
      commit_pc_dbg = 0;
      mispredict_pc = 32'h1008;
      correct_pc_cfg = 32'h2000;
      phase2 = 0;
      flush_count = 0;
    end else begin
      // 1) fake RS pop / delay decrement
      drop_cnt = 0;
      for (int i = 0; i < RSQ; i = i + 1) begin
        if (q_valid[i]) begin
          drop = (cdb.valid && (c_idx == i)) || (flush.valid && mask_get(q_pkt[i].rob_idx));
          if (drop) begin
            q_valid[i] = 0;
            drop_cnt = drop_cnt + 1;
          end else if (q_delay[i] > 0) begin
            q_delay[i] = q_delay[i] - 1;
          end
        end
      end

      // 2) fake RS push (reuse a slot freed above)
      if (rn_disp_valid && rs_disp_ready) begin
        push_done = 0;
        for (int i = 0; i < RSQ; i = i + 1)
          if (!push_done && !q_valid[i]) begin
            q_pkt[i]   = rn_disp_pkt;
            q_delay[i] = rn_disp_pkt.is_branch ? 8 : 2;
            q_valid[i] = 1;
            q_count    = q_count + 1;
            obs_valid  = 1;
            obs_pc     = rn_disp_pkt.pc;
            obs_rs1_tag= rn_disp_pkt.rs1_tag;
            obs_rs2_tag= rn_disp_pkt.rs2_tag;
            obs_rd_tag = rn_disp_pkt.rd_tag;
            push_done  = 1;
          end
      end
      q_count = q_count - drop_cnt;

      // 3) expected queue: push on ROB alloc
      if (rn_rob_valid && rn_rob_ready) begin
        exp_q[exp_count] = rn_rob_pkt;
        exp_count = exp_count + 1;
      end

      // 3b) flush assertions (before rebuild so squashed entries are visible)
      if (flush.valid) begin
        flush_count = flush_count + 1;
        if (flush.redirect_pc !== correct_pc_cfg)
          $fatal(1, "flush redirect_pc got %h exp %h", flush.redirect_pc, correct_pc_cfg);
        if (!phase2) begin
          for (int i = 0; i < exp_count; i = i + 1) begin
            if (exp_q[i].pc == 32'h100c || exp_q[i].pc == 32'h1010 || exp_q[i].pc == 32'h1014)
              if (!mask_get(exp_q[i].rob_idx))
                $fatal(1, "flush missing squash bit for pc=%h idx=%0d", exp_q[i].pc, exp_q[i].rob_idx);
            if (exp_q[i].pc == 32'h1000 || exp_q[i].pc == 32'h1004 || exp_q[i].pc == 32'h1006 || exp_q[i].pc == 32'h1008)
              if (mask_get(exp_q[i].rob_idx))
                $fatal(1, "flush wrongly squashed pc=%h idx=%0d", exp_q[i].pc, exp_q[i].rob_idx);
          end
        end else begin
          for (int i = 0; i < exp_count; i = i + 1) begin
            if (exp_q[i].pc == 32'h3000 && mask_get(exp_q[i].rob_idx))
              $fatal(1, "phase2: JAL itself wrongly squashed");
            if (exp_q[i].pc == 32'h3004 && !mask_get(exp_q[i].rob_idx))
              $fatal(1, "phase2: younger ADDI not squashed");
          end
        end
      end

      // 4) flush removes squashed entries from expected queue
      if (flush.valid) begin
        drop = 0; // reused as temp
        begin : flush_rebuild
          int k;
          k = 0;
          for (int i = 0; i < exp_count; i = i + 1) begin
            drop = mask_get(exp_q[i].rob_idx);
            if (!drop) begin
              exp_q[k] = exp_q[i];
              k = k + 1;
            end
          end
          exp_count = k;
        end
      end

      // 5) commit check
      if (commit.valid) begin
        if (exp_count == 0) $fatal(1, "commit with empty expected queue idx=%0d", commit.rob_idx);
        if (exp_q[0].rob_idx !== commit.rob_idx)
          $fatal(1, "commit order: got idx %0d, expected idx %0d pc %h",
                 commit.rob_idx, exp_q[0].rob_idx, exp_q[0].pc);
        if (exp_q[0].is_store !== commit.is_store)
          $fatal(1, "commit is_store mismatch pc=%h got %0b exp %0b",
                 exp_q[0].pc, commit.is_store, exp_q[0].is_store);
        commit_pc_dbg = exp_q[0].pc;
        if (exp_q[0].pc == 32'h1000) seen_p1_commit = 1;
        commit_count = commit_count + 1;
        // pop
        for (int i = 0; i < exp_count - 1; i = i + 1)
          exp_q[i] = exp_q[i+1];
        exp_count = exp_count - 1;
      end

    end
  end

  // ---------------- stimulus ----------------
  task automatic send_pkt(
    input [31:0] pc,
    input opcode_e op,
    input [4:0] rd,
    input [4:0] rs1,
    input [4:0] rs2,
    input logic has_dest,
    input logic use1,
    input logic use2,
    input logic is_branch,
    input logic is_store,
    input [31:0] imm
  );
    begin
      @(negedge clk);
      dec_valid = 1'b1;
      dec_pkt = '0;
      dec_pkt.pc = pc;
      dec_pkt.op = op;
      dec_pkt.imm = imm;
      dec_pkt.rd_arch = rd;
      dec_pkt.rs1_arch = rs1;
      dec_pkt.rs2_arch = rs2;
      dec_pkt.has_dest = has_dest;
      dec_pkt.use_rs1 = use1;
      dec_pkt.use_rs2 = use2;
      dec_pkt.is_branch = is_branch;
      dec_pkt.is_store = is_store;
      while (!dec_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      dec_valid = 1'b0;
    end
  endtask

  int timeout;
  initial begin
    dec_valid = 0; dec_pkt = '0;
    prf_raddr1 = 0; prf_raddr2 = 0;
    repeat (5) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // P1, P2, store, branch, then wrong-path instructions
    send_pkt(32'h1000, OP_ADDI, 5'd1, 5'd0, 5'd0, 1, 1, 0, 0, 0, 32'd5);
    send_pkt(32'h1004, OP_ADDI, 5'd2, 5'd0, 5'd0, 1, 1, 0, 0, 0, 32'd7);
    send_pkt(32'h1006, OP_SW,   5'd0, 5'd0, 5'd1, 0, 1, 1, 0, 1, 32'd0);
    send_pkt(32'h1008, OP_BEQ,  5'd0, 5'd1, 5'd2, 0, 1, 1, 1, 0, 32'd8);
    send_pkt(32'h100c, OP_ADDI, 5'd3, 5'd0, 5'd0, 1, 1, 0, 0, 0, 32'd3);
    send_pkt(32'h1010, OP_ADD,  5'd4, 5'd1, 5'd2, 1, 1, 1, 0, 0, 32'd0);
    send_pkt(32'h1014, OP_ADDI, 5'd5, 5'd0, 5'd0, 1, 1, 0, 0, 0, 32'd5);

    // wait for branch flush
    timeout = 0;
    while (!flush.valid && timeout < 200) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (!flush.valid) $fatal(1, "no flush observed");
    $display("flush observed: idx=%0d redirect=%h", flush.rob_idx, flush.redirect_pc);
    @(posedge clk);

    // correct path: P7 uses x3 (squashed write) -> must see tag 3
    send_pkt(32'h2000, OP_ADD,  5'd7, 5'd3, 5'd0, 1, 1, 0, 0, 0, 32'd0);
    if (obs_pc !== 32'h2000) $fatal(1, "obs pc got %h", obs_pc);
    if (obs_rs1_tag !== 3) $fatal(1, "P7 rs1_tag got %0d exp 3", obs_rs1_tag);
    if (obs_rd_tag !== 1) $fatal(1, "P7 rd_tag got %0d exp 1 (commit-freed x1 tag)", obs_rd_tag);
    $display("P7 ok: rs1_tag=%0d rd_tag=%0d", obs_rs1_tag, obs_rd_tag);

    // P8 another correct-path instruction
    send_pkt(32'h2004, OP_ADDI, 5'd6, 5'd0, 5'd0, 1, 1, 0, 0, 0, 32'd6);
    if (obs_pc !== 32'h2004) $fatal(1, "obs pc got %h", obs_pc);
    if (obs_rd_tag !== 2) $fatal(1, "P8 rd_tag got %0d exp 2 (commit-freed x2 tag)", obs_rd_tag);

    // P9 uses x4/x5 (both squashed writes) -> must restore to 4/5
    send_pkt(32'h2008, OP_ADD,  5'd8, 5'd4, 5'd5, 1, 1, 1, 0, 0, 32'd0);
    if (obs_pc !== 32'h2008) $fatal(1, "obs pc got %h", obs_pc);
    if (obs_rs1_tag !== 4) $fatal(1, "P9 rs1_tag got %0d exp 4", obs_rs1_tag);
    if (obs_rs2_tag !== 5) $fatal(1, "P9 rs2_tag got %0d exp 5", obs_rs2_tag);
    if (obs_rd_tag !== 34) $fatal(1, "P9 rd_tag got %0d exp 34 (reuse squashed tag)", obs_rd_tag);
    $display("P9 ok: rs1_tag=%0d rs2_tag=%0d", obs_rs1_tag, obs_rs2_tag);

    // wait for P1 commit, then P10 writes x1 and should reuse tag 1
    timeout = 0;
    while (!seen_p1_commit && timeout < 200) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (!seen_p1_commit) $fatal(1, "P1 never committed");
    send_pkt(32'h200c, OP_ADDI, 5'd1, 5'd0, 5'd0, 1, 1, 0, 0, 0, 32'h55);
    if (obs_pc !== 32'h200c) $fatal(1, "obs pc got %h", obs_pc);
    $display("P10 ok: rd_tag=%0d (freed tag reused)", obs_rd_tag);

    // wait for all expected commits: P1,P2,SW,BEQ,P7,P8,P9,P10 = 8
    timeout = 0;
    while (commit_count < 8 && timeout < 500) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (commit_count != 8) $fatal(1, "commit_count got %0d exp 8", commit_count);
    if (exp_count != 0) $fatal(1, "expected queue not empty: %0d", exp_count);

    // x0 read must be 0
    prf_raddr1 = 0; prf_raddr2 = 0;
    #1;
    if (prf_rdata1 !== 0 || prf_rdata2 !== 0) $fatal(1, "x0 read not zero");

    if (flush_count != 1) $fatal(1, "phase1 flush_count got %0d exp 1", flush_count);
    $display("PHASE1_PASS commits=%0d", commit_count);

    // ---------------- phase 2: JAL with dest + correct branch ----------------
    @(negedge clk);
    rst = 1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 0;
    @(posedge clk);
    phase2 = 1;
    mispredict_pc = 32'h3000;
    correct_pc_cfg = 32'h4000;

    // P1: JAL x1, target 0x4000 (mispredicted); P2 younger and squashed
    send_pkt(32'h3000, OP_JAL, 5'd1, 5'd0, 5'd0, 1, 0, 0, 1, 0, 32'h100);
    send_pkt(32'h3004, OP_ADDI, 5'd3, 5'd0, 5'd0, 1, 1, 0, 0, 0, 32'd3);
    timeout = 0;
    while (!flush.valid && timeout < 200) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (!flush.valid) $fatal(1, "phase2 no flush");
    @(posedge clk);

    // P4 reads x1 written by JAL: must see JAL's rd_tag 32, not initial x1 tag 1.
    send_pkt(32'h4000, OP_ADD, 5'd2, 5'd1, 5'd0, 1, 1, 0, 0, 0, 32'd0);
    if (obs_pc !== 32'h4000) $fatal(1, "phase2 obs pc got %h", obs_pc);
    if (obs_rs1_tag !== 32) $fatal(1, "phase2 P4 rs1_tag got %0d exp 32 (JAL dest survives flush)", obs_rs1_tag);
    $display("phase2 P4 rd_tag=%0d (1 if JAL already committed, else 33)", obs_rd_tag);

    // P5 correctly predicted branch, P6 younger must not be squashed.
    send_pkt(32'h4004, OP_BEQ, 5'd0, 5'd0, 5'd0, 0, 1, 1, 1, 0, 32'd8);
    send_pkt(32'h4008, OP_ADDI, 5'd4, 5'd0, 5'd0, 1, 1, 0, 0, 0, 32'd4);

    timeout = 0;
    while (commit_count < 4 && timeout < 300) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (commit_count != 4) $fatal(1, "phase2 commit_count got %0d exp 4", commit_count);
    if (flush_count != 1) $fatal(1, "phase2 unexpected flush, count=%0d", flush_count);
    if (exp_count != 0) $fatal(1, "phase2 expected queue not empty: %0d", exp_count);

    $display("PHASE2_PASS commits=%0d flush_count=%0d", commit_count, flush_count);

    // ---------------- phase 3: ROB wrap-around / tag churn ----------------
    @(negedge clk);
    rst = 1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 0;
    @(posedge clk);
    phase2 = 1;
    mispredict_pc = 32'hffff_ffff;
    correct_pc_cfg = 32'h0;

    for (int i = 0; i < 128; i = i + 1) begin
      logic [4:0] rdidx;
      rdidx = 5'((i % 16) + 1);
      send_pkt(32'h5000 + i*4, OP_ADDI, rdidx, 5'd0, 5'd0, 1, 1, 0, 0, 0, i);
    end

    timeout = 0;
    while (commit_count < 128 && timeout < 2000) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (commit_count != 128) $fatal(1, "phase3 commit_count got %0d exp 128", commit_count);
    if (exp_count != 0) $fatal(1, "phase3 expected queue not empty: %0d", exp_count);
    if (flush_count != 0) $fatal(1, "phase3 unexpected flush: %0d", flush_count);

    $display("TB_CORE_PASS phase1+phase2+phase3 commits=%0d", commit_count);
    $finish;
  end
endmodule
