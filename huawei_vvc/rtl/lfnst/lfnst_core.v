//===========================================================================
// lfnst_core.v - LFNST主模块
// 功能: 完成扫描取数、矩阵乘、限幅、写回
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module lfnst_core (
    input  wire        clk,
    input  wire        rst_n,

    // 控制接口
    input  wire        lfnst_start,
    output reg         lfnst_ready,
    output reg         lfnst_done,
    input  wire [6:0]  tu_width,
    input  wire [6:0]  tu_height,
    input  wire [1:0]  lfnst_idx,
    input  wire [1:0]  lfnst_tr_set_idx,

    // TU Buffer访问接口
    output reg         buf_rd_req,
    output reg  [11:0] buf_rd_addr,
    input  wire [15:0] buf_rd_data,
    output reg         buf_wr_valid,
    output reg  [11:0] buf_wr_addr,
    output reg  [15:0] buf_wr_data,
    input  wire        buf_wr_ready
);

    //===========================================================================
    // 状态定义
    //===========================================================================
    localparam IDLE       = 3'd0;
    localparam SCAN       = 3'd1;
    localparam LOAD       = 3'd2;
    localparam FETCH      = 3'd3;
    localparam COMPUTE    = 3'd4;
    localparam WRITEBACK  = 3'd5;
    localparam DONE       = 3'd6;

    //===========================================================================
    // LFNST配置参数
    //===========================================================================
    wire [6:0]  nTrs;
    wire [6:0]  nonZeroSize;
    wire        sel_nTrs;

    assign nTrs = ((tu_width >= 8) && (tu_height >= 8)) ? 7'd48 : 7'd16;

    assign nonZeroSize = ((tu_width == 4 && tu_height == 4) ||
                          (tu_width == 8 && tu_height == 8)) ? 7'd8 : 7'd16;

    assign sel_nTrs = (nTrs == 48) ? 1'b1 : 1'b0;

    //===========================================================================
    // 内部寄存器
    //===========================================================================
    reg [2:0]   state;
    reg [6:0]   scan_cnt;
    reg [6:0]   compute_cnt;
    reg [6:0]   writeback_cnt;
    reg         col_done;
    reg         save_pending;
    reg         scan_first_cycle;
    reg [15:0]  input_vec [0:15];
    reg [31:0]  output_vec [0:47];
    reg signed [31:0] compute_accum;

    //===========================================================================
    // LFNST扫描模块
    //===========================================================================
    wire [11:0] scan_addr;
    wire        scan_valid;

    lfnst_scan u_lfnst_scan (
        .clk          (clk),
        .rst_n        (rst_n),
        .scan_en      (state == SCAN),
        .tu_width     (tu_width),
        .tu_height    (tu_height),
        .nonZeroSize  (nonZeroSize),
        .scan_cnt     (scan_cnt),
        .scan_addr    (scan_addr),
        .scan_valid   (scan_valid)
    );

    //===========================================================================
    // LFNST矩阵ROM (同步, 1拍延迟)
    // ROM数据布局: [input_idx][output_idx] (与Python LFNST_KERNELS一致)
    // rd_addr = input维度, rd_col = output维度
    // nTrs=48时, normalize重排: norm[j][i] = raw[j + (i>>4)*16][i&15]
    //   所以 rd_addr = col + row_group*16, rd_col = row[3:0]
    //===========================================================================
    wire [7:0]  matrix_data;
    reg  [5:0]  matrix_row;   // output index (0..nTrs-1)
    reg  [3:0]  matrix_col;   // input index (0..nonZeroSize-1)

    wire [5:0] matrix_col_ext = {2'b0, matrix_col};

    // ROM地址: input维度 → rd_addr, output维度 → rd_col
    // 统一公式: rd_addr = col + {row[5:4], 4'b0}, rd_col = {2'b0, row[3:0]}
    // nTrs=16时 row[5:4]=0, 所以 rd_addr=col, rd_col=row (都在0..15范围)
    wire [5:0] rom_rd_addr = matrix_col_ext + {matrix_row[5:4], 4'b0};
    wire [5:0] rom_rd_col  = {2'b0, matrix_row[3:0]};

    lfnst_matrix_rom u_lfnst_matrix_rom (
        .clk       (clk),
        .rd_addr   (rom_rd_addr),
        .rd_col    (rom_rd_col),
        .sel_nTrs  (sel_nTrs),
        .sel_set   (lfnst_tr_set_idx),
        .sel_idx   (~lfnst_idx[0]),
        .rd_data   (matrix_data)
    );

    //===========================================================================
    // LFNST配置模块
    //===========================================================================
    wire [6:0]  cfg_nTrs;
    wire [6:0]  cfg_nonZeroSize;
    wire [4:0]  cfg_sbSize;

    lfnst_config u_lfnst_config (
        .tu_width     (tu_width),
        .tu_height    (tu_height),
        .nTrs         (cfg_nTrs),
        .nonZeroSize  (cfg_nonZeroSize),
        .sbSize       (cfg_sbSize)
    );

    //===========================================================================
    // LFNST写回模块
    //===========================================================================
    wire [11:0] wb_addr;
    wire [15:0] wb_data;
    wire        wb_valid;
    wire        wb_ready;

    lfnst_writeback u_lfnst_writeback (
        .clk          (clk),
        .rst_n        (rst_n),
        .wb_en        (state == WRITEBACK),
        .tu_width     (tu_width),
        .nTrs         (nTrs),
        .writeback_cnt(writeback_cnt),
        .output_val   (output_vec[writeback_cnt[5:0]]),
        .wb_addr      (wb_addr),
        .wb_data      (wb_data),
        .wb_valid     (wb_valid),
        .wb_ready     (wb_ready)
    );

    //===========================================================================
    // 累加器流水线信号
    // ROM同步: 地址在posedge锁存, 数据在下一个posedge输出 (1拍延迟)。
    // signed_input_d: 延迟1拍的输入, 与ROM输出对齐。
    //   col=0: capture input_vec[0]. 不累加(ROM数据来自上一行).
    //   col=1: signed_input_d=input_vec[0], ROM→M[row][0]. 累加 ✓
    //   col=k: signed_input_d=input_vec[k-1], ROM→M[row][k-1]. 累加 ✓
    //   col_done: signed_input_d=input_vec[nonZeroSize-1], ROM→M[row][nonZeroSize-1]. 累加 ✓
    //   累加完成时compute_accum包含全部nonZeroSize项.
    //===========================================================================
    reg signed [15:0] signed_input_d;  // 延迟1拍的输入, 与ROM对齐
    wire signed [7:0]  signed_matrix = $signed(matrix_data);
    // col=0不累加(ROM数据无效), col_done也累加(最后一项)
    wire        do_accum = (state == COMPUTE) && (matrix_col != 4'd0) && !save_pending;

    //===========================================================================
    // 主状态机 + 累加器 (合并到单个always块, 避免Verilator执行顺序问题)
    //
    // 流水线时序 (nonZeroSize=8 为例, ROM同步1拍延迟):
    //   LOAD:    row=0, col=0
    //   FETCH:   ROM addr=(0,0)
    //   COMP 0:  col=0. ROM→M[0][0](无效). 不累加. signed_input_d<=in[0]. col<=1.
    //   COMP 1:  col=1. ROM→M[0][0](addr=0). acc+=in[0]*M[0][0]. col<=2. sid<=in[1].
    //   COMP 2:  col=2. ROM→M[0][1](addr=1). acc+=in[1]*M[0][1]. col<=3. sid<=in[2].
    //   ...
    //   COMP 6:  col=6. ROM→M[0][5](addr=5). acc+=in[5]*M[0][5]. col<=7. sid<=in[6].
    //   COMP 7:  col=7. ROM→M[0][6](addr=6). acc+=in[6]*M[0][6]. col_done<=1.
    //   COMP 8:  col=7, col_done=1. ROM→M[0][7](addr=7). acc+=in[7]*M[0][7]. save_pending<=1.
    //   COMP 9:  save_pending=1. 保存accum(全部8项). 推进到下一行.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            lfnst_ready   <= 1'b1;
            lfnst_done    <= 1'b0;
            buf_rd_req    <= 1'b0;
            buf_rd_addr   <= 12'd0;
            buf_wr_valid  <= 1'b0;
            buf_wr_addr   <= 12'd0;
            buf_wr_data   <= 16'd0;
            scan_cnt      <= 7'd0;
            compute_cnt   <= 7'd0;
            writeback_cnt <= 7'd0;
            col_done      <= 1'b0;
            save_pending  <= 1'b0;
            signed_input_d <= 16'd0;
            scan_first_cycle <= 1'b0;
            matrix_row    <= 6'd0;
            matrix_col    <= 4'd0;
            compute_accum <= 32'd0;
        end else begin
            lfnst_done    <= 1'b0;
            buf_rd_req    <= 1'b0;
            buf_wr_valid  <= 1'b0;

            // 累加器: 仅在COMPUTE且col≠0时累加 (col_done时也累加最后一项)
            if (do_accum)
                compute_accum <= compute_accum + signed_input_d * signed_matrix;

            // signed_input_d更新: 为下一拍的累加做准备
            if (state == COMPUTE && !col_done)
                signed_input_d <= input_vec[matrix_col];
            else if (state == LOAD || state == FETCH)
                signed_input_d <= 16'd0;

            case (state)
                IDLE: begin
                    lfnst_ready <= 1'b1;
                    if (lfnst_start) begin
                        state       <= SCAN;
                        lfnst_ready <= 1'b0;
                        scan_cnt    <= 7'd0;
                        scan_first_cycle <= 1'b1;
                    end
                end

                SCAN: begin
                    // Pipeline延迟: scan_addr 1拍 + MUX 1拍 + TU buffer 1拍 = 3拍总延迟
                    // 拍0: scan_en=1, scan_first_cycle=1. 不发读请求, 等管线预热.
                    // 拍1: buf_rd_req=1, buf_rd_addr=diag[0]. TU buffer开始读.
                    // 拍2: buf_rd_addr=diag[1]. buf_rd_data=初始地址数据(stale).
                    // 拍3: buf_rd_data=diag[0] → 捕获input_vec[0]
                    // 拍4: buf_rd_data=diag[1] → 捕获input_vec[1]
                    // ...
                    // 拍K+3: buf_rd_data=diag[K] → 捕获input_vec[K]

                    if (scan_first_cycle) begin
                        // 第1拍: 只启动scan_en, 不发读请求
                        scan_first_cycle <= 1'b0;
                    end else begin
                        buf_rd_req  <= 1'b1;
                        buf_rd_addr <= scan_addr;
                    end

                    if (scan_valid) begin
                        scan_cnt <= scan_cnt + 1'b1;

                        // cnt=0,1,2: 预热(3拍). cnt>=3: 捕获input_vec[cnt-3]
                        if (scan_cnt >= 7'd3) begin
                            input_vec[scan_cnt[3:0] - 3'd3] <= buf_rd_data;
                        end

                        // 转换条件: 捕获cnt=4..nonZeroSize+3, 转换在cnt=nonZeroSize+3
                        if (scan_cnt >= nonZeroSize + 7'd3) begin
                            state <= LOAD;
                        end
                    end
                end

                LOAD: begin
                    state       <= FETCH;
                    matrix_row  <= 6'd0;
                    matrix_col  <= 4'd0;
                    compute_accum <= 32'd0;
                    save_pending <= 1'b0;
                end

                FETCH: begin
                    state <= COMPUTE;
                end

                COMPUTE: begin
                    if (save_pending) begin
                        // Last term was accumulated in previous cycle (col_done cycle)
                        // Now compute_accum has all nonZeroSize terms
                        output_vec[matrix_row] <= compute_accum;
                        save_pending <= 1'b0;
                        col_done <= 1'b0;
                        matrix_col <= 4'd0;
                        matrix_row <= matrix_row + 1'b1;
                        compute_accum <= 32'd0;

                        if ({1'b0, matrix_row} >= nTrs - 1) begin
                            state       <= WRITEBACK;
                            writeback_cnt <= 7'd0;
                        end
                    end else if (col_done) begin
                        // Accumulator adds last term via do_accum (col≠0)
                        // Signal save for next cycle
                        save_pending <= 1'b1;
                    end else if ({3'b0, matrix_col} == nonZeroSize - 1) begin
                        // Reached last column: set col_done
                        col_done <= 1'b1;
                    end else begin
                        matrix_col <= matrix_col + 1'b1;
                    end
                end

                WRITEBACK: begin
                    if (wb_valid) begin
                        buf_wr_valid <= 1'b1;
                        buf_wr_addr  <= wb_addr;
                        buf_wr_data  <= wb_data;

                        writeback_cnt <= writeback_cnt + 1'b1;

                        if (writeback_cnt >= nTrs - 1) begin
                            state <= DONE;
                        end
                    end
                end

                DONE: begin
                    lfnst_done <= 1'b1;
                    state      <= IDLE;
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
