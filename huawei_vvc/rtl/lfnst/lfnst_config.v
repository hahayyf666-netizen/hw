//===========================================================================
// lfnst_config.v - LFNST参数配置
// 功能: 根据TU尺寸生成nTrs/nonZeroSize/sbSize
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module lfnst_config (
    input  wire [6:0]  tu_width,
    input  wire [6:0]  tu_height,
    output reg  [6:0]  nTrs,          // 输出大小: 16或48
    output reg  [6:0]  nonZeroSize,   // 输入大小: 8或16
    output reg  [4:0]  sbSize         // 子块大小
);

    //===========================================================================
    // 参数判断逻辑
    //===========================================================================
    always @(*) begin
        // nTrs判断: (tu_width >= 8 && tu_height >= 8) ? 48 : 16
        if (tu_width >= 8 && tu_height >= 8)
            nTrs = 7'd48;
        else
            nTrs = 7'd16;

        // nonZeroSize判断
        if ((tu_width == 4 && tu_height == 4) ||
            (tu_width == 8 && tu_height == 8))
            nonZeroSize = 7'd8;
        else
            nonZeroSize = 7'd16;

        // sbSize判断
        if (tu_width >= 16 && tu_height >= 16)
            sbSize = 5'd16;
        else if (tu_width >= 8 && tu_height >= 8)
            sbSize = 5'd8;
        else
            sbSize = 5'd4;
    end

endmodule
