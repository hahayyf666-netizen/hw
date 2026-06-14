//===========================================================================
// round_shift.v - 通用舍入右移模块
// 功能: (val + (1<<(shift-1))) >>> shift
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module round_shift (
    input  wire [31:0] in_data,    // 输入数据
    input  wire [4:0]  shift,      // 右移位数 (0~31)
    output wire [31:0] out_data    // 舍入右移结果
);

    //===========================================================================
    // 舍入右移计算
    // 公式: (val + (1<<(shift-1))) >>> shift
    //===========================================================================
    wire [31:0] round_val;
    wire [31:0] shift_result;

    // 计算舍入值: 1 << (shift-1)
    assign round_val = (shift == 0) ? 32'd0 : (32'd1 << (shift - 1));

    // 有符号数加法和右移
    wire signed [31:0] signed_in = $signed(in_data);
    wire signed [31:0] signed_round = $signed(round_val);
    wire signed [31:0] sum = signed_in + signed_round;

    // 算术右移
    assign shift_result = sum >>> shift;

    assign out_data = shift_result;

endmodule
