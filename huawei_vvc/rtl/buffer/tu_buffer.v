//===========================================================================
// tu_buffer.v - TU系数缓存
// 功能: 最大64x64=4096点，双口RAM设计
// 位宽: 16bit有符号数
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module tu_buffer (
    input  wire        clk,
    input  wire        rst_n,

    // 写端口
    input  wire [11:0] wr_addr,    // 0~4095
    input  wire [15:0] wr_data,    // 16bit有符号
    input  wire        wr_en,

    // 读端口
    input  wire [11:0] rd_addr,    // 0~4095
    output reg  [15:0] rd_data,    // 16bit有符号

    // 清零端口 - 稀疏输入时清零前clear_length个位置
    input  wire        clear,
    input  wire [15:0] clear_length,
    output reg         clear_done,

    // Debug
    output wire        debug_clearing
);

    // 64x64 = 4096点
    localparam BUFFER_DEPTH = 4096;

    // RAM存储
    reg [15:0] mem [0:BUFFER_DEPTH-1];

    // 清零计数器
    reg [11:0] clear_cnt;
    reg        clearing;
    reg [11:0] clear_last_reg;  // registered clear_last to break critical path

    assign debug_clearing = clearing;

    //===========================================================================
    // 清零控制 - 状态机控制 clear_cnt/clearing/clear_done
    // clear_done 为单周期脉冲：清除完成时拉高1拍，随后自动回到0
    //===========================================================================
    // Register clear_last on clear pulse to break combinational path
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
    // 写操作 - 单端口：清零优先，正常写其次
    //===========================================================================
    always @(posedge clk) begin
        if (clearing) begin
            mem[clear_cnt] <= 16'd0;
        end else if (wr_en) begin
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
