// Minimal wrapper for trans_matrix_rom unit test
module rom_test_top (
    input  wire        clk,
    input  wire [1:0]  tr_type,
    input  wire [6:0]  length,
    input  wire [6:0]  row_addr,
    input  wire [6:0]  col_addr,
    output wire [7:0]  rd_data
);

    trans_matrix_rom u_rom (
        .clk      (clk),
        .tr_type  (tr_type),
        .length   (length),
        .row_addr (row_addr),
        .col_addr (col_addr),
        .rd_data  (rd_data)
    );

endmodule
