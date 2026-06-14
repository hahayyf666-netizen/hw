//===========================================================================
// mac_array.v - 可复用MAC阵列
// 功能: 8路并行MAC复用，用于加速1D变换计算
// 设计目标: 500MHz时序优化
//===========================================================================

/* verilator lint_off MULTITOP */
/* verilator lint_off UNUSEDSIGNAL */

module mac_array (
    input  wire        clk,
    input  wire        rst_n,

    // 控制接口
    input  wire        start,
    output reg         done,
    input  wire [6:0]  length,       // 向量长度

    // 数据输入
    input  wire [7:0]  matrix_vals [0:7],  // 8个矩阵系数
    input  wire [15:0] data_vals  [0:7],  // 8个数据
    input  wire        valid,

    // 累加结果
    output reg  [31:0] acc_result    // 累加结果
);

    //===========================================================================
    // 8路并行乘法
    //===========================================================================
    wire signed [15:0] signed_data [0:7];
    wire signed [7:0]  signed_matrix [0:7];
    wire signed [23:0] mult_result [0:7];

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : mult_gen
            assign signed_data[i]   = $signed(data_vals[i]);
            assign signed_matrix[i] = $signed(matrix_vals[i]);
            assign mult_result[i]   = signed_data[i] * signed_matrix[i];
        end
    endgenerate

    //===========================================================================
    // 树形加法器 - 第一级
    //===========================================================================
    reg signed [24:0] add_level1 [0:3];

    always @(posedge clk) begin
        if (valid) begin
            add_level1[0] <= mult_result[0] + mult_result[1];
            add_level1[1] <= mult_result[2] + mult_result[3];
            add_level1[2] <= mult_result[4] + mult_result[5];
            add_level1[3] <= mult_result[6] + mult_result[7];
        end
    end

    //===========================================================================
    // 树形加法器 - 第二级
    //===========================================================================
    reg signed [25:0] add_level2 [0:1];

    always @(posedge clk) begin
        add_level2[0] <= add_level1[0] + add_level1[1];
        add_level2[1] <= add_level1[2] + add_level1[3];
    end

    //===========================================================================
    // 树形加法器 - 第三级
    //===========================================================================
    reg signed [31:0] final_sum;
    reg signed [31:0] acc_reg;

    wire signed [31:0] add_level2_ext0 = {{6{add_level2[0][25]}}, add_level2[0]};  // 符号扩展到32bit
    wire signed [31:0] add_level2_ext1 = {{6{add_level2[1][25]}}, add_level2[1]};

    always @(posedge clk) begin
        final_sum <= add_level2_ext0 + add_level2_ext1;  // 现在都是32bit
    end

    //===========================================================================
    // 累加器
    //===========================================================================
    reg [6:0] cycle_cnt;
    reg       computing;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_reg   <= 32'd0;
            cycle_cnt <= 7'd0;
            computing <= 1'b0;
            done      <= 1'b0;
            acc_result<= 32'd0;
        end else begin
            done <= 1'b0;

            if (start) begin
                acc_reg   <= 32'd0;
                cycle_cnt <= 7'd0;
                computing <= 1'b1;
            end else if (computing) begin
                // 累加8路结果
                acc_reg <= acc_reg + final_sum;
                cycle_cnt <= cycle_cnt + 7'd8;  // 扩展到7bit

                // 计算完成
                if (cycle_cnt >= length - 7'd8) begin  // 改为减法避免位宽问题
                    computing <= 1'b0;
                    done      <= 1'b1;
                    acc_result<= acc_reg + final_sum;
                end
            end
        end
    end

endmodule
