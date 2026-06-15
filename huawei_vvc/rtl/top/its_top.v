//===========================================================================
// its_top.v - VVC反变换模块顶层 (优化版 - 支持4点并行和流水)
// 功能: 整合LFNST、1D反变换、Buffer管理、输出打包
// 优化: 支持一拍4点并行计算，支持输入/计算/输出全流水
//===========================================================================

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNSIGNED */

module its_top (
    // 全局信号
    input  wire        clk,
    input  wire        rst_n,

    // 配置接口 (it_info)
    input  wire [21:0] it_info,         // 22位配置信息
    input  wire        it_info_vld,     // 配置有效

    // 数据输入接口
    input  wire        it_data_in_vld,  // 输入数据有效
    input  wire [11:0] it_data_addr,    // 输入数据地址（光栅扫描）
    input  wire [15:0] it_data_in,      // 输入数据（16bit有符号）
    input  wire        it_data_end,     // TU输入完成指示

    // 反压接口
    output wire        it_data_in_req,  // 输入请求（反压）

    // 数据输出接口 - 优化为一拍4点
    output wire [39:0] it_data_out,     // 输出数据（40bit打包）
    output wire        it_data_out_vld, // 输出有效
    input  wire        it_data_out_req, // 输出请求（流控）

    // 完成指示
    output wire        it_done           // TU计算完成

    // Debug接口（编译时可通过ITS_DEBUG宏开启）
    `ifdef ITS_DEBUG
    ,
    output wire [7:0]  debug_state,      // FSM状态
    output wire [3:0]  debug_stage,      // 0=idle, 1=lfnst, 2=col, 3=row, 4=out
    output wire [15:0] debug_count,      // 计数器
    output wire        debug_buf_wr_en,
    output wire [11:0] debug_buf_wr_addr,
    output wire [15:0] debug_buf_wr_data,
    output wire        debug_buf_clearing,
    output wire [1:0]  debug_rd_state_o,
    output wire [2:0]  debug_1d_state_o,
    output wire        debug_it1d_ready_o,
    output wire        debug_it1d_start_o,
    output wire        debug_it1d_done_o
    `endif
);

    //===========================================================================
    // 内部信号声明
    //===========================================================================

    // 配置解码输出
    wire [6:0]  cfg_tu_width;
    wire [6:0]  cfg_tu_height;
    wire [1:0]  cfg_tr_type_hor;
    wire [1:0]  cfg_tr_type_ver;
    wire [1:0]  cfg_lfnst_tr_set_idx;
    wire [1:0]  cfg_lfnst_idx;
    wire        cfg_valid;

    // FSM控制信号
    wire [3:0]  fsm_state;
    wire [3:0]  fsm_stage;
    wire [15:0] fsm_count;
    wire        fsm_idle;
    wire        fsm_lfnst;
    wire        fsm_col_1d;
    wire        fsm_row_1d;
    wire        fsm_output;
    wire [6:0]  r_tu_width;
    wire [6:0]  r_tu_height;

    // 12-bit extended config for address calculations
    wire [11:0] r_tu_width_12  = {5'd0, r_tu_width};
    wire [11:0] r_tu_height_12 = {5'd0, r_tu_height};

    // LFNST控制接口
    wire        lfnst_start;
    wire        lfnst_ready;
    wire        lfnst_done;
    wire        buffer_owner_lfnst;

    // TU Buffer接口（来自A）
    wire [11:0] a_wr_addr;
    wire [15:0] a_wr_data;
    wire        a_wr_en;
    wire [15:0] a_rd_data;

    // Pre/Post Buffer写信号（寄存器，在mux区域声明）

    // TU Buffer接口（来自C/LFNST）
    wire        lfnst_rd_req;
    wire [11:0] lfnst_rd_addr;
    wire [15:0] lfnst_rd_data;
    wire        lfnst_wr_valid;
    wire [11:0] lfnst_wr_addr;
    wire [15:0] lfnst_wr_data;

    // TU Post-Buffer读数据
    wire [15:0] buf_rd_data;

    // 中间Buffer接口 - 32bit单点
    wire        inter_wr_en;
    reg  [11:0] inter_wr_addr;
    wire [31:0] inter_wr_data;   // 32bit单点
    wire [11:0] inter_rd_addr;
    wire [31:0] inter_rd_data;   // 32bit单点

    // 中间Buffer控制信号
    reg [6:0]   inter_wr_cnt;
    reg [6:0]   inter_wr_line_cnt;
    reg [6:0]   inter_rd_cnt;
    reg [6:0]   inter_rd_line_cnt;

    // 1D反变换接口（优化为4点并行）
    wire        it1d_start;
    wire        it1d_ready;
    wire        it1d_done;
    wire [1:0]  it1d_tr_type;
    wire [6:0]  it1d_length;
    wire [4:0]  it1d_shift;
    wire        it1d_clip_en;
    wire [5:0]  it1d_clip_bits;

    // 1D数据输入（逐点，但内部缓冲）
    wire        it1d_in_valid;
    wire        it1d_in_ready;
    wire [6:0]  it1d_in_idx;
    wire [15:0] it1d_in_data;

    // 1D数据输出（一拍4点 x 32bit = 128bit）
    wire        it1d_out_valid;
    wire        it1d_out_ready = 1'b1;  // Always ready (no backpressure from downstream)
    wire [6:0]  it1d_out_idx;
    wire [127:0] it1d_out_data;  // 4点 x 32bit

    // 输出打包接口
    wire        packer_start;
    wire [6:0]  packer_tu_width;
    wire [6:0]  packer_tu_height;
    wire        packer_done;

    // 行变换输出写回TU Buffer接口
    wire        row_1d_wr_en;
    wire [11:0] row_1d_wr_addr;
    wire [15:0] row_1d_wr_data;

    // TU Buffer清零接口
    wire        tu_buf_clear;
    wire        tu_buf_clear_done;
    wire [15:0] total_pixels_comb = cfg_tu_width * cfg_tu_height;
    reg  [15:0] total_pixels;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            total_pixels <= 16'd0;
        else
            total_pixels <= total_pixels_comb;
    end

    // 地址生成接口
    wire [11:0] addr_gen_out;
    wire [11:0] addr_gen_col_rd;
    wire [11:0] addr_gen_col_wr;
    wire [11:0] addr_gen_row_rd;
    wire        addr_gen_col_rd_en;
    wire [6:0]  addr_gen_col_idx;
    wire [6:0]  addr_gen_row_idx;
    wire [11:0] addr_gen_output_idx;
    wire        addr_gen_output_rd_en;

    //===========================================================================
    // 列变换输出写入中间buffer - 128bit→4×32bit缓冲写入
    //===========================================================================
    // 128bit输出缓冲（4个32bit值）
    reg [31:0]  out_buf [0:3];
    reg [1:0]   wr_buf_cnt;
    reg         wr_buf_valid;

    // 写缓冲控制
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_buf[0]   <= 32'd0;
            out_buf[1]   <= 32'd0;
            out_buf[2]   <= 32'd0;
            out_buf[3]   <= 32'd0;
            wr_buf_cnt   <= 2'd0;
            wr_buf_valid <= 1'b0;
        end else if (fsm_col_1d) begin
            // 捕获1D core的128bit输出
            if (it1d_out_valid && !wr_buf_valid) begin
                out_buf[0]   <= it1d_out_data[31:0];
                out_buf[1]   <= it1d_out_data[63:32];
                out_buf[2]   <= it1d_out_data[95:64];
                out_buf[3]   <= it1d_out_data[127:96];
                wr_buf_cnt   <= 2'd0;
                wr_buf_valid <= 1'b1;
            end
            // 逐点写入中间buffer
            if (wr_buf_valid) begin
                wr_buf_cnt <= wr_buf_cnt + 1'b1;
                if (wr_buf_cnt == 2'd3) begin
                    wr_buf_valid <= 1'b0;
                    wr_buf_cnt   <= 2'd0;
                end
            end
        end else begin
            wr_buf_valid <= 1'b0;
            wr_buf_cnt   <= 2'd0;
        end
    end

    // 写使能：缓冲有效时持续写入
    assign inter_wr_en   = wr_buf_valid && fsm_col_1d;
    // 数据：从缓冲中选取当前32bit
    assign inter_wr_data = out_buf[wr_buf_cnt];

    // 写地址：增量寄存器，避免组合逻辑乘法器在关键路径上
    // 列主序: addr = col * height + row. 每写一次addr+1, 列切换时自然递增到正确地址.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            inter_wr_addr <= 12'd0;
        else if (!fsm_col_1d)
            inter_wr_addr <= 12'd0;
        else if (inter_wr_en)
            inter_wr_addr <= inter_wr_addr + 12'd1;
    end

    // 写入计数器（32bit单点）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inter_wr_cnt      <= 7'd0;
            inter_wr_line_cnt <= 7'd0;
        end else if (fsm_col_1d && wr_buf_valid) begin
            inter_wr_cnt <= inter_wr_cnt + 1'b1;  // 每次1点
            if (inter_wr_cnt >= r_tu_height - 1) begin
                inter_wr_cnt      <= 7'd0;
                inter_wr_line_cnt <= inter_wr_line_cnt + 1'b1;
                if (inter_wr_line_cnt >= r_tu_width - 1) begin
                    inter_wr_line_cnt <= 7'd0;
                end
            end
        end else if (!fsm_col_1d) begin
            inter_wr_cnt      <= 7'd0;
            inter_wr_line_cnt <= 7'd0;
        end
    end

    //===========================================================================
    // 行变换从中间buffer读取 - 32bit单点读取
    //===========================================================================
    // 地址：中间buffer按列主序存储 (col * r_tu_height + row)
    // 行变换读取: row=r行, col=c列 → addr = c * r_tu_height + row
    // 使用组合逻辑地址 + 流水线寄存器分离地址生成和数据消费
    // Registered address for intermediate buffer read during ROW_1D
    // Uses fsm_row_1d rising edge detection to set initial col 0 address.
    // The it_1d_core LOAD_WAIT state provides 1-cycle latency compensation.
    // Registered address for intermediate buffer read during ROW_1D
    // The intermediate buffer has 1-cycle registered read latency:
    //   addr set at posedge N → buffer reads mem[addr] → rd_data at posedge N+1
    // Therefore: address must be advanced 1 cycle BEFORE data is consumed.
    // Use prefetch flag (same approach as RD_COL for TU buffer).
    // 1D变换数据输入控制 - 状态声明提前（避免used before declaration警告）
    localparam RD_IDLE     = 2'd0;
    localparam RD_COL      = 2'd1;
    localparam RD_ROW      = 2'd2;
    localparam RD_DONE     = 2'd3;

    reg [1:0]   rd_state;
    reg [6:0]   rd_cnt;
    reg [6:0]   rd_line_cnt;
    (* MAX_FANOUT = 30 *) reg [11:0]  rd_addr;
    reg         rd_need_prefetch;  // Prefetch during LOAD_WAIT for registered TU buffer
    reg         row_wr_valid;

    (* MAX_FANOUT = 30 *) reg [11:0] inter_rd_addr_reg;
    reg        inter_rd_prefetch;  // Advance addr during LOAD_WAIT (before handshake)
    reg [11:0] row_stride_reg;     // Registered stride to break config→addr critical path
    reg [11:0] col_stride_reg;     // Registered stride for COL_1D rd_addr
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inter_rd_addr_reg <= 12'd0;
            inter_rd_prefetch <= 1'b0;
            row_stride_reg    <= 12'd0;
            col_stride_reg    <= 12'd0;
        end else begin
            // Latch stride at ROW_1D start
            if (fsm_row_1d && it1d_start)
                row_stride_reg <= r_tu_height_12;
            // Latch stride at COL_1D start
            if (fsm_col_1d && it1d_start)
                col_stride_reg <= r_tu_width_12;
            if (fsm_row_1d && it1d_start) begin
                // ROW_1D start: set col 0 address, enable prefetch for LOAD_WAIT
                // Column-major: addr = col * height + row; col=0, row=inter_rd_line_cnt
                inter_rd_addr_reg <= {5'd0, inter_rd_line_cnt};
                inter_rd_prefetch <= 1'b1;
            end else if (rd_state == RD_DONE && it1d_ready && fsm_row_1d) begin
                // Next row after DONE: set col 0 address, enable prefetch
                inter_rd_addr_reg <= {5'd0, inter_rd_line_cnt};
                inter_rd_prefetch <= 1'b1;
            end else begin
                // Prefetch: advance addr during LOAD_WAIT (before 1D core starts consuming)
                if (inter_rd_prefetch && !it1d_in_ready) begin
                    // LOAD_WAIT: advance addr from col 0 to col 1
                    // Incremental: just add registered stride (no multiplier needed)
                    inter_rd_addr_reg <= inter_rd_addr_reg + row_stride_reg;
                    inter_rd_prefetch <= 1'b0;
                end
                // Normal: advance addr when data consumed (for cnt >= 1)
                // Incremental: add registered stride each cycle instead of full multiply
                if (it1d_in_valid && it1d_in_ready) begin
                    inter_rd_prefetch <= 1'b0;
                    inter_rd_addr_reg <= inter_rd_addr_reg + row_stride_reg;
                end
            end
        end
    end
    assign inter_rd_addr = inter_rd_addr_reg;

    // Debug: trace row 1D address and state
    // 中间buffer读取计数器 - 使用it1d_in_valid && it1d_in_ready驱动
    // 不依赖fsm_row_1d，避免LOAD阶段地址不同步
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inter_rd_cnt      <= 7'd0;
            inter_rd_line_cnt <= 7'd0;
        end else if (it1d_in_valid && it1d_in_ready && fsm_row_1d) begin
            inter_rd_cnt <= inter_rd_cnt + 1'b1;  // 每次1点
            if (inter_rd_cnt >= r_tu_width - 1) begin
                inter_rd_cnt      <= 7'd0;
                inter_rd_line_cnt <= inter_rd_line_cnt + 1'b1;
                if (inter_rd_line_cnt >= r_tu_height - 1) begin
                    inter_rd_line_cnt <= 7'd0;
                end
            end
        end else if (!fsm_row_1d && !fsm_col_1d) begin
            inter_rd_cnt      <= 7'd0;
            inter_rd_line_cnt <= 7'd0;
        end
    end

    //===========================================================================
    // 1D变换数据输入控制 - 列变换从TU Buffer读，行变换从中间buffer读
    //===========================================================================

    // 1D变换输入信号赋值
    assign it1d_in_valid = (rd_state == RD_COL) || (rd_state == RD_ROW);
    assign it1d_in_idx   = rd_cnt;
    // 列变换从TU Buffer读，行变换从32bit中间buffer直接读
    assign it1d_in_data  = (rd_state == RD_ROW) ? inter_rd_data[15:0] : a_rd_data;

    // 行变换输出写回地址 - 使用独立计数器跟踪已写回的总元素数
    reg [11:0] row_wr_total_cnt;  // 已写回TU buffer的总元素计数
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_wr_total_cnt <= 12'd0;
        end else if (fsm_row_1d && row_wr_valid) begin
            row_wr_total_cnt <= row_wr_total_cnt + 1'b1;
        end else if (!fsm_row_1d) begin
            row_wr_total_cnt <= 12'd0;
        end
    end

    // 数据读取状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state    <= RD_IDLE;
            rd_cnt      <= 7'd0;
            rd_line_cnt <= 7'd0;
            rd_addr     <= 12'd0;
            rd_need_prefetch <= 1'b0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    rd_cnt      <= 7'd0;
                    rd_line_cnt <= 7'd0;  // Always reset line counter in IDLE
                    if (fsm_col_1d && it1d_start) begin
                        rd_state <= RD_COL;
                        // Column-major: first addr = 0 * width + col = rd_line_cnt
                        rd_addr  <= {5'd0, rd_line_cnt};
                        rd_need_prefetch <= 1'b1;
                    end else if (fsm_row_1d && it1d_start) begin
                        rd_state <= RD_ROW;
                        rd_need_prefetch <= 1'b1;  // Prefetch for registered read latency
                    end
                end

                RD_COL: begin
                    // Safety: if FSM left COL_1D (e.g., COL_1D_DONE → ROW_1D),
                    // go back to RD_IDLE to avoid getting stuck
                    if (!fsm_col_1d && !fsm_row_1d) begin
                        rd_state <= RD_IDLE;
                    end
                    // Column-major read with TU buffer 1-cycle registered read latency.
                    // Pipeline: addr at posedge N → TU latches mem[addr] → rd_data at posedge N+1
                    // Timing:
                    //   it1d_start: addr <= rd_line_cnt. TU latches OLD addr.
                    //   LOAD_WAIT: prefetch addr += r_tu_width. TU latches rd_line_cnt.
                    //   LOAD: a_rd_data = mem[rd_line_cnt]. coeff_mem[0] captured.
                    //         handshake: addr <= (cnt+2)*width+col (2 ahead for pipeline).
                    //   LOAD+1: a_rd_data = mem[rd_line_cnt+width]. coeff_mem[1] captured.
                    else if (it1d_start) begin
                        // New column starting - reset addr, enable prefetch for LOAD_WAIT
                        rd_addr <= {5'd0, rd_line_cnt};
                        rd_cnt  <= 7'd0;
                        rd_need_prefetch <= 1'b1;
                    end
                    // Prefetch: advance addr during LOAD_WAIT (no handshake yet)
                    else if (rd_need_prefetch && !it1d_in_ready) begin
                        rd_addr <= rd_addr + col_stride_reg;
                        rd_need_prefetch <= 1'b0;
                    end
                    else if (it1d_in_ready && it1d_in_valid) begin
                        rd_need_prefetch <= 1'b0;
                        rd_cnt <= rd_cnt + 1'b1;
                        rd_addr <= rd_addr + col_stride_reg;
                        if (rd_cnt >= r_tu_height - 1) begin
                            rd_cnt      <= 7'd0;
                            rd_line_cnt <= rd_line_cnt + 1'b1;
                            if (rd_line_cnt >= r_tu_width - 1) begin
                                rd_state <= RD_DONE;
                            end
                        end
                    end
                end

                RD_ROW: begin
                    // Catch it1d_start for next TU's COL_1D while still in RD_ROW
                    // (rd_state cycles RD_DONE→RD_ROW→RD_IDLE; it1d_start may fire during RD_ROW)
                    if (fsm_col_1d && it1d_start) begin
                        rd_state <= RD_COL;
                        rd_line_cnt <= 7'd0;
                        rd_addr  <= 12'd0;
                        rd_cnt   <= 7'd0;
                        rd_need_prefetch <= 1'b1;
                    end
                    // Go to RD_DONE when 1D core signals row computation complete
                    else if (it1d_done) begin
                        rd_state <= RD_DONE;
                        rd_need_prefetch <= 1'b1;  // Prefetch for next row
                    end
                    // If FSM already left ROW_1D (last row's it1d_done already processed),
                    // go back to RD_IDLE to avoid getting stuck
                    else if (!fsm_row_1d && !it1d_done) begin
                        rd_state <= RD_IDLE;
                    end
                    // Prefetch: advance addr during LOAD_WAIT (no handshake yet)
                    else if (rd_need_prefetch && !it1d_in_ready) begin
                        // During LOAD_WAIT, inter_rd_addr_reg already holds correct address.
                        // Just clear prefetch flag when LOAD starts.
                    end
                    else if (rd_need_prefetch && it1d_in_ready) begin
                        // LOAD state entered, clear prefetch and set up next address
                        rd_need_prefetch <= 1'b0;
                    end
                    if (it1d_in_ready && it1d_in_valid) begin
                        rd_cnt <= rd_cnt + 1'b1;
                        if (rd_cnt >= r_tu_width - 1) begin
                            rd_cnt      <= 7'd0;
                            rd_line_cnt <= rd_line_cnt + 1'b1;
                        end
                    end
                end

                RD_DONE: begin
                    // Catch it1d_start pulse while transitioning from RD_DONE:
                    // it1d_start fires on same posedge as rd_state→RD_IDLE transition,
                    // so RD_IDLE would miss the pulse. Jump directly to RD_COL instead.
                    if (fsm_col_1d && it1d_start) begin
                        rd_state <= RD_COL;
                        rd_line_cnt <= 7'd0;  // Reset for new TU
                        rd_addr  <= 12'd0;     // col=0 first addr
                        rd_cnt   <= 7'd0;
                        rd_need_prefetch <= 1'b1;
                    end
                    // 等1D core回到IDLE后，根据当前变换类型选择下一状态
                    else if (it1d_ready) begin
                        if (fsm_row_1d) begin
                            // Row 1D: directly start next row (it1d_start pulse is too short)
                            rd_state    <= RD_ROW;
                            rd_cnt      <= 7'd0;
                            rd_need_prefetch <= 1'b1;  // Prefetch for registered read
                            // Note: inter_rd_addr_reg already set by the "RD_DONE && it1d_ready" condition
                        end else begin
                            rd_state <= RD_IDLE;
                        end
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    // 列变换时读取地址由数据读取状态机控制
    // OUTPUT时由packer驱动读地址
    wire [11:0] packer_buf_rd_addr;


    //===========================================================================
    // 行变换输出写回TU Buffer - 128bit→4×16bit缓冲写入
    //===========================================================================
    reg [31:0]  row_out_buf [0:3];
    reg [1:0]   row_wr_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_out_buf[0] <= 32'd0;
            row_out_buf[1] <= 32'd0;
            row_out_buf[2] <= 32'd0;
            row_out_buf[3] <= 32'd0;
            row_wr_cnt     <= 2'd0;
            row_wr_valid   <= 1'b0;
        end else if (fsm_row_1d) begin
            // 捕获行变换1D core的128bit输出
            if (it1d_out_valid && !row_wr_valid) begin
                row_out_buf[0] <= it1d_out_data[31:0];
                row_out_buf[1] <= it1d_out_data[63:32];
                row_out_buf[2] <= it1d_out_data[95:64];
                row_out_buf[3] <= it1d_out_data[127:96];
                row_wr_cnt     <= 2'd0;
                row_wr_valid   <= 1'b1;
            end
            // 逐点写入TU Buffer
            if (row_wr_valid) begin
                row_wr_cnt <= row_wr_cnt + 1'b1;
                if (row_wr_cnt == 2'd3) begin
                    row_wr_valid <= 1'b0;
                    row_wr_cnt   <= 2'd0;
                end
            end
        end else begin
            row_wr_valid <= 1'b0;
            row_wr_cnt   <= 2'd0;
        end
    end

    assign row_1d_wr_en   = row_wr_valid && fsm_row_1d;
    assign row_1d_wr_addr = row_wr_total_cnt;  // 使用独立计数器，每行从0开始
    assign row_1d_wr_data = row_out_buf[row_wr_cnt][15:0];  // 截断到16bit

    //===========================================================================
    // Debug信号赋值
    //===========================================================================
    wire [2:0] dbg_1d_state;
    `ifdef ITS_DEBUG
    assign debug_state = {4'd0, fsm_state};
    assign debug_stage = fsm_stage;
    assign debug_count = fsm_count;
    assign debug_buf_wr_en = pre_buf_wr_en;
    assign debug_buf_wr_addr = pre_buf_wr_addr;
    assign debug_buf_wr_data = pre_buf_wr_data;
    assign debug_buf_clearing = pre_buf_clearing;
    assign debug_rd_state_o = rd_state;
    assign debug_it1d_ready_o = it1d_ready;
    assign debug_it1d_start_o = it1d_start;
    assign debug_it1d_done_o = it1d_done;
    assign debug_1d_state_o = dbg_1d_state;
    `endif

    //===========================================================================
    // 配置解码模块
    //===========================================================================
    config_decode u_config_decode (
        .clk              (clk),
        .rst_n            (rst_n),
        .it_info          (it_info),
        .it_info_vld      (it_info_vld),
        .tu_width         (cfg_tu_width),
        .tu_height        (cfg_tu_height),
        .tr_type_hor      (cfg_tr_type_hor),
        .tr_type_ver      (cfg_tr_type_ver),
        .lfnst_tr_set_idx (cfg_lfnst_tr_set_idx),
        .lfnst_idx        (cfg_lfnst_idx),
        .cfg_valid        (cfg_valid)
    );

    //===========================================================================
    // 顶层控制FSM - 优化支持流水
    //===========================================================================
    its_ctrl_fsm u_its_ctrl_fsm (
        .clk                (clk),
        .rst_n              (rst_n),
        .cfg_valid          (cfg_valid),
        .cfg_tu_width       (cfg_tu_width),
        .cfg_tu_height      (cfg_tu_height),
        .cfg_tr_type_hor    (cfg_tr_type_hor),
        .cfg_tr_type_ver    (cfg_tr_type_ver),
        .cfg_lfnst_idx      (cfg_lfnst_idx),
        .it_data_in_vld     (it_data_in_vld),
        .it_data_end        (it_data_end),
        .it_data_out_req    (it_data_out_req),
        .lfnst_ready        (lfnst_ready),
        .lfnst_done         (lfnst_done),
        .it1d_ready         (it1d_ready),
        .it1d_done          (it1d_done),
        .packer_done        (packer_done),
        .it_data_in_req     (it_data_in_req),
        .it_done            (it_done),
        .tu_buf_clear_done  (tu_buf_clear_done),
        .tu_buf_clear       (tu_buf_clear),
        .wr_buf_valid       (wr_buf_valid),
        .row_wr_valid       (row_wr_valid),
        .lfnst_start        (lfnst_start),
        .buffer_owner_lfnst (buffer_owner_lfnst),
        .it1d_start         (it1d_start),
        .it1d_tr_type       (it1d_tr_type),
        .it1d_length        (it1d_length),
        .it1d_shift         (it1d_shift),
        .it1d_clip_en       (it1d_clip_en),
        .it1d_clip_bits     (it1d_clip_bits),
        .packer_start       (packer_start),
        .packer_tu_width    (packer_tu_width),
        .packer_tu_height   (packer_tu_height),
        .fsm_state          (fsm_state),
        .fsm_stage          (fsm_stage),
        .fsm_count          (fsm_count),
        .fsm_idle           (fsm_idle),
        .fsm_lfnst          (fsm_lfnst),
        .fsm_col_1d         (fsm_col_1d),
        .fsm_row_1d         (fsm_row_1d),
        .fsm_output         (fsm_output),
        .cfg_tu_width_out   (r_tu_width),
        .cfg_tu_height_out  (r_tu_height)
    );

    //===========================================================================
    // TU Buffer Mux - 拆分为pre/post两路写
    // Pre-Buffer写: INPUT + LFNST
    // Post-Buffer写: ROW_1D
    // Registered output to break critical path to RAMD64E write port
    //===========================================================================
    wire        buf_wr_en_comb;
    wire [11:0] buf_wr_addr_comb;
    wire [15:0] buf_wr_data_comb;

    assign buf_wr_addr_comb = buffer_owner_lfnst ? lfnst_wr_addr : a_wr_addr;
    assign buf_wr_data_comb = buffer_owner_lfnst ? lfnst_wr_data : a_wr_data;
    assign buf_wr_en_comb   = buffer_owner_lfnst ? lfnst_wr_valid : a_wr_en;

    reg         pre_buf_wr_en;
    reg  [11:0] pre_buf_wr_addr;
    reg  [15:0] pre_buf_wr_data;
    reg         post_buf_wr_en;
    reg  [11:0] post_buf_wr_addr;
    reg  [15:0] post_buf_wr_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_buf_wr_en   <= 1'b0;
            pre_buf_wr_addr <= 12'd0;
            pre_buf_wr_data <= 16'd0;
            post_buf_wr_en  <= 1'b0;
            post_buf_wr_addr<= 12'd0;
            post_buf_wr_data<= 16'd0;
        end else begin
            // Pre-buffer: INPUT + LFNST writes
            pre_buf_wr_en   <= buf_wr_en_comb;
            pre_buf_wr_addr <= buf_wr_addr_comb;
            pre_buf_wr_data <= buf_wr_data_comb;
            // Post-buffer: ROW_1D writes
            post_buf_wr_en  <= row_1d_wr_en;
            post_buf_wr_addr<= row_1d_wr_addr;
            post_buf_wr_data<= row_1d_wr_data;
        end
    end

    // Pre-buffer read: COL_1D + LFNST
    wire [11:0] pre_buf_rd_addr;
    wire [15:0] pre_buf_rd_data;
    assign pre_buf_rd_addr = buffer_owner_lfnst ? lfnst_rd_addr : rd_addr;
    assign a_rd_data     = pre_buf_rd_data;
    assign lfnst_rd_data = pre_buf_rd_data;

    //===========================================================================
    // TU Buffer (Register Bank版本)
    //===========================================================================
    wire pre_buf_clearing;

    //===========================================================================
    // TU Pre-Buffer: INPUT写入, LFNST读写, COL_1D读
    //===========================================================================
    tu_pre_buffer u_tu_pre_buffer (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_addr      (pre_buf_wr_addr),
        .wr_data      (pre_buf_wr_data),
        .wr_en        (pre_buf_wr_en),
        .rd_addr      (pre_buf_rd_addr),
        .rd_data      (pre_buf_rd_data),
        .clear        (tu_buf_clear),
        .clear_length (total_pixels),
        .clear_done   (tu_buf_clear_done),
        .debug_clearing(pre_buf_clearing)
    );

    //===========================================================================
    // TU Post-Buffer: ROW_1D写入, OUTPUT读取 (无需清零)
    //===========================================================================
    tu_post_buffer u_tu_post_buffer (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_addr      (post_buf_wr_addr),
        .wr_data      (post_buf_wr_data),
        .wr_en        (post_buf_wr_en),
        .rd_addr      (packer_buf_rd_addr),
        .rd_data      (buf_rd_data)
    );

    //===========================================================================
    // 地址生成器
    //===========================================================================
    addr_gen u_addr_gen (
        .clk            (clk),
        .rst_n          (rst_n),
        .tu_width       (cfg_tu_width),
        .tu_height      (cfg_tu_height),
        .input_wr_en    (it_data_in_vld),
        .input_addr_in  (it_data_addr),
        .input_addr_out (a_wr_addr),
        .col_rd_addr    (addr_gen_col_rd),
        .col_rd_en      (1'b0),
        .col_idx        (7'd0),
        .row_idx        (7'd0),
        .col_wr_addr    (addr_gen_col_wr),
        .row_rd_addr    (addr_gen_row_rd),
        .output_rd_addr (addr_gen_out),
        .output_rd_en   (1'b0),
        .output_idx     (12'd0)
    );

    // 输入数据直接写入buffer
    assign a_wr_data = it_data_in;
    assign a_wr_en   = it_data_in_vld;

    //===========================================================================
    // LFNST模块
    //===========================================================================
    lfnst_core u_lfnst_core (
        .clk              (clk),
        .rst_n            (rst_n),
        .lfnst_start      (lfnst_start),
        .lfnst_ready      (lfnst_ready),
        .lfnst_done       (lfnst_done),
        .tu_width         (cfg_tu_width),
        .tu_height        (cfg_tu_height),
        .lfnst_idx        (cfg_lfnst_idx),
        .lfnst_tr_set_idx (cfg_lfnst_tr_set_idx),
        .buf_rd_req       (lfnst_rd_req),
        .buf_rd_addr      (lfnst_rd_addr),
        .buf_rd_data      (lfnst_rd_data),
        .buf_wr_valid     (lfnst_wr_valid),
        .buf_wr_addr      (lfnst_wr_addr),
        .buf_wr_data      (lfnst_wr_data),
        .buf_wr_ready     (1'b1)
    );

    //===========================================================================
    // 中间结果Buffer - 32bit单点宽度
    //===========================================================================
    intermediate_buffer u_intermediate_buffer (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (inter_wr_en),
        .wr_addr  (inter_wr_addr),
        .wr_data  (inter_wr_data),
        .rd_addr  (inter_rd_addr),
        .rd_data  (inter_rd_data)
    );

    //===========================================================================
    // 1D反变换核心 - 优化为4点并行输出
    //===========================================================================
    it_1d_core u_it_1d_core (
        .clk           (clk),
        .rst_n         (rst_n),
        .it1d_start    (it1d_start),
        .it1d_ready    (it1d_ready),
        .it1d_done     (it1d_done),
        .tr_type       (it1d_tr_type),
        .length        (it1d_length),
        .shift         (it1d_shift),
        .clip_en       (it1d_clip_en),
        .clip_bits     (it1d_clip_bits),
        .in_ready      (it1d_in_ready),
        .in_valid      (it1d_in_valid),
        .in_idx        (it1d_in_idx),
        .in_data       (it1d_in_data),
        .out_valid     (it1d_out_valid),
        .out_ready     (it1d_out_ready),
        .out_idx       (it1d_out_idx),
        .out_data      (it1d_out_data),
        .debug_state    (dbg_1d_state),
        .debug_input_cnt(),
        .debug_in_valid (),
        .debug_in_ready ()
    );

    //===========================================================================
    // 输出打包模块
    //===========================================================================
    output_packer u_output_packer (
        .clk             (clk),
        .rst_n           (rst_n),
        .packer_start    (packer_start),
        .tu_width        (packer_tu_width),
        .tu_height       (packer_tu_height),
        .buf_rd_addr     (packer_buf_rd_addr),
        .buf_rd_data     (buf_rd_data),
        .it_data_out     (it_data_out),
        .it_data_out_vld (it_data_out_vld),
        .it_data_out_req (it_data_out_req),
        .packer_done     (packer_done)
    );

endmodule
