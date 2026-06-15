//===========================================================================
// tu_buffer_bank.v - TU系数缓存 (4-Bank BRAM版本)
// 功能: 最大64x64=4096点，4-bank结构，BRAM实现
// 位宽: 16bit有符号数
// 接口: 与tu_buffer.v完全兼容，1拍读延迟
// 设计: 同步读写，BRAM友好
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module tu_buffer_bank (
    input  wire        clk,
    input  wire        rst_n,

    // 写端口
    input  wire [11:0] wr_addr,    // 0~4095
    input  wire [15:0] wr_data,    // 16bit有符号
    input  wire        wr_en,

    // 读端口
    input  wire [11:0] rd_addr,    // 0~4095
    output reg  [15:0] rd_data,    // 16bit有符号

    // 清零端口 - 稀疏输入时清零前clear_length个位置
    input  wire        clear,
    input  wire [15:0] clear_length,
    output reg         clear_done,

    // Debug
    output wire        debug_clearing
);

    //===========================================================================
    // 4-Bank配置
    // bank_id = addr[1:0], bank_addr = addr[11:2]
    // 每个bank: 1024x16
    //===========================================================================
    localparam NUM_BANKS     = 4;
    localparam BANK_DEPTH    = 1024;  // 4096 / 4
    localparam ADDR_BANK_BITS = 2;    // log2(4)
    localparam ADDR_LINE_BITS = 10;   // log2(1024)

    //===========================================================================
    // Bank存储 - 4个独立BRAM
    //===========================================================================
    (* ram_style = "block" *) reg [15:0] bank0 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [15:0] bank1 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [15:0] bank2 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) reg [15:0] bank3 [0:BANK_DEPTH-1];

    //===========================================================================
    // 地址分解
    //===========================================================================
    wire [1:0] wr_bank_id   = wr_addr[ADDR_BANK_BITS-1:0];
    wire [9:0] wr_bank_addr = wr_addr[ADDR_LINE_BITS+ADDR_BANK_BITS-1:ADDR_BANK_BITS];

    wire [1:0] rd_bank_id   = rd_addr[ADDR_BANK_BITS-1:0];
    wire [9:0] rd_bank_addr = rd_addr[ADDR_LINE_BITS+ADDR_BANK_BITS-1:ADDR_BANK_BITS];

    //===========================================================================
    // 清零控制
    //===========================================================================
    reg [11:0] clear_cnt;
    reg        clearing;
    reg [11:0] clear_last_reg;

    assign debug_clearing = clearing;

    wire [1:0] clear_bank_id   = clear_cnt[ADDR_BANK_BITS-1:0];
    wire [9:0] clear_bank_addr = clear_cnt[ADDR_LINE_BITS+ADDR_BANK_BITS-1:ADDR_BANK_BITS];

    // Register clear_last on clear pulse to break critical path
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            clear_last_reg <= 12'd0;
        else if (clear)
            clear_last_reg <= clear_length[11:0] - 12'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clear_cnt  <= 12'd0;
            clearing   <= 1'b0;
            clear_done <= 1'b0;
        end else if (clearing) begin
            clear_cnt <= clear_cnt + 1'b1;
            if (clear_cnt >= clear_last_reg) begin
                clearing   <= 1'b0;
                clear_done <= 1'b1;
            end
        end else begin
            clear_done <= 1'b0;
            if (clear) begin
                clear_cnt <= 12'd0;
                clearing  <= 1'b1;
            end
        end
    end

    //===========================================================================
    // 写操作 - 清零优先，正常写其次
    //===========================================================================
    always @(posedge clk) begin
        if (clearing) begin
            case (clear_bank_id)
                2'd0: bank0[clear_bank_addr] <= 16'd0;
                2'd1: bank1[clear_bank_addr] <= 16'd0;
                2'd2: bank2[clear_bank_addr] <= 16'd0;
                2'd3: bank3[clear_bank_addr] <= 16'd0;
            endcase
        end else if (wr_en) begin
            case (wr_bank_id)
                2'd0: bank0[wr_bank_addr] <= wr_data;
                2'd1: bank1[wr_bank_addr] <= wr_data;
                2'd2: bank2[wr_bank_addr] <= wr_data;
                2'd3: bank3[wr_bank_addr] <= wr_data;
            endcase
        end
    end

    //===========================================================================
    // 读操作 - 同步读，1拍延迟
    // BRAM需要同步读：地址在posedge采样，数据在下一个posedge输出
    //===========================================================================
    reg [15:0] bank0_rd, bank1_rd, bank2_rd, bank3_rd;
    reg [1:0]  rd_bank_id_d;

    always @(posedge clk) begin
        bank0_rd <= bank0[rd_bank_addr];
        bank1_rd <= bank1[rd_bank_addr];
        bank2_rd <= bank2[rd_bank_addr];
        bank3_rd <= bank3[rd_bank_addr];
        rd_bank_id_d <= rd_bank_id;
    end

    // MUX选择 (组合逻辑)
    reg [15:0] rd_data_mux;
    always @(*) begin
        case (rd_bank_id_d)
            2'd0: rd_data_mux = bank0_rd;
            2'd1: rd_data_mux = bank1_rd;
            2'd2: rd_data_mux = bank2_rd;
            2'd3: rd_data_mux = bank3_rd;
        endcase
    end

    // 输出寄存 (1拍延迟)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_data <= 16'd0;
        else
            rd_data <= rd_data_mux;
    end

endmodule
