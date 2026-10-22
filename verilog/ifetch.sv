// ifetch.sv — sequential instruction prefetch unit.
//
// Depth-4 FIFO of {pc, instr}. Whenever (fifo occupancy + outstanding
// requests) < 4 and the prefetch address is below 0x10000000, a read for the
// next sequential address is requested from axi_bus. Responses return in
// order, so a separate response PC tracks which address each response fills.
//
// On a branch redirect the FIFO is cleared, the outstanding counter is
// reset, and the epoch bit flips; axi_bus drops the stale in-flight
// responses of the old epoch.

module ifetch (
    input  wire        clk,
    input  wire        rst,

    // branch redirect from EX
    input  wire        redirect_valid,
    input  wire [31:0] redirect_pc,

    // axi_bus read client
    output logic       if_req_valid,
    input  wire        if_req_ready,
    output logic [31:0] if_req_addr,
    output logic       if_epoch,
    input  wire        if_resp_valid,
    input  wire [31:0] if_resp_data,

    // instruction stream to the IF stage
    output logic       out_valid,
    input  wire        out_ready,
    output logic [31:0] out_pc,
    output logic [31:0] out_instr
);

    localparam int DEPTH = 4;

    logic [31:0] fifo_pc    [DEPTH];
    logic [31:0] fifo_instr [DEPTH];
    logic [1:0]  rptr, wptr;
    logic [2:0]  count;
    logic [2:0]  outstanding;
    logic [31:0] prefetch_pc;
    logic [31:0] resp_pc;
    logic        epoch;

    assign if_epoch = epoch;

    // Never prefetch at or beyond 0x10000000 (out of RAM range -> DECERR).
    wire can_issue = ({1'b0, count} + {1'b0, outstanding} < 4'd4)
                  && (prefetch_pc < 32'h10000000)
                  && !redirect_valid;

    assign if_req_valid = can_issue;
    assign if_req_addr  = prefetch_pc;

    wire req_fire = if_req_valid && if_req_ready;
    wire push     = if_resp_valid;  // guaranteed room: count+outstanding <= DEPTH
    wire pop      = out_valid && out_ready;

    assign out_valid = (count != 3'd0);
    assign out_pc    = fifo_pc[rptr];
    assign out_instr = fifo_instr[rptr];

    always_ff @(posedge clk) begin
        if (rst) begin
            rptr        <= 2'd0;
            wptr        <= 2'd0;
            count       <= 3'd0;
            outstanding <= 3'd0;
            prefetch_pc <= 32'd0;
            resp_pc     <= 32'd0;
            epoch       <= 1'b0;
        end else if (redirect_valid) begin
            rptr        <= 2'd0;
            wptr        <= 2'd0;
            count       <= 3'd0;
            outstanding <= 3'd0;
            prefetch_pc <= redirect_pc;
            resp_pc     <= redirect_pc;
            epoch       <= ~epoch;
        end else begin
            if (req_fire) prefetch_pc <= prefetch_pc + 32'd4;
            if (push) begin
                fifo_pc[wptr]    <= resp_pc;
                fifo_instr[wptr] <= if_resp_data;
                wptr             <= wptr + 2'd1;
                resp_pc          <= resp_pc + 32'd4;
            end
            if (pop) rptr <= rptr + 2'd1;
            count       <= count + (push ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);
            outstanding <= outstanding + (req_fire ? 3'd1 : 3'd0) - (push ? 3'd1 : 3'd0);
        end
    end

endmodule
