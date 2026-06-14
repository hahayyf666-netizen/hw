//===========================================================================
// its_ctrl_fsm.v - ITS顶层控制FSM (优化版 - 支持流水)
// 功能: 控制完整流程：输入→LFNST→列1D→行1D→输出，支持全流水
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module its_ctrl_fsm (
    input  wire        clk,
    input  wire        rst_n,

    // 配置接口
    input  wire        cfg_valid,
    input  wire [6:0]  cfg_tu_width,
    input  wire [6:0]  cfg_tu_height,
    input  wire [1:0]  cfg_tr_type_hor,
    input  wire [1:0]  cfg_tr_type_ver,
    input  wire [1:0]  cfg_lfnst_idx,

    // 数据输入接口
    input  wire        it_data_in_vld,
    input  wire        it_data_end,

    // 数据输出接口
    input  wire        it_data_out_req,

    // LFNST接口
    input  wire        lfnst_ready,
    input  wire        lfnst_done,
    output reg         lfnst_start,
    output reg         buffer_owner_lfnst,

    // 1D变换接口
    input  wire        it1d_ready,
    input  wire        it1d_done,
    output reg         it1d_start,
    output reg  [1:0]  it1d_tr_type,
    output reg  [6:0]  it1d_length,
    output reg  [4:0]  it1d_shift,
    output reg         it1d_clip_en,
    output reg  [5:0]  it1d_clip_bits,

    // 输出打包接口
    input  wire        packer_done,
    output reg         packer_start,
    output reg  [6:0]  packer_tu_width,
    output reg  [6:0]  packer_tu_height,

    // 顶层接口
    output reg         it_data_in_req,
    output reg         it_done,

    // Buffer清零接口
    input  wire        tu_buf_clear_done,
    output reg         tu_buf_clear,

    // 中间Buffer写状态（列变换输出写入状态）
    input  wire        wr_buf_valid,

    // 行写入状态（行变换输出写入TU Buffer状态）
    input  wire        row_wr_valid,

    // Debug接口
    output reg  [3:0]  fsm_state,
    output reg  [3:0]  fsm_stage,
    output reg  [15:0] fsm_count,
    output wire        fsm_idle,
    output wire        fsm_lfnst,
    output wire        fsm_col_1d,
    output wire        fsm_row_1d,
    output wire        fsm_output,

    // 配置输出（供顶层使用）
    output reg  [6:0]  cfg_tu_width_out,
    output reg  [6:0]  cfg_tu_height_out
);

    //===========================================================================
    // FSM状态定义 - 优化为流水架构
    //===========================================================================
    localparam IDLE       = 4'd0;
    localparam CLEAR      = 4'd9;
    localparam INPUT      = 4'd1;
    localparam LFNST_WAIT = 4'd2;
    localparam LFNST_RUN  = 4'd3;
    localparam WAIT_1CYCLE= 4'd4;
    localparam COL_1D     = 4'd5;
    localparam ROW_1D     = 4'd6;
    localparam OUTPUT     = 4'd7;
    localparam DONE       = 4'd8;
    localparam COL_1D_DONE = 4'd10;
    localparam ROW_1D_DONE = 4'd11;

    // Stage定义
    localparam STAGE_IDLE = 4'd0;
    localparam STAGE_LFNST= 4'd1;
    localparam STAGE_COL  = 4'd2;
    localparam STAGE_ROW  = 4'd3;
    localparam STAGE_OUT  = 4'd4;

    //===========================================================================
    // 流水控制 - 支持3级流水: 输入/计算/输出
    //===========================================================================
    // 配置队列（FIFO深度2，支持配置预取）
    reg [6:0]  cfg_width_queue  [0:1];
    reg [6:0]  cfg_height_queue [0:1];
    reg [1:0]  cfg_tr_hor_queue [0:1];
    reg [1:0]  cfg_tr_ver_queue [0:1];
    reg [1:0]  cfg_lfnst_queue  [0:1];
    reg [1:0]  cfg_valid_queue;

    // 流水控制信号
    reg        pipe_input_busy;
    reg        pipe_compute_busy;
    reg        pipe_output_busy;

    // 当前处理TU的配置
    reg [6:0]  r_tu_width;
    reg [6:0]  r_tu_height;
    reg [1:0]  r_tr_type_hor;
    reg [1:0]  r_tr_type_ver;
    reg [1:0]  r_lfnst_idx;
    reg [15:0] input_count;
    reg [15:0] total_pixels;

    // 循环计数器 - 列/行1D外层循环
    reg [6:0]  col_cnt;   // 列变换当前列号 (0 ~ r_tu_width-1)
    reg [6:0]  row_cnt;   // 行变换当前行号 (0 ~ r_tu_height-1)
    reg        row_wr_done_wait;  // 等待行写入提交

    //===========================================================================
    // 状态输出
    //===========================================================================
    assign fsm_idle    = (fsm_state == IDLE);
    assign fsm_lfnst   = (fsm_state == LFNST_RUN) || (fsm_state == LFNST_WAIT);
    assign fsm_col_1d  = (fsm_state == COL_1D) || (fsm_state == COL_1D_DONE);
    assign fsm_row_1d  = (fsm_state == ROW_1D) || (fsm_state == ROW_1D_DONE);
    assign fsm_output  = (fsm_state == OUTPUT);

    //===========================================================================
    // 配置队列管理（支持流水配置）
    //===========================================================================
    wire cfg_queue_full  = cfg_valid_queue[0] && cfg_valid_queue[1];
    wire cfg_queue_empty = !cfg_valid_queue[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_valid_queue <= 2'b00;
        end else begin
            // 新配置入队
            if (cfg_valid && !cfg_queue_full) begin
                if (!cfg_valid_queue[0]) begin
                    cfg_width_queue[0]  <= cfg_tu_width;
                    cfg_height_queue[0] <= cfg_tu_height;
                    cfg_tr_hor_queue[0] <= cfg_tr_type_hor;
                    cfg_tr_ver_queue[0] <= cfg_tr_type_ver;
                    cfg_lfnst_queue[0]  <= cfg_lfnst_idx;
                    cfg_valid_queue[0]  <= 1'b1;
                end else begin
                    cfg_width_queue[1]  <= cfg_tu_width;
                    cfg_height_queue[1] <= cfg_tu_height;
                    cfg_tr_hor_queue[1] <= cfg_tr_type_hor;
                    cfg_tr_ver_queue[1] <= cfg_tr_type_ver;
                    cfg_lfnst_queue[1]  <= cfg_lfnst_idx;
                    cfg_valid_queue[1]  <= 1'b1;
                end
            end

            // 配置出队（开始处理时）
            if (fsm_state == IDLE && !cfg_queue_empty && !pipe_input_busy) begin
                cfg_valid_queue[0] <= cfg_valid_queue[1];
                cfg_valid_queue[1] <= 1'b0;
            end
        end
    end

    // 计算总像素数
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_pixels <= 16'd0;
        end else if (fsm_state == IDLE && !cfg_queue_empty && !pipe_input_busy) begin
            total_pixels <= cfg_width_queue[0] * cfg_height_queue[0];
        end
    end

    //===========================================================================
    // 主FSM - 优化为支持流水的状态机
    //===========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state          <= IDLE;
            fsm_stage          <= STAGE_IDLE;
            fsm_count          <= 16'd0;
            input_count        <= 16'd0;
            lfnst_start        <= 1'b0;
            buffer_owner_lfnst <= 1'b0;
            it1d_start         <= 1'b0;
            it1d_tr_type       <= 2'd0;
            it1d_length        <= 7'd0;
            it1d_shift         <= 5'd0;
            it1d_clip_en       <= 1'b0;
            it1d_clip_bits     <= 6'd0;
            packer_start       <= 1'b0;
            packer_tu_width    <= 7'd0;
            packer_tu_height   <= 7'd0;
            it_data_in_req     <= 1'b0;
            it_done            <= 1'b0;
            tu_buf_clear       <= 1'b0;
            r_tu_width         <= 7'd0;
            r_tu_height        <= 7'd0;
            r_tr_type_hor      <= 2'd0;
            r_tr_type_ver      <= 2'd0;
            r_lfnst_idx        <= 2'd0;
            cfg_tu_width_out   <= 7'd0;
            cfg_tu_height_out  <= 7'd0;
            pipe_input_busy    <= 1'b0;
            pipe_compute_busy  <= 1'b0;
            pipe_output_busy   <= 1'b0;
            col_cnt            <= 7'd0;
            row_cnt            <= 7'd0;
            row_wr_done_wait   <= 1'b0;
        end else begin
            // 默认信号
            lfnst_start    <= 1'b0;
            it1d_start     <= 1'b0;
            packer_start   <= 1'b0;
            it_done        <= 1'b0;
            tu_buf_clear   <= 1'b0;

            case (fsm_state)
                IDLE: begin
                    fsm_stage <= STAGE_IDLE;

                    // 检查是否有待处理的配置且输入流水空闲
                    if (!cfg_queue_empty && !pipe_input_busy) begin
                        // 加载配置
                        r_tu_width        <= cfg_width_queue[0];
                        r_tu_height       <= cfg_height_queue[0];
                        r_tr_type_hor     <= cfg_tr_hor_queue[0];
                        r_tr_type_ver     <= cfg_tr_ver_queue[0];
                        r_lfnst_idx       <= cfg_lfnst_queue[0];
                        cfg_tu_width_out  <= cfg_width_queue[0];
                        cfg_tu_height_out <= cfg_height_queue[0];

                        // 先清零TU Buffer，再接受输入
                        tu_buf_clear     <= 1'b1;
                        fsm_state        <= CLEAR;
                        pipe_input_busy  <= 1'b1;
                    end
                end

                CLEAR: begin
                    // 等待TU Buffer清零完成
                    if (tu_buf_clear_done) begin
                        tu_buf_clear    <= 1'b0;
                        fsm_state       <= INPUT;
                        it_data_in_req  <= 1'b1;
                        input_count     <= 16'd0;
                    end
                end

                INPUT: begin
                    fsm_stage <= STAGE_IDLE;

                    // 统计输入数据
                    if (it_data_in_vld) begin
                        input_count <= input_count + 1'b1;
                    end

                    // 检查输入完成
                    if (it_data_end || (input_count >= total_pixels && total_pixels > 0)) begin
                        it_data_in_req <= 1'b0;
                        pipe_input_busy<= 1'b0;

                        // 立即接受下一个TU的输入（流水）
                        if (!cfg_queue_empty && !pipe_input_busy) begin
                            // 加载配置
                            r_tu_width        <= cfg_width_queue[0];
                            r_tu_height       <= cfg_height_queue[0];
                            r_tr_type_hor     <= cfg_tr_hor_queue[0];
                            r_tr_type_ver     <= cfg_tr_ver_queue[0];
                            r_lfnst_idx       <= cfg_lfnst_queue[0];
                            cfg_tu_width_out  <= cfg_width_queue[0];
                            cfg_tu_height_out <= cfg_height_queue[0];

                            it_data_in_req <= 1'b1;
                            input_count    <= 16'd0;
                            pipe_input_busy<= 1'b1;
                        end

                        // 判断是否需要LFNST
                        if (r_lfnst_idx != 2'd0) begin
                            fsm_state <= LFNST_WAIT;
                        end else begin
                            fsm_state <= COL_1D;
                            col_cnt   <= 7'd0;  // 列变换计数器清零
                        end
                    end
                end

                LFNST_WAIT: begin
                    fsm_stage <= STAGE_LFNST;
                    if (lfnst_ready) begin
                        lfnst_start        <= 1'b1;
                        buffer_owner_lfnst <= 1'b1;
                        pipe_compute_busy  <= 1'b1;
                        fsm_state          <= LFNST_RUN;
                    end
                end

                LFNST_RUN: begin
                    fsm_stage <= STAGE_LFNST;
                    if (lfnst_done) begin
                        buffer_owner_lfnst <= 1'b0;
                        fsm_state          <= WAIT_1CYCLE;
                    end
                end

                WAIT_1CYCLE: begin
                    fsm_stage <= STAGE_LFNST;
                    fsm_state <= COL_1D;
                    col_cnt   <= 7'd0;  // 列变换计数器清零
                end

                COL_1D: begin
                    fsm_stage <= STAGE_COL;
                    fsm_count <= fsm_count + 1'b1;

                    // Only start next column if current one is not completing
                    // (it1d_done && it1d_ready means last column just finished - don't start new one)
                    if (it1d_ready && !it1d_start && !(it1d_done && col_cnt >= r_tu_width - 1)) begin
                        // 配置列变换参数
                        it1d_start   <= 1'b1;
                        it1d_tr_type <= r_tr_type_ver;
                        it1d_length  <= r_tu_height;
                        it1d_shift   <= 5'd7;
                        it1d_clip_en <= 1'b1;
                        it1d_clip_bits<= 6'd16;
                        pipe_compute_busy <= 1'b1;
                    end

                    if (it1d_done) begin
                        col_cnt <= col_cnt + 1'b1;
                        if (col_cnt >= r_tu_width - 1) begin
                            // 所有列处理完毕，但需等中间buffer写完再进入行变换
                            // 使用 COL_1D_DONE 子状态等待写完成
                            fsm_state   <= COL_1D_DONE;
                            fsm_count   <= 16'd0;
                            col_cnt     <= 7'd0;
                            row_cnt     <= 7'd0;
                        end
                        // else: 等待it1d_ready回到IDLE后自动启动下一列
                    end

                end

                COL_1D_DONE: begin
                    fsm_stage <= STAGE_COL;
                    // 等待中间buffer写入完成 (wr_buf_valid变0表示4个值都写完了)
                    if (!wr_buf_valid) begin
                        fsm_state <= ROW_1D;
                        row_cnt   <= 7'd0;
                    end
                end

                ROW_1D: begin
                    fsm_stage <= STAGE_ROW;
                    fsm_count <= fsm_count + 1'b1;

                    if (it1d_ready && !it1d_start && !(it1d_done && row_cnt >= r_tu_height - 1)) begin
                        // 配置行变换参数
                        it1d_start   <= 1'b1;
                        it1d_tr_type <= r_tr_type_hor;
                        it1d_length  <= r_tu_width;
                        it1d_shift   <= 5'd10;
                        it1d_clip_en <= 1'b0;
                    end

                    if (it1d_done) begin
                        row_cnt <= row_cnt + 1'b1;
                        if (row_cnt >= r_tu_height - 1) begin
                            // 所有行处理完毕，等待行写入完成再进入输出
                            fsm_state   <= ROW_1D_DONE;
                            fsm_count   <= 16'd0;
                            row_cnt     <= 7'd0;
                        end
                        // else: 等待it1d_ready回到IDLE后自动启动下一行
                    end
                end

                ROW_1D_DONE: begin
                    fsm_stage <= STAGE_ROW;
                    // 等待行写入TU Buffer完成 (row_wr_valid变0表示4个值都写完了)
                    // 然后多等1拍，确保TU Buffer寄存器写入已提交
                    if (!row_wr_valid && !row_wr_done_wait) begin
                        row_wr_done_wait <= 1'b1;
                    end else if (row_wr_done_wait) begin
                        fsm_state <= OUTPUT;
                        pipe_compute_busy <= 1'b0;
                        row_wr_done_wait <= 1'b0;
                    end
                end

                OUTPUT: begin
                    fsm_stage <= STAGE_OUT;

                    // packer_start只脉冲一拍，避免packer反复重启
                    if (!packer_start && !pipe_output_busy) begin
                        packer_start     <= 1'b1;
                        packer_tu_width  <= r_tu_width;
                        packer_tu_height <= r_tu_height;
                        pipe_output_busy <= 1'b1;
                    end else begin
                        packer_start <= 1'b0;
                    end

                    if (packer_done) begin
                        pipe_output_busy <= 1'b0;
                        fsm_state <= DONE;
                    end
                end

                DONE: begin
                    fsm_stage <= STAGE_IDLE;
                    it_done   <= 1'b1;
                    fsm_state <= IDLE;
                end

                default: begin
                    fsm_state <= IDLE;
                end
            endcase
        end
    end

endmodule
