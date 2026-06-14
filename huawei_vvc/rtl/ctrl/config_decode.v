//===========================================================================
// config_decode.v - it_info配置解析模块
// 功能: 解析22位it_info信号，提取所有配置参数
// 赛题接口定义（22位）:
//   it_info[6:0]   : tu_width  (4~64)
//   it_info[13:7]  : tu_height (4~64)
//   it_info[15:14] : tr_type_hor (0=DCT2, 1=DST7, 2=DCT8)
//   it_info[17:16] : tr_type_ver (0=DCT2, 1=DST7, 2=DCT8)
//   it_info[19:18] : lfnst_tr_set_idx (0~3)
//   it_info[21:20] : lfnst_idx (0=直通, 1~2=变换)
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module config_decode (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [21:0] it_info,          // 22位配置输入
    input  wire        it_info_vld,      // 配置有效

    output reg  [6:0]  tu_width,         // TU宽度 (4~64)
    output reg  [6:0]  tu_height,        // TU高度 (4~64)
    output reg  [1:0]  tr_type_hor,      // 水平变换类型 (0=DCT2, 1=DST7, 2=DCT8)
    output reg  [1:0]  tr_type_ver,      // 垂直变换类型 (0=DCT2, 1=DST7, 2=DCT8)
    output reg  [1:0]  lfnst_tr_set_idx, // LFNST集合索引 (0~3)
    output reg  [1:0]  lfnst_idx,        // LFNST索引 (0=直通, 1~2=变换)
    output reg         cfg_valid         // 配置有效指示
);

    //===========================================================================
    // 配置解析 - 时序逻辑，打一拍输出
    //===========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_valid        <= 1'b0;
            tu_width         <= 7'd0;
            tu_height        <= 7'd0;
            tr_type_hor      <= 2'd0;
            tr_type_ver      <= 2'd0;
            lfnst_tr_set_idx <= 2'd0;
            lfnst_idx        <= 2'd0;
        end else if (it_info_vld) begin
            // 解析it_info各位域
            tu_width         <= it_info[6:0];
            tu_height        <= it_info[13:7];
            tr_type_hor      <= it_info[15:14];
            tr_type_ver      <= it_info[17:16];
            lfnst_tr_set_idx <= it_info[19:18];
            lfnst_idx        <= it_info[21:20];
            cfg_valid        <= 1'b1;
        end else begin
            cfg_valid <= 1'b0;
        end
    end

endmodule
