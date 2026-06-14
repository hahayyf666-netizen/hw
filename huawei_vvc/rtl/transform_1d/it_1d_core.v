//===========================================================================
// it_1d_core.v - 统一1D反变换入口 (优化版)
// 功能: 根据tr_type/length/shift/clip调度到具体的变换实现
// 支持: DCT2, DST7, DCT8
// 优化: 支持一拍4点并行输出，支持流水
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module it_1d_core (
    input  wire        clk,
    input  wire        rst_n,

    // 控制接口
    input  wire        it1d_start,
    output wire        it1d_ready,
    output reg         it1d_done,
    input  wire [1:0]  tr_type,      // 0=DCT2, 1=DST7, 2=DCT8
    input  wire [6:0]  length,       // 4/8/16/32/64
    input  wire [4:0]  shift,        // 7或10
    input  wire        clip_en,      // 是否限幅
    input  wire [5:0]  clip_bits,    // 限幅位数

    // 数据输入接口（逐点输入，流水）
    output wire        in_ready,     // 准备好接收输入
    input  wire        in_valid,     // 输入数据有效
    input  wire [6:0]  in_idx,       // 输入索引
    input  wire [15:0] in_data,      // 输入数据

    // 数据输出接口（一拍4点，流水）
    output reg         out_valid,    // 输出有效
    input  wire        out_ready,    // 下游准备好接收
    output reg  [6:0]  out_idx,      // 输出起始索引（0, 4, 8, ...）
    output wire [127:0] out_data,    // 4点×32bit = 128bit输出

    // Debug
    output wire [2:0]  debug_state,
    output wire [6:0]  debug_input_cnt,
    output wire        debug_in_valid,
    output wire        debug_in_ready
);

    //===========================================================================
    // 变换类型编码
    //===========================================================================
    localparam TR_DCT2 = 2'd0;
    localparam TR_DST7 = 2'd1;
    localparam TR_DCT8 = 2'd2;

    //===========================================================================
    // 配置寄存器
    //===========================================================================
    reg [1:0]  r_tr_type;
    reg [6:0]  r_length;
    reg [4:0]  r_shift;
    reg        r_clip_en;
    reg [5:0]  r_clip_bits;
    reg        processing;

    //===========================================================================
    // 输入缓冲 - 乒乓缓冲实现流水
    //===========================================================================
    reg [15:0] coeff_mem [0:63];
    reg [6:0]  input_cnt;
    reg        input_done;

    // Flattened coefficient bus (Vivado synthesis: cannot pass memory array as port)
    wire [1023:0] coeff_mem_flat;
    genvar gi;
    generate
        for (gi = 0; gi < 64; gi = gi + 1) begin : coeff_flat
            assign coeff_mem_flat[gi*16 +: 16] = coeff_mem[gi];
        end
    endgenerate

    // 下一个配置缓冲（支持流水配置）
    reg [1:0]  next_tr_type;
    reg [6:0]  next_length;
    reg [4:0]  next_shift;
    reg        next_clip_en;
    reg [5:0]  next_clip_bits;
    reg        next_cfg_valid;

    //===========================================================================
    // 计算状态机
    //===========================================================================
    localparam IDLE     = 3'd0;
    localparam LOAD     = 3'd1;
    localparam COMPUTE  = 3'd2;
    localparam OUTPUT   = 3'd3;
    localparam DONE     = 3'd4;
    localparam LOAD_WAIT = 3'd5;  // Wait 1 cycle for buffer read latency

    reg [2:0]  state;
    reg [6:0]  compute_cnt;  // 计算组计数 (0, 4, 8, ...)

    //===========================================================================
    // 4点并行计算子模块接口
    //===========================================================================
    wire        dct2_start, dst7_start, dct8_start;
    wire        dct2_done, dst7_done, dct8_done;
    wire [31:0] dct2_result [0:3];
    wire [31:0] dst7_result [0:3];
    wire [31:0] dct8_result [0:3];
    wire        dct2_out_valid, dst7_out_valid, dct8_out_valid;

    // 结果选择
    reg [31:0] result_sel [0:3];
    reg        result_valid_sel;

    //===========================================================================
    // 流水控制信号
    //===========================================================================
    assign in_ready = (state == LOAD && input_cnt < r_length);
    assign it1d_ready = (state == IDLE) && !processing;

    // 启动信号 - 仅在第一组时触发，子模块内部自循环处理多组
    assign dct2_start = (state == COMPUTE) && (r_tr_type == TR_DCT2) && (compute_cnt == 0);
    assign dst7_start = (state == COMPUTE) && (r_tr_type == TR_DST7) && (compute_cnt == 0);
    assign dct8_start = (state == COMPUTE) && (r_tr_type == TR_DCT8) && (compute_cnt == 0);

    //===========================================================================
    // DCT2实例 (4点并行)
    //===========================================================================
    dct2_1d u_dct2_1d (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (dct2_start),
        .done       (dct2_done),
        .out_valid  (dct2_out_valid),
        .length     (r_length),
        .shift      (r_shift),
        .clip_en    (r_clip_en),
        .clip_bits  (r_clip_bits),
        .coeff_in   (coeff_mem_flat),
        .result_out0(dct2_result[0]),
        .result_out1(dct2_result[1]),
        .result_out2(dct2_result[2]),
        .result_out3(dct2_result[3])
    );

    //===========================================================================
    // DST7实例 (4点并行)
    //===========================================================================
    dst7_1d u_dst7_1d (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (dst7_start),
        .done       (dst7_done),
        .out_valid  (dst7_out_valid),
        .length     (r_length),
        .shift      (r_shift),
        .clip_en    (r_clip_en),
        .clip_bits  (r_clip_bits),
        .coeff_in   (coeff_mem_flat),
        .result_out0(dst7_result[0]),
        .result_out1(dst7_result[1]),
        .result_out2(dst7_result[2]),
        .result_out3(dst7_result[3])
    );

    //===========================================================================
    // DCT8实例 (4点并行)
    //===========================================================================
    dct8_1d u_dct8_1d (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (dct8_start),
        .done       (dct8_done),
        .out_valid  (dct8_out_valid),
        .length     (r_length),
        .shift      (r_shift),
        .clip_en    (r_clip_en),
        .clip_bits  (r_clip_bits),
        .coeff_in   (coeff_mem_flat),
        .result_out0(dct8_result[0]),
        .result_out1(dct8_result[1]),
        .result_out2(dct8_result[2]),
        .result_out3(dct8_result[3])
    );

    //===========================================================================
    // 结果输出选择
    //===========================================================================
    always @(*) begin
        case (r_tr_type)
            TR_DCT2: begin
                result_sel[0] = dct2_result[0];
                result_sel[1] = dct2_result[1];
                result_sel[2] = dct2_result[2];
                result_sel[3] = dct2_result[3];
                result_valid_sel = dct2_out_valid;
            end
            TR_DST7: begin
                result_sel[0] = dst7_result[0];
                result_sel[1] = dst7_result[1];
                result_sel[2] = dst7_result[2];
                result_sel[3] = dst7_result[3];
                result_valid_sel = dst7_out_valid;
            end
            TR_DCT8: begin
                result_sel[0] = dct8_result[0];
                result_sel[1] = dct8_result[1];
                result_sel[2] = dct8_result[2];
                result_sel[3] = dct8_result[3];
                result_valid_sel = dct8_out_valid;
            end
            default: begin
                result_sel[0] = 32'd0;
                result_sel[1] = 32'd0;
                result_sel[2] = 32'd0;
                result_sel[3] = 32'd0;
                result_valid_sel = 1'b0;
            end
        endcase
    end

    // 输出打包 4×32bit = 128bit
    assign out_data = {result_sel[3], result_sel[2], result_sel[1], result_sel[0]};

    // Debug
    assign debug_state = state;
    assign debug_input_cnt = input_cnt;
    assign debug_in_valid = in_valid;
    assign debug_in_ready = in_ready;

    //===========================================================================
    // 主状态机
    //===========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            input_cnt   <= 7'd0;
            compute_cnt <= 7'd0;
            out_valid   <= 1'b0;
            out_idx     <= 7'd0;
            it1d_done   <= 1'b0;
            processing  <= 1'b0;
            input_done  <= 1'b0;
        end else begin
            it1d_done <= 1'b0;
            out_valid <= 1'b0;

            case (state)
                IDLE: begin
                    input_cnt   <= 7'd0;
                    compute_cnt <= 7'd0;
                    input_done  <= 1'b0;

                    // 复位input_cnt（LOAD状态中不复位，需要在IDLE清除残留值）
                    if (it1d_start || next_cfg_valid) begin
                        // 加载配置
                        if (next_cfg_valid) begin
                            r_tr_type   <= next_tr_type;
                            r_length    <= next_length;
                            r_shift     <= next_shift;
                            r_clip_en   <= next_clip_en;
                            r_clip_bits <= next_clip_bits;
                            next_cfg_valid <= 1'b0;
                        end else begin
                            r_tr_type   <= tr_type;
                            r_length    <= length;
                            r_shift     <= shift;
                            r_clip_en   <= clip_en;
                            r_clip_bits <= clip_bits;
                        end
                        state      <= LOAD_WAIT;
                        processing <= 1'b1;
                    end
                end

                LOAD_WAIT: begin
                    state <= LOAD;
                end

                LOAD: begin
                    // 直接写入coeff_mem（不使用流水线）
                    if (in_valid && in_ready) begin
                        coeff_mem[input_cnt[5:0]] <= in_data;
                        input_cnt <= input_cnt + 1'b1;

                        if (input_cnt >= r_length - 1) begin
                            input_done <= 1'b1;
                            state      <= COMPUTE;
                        end
                    end

                    // 同时可以接收下一个配置（流水）
                    if (it1d_start && !next_cfg_valid) begin
                        next_tr_type   <= tr_type;
                        next_length    <= length;
                        next_shift     <= shift;
                        next_clip_en   <= clip_en;
                        next_clip_bits <= clip_bits;
                        next_cfg_valid <= 1'b1;
                    end
                end

                COMPUTE: begin
                    // 等待计算完成，每4点输出一次
                    if (result_valid_sel) begin
                        out_valid <= 1'b1;
                        out_idx   <= compute_cnt;
                        compute_cnt <= compute_cnt + 4;

                        if (compute_cnt >= r_length - 4) begin
                            state <= DONE;
                        end
                    end
                end

                DONE: begin
                    it1d_done     <= 1'b1;
                    processing    <= 1'b0;
                    input_cnt     <= 7'd0;   // 复位输入计数器，防止残留值影响下一TU
                    next_cfg_valid <= 1'b0;  // 清除预取，防止最后一列后进入LOAD_WAIT
                    state         <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
