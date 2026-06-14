#include <verilated.h>
#include "Vlfnst_matrix_rom.h"
#include "lfnst_matrix_golden.h"
#include <cstdio>
#include <cstdint>

vluint64_t sim_time = 0;
double sc_time_stamp() { return (double)sim_time; }

struct LfnstCombo {
    int nTrs;      // 16 or 48
    int sel_set;   // 0-3
    int sel_idx;   // 1 or 2
    const int8_t* golden; // flat [row][col], row-major
};

static const LfnstCombo COMBOS[] = {
    {16, 0, 1, &GOLDEN_LFNST_16_SET0_IDX1[0][0]},
    {16, 0, 2, &GOLDEN_LFNST_16_SET0_IDX2[0][0]},
    {16, 1, 1, &GOLDEN_LFNST_16_SET1_IDX1[0][0]},
    {16, 1, 2, &GOLDEN_LFNST_16_SET1_IDX2[0][0]},
    {16, 2, 1, &GOLDEN_LFNST_16_SET2_IDX1[0][0]},
    {16, 2, 2, &GOLDEN_LFNST_16_SET2_IDX2[0][0]},
    {16, 3, 1, &GOLDEN_LFNST_16_SET3_IDX1[0][0]},
    {16, 3, 2, &GOLDEN_LFNST_16_SET3_IDX2[0][0]},
    {48, 0, 1, &GOLDEN_LFNST_48_SET0_IDX1[0][0]},
    {48, 0, 2, &GOLDEN_LFNST_48_SET0_IDX2[0][0]},
    {48, 1, 1, &GOLDEN_LFNST_48_SET1_IDX1[0][0]},
    {48, 1, 2, &GOLDEN_LFNST_48_SET1_IDX2[0][0]},
    {48, 2, 1, &GOLDEN_LFNST_48_SET2_IDX1[0][0]},
    {48, 2, 2, &GOLDEN_LFNST_48_SET2_IDX2[0][0]},
    {48, 3, 1, &GOLDEN_LFNST_48_SET3_IDX1[0][0]},
    {48, 3, 2, &GOLDEN_LFNST_48_SET3_IDX2[0][0]},
};
static const int NUM_COMBOS = sizeof(COMBOS) / sizeof(COMBOS[0]);

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vlfnst_matrix_rom* rom = new Vlfnst_matrix_rom;

    int total = 0, passed = 0, failed = 0;

    for (int ci = 0; ci < NUM_COMBOS; ci++) {
        int nTrs    = COMBOS[ci].nTrs;
        int sel_set = COMBOS[ci].sel_set;
        int sel_idx = COMBOS[ci].sel_idx;
        const int8_t* golden = COMBOS[ci].golden;

        int combo_fails = 0;
        int num_rows = nTrs;
        int num_cols = 16;

        for (int row = 0; row < num_rows; row++) {
            for (int col = 0; col < num_cols; col++) {
                // Set inputs on negedge
                rom->clk = 0;
                rom->sel_nTrs = (nTrs == 48) ? 1 : 0;
                rom->sel_set  = sel_set;
                rom->sel_idx  = (sel_idx == 1) ? 0 : 1; // idx1→0, idx2→1
                rom->rd_addr  = row;
                rom->rd_col   = col;
                rom->eval();

                // Rising edge: latch data
                rom->clk = 1;
                rom->eval();

                int8_t rtl_val  = (int8_t)rom->rd_data;
                // Golden layout: [row][col], flat index = row*num_cols + col
                int8_t expected = golden[row * num_cols + col];

                total++;
                if (rtl_val != expected) {
                    if (combo_fails < 5) {
                        printf("  MISMATCH nTrs=%d set=%d idx=%d [%d][%d]: RTL=%d expected=%d\n",
                               nTrs, sel_set, sel_idx, row, col, rtl_val, expected);
                    }
                    combo_fails++;
                    failed++;
                } else {
                    passed++;
                }
            }
        }

        if (combo_fails == 0) {
            printf("[nTrs=%2d set=%d idx=%d] PASS (%d values)\n",
                   nTrs, sel_set, sel_idx, num_rows * num_cols);
        } else {
            printf("[nTrs=%2d set=%d idx=%d] FAIL (%d mismatches out of %d)\n",
                   nTrs, sel_set, sel_idx, combo_fails, num_rows * num_cols);
        }
    }

    printf("\n=== LFNST ROM Test Summary ===\n");
    printf("Total: %d, Passed: %d, Failed: %d\n", total, passed, failed);
    if (failed == 0) {
        printf("ALL LFNST ROM TESTS PASSED!\n");
    }

    delete rom;
    return (failed == 0) ? 0 : 1;
}
