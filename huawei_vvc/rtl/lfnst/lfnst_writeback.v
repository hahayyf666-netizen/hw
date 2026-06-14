//===========================================================================
// lfnst_writeback.v - LFNST写回地址生成 (2-stage pipeline)
// 功能: 支持nTrs=16/48的写回区域生成
//   nTrs=16: 填充左上角4x4区域
//   nTrs=48: 填充左上角8x8倒L型区域
// 流水线: Stage 1 = round+shift, Stage 2 = clip+output
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module lfnst_writeback (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wb_en,
    input  wire [6:0]  tu_width,
    input  wire [6:0]  nTrs,           // 16或48
    input  wire [6:0]  writeback_cnt,  // 写回计数
    input  wire [31:0] output_val,     // 输出值
    output reg  [11:0] wb_addr,        // 写回地址 (寄存器, 2拍延迟)
    output reg  [15:0] wb_data,        // 写回数据 (Clip16后, 寄存器, 2拍延迟)
    output reg         wb_valid,       // 写回有效 (寄存器, 2拍延迟)
    output wire        wb_ready        // 流水线空闲, 可接受新数据
);

    //===========================================================================
    // 写回地址计算 - 组合逻辑
    //===========================================================================
    reg [3:0] row;
    reg [3:0] col;

    wire [6:0] cnt_offset = writeback_cnt - 7'd32;

    always @(*) begin
        if (nTrs == 16) begin
            row = writeback_cnt[5:2];
            col = {2'b0, writeback_cnt[1:0]};
        end else begin
            if (writeback_cnt < 32) begin
                row = {1'b0, writeback_cnt[5:3]};
                col = {1'b0, writeback_cnt[2:0]};
            end else begin
                row = 4'd4 + cnt_offset[5:2];
                col = {2'b0, cnt_offset[1:0]};
            end
        end
    end

    wire [11:0] col_ext = {8'd0, col};
    wire [11:0] row_ext = {8'd0, row};
    wire [11:0] addr_calc = row_ext * {5'd0, tu_width} + col_ext;

    //===========================================================================
    // Pipeline control: accept new data only when pipeline is free
    //===========================================================================
    reg signed [31:0] rounded_val_reg;
    reg [11:0] addr_stage1;
    reg        valid_stage1;

    assign wb_ready = ~valid_stage1 & ~wb_valid;

    //===========================================================================
    // Stage 1: Round shift - (val + 64) >>> 7
    //===========================================================================
    wire signed [31:0] signed_val = $signed(output_val);
    wire signed [31:0] rounded_val = (signed_val + 32'sd64) >>> 7;

    wire stage1_en = wb_en & wb_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rounded_val_reg <= 32'd0;
            addr_stage1     <= 12'd0;
            valid_stage1    <= 1'b0;
        end else begin
            valid_stage1 <= stage1_en;
            if (stage1_en) begin
                rounded_val_reg <= rounded_val;
                addr_stage1     <= addr_calc;
            end
        end
    end

    //===========================================================================
    // Stage 2: Clip16 - clamp to [-32768, 32767]
    //===========================================================================
    reg signed [15:0] clipped_val;

    always @(*) begin
        if (rounded_val_reg < -32768)
            clipped_val = -32768;
        else if (rounded_val_reg > 32767)
            clipped_val = 32767;
        else
            clipped_val = rounded_val_reg[15:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_data  <= 16'd0;
            wb_addr  <= 12'd0;
            wb_valid <= 1'b0;
        end else begin
            wb_valid <= valid_stage1;
            if (valid_stage1) begin
                wb_data <= clipped_val;
                wb_addr <= addr_stage1;
            end
        end
    end

endmodule
