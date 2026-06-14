//===========================================================================
// output_packer.v - 输出打包模块
// 功能: 最终Clip10限幅(-512~511)，将4个10bit点打包为40bit
// 时序: TU Buffer有1拍读延迟
//   SETUP拍: 地址在总线上，TU采样 → CAPTURE拍: 数据有效，采样并设下一地址
//   每个像素需要 SETUP+CAPTURE = 2拍
//===========================================================================

module output_packer (
    input  wire        clk,
    input  wire        rst_n,

    // 控制接口
    input  wire        packer_start,   // 脉冲: 启动打包
    input  wire [6:0]  tu_width,
    input  wire [6:0]  tu_height,

    // Buffer读接口 (地址组合输出，数据1拍后有效)
    output wire [11:0] buf_rd_addr,
    input  wire [15:0] buf_rd_data,

    // 输出接口
    output reg  [39:0] it_data_out,
    output reg         it_data_out_vld,
    input  wire        it_data_out_req,
    output reg         packer_done
);

    localparam IDLE    = 2'd0;
    localparam SETUP   = 2'd1;  // 设地址，等TU采样
    localparam CAPTURE = 2'd2;  // 数据有效，采样并设下一地址
    localparam OUTPUT  = 2'd3;  // 输出打包结果

    reg [1:0]  state;
    reg [15:0] rd_cnt;        // 全局读地址计数器
    reg [15:0] total_pixels;
    reg [1:0]  pack_cnt;      // 组内计数 0~3
    reg [9:0]  pixel_buf [0:3];

    // 地址: 组合输出，直接驱动TU Buffer读地址
    assign buf_rd_addr = rd_cnt[11:0];


    // Clip10 - use explicit bit checks to avoid Verilator signed comparison issues
    wire [15:0] raw_data = buf_rd_data;
    wire        is_negative = raw_data[15];
    wire [14:0] abs_val = is_negative ? (~raw_data[14:0] + 1'b1) : raw_data[14:0];
    wire        overflow_pos = !is_negative && (raw_data[14:9] != 0);  // > 511
    wire        overflow_neg = is_negative && (abs_val > 15'd512);     // < -512
    reg  [9:0]  clip10_result;

    always @(*) begin
        if (overflow_neg)
            clip10_result = 10'h200;  // -512 in 10-bit two's complement
        else if (overflow_pos)
            clip10_result = 10'h1FF;  // 511
        else
            clip10_result = raw_data[9:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            rd_cnt         <= 16'd0;
            total_pixels   <= 16'd0;
            pack_cnt       <= 2'd0;
            it_data_out    <= 40'd0;
            it_data_out_vld<= 1'b0;
            packer_done    <= 1'b0;
            pixel_buf[0]   <= 10'd0;
            pixel_buf[1]   <= 10'd0;
            pixel_buf[2]   <= 10'd0;
            pixel_buf[3]   <= 10'd0;
        end else begin
            it_data_out_vld <= 1'b0;

            case (state)
                IDLE: begin
                    packer_done <= 1'b0;
                    if (packer_start) begin
                        state        <= SETUP;
                        total_pixels <= tu_width * tu_height;
                        rd_cnt       <= 16'd0;
                        pack_cnt     <= 2'd0;
                    end
                end

                SETUP: begin
                    // buf_rd_addr = rd_cnt (组合输出)
                    // TU Buffer在posedge采样此地址，数据在下一拍有效
                    state <= CAPTURE;
                end

                CAPTURE: begin
                    // buf_rd_data此时有效(TU在SETUP拍采样了地址)
                    pixel_buf[pack_cnt] <= clip10_result;
                    rd_cnt <= rd_cnt + 1'b1;  // 设下一像素地址

                    if (pack_cnt == 2'd3) begin
                        // 4个像素全部采完
                        state   <= OUTPUT;
                        pack_cnt <= 2'd0;
                    end else begin
                        pack_cnt <= pack_cnt + 1'b1;
                        state    <= SETUP;  // 等TU采样新地址
                    end
                end

                OUTPUT: begin
                    // 打包输出: 等待it_data_out_req反压释放
                    it_data_out <= {pixel_buf[3], pixel_buf[2],
                                    pixel_buf[1], pixel_buf[0]};

                    if (it_data_out_req) begin
                        it_data_out_vld <= 1'b1;

                        if (rd_cnt >= total_pixels) begin
                            state <= IDLE;
                            packer_done <= 1'b1;
                        end else begin
                            state <= SETUP;  // 下一组
                        end
                    end
                    // else: hold data and stay in OUTPUT
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
