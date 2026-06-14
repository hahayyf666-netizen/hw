//===========================================================================
// intermediate_buffer.v - 中间结果缓存 (优化版 - 支持4点并行)
// 功能: 列1D输出后的中间buffer，保存tmp[row][col]
// 优化: 128bit宽度支持4点 x 32bit并行读写
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module intermediate_buffer (
    input  wire        clk,
    input  wire        rst_n,

    // 写端口 - 32bit (单点)
    input  wire        wr_en,
    input  wire [11:0] wr_addr,    // 0~4095
    input  wire [31:0] wr_data,    // 32bit (单点)

    // 读端口 - 32bit (单点)
    input  wire [11:0] rd_addr,    // 0~4095
    output reg  [31:0] rd_data     // 32bit (单点)
);

    // 64x64 = 4096点，每点32bit
    localparam BUFFER_DEPTH = 4096;

    // RAM存储 - 32bit宽度
    reg [31:0] mem [0:BUFFER_DEPTH-1];

    //===========================================================================
    // 写操作
    //===========================================================================
    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr[11:0]] <= wr_data;
        end
    end

    //===========================================================================
    // 读操作 - 寄存器输出（与TU Buffer一致的1拍延迟）
    //===========================================================================
    always @(posedge clk) begin
        rd_data <= mem[rd_addr[11:0]];
    end

endmodule
