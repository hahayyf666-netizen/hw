//===========================================================================
// dct2_1d.v - DCT2 1D反变换 (优化版)
//===========================================================================

/* verilator lint_off UNUSEDSIGNAL */

module dct2_1d (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         out_valid,
    input  wire [6:0]  length,
    input  wire [4:0]  shift,
    input  wire        clip_en,
    input  wire [5:0]  clip_bits,
    input  wire [1023:0] coeff_in,           // 64x16 flattened coefficient bus
    output reg  [31:0] result_out0,
    output reg  [31:0] result_out1,
    output reg  [31:0] result_out2,
    output reg  [31:0] result_out3
);

    localparam IDLE    = 3'd0;
    localparam COMPUTE = 3'd1;
    localparam SHIFT   = 3'd2;  // Pipeline stage: register shift results
    localparam OUTPUT  = 3'd3;

    reg [2:0]  state;
    reg [6:0]  row_base;
    reg [6:0]  col_cnt;
    reg [31:0] acc [0:3];

    // Stage 1: ROM read + coefficient mux (combinational)
    wire [7:0] matrix_data [0:3];

    trans_matrix_rom u_matrix_rom_0 (
        .clk(clk), .tr_type(2'd0), .length(length),
        .row_addr(row_base), .col_addr(col_cnt),
        .rd_data(matrix_data[0])
    );
    trans_matrix_rom u_matrix_rom_1 (
        .clk(clk), .tr_type(2'd0), .length(length),
        .row_addr(row_base + 7'd1), .col_addr(col_cnt),
        .rd_data(matrix_data[1])
    );
    trans_matrix_rom u_matrix_rom_2 (
        .clk(clk), .tr_type(2'd0), .length(length),
        .row_addr(row_base + 7'd2), .col_addr(col_cnt),
        .rd_data(matrix_data[2])
    );
    trans_matrix_rom u_matrix_rom_3 (
        .clk(clk), .tr_type(2'd0), .length(length),
        .row_addr(row_base + 7'd3), .col_addr(col_cnt),
        .rd_data(matrix_data[3])
    );

    wire [5:0] coeff_idx = col_cnt[5:0];
    wire signed [15:0] signed_coeff = $signed(coeff_in[coeff_idx*16 +: 16]);

    // Stage 2: registered ROM/coeff → MAC (pipeline register)
    reg        mac_valid;
    reg signed [7:0]  matrix_data_reg [0:3];
    reg signed [15:0] coeff_reg;

    // MAC uses registered values (Stage 2)
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : parallel_mac
            wire signed [23:0] mult_result = coeff_reg * matrix_data_reg[i];
            wire signed [31:0] mult_ext = {{8{mult_result[23]}}, mult_result};
            wire signed [31:0] signed_acc = $signed(acc[i]) + mult_ext;
        end
    endgenerate

    //===========================================================================
    // 舍入右移和限幅实例 (4路)
    // shifted_result 从 acc[i] 组合逻辑输出
    // shifted_result_reg 在 SHIFT 状态寄存，截断桶形移位器关键路径
    //===========================================================================
    wire [31:0] shifted_result [0:3];
    wire [31:0] clipped_result [0:3];
    reg  [31:0] shifted_result_reg [0:3];

    generate
        for (i = 0; i < 4; i = i + 1) begin : clip_shift_gen
            round_shift u_round_shift (
                .in_data(acc[i]), .shift(shift), .out_data(shifted_result[i])
            );
            clip u_clip (
                .in_data(shifted_result_reg[i]), .clip_en(clip_en),
                .clip_bits(clip_bits), .out_data(clipped_result[i])
            );
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; done <= 1'b0; out_valid <= 1'b0;
            row_base <= 7'd0; col_cnt <= 7'd0;
            mac_valid <= 1'b0;
            acc[0] <= 32'd0; acc[1] <= 32'd0; acc[2] <= 32'd0; acc[3] <= 32'd0;
            result_out0 <= 32'd0; result_out1 <= 32'd0;
            result_out2 <= 32'd0; result_out3 <= 32'd0;
            shifted_result_reg[0] <= 32'd0; shifted_result_reg[1] <= 32'd0;
            shifted_result_reg[2] <= 32'd0; shifted_result_reg[3] <= 32'd0;
            matrix_data_reg[0] <= 8'sd0; matrix_data_reg[1] <= 8'sd0;
            matrix_data_reg[2] <= 8'sd0; matrix_data_reg[3] <= 8'sd0;
            coeff_reg <= 16'sd0;
        end else begin
            done <= 1'b0; out_valid <= 1'b0;
            case (state)
                IDLE: begin
                    if (start) begin
                        state <= COMPUTE; row_base <= 7'd0; col_cnt <= 7'd0;
                        mac_valid <= 1'b0;
                        acc[0] <= 32'd0; acc[1] <= 32'd0;
                        acc[2] <= 32'd0; acc[3] <= 32'd0;
                    end
                end
                COMPUTE: begin
                    // Stage 1 → Stage 2 register: latch ROM + coeff
                    matrix_data_reg[0] <= $signed(matrix_data[0]);
                    matrix_data_reg[1] <= $signed(matrix_data[1]);
                    matrix_data_reg[2] <= $signed(matrix_data[2]);
                    matrix_data_reg[3] <= $signed(matrix_data[3]);
                    coeff_reg <= signed_coeff;
                    mac_valid <= 1'b1;
                    col_cnt <= col_cnt + 1'b1;

                    // Stage 2: MAC with registered values (1 cycle delayed)
                    if (mac_valid) begin
                        acc[0] <= parallel_mac[0].signed_acc;
                        acc[1] <= parallel_mac[1].signed_acc;
                        acc[2] <= parallel_mac[2].signed_acc;
                        acc[3] <= parallel_mac[3].signed_acc;
                        // Last MAC cycle: acc will have final value next cycle
                        if (col_cnt >= length) begin
                            state <= SHIFT;
                        end
                    end
                end
                SHIFT: begin
                    // acc[i] now has the final MAC result (updated last cycle)
                    // Register shifted_result to break barrel shifter critical path
                    shifted_result_reg[0] <= shifted_result[0];
                    shifted_result_reg[1] <= shifted_result[1];
                    shifted_result_reg[2] <= shifted_result[2];
                    shifted_result_reg[3] <= shifted_result[3];
                    done <= 1'b1;
                    state <= OUTPUT;
                end
                OUTPUT: begin
                    out_valid <= 1'b1;
                    result_out0 <= clip_en ? clipped_result[0] : shifted_result_reg[0];
                    result_out1 <= clip_en ? clipped_result[1] : shifted_result_reg[1];
                    result_out2 <= clip_en ? clipped_result[2] : shifted_result_reg[2];
                    result_out3 <= clip_en ? clipped_result[3] : shifted_result_reg[3];
                    row_base <= row_base + 4; col_cnt <= 7'd0;
                    mac_valid <= 1'b0;
                    acc[0] <= 32'd0; acc[1] <= 32'd0;
                    acc[2] <= 32'd0; acc[3] <= 32'd0;
                    if (row_base >= length - 4) begin
                        done <= 1'b1; state <= IDLE;
                    end else state <= COMPUTE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
