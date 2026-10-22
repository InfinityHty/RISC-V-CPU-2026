// axi_bus.sv — AXI4-Lite master arbiter.
//
// Three clients:
//   - ifetch read  (if_req_* / if_resp_*), multiple outstanding, epoch-tagged;
//     responses whose recorded epoch no longer matches if_epoch are dropped.
//   - load read    (ld_req_* / ld_resp_*), at most one outstanding.
//   - store write  (st_req_* / st_resp_*), at most one outstanding.
//
// AR channel: load has priority over ifetch. Every accepted AR pushes an
// {is_ifetch, epoch} entry into the owner FIFO; R responses return in order
// and are dispatched by popping the owner FIFO. rready is constant 1.
// AW/W/B serve stores only: awvalid and wvalid rise together; st_resp_valid
// pulses on the B handshake. bready is constant 1.

module axi_bus (
    input  wire        clk,
    input  wire        rst,

    // ifetch read client
    input  wire        if_req_valid,
    output logic       if_req_ready,
    input  wire [31:0] if_req_addr,
    input  wire        if_epoch,
    output logic       if_resp_valid,
    output logic [31:0] if_resp_data,

    // load read client
    input  wire        ld_req_valid,
    output logic       ld_req_ready,
    input  wire [31:0] ld_req_addr,
    output logic       ld_resp_valid,
    output logic [31:0] ld_resp_data,

    // store write client
    input  wire        st_req_valid,
    output logic       st_req_ready,
    input  wire [31:0] st_req_addr,
    input  wire [31:0] st_req_wdata,
    input  wire [3:0]  st_req_wstrb,
    output logic       st_resp_valid,

    // AXI4-Lite read address channel
    output logic [31:0] araddr,
    output logic        arvalid,
    input  wire         arready,
    // AXI4-Lite read data channel
    input  wire [31:0]  rdata,
    input  wire [1:0]   rresp,
    input  wire         rvalid,
    output logic        rready,
    // AXI4-Lite write address channel
    output logic [31:0] awaddr,
    output logic        awvalid,
    input  wire         awready,
    // AXI4-Lite write data channel
    output logic [31:0] wdata,
    output logic [3:0]  wstrb,
    output logic        wvalid,
    input  wire         wready,
    // AXI4-Lite write response channel
    input  wire [1:0]   bresp,
    input  wire         bvalid,
    output logic        bready
);

    // ------------------------------------------------------------------
    // Owner FIFO: one entry per outstanding read, in AR issue order.
    // ------------------------------------------------------------------
    localparam int OWNER_DEPTH = 16;

    logic        owner_if    [OWNER_DEPTH];
    logic        owner_epoch [OWNER_DEPTH];
    logic [3:0]  ow_rptr, ow_wptr;
    logic [4:0]  ow_count;

    wire ow_full = (ow_count == OWNER_DEPTH[4:0]);

    // ------------------------------------------------------------------
    // AR arbitration: load beats ifetch. arvalid never depends on arready.
    // ------------------------------------------------------------------
    wire sel_load = ld_req_valid;

    assign arvalid = (ld_req_valid || if_req_valid) && !ow_full;
    assign araddr  = sel_load ? ld_req_addr : if_req_addr;

    wire ar_fire = arvalid && arready;
    assign ld_req_ready = ar_fire && sel_load;
    assign if_req_ready = ar_fire && !sel_load;

    // ------------------------------------------------------------------
    // R channel: dispatch in owner-FIFO order; drop stale ifetch epochs.
    // ------------------------------------------------------------------
    assign rready = 1'b1;

    wire cur_is_if = owner_if[ow_rptr];
    wire cur_epoch = owner_epoch[ow_rptr];

    assign if_resp_valid = rvalid &&  cur_is_if && (cur_epoch == if_epoch);
    assign if_resp_data  = rdata;
    assign ld_resp_valid = rvalid && !cur_is_if;
    assign ld_resp_data  = rdata;

    always_ff @(posedge clk) begin
        if (rst) begin
            ow_rptr  <= 4'd0;
            ow_wptr  <= 4'd0;
            ow_count <= 5'd0;
        end else begin
            if (ar_fire) begin
                owner_if[ow_wptr]    <= !sel_load;
                owner_epoch[ow_wptr] <= if_epoch;
                ow_wptr              <= ow_wptr + 4'd1;
            end
            if (rvalid) begin
                ow_rptr <= ow_rptr + 4'd1;
            end
            ow_count <= ow_count + (ar_fire ? 5'd1 : 5'd0) - (rvalid ? 5'd1 : 5'd0);
        end
    end

    // ------------------------------------------------------------------
    // Write channels: AW and W rise together, track each side's handshake
    // independently for robustness; one store outstanding at a time.
    // ------------------------------------------------------------------
    logic aw_sent, w_sent;

    assign awvalid = st_req_valid && !aw_sent;
    assign awaddr  = st_req_addr;
    assign wvalid  = st_req_valid && !w_sent;
    assign wdata   = st_req_wdata;
    assign wstrb   = st_req_wstrb;

    wire aw_fire = awvalid && awready;
    wire w_fire  = wvalid && wready;

    assign st_req_ready = (aw_fire || aw_sent) && (w_fire || w_sent);

    assign bready        = 1'b1;
    assign st_resp_valid = bvalid;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_sent <= 1'b0;
            w_sent  <= 1'b0;
        end else begin
            if (aw_fire) aw_sent <= 1'b1;
            if (w_fire)  w_sent  <= 1'b1;
            if (bvalid) begin
                aw_sent <= 1'b0;
                w_sent  <= 1'b0;
            end
        end
    end

    wire unused_ok = &{1'b0, rresp, bresp};

endmodule
