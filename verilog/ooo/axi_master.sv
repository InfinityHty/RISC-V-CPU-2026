// axi_master.sv — AXI4-Lite 主接口封装 [B]
// TODO: AR/R、AW/W/B 五通道事务状态机；在 ifetch（只读）与 dmem 两类
// 客户端之间仲裁；注意框架从机握手后最早下一拍才响应、默认延迟 10 拍。
// 协议细节见 docs/axi4-lite.md。
// 当前骨架：AXI 输出全部空闲。
module axi_master (
  input  logic        clk,
  input  logic        rst,

  // 取指客户端（只读）
  input  logic        if_req_valid,
  output logic        if_req_ready,
  input  logic [31:0] if_req_addr,
  output logic        if_resp_valid,
  output logic [31:0] if_resp_data,

  // 数据访存客户端
  input  logic        dm_req_valid,
  output logic        dm_req_ready,
  input  logic [31:0] dm_req_addr,
  input  logic [31:0] dm_req_wdata,
  input  logic [3:0]  dm_req_wstrb,
  input  logic        dm_req_write,
  output logic        dm_resp_valid,
  output logic [31:0] dm_resp_data,

  // AXI4-Lite 读地址通道
  output logic [31:0] araddr,
  output logic        arvalid,
  input  logic        arready,
  // AXI4-Lite 读数据通道
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,
  // AXI4-Lite 写地址通道
  output logic [31:0] awaddr,
  output logic        awvalid,
  input  logic        awready,
  // AXI4-Lite 写数据通道
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,
  // AXI4-Lite 写响应通道
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready
);

  assign if_req_ready = 1'b0;
  assign if_resp_valid = 1'b0;
  assign if_resp_data  = '0;
  assign dm_req_ready  = 1'b0;
  assign dm_resp_valid = 1'b0;
  assign dm_resp_data  = '0;

  assign araddr  = '0;
  assign arvalid = 1'b0;
  assign rready  = 1'b0;
  assign awaddr  = '0;
  assign awvalid = 1'b0;
  assign wdata   = '0;
  assign wstrb   = '0;
  assign wvalid  = 1'b0;
  assign bready  = 1'b0;

endmodule
