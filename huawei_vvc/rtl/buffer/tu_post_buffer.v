//===========================================================================
// tu_post_buffer.v - TU后置缓存
// 功能: 服务ROW_1D写回、output_packer读取
// 位宽: 16bit有符号数
// 接口: 1拍读延迟，无清零逻辑（ROW_1D全量覆盖）
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module tu_post_buffer (
    input  wire        clk,
    input  wire        rst_n,

    // 写端口
    input  wire [11:0] wr_addr,    // 0~4095
    input  wire [15:0] wr_data,    // 16bit有符号
    input  wire        wr_en,

    // 读端口
    input  wire [11:0] rd_addr,    // 0~4095
    output reg  [15:0] rd_data     // 16bit有符号
);

    // 64x64 = 4096点
    localparam BUFFER_DEPTH = 4096;

    // RAM存储
    reg [15:0] mem [0:BUFFER_DEPTH-1];

    //===========================================================================
    // 写操作
    //===========================================================================
    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    //===========================================================================
    // 读操作 - 打一拍输出
    //===========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data <= 16'd0;
        end else begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule
