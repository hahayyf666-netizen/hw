//===========================================================================
// tu_buffer_regbank.v - TU系数缓存 (Register Bank版本)
// 功能: 最大64x64=4096点，纯寄存器实现，无RAMD64E
// 位宽: 16bit有符号数
// 接口: 与tu_buffer.v完全兼容，1拍读延迟
// 目标: 消除RAMD64E脉宽限制，验证500MHz可行性
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSED */

module tu_buffer_regbank (
    input  wire        clk,
    input  wire        rst_n,

    // 写端口
    input  wire [11:0] wr_addr,    // 0~4095
    input  wire [15:0] wr_data,    // 16bit有符号
    input  wire        wr_en,

    // 读端口
    input  wire [11:0] rd_addr,    // 0~4095
    output reg  [15:0] rd_data,    // 16bit有符号

    // 清零端口
    input  wire        clear,
    input  wire [15:0] clear_length,
    output reg         clear_done,

    // Debug
    output wire        debug_clearing
);

    //===========================================================================
    // Register Bank - 4096个16bit寄存器
    //===========================================================================
    reg [15:0] mem [0:4095];

    //===========================================================================
    // 清零控制
    //===========================================================================
    reg [11:0] clear_cnt;
    reg        clearing;
    reg [11:0] clear_last_reg;

    assign debug_clearing = clearing;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            clear_last_reg <= 12'd0;
        else if (clear)
            clear_last_reg <= clear_length[11:0] - 12'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clear_cnt  <= 12'd0;
            clearing   <= 1'b0;
            clear_done <= 1'b0;
        end else if (clearing) begin
            clear_cnt <= clear_cnt + 1'b1;
            if (clear_cnt >= clear_last_reg) begin
                clearing   <= 1'b0;
                clear_done <= 1'b1;
            end
        end else begin
            clear_done <= 1'b0;
            if (clear) begin
                clear_cnt <= 12'd0;
                clearing  <= 1'b1;
            end
        end
    end

    //===========================================================================
    // 写操作 - 清零优先，正常写其次
    //===========================================================================
    always @(posedge clk) begin
        if (clearing) begin
            mem[clear_cnt] <= 16'd0;
        end else if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    //===========================================================================
    // 读操作 - 组合逻辑读取，1拍延迟
    //===========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_data <= 16'd0;
        else
            rd_data <= mem[rd_addr];
    end

endmodule
