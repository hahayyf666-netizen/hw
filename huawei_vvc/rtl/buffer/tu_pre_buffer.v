//===========================================================================
// tu_pre_buffer.v - TU前置缓存 (4-Bank + 独立清零路径)
// 功能: 服务INPUT、LFNST、COL_1D阶段
// 结构: 4个bank，bank_id=addr[1:0]，每个bank 1024x16
// 清零: epoch标记 + 独立tag清零路径（不走写MUX）
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module tu_pre_buffer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] wr_addr,
    input  wire [15:0] wr_data,
    input  wire        wr_en,
    input  wire [11:0] rd_addr,
    output reg  [15:0] rd_data,
    input  wire        clear,
    input  wire [15:0] clear_length,
    output reg         clear_done,
    output wire        debug_clearing
);

    //===========================================================================
    // Epoch + Tag清零
    // clear时: epoch递增，同时逐周期清零所有tag RAM
    // 清零完成: tag全部为旧epoch值，新写入带新epoch
    //===========================================================================
    reg [7:0]  epoch;
    reg        clearing;
    reg [9:0]  tag_clear_cnt;  // 清零计数器 (0~1023, 每周期清4个tag)
    reg        tag_clearing;

    assign debug_clearing = clearing;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            epoch         <= 8'd0;
            clearing      <= 1'b0;
            clear_done    <= 1'b0;
            tag_clear_cnt <= 10'd0;
            tag_clearing  <= 1'b0;
        end else if (clear && !tag_clearing && !clear_done) begin
            // 开始清零: epoch递增，启动tag清零
            epoch         <= epoch + 1'b1;
            clearing      <= 1'b1;
            tag_clearing  <= 1'b1;
            tag_clear_cnt <= 10'd0;
            clear_done    <= 1'b0;
        end else if (tag_clearing) begin
            // tag清零进行中: 每周期清4个bank的同一地址tag
            tag_clear_cnt <= tag_clear_cnt + 1'b1;
            if (tag_clear_cnt == 10'd1023) begin
                tag_clearing <= 1'b0;
                clear_done   <= 1'b1;
            end
        end else if (clear_done && clear) begin
            // 清零完成，保持clear_done直到clear释放
            clear_done <= 1'b1;
            clearing   <= 1'b0;
        end else begin
            clear_done <= 1'b0;
            clearing   <= 1'b0;
        end
    end

    //===========================================================================
    // 4个Bank存储 + Tag存储
    //===========================================================================
    reg [15:0] bank0 [0:1023];
    reg [15:0] bank1 [0:1023];
    reg [15:0] bank2 [0:1023];
    reg [15:0] bank3 [0:1023];

    reg [7:0] tag0 [0:1023];
    reg [7:0] tag1 [0:1023];
    reg [7:0] tag2 [0:1023];
    reg [7:0] tag3 [0:1023];

    //===========================================================================
    // 写操作 - 数据写bank，tag写epoch
    // 清零期间: 正常写被阻塞（clearing=1时wr_en不传入）
    //===========================================================================
    wire       wr_active = wr_en && !clearing;
    wire [1:0] wr_bank   = wr_addr[1:0];
    wire [9:0] wr_baddr  = wr_addr[11:2];

    always @(posedge clk) begin
        // Tag清零路径（独立于写MUX）
        if (tag_clearing) begin
            tag0[tag_clear_cnt] <= 8'd0;
            tag1[tag_clear_cnt] <= 8'd0;
            tag2[tag_clear_cnt] <= 8'd0;
            tag3[tag_clear_cnt] <= 8'd0;
        end
        // 正常写（清零期间被阻塞）
        else if (wr_active) begin
            case (wr_bank)
                2'd0: begin bank0[wr_baddr] <= wr_data; tag0[wr_baddr] <= epoch; end
                2'd1: begin bank1[wr_baddr] <= wr_data; tag1[wr_baddr] <= epoch; end
                2'd2: begin bank2[wr_baddr] <= wr_data; tag2[wr_baddr] <= epoch; end
                2'd3: begin bank3[wr_baddr] <= wr_data; tag3[wr_baddr] <= epoch; end
            endcase
        end
    end

    //===========================================================================
    // 读操作 - 单级: 读bank+tag，检查epoch，1拍延迟
    //===========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_data <= 16'd0;
        else begin
            case (rd_addr[1:0])
                2'd0: rd_data <= (tag0[rd_addr[11:2]] == epoch) ? bank0[rd_addr[11:2]] : 16'd0;
                2'd1: rd_data <= (tag1[rd_addr[11:2]] == epoch) ? bank1[rd_addr[11:2]] : 16'd0;
                2'd2: rd_data <= (tag2[rd_addr[11:2]] == epoch) ? bank2[rd_addr[11:2]] : 16'd0;
                2'd3: rd_data <= (tag3[rd_addr[11:2]] == epoch) ? bank3[rd_addr[11:2]] : 16'd0;
            endcase
        end
    end

endmodule
