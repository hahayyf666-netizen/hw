//===========================================================================
// clip.v - 通用限幅模块
// 功能: 支持Clip16(-32768~32767)和Clip10(0~1023)
//===========================================================================

module clip (
    input  wire [31:0] in_data,      // 输入数据
    input  wire        clip_en,      // 限幅使能
    input  wire [5:0]  clip_bits,    // 限幅位数 (10或16)
    output reg  [31:0] out_data      // 限幅输出
);

    // Clip16范围: -32768 ~ 32767
    localparam CLIP16_MIN = -32768;
    localparam CLIP16_MAX = 32767;

    // Clip10范围: 0 ~ 1023
    localparam CLIP10_MIN = 0;
    localparam CLIP10_MAX = 1023;

    //===========================================================================
    // 有符号数限幅逻辑
    //===========================================================================
    wire signed [32:0] signed_in = $signed({in_data[31], in_data});
    reg signed [32:0] signed_out;

    always @(*) begin
        if (!clip_en) begin
            signed_out = signed_in;
        end else if (clip_bits == 6'd10) begin
            // Clip10
            if (signed_in < CLIP10_MIN)
                signed_out = CLIP10_MIN;
            else if (signed_in > CLIP10_MAX)
                signed_out = CLIP10_MAX;
            else
                signed_out = signed_in;
        end else if (clip_bits == 6'd16) begin
            // Clip16
            if (signed_in < CLIP16_MIN)
                signed_out = CLIP16_MIN;
            else if (signed_in > CLIP16_MAX)
                signed_out = CLIP16_MAX;
            else
                signed_out = signed_in;
        end else begin
            signed_out = signed_in;
        end
    end

    assign out_data = signed_out[31:0];

endmodule
