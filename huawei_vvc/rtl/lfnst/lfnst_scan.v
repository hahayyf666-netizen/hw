//===========================================================================
// lfnst_scan.v - LFNST低频扫描地址生成
// 功能: 生成对角线扫描顺序的地址
// 扫描顺序: (0,0), (1,0), (0,1), (2,0), (1,1), (0,2), ...
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module lfnst_scan (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_en,
    input  wire [6:0]  tu_width,
    input  wire [6:0]  tu_height,
    input  wire [6:0]  nonZeroSize,  // 8或16
    input  wire [6:0]  scan_cnt,     // 当前扫描计数
    output reg  [11:0] scan_addr,    // 扫描地址输出
    output reg         scan_valid    // 地址有效
);

    //===========================================================================
    // 对角线扫描生成
    // 坐标顺序: (0,0), (1,0), (0,1), (2,0), (1,1), (0,2), ...
    //===========================================================================

    // 根据scan_cnt计算对角线索引
    // 使用公式直接计算，避免复杂循环

    reg [3:0] scan_x;  // 列坐标
    reg [3:0] scan_y;  // 行坐标
    reg [4:0] diag_idx; // 对角线索引
    reg [3:0] pos_in_diag; // 在对角线中的位置

    // 计算对角线索引和位置
    // 参考模型: LOW_FREQ_COORDS = [(row,col), ...], addr = row * width + col
    // scan模块: addr = scan_y * tu_width + scan_x
    // 所以 scan_y = row, scan_x = col
    always @(*) begin
        case (scan_cnt)
            // (row, col) from LOW_FREQ_COORDS_4x4
            7'd0:  begin scan_x = 4'd0; scan_y = 4'd0; end  // (0,0)
            7'd1:  begin scan_x = 4'd0; scan_y = 4'd1; end  // (1,0)
            7'd2:  begin scan_x = 4'd1; scan_y = 4'd0; end  // (0,1)
            7'd3:  begin scan_x = 4'd0; scan_y = 4'd2; end  // (2,0)
            7'd4:  begin scan_x = 4'd1; scan_y = 4'd1; end  // (1,1)
            7'd5:  begin scan_x = 4'd2; scan_y = 4'd0; end  // (0,2)
            7'd6:  begin scan_x = 4'd0; scan_y = 4'd3; end  // (3,0)
            7'd7:  begin scan_x = 4'd1; scan_y = 4'd2; end  // (2,1)
            // nonZeroSize=16 extended points
            7'd8:  begin scan_x = 4'd2; scan_y = 4'd1; end  // (1,2)
            7'd9:  begin scan_x = 4'd3; scan_y = 4'd0; end  // (0,3)
            7'd10: begin scan_x = 4'd1; scan_y = 4'd3; end  // (3,1)
            7'd11: begin scan_x = 4'd2; scan_y = 4'd2; end  // (2,2)
            7'd12: begin scan_x = 4'd3; scan_y = 4'd1; end  // (1,3)
            7'd13: begin scan_x = 4'd2; scan_y = 4'd3; end  // (3,2)
            7'd14: begin scan_x = 4'd3; scan_y = 4'd2; end  // (2,3)
            7'd15: begin scan_x = 4'd3; scan_y = 4'd3; end  // (3,3)
            default: begin scan_x = 4'd0; scan_y = 4'd0; end
        endcase
    end

    //===========================================================================
    // 地址计算: addr = row * tu_width + col
    //===========================================================================
    wire [11:0] scan_x_ext = {8'd0, scan_x};
    wire [11:0] scan_y_ext = {8'd0, scan_y};
    wire [11:0] scan_addr_calc = scan_y_ext * {5'd0, tu_width} + scan_x_ext;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_addr <= 12'd0;
            scan_valid <= 1'b0;
        end else if (scan_en) begin
            scan_addr <= scan_addr_calc;
            // 3 extra cycles for pipeline warm-up (addr ROM delay + TU buffer 2-cycle delay)
            // Need: nonZeroSize+3 posedges with scan_valid=1 (3 warm-up + nonZeroSize captures)
            // cnt goes 0..nonZeroSize+2 (inclusive), so condition: cnt <= nonZeroSize+2
            scan_valid <= (scan_cnt <= nonZeroSize + 7'd3);
        end else begin
            scan_valid <= 1'b0;
        end
    end

endmodule
