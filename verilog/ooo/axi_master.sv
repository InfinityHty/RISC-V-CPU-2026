// axi_master.sv — AXI4-Lite 主接口封装 [B]
// 单在途事务。读请求记录来源并路由 R 响应；写通道分别跟踪 AW/W 握手。
module axi_master (
  input  logic        clk,
  input  logic        rst,

  input  logic        if_req_valid,
  output logic        if_req_ready,
  input  logic [31:0] if_req_addr,
  output logic        if_resp_valid,
  output logic [31:0] if_resp_data,

  input  logic        dm_req_valid,
  output logic        dm_req_ready,
  input  logic [31:0] dm_req_addr,
  input  logic [31:0] dm_req_wdata,
  input  logic [3:0]  dm_req_wstrb,
  input  logic        dm_req_write,
  output logic        dm_resp_valid,
  output logic [31:0] dm_resp_data,

  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_READ_AR,
    ST_READ_WAIT,
    ST_WRITE,
    ST_WRITE_WAIT
  } state_t;
  state_t state;

  logic [31:0] saved_addr;
  logic [31:0] saved_wdata;
  logic [3:0]  saved_wstrb;
  logic        read_is_if;
  logic        aw_sent;
  logic        w_sent;

  assign dm_req_ready = (state == ST_IDLE);
  assign if_req_ready = (state == ST_IDLE) && !dm_req_valid;

  assign araddr  = saved_addr;
  assign arvalid = (state == ST_READ_AR);
  assign rready  = 1'b1;

  assign awaddr  = saved_addr;
  assign awvalid = (state == ST_WRITE) && !aw_sent;
  assign wdata   = saved_wdata;
  assign wstrb   = saved_wstrb;
  assign wvalid  = (state == ST_WRITE) && !w_sent;
  assign bready  = 1'b1;

  assign if_resp_valid = (state == ST_READ_WAIT) && rvalid && read_is_if;
  assign if_resp_data  = rdata;
  assign dm_resp_valid = ((state == ST_READ_WAIT) && rvalid && !read_is_if) ||
                         ((state == ST_WRITE_WAIT) && bvalid);
  assign dm_resp_data  = (state == ST_READ_WAIT) ? rdata : 32'd0;

  wire aw_fire = awvalid && awready;
  wire w_fire  = wvalid && wready;
  wire write_sent = (aw_sent || aw_fire) && (w_sent || w_fire);

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= ST_IDLE;
      saved_addr  <= '0;
      saved_wdata <= '0;
      saved_wstrb <= '0;
      read_is_if  <= 1'b0;
      aw_sent     <= 1'b0;
      w_sent      <= 1'b0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (dm_req_valid && dm_req_ready) begin
            saved_addr  <= {dm_req_addr[31:2], 2'b00};
            saved_wdata <= dm_req_wdata;
            saved_wstrb <= dm_req_wstrb;
            read_is_if  <= 1'b0;
            aw_sent     <= 1'b0;
            w_sent      <= 1'b0;
            state       <= dm_req_write ? ST_WRITE : ST_READ_AR;
          end else if (if_req_valid && if_req_ready) begin
            saved_addr  <= {if_req_addr[31:2], 2'b00};
            read_is_if  <= 1'b1;
            state       <= ST_READ_AR;
          end
        end

        ST_READ_AR: begin
          if (arvalid && arready)
            state <= ST_READ_WAIT;
        end

        ST_READ_WAIT: begin
          if (rvalid)
            state <= ST_IDLE;
        end

        ST_WRITE: begin
          if (aw_fire)
            aw_sent <= 1'b1;
          if (w_fire)
            w_sent <= 1'b1;
          if (write_sent)
            state <= ST_WRITE_WAIT;
        end

        ST_WRITE_WAIT: begin
          if (bvalid)
            state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  wire unused_ok = &{1'b0, rresp, bresp};

endmodule
