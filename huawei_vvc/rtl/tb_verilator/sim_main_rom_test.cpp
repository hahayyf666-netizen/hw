#include <verilated.h>
#include "Vtrans_matrix_rom.h"
#include "trans_matrix_golden.h"
#include <cstdio>
#include <cstdint>

vluint64_t sim_time = 0;
double sc_time_stamp() { return (double)sim_time; }

struct MatrixCombo {
    int tr_type;
    int length;
    const int8_t* golden; // flat [out][in], row-major
};

static const MatrixCombo COMBOS[] = {
    {0,  4, &GOLDEN_DCT2_4[0][0]},
    {0,  8, &GOLDEN_DCT2_8[0][0]},
    {0, 16, &GOLDEN_DCT2_16[0][0]},
    {0, 32, &GOLDEN_DCT2_32[0][0]},
    {0, 64, &GOLDEN_DCT2_64[0][0]},
    {1,  4, &GOLDEN_DST7_4[0][0]},
    {1,  8, &GOLDEN_DST7_8[0][0]},
    {1, 16, &GOLDEN_DST7_16[0][0]},
    {1, 32, &GOLDEN_DST7_32[0][0]},
    {2,  4, &GOLDEN_DCT8_4[0][0]},
    {2,  8, &GOLDEN_DCT8_8[0][0]},
    {2, 16, &GOLDEN_DCT8_16[0][0]},
    {2, 32, &GOLDEN_DCT8_32[0][0]},
};
static const int NUM_COMBOS = sizeof(COMBOS) / sizeof(COMBOS[0]);

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vtrans_matrix_rom* rom = new Vtrans_matrix_rom;

    int total = 0, passed = 0, failed = 0;

    for (int ci = 0; ci < NUM_COMBOS; ci++) {
        int tr_type = COMBOS[ci].tr_type;
        int length  = COMBOS[ci].length;
        const int8_t* golden = COMBOS[ci].golden;

        int combo_fails = 0;
        for (int col = 0; col < length; col++) {
            for (int row = 0; row < length; row++) {
                rom->tr_type  = tr_type;
                rom->length   = length;
                rom->row_addr = row;
                rom->col_addr = col;
                rom->eval();

                int8_t rtl_val  = (int8_t)rom->rd_data;
                // Golden layout: [out][in] = [row][col], flat index = row*length + col
                // But ROM stores [col][row] directly from TRANS_MATRIX[col][row]
                // So golden[col][row] is the expected value
                int8_t expected = golden[col * length + row];

                total++;
                if (rtl_val != expected) {
                    if (combo_fails < 5) {
                        const char* tn = (tr_type == 0) ? "DCT2" : (tr_type == 1) ? "DST7" : "DCT8";
                        printf("  MISMATCH %s_%d [%d][%d]: RTL=%d expected=%d\n",
                               tn, length, col, row, rtl_val, expected);
                    }
                    combo_fails++;
                    failed++;
                } else {
                    passed++;
                }
            }
        }

        const char* type_name = (tr_type == 0) ? "DCT2" : (tr_type == 1) ? "DST7" : "DCT8";
        if (combo_fails == 0) {
            printf("[%s %2d] PASS (%d values)\n", type_name, length, length * length);
        } else {
            printf("[%s %2d] FAIL (%d mismatches out of %d)\n",
                   type_name, length, combo_fails, length * length);
        }
    }

    printf("\n=== ROM Test Summary ===\n");
    printf("Total: %d, Passed: %d, Failed: %d\n", total, passed, failed);
    if (failed == 0) {
        printf("ALL ROM TESTS PASSED!\n");
    }

    delete rom;
    return (failed == 0) ? 0 : 1;
}
