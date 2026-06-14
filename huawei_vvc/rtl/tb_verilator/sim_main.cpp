#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vits_top.h"
#include "Vits_top___024root.h"

vluint64_t sim_time = 0;

double sc_time_stamp() { return (double)sim_time; }

void tick(Vits_top* dut, VerilatedVcdC* trace) {
    dut->eval();
    trace->dump(sim_time);
    sim_time++;
}

// Golden data: 4x4 DCT2xDCT2 lfnst0 test case 000
// Input: [-128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 103, 0, 23, 127]
// Expected output (10-bit signed, raster order):
//   Row 0: 0, -11, 3, -8
//   Row 1: -10, 6, -14, 2
//   Row 2: -2, -6, -2, -6
//   Row 3: -4, -6, -2, -4
// Expected packed output:
//   FE003FD400, 00BF201BF6, FEBFEFEBFE, FF3FEFEBFC

static const int16_t INPUT_DATA[16] = {
    -128, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  103, 0, 23, 127
};

static const int EXPECTED_OUT[16] = {
    -1, -5, 0, -3,  -12, -1, -14, -6,  4, -7, 6, -2,  -7, -3, -8, -5
};

static const uint64_t EXPECTED_PACKED[4] = {
    0xFF400FEFFFULL,
    0xFEBF2FFFF4ULL,
    0xFF806FE404ULL,
    0xFEFF8FF7F9ULL
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Vits_top* dut = new Vits_top;
    VerilatedVcdC* trace = new VerilatedVcdC;
    dut->trace(trace, 99);
    trace->open("waveform.vcd");

    dut->clk = 0;
    dut->rst_n = 0;
    dut->it_info = 0;
    dut->it_info_vld = 0;
    dut->it_data_in_vld = 0;
    dut->it_data_addr = 0;
    dut->it_data_in = 0;
    dut->it_data_end = 0;
    dut->it_data_out_req = 1;

    // Reset
    for (int i = 0; i < 20; i++) {
        dut->clk = !dut->clk;
        if (i == 5) dut->rst_n = 1;
        tick(dut, trace);
    }

    // Send config: 4x4, DCT2xDCT2, lfnst0
    // it_info[6:0]=4, [13:7]=4, [15:14]=0, [17:16]=0, [19:18]=0, [21:20]=0
    dut->it_info = (4 << 0) | (4 << 7) | (0 << 14) | (0 << 16) | (0 << 18) | (0 << 20);
    dut->it_info_vld = 1;
    dut->clk = !dut->clk; tick(dut, trace);  // negedge
    dut->clk = !dut->clk; tick(dut, trace);  // posedge: config_decode samples
    dut->it_info_vld = 0;
    dut->clk = !dut->clk; tick(dut, trace);  // negedge
    dut->clk = !dut->clk; tick(dut, trace);  // posedge: cfg_valid clears

    // Wait for it_data_in_req
    for (int i = 0; i < 5000; i++) {
        dut->clk = !dut->clk; tick(dut, trace);
        if (dut->it_data_in_req) break;
    }
    printf("  Data input starting at cycle %lu\n", sim_time/2);

    // Send all 16 input values (raster order)
    for (int i = 0; i < 16; i++) {
        dut->it_data_in_vld = (INPUT_DATA[i] != 0) ? 1 : 0;
        dut->it_data_addr = i;
        dut->it_data_in = (uint16_t)INPUT_DATA[i];
        dut->it_data_end = (i == 15) ? 1 : 0;
        dut->clk = !dut->clk; tick(dut, trace);  // negedge
        dut->clk = !dut->clk; tick(dut, trace);  // posedge: FSM samples
    }
    dut->it_data_in_vld = 0;
    dut->it_data_end = 0;

    // Wait for output and collect results
    int out_cnt = 0;
    int last_stage = -1;
    uint64_t packed_out[4] = {0};
    int out_idx = 0;

    for (int i = 0; i < 200000; i++) {
        dut->clk = !dut->clk; tick(dut, trace);
        int st = dut->debug_stage;
        int fsm_st = (int)dut->debug_state & 0xF;

        if (st != last_stage) {
            printf("  Stage -> %d at cycle %lu (fsm=%d)\n", st, sim_time/2, fsm_st);
            last_stage = st;
        }

        if (dut->it_data_out_vld && dut->clk && out_idx < 4) {
            packed_out[out_idx] = (uint64_t)dut->it_data_out;
            printf("  Output[%d]: %010llx (expected %010llx)\n",
                out_idx, (unsigned long long)packed_out[out_idx],
                (unsigned long long)EXPECTED_PACKED[out_idx]);

            // Decode 10-bit signed values
            for (int p = 0; p < 4; p++) {
                int raw = (packed_out[out_idx] >> (p * 10)) & 0x3FF;
                int signed_val = (raw >= 512) ? (raw - 1024) : raw;
                int global_idx = out_idx * 4 + p;
                int exp_val = EXPECTED_OUT[global_idx];
                const char* match = (signed_val == exp_val) ? "OK" : "MISMATCH";
                printf("    pixel[%d] = %d (expected %d) %s\n",
                    global_idx, signed_val, exp_val, match);
            }
            out_idx++;
            out_cnt++;
        }

        if (dut->it_done) {
            printf("  Done at cycle %lu\n", sim_time/2);
            break;
        }
    }

    printf("\nTotal output groups: %d\n", out_cnt);
    if (out_cnt == 4) {
        printf("All 4 groups received.\n");
        // Check packed output
        int all_match = 1;
        for (int i = 0; i < 4; i++) {
            if (packed_out[i] != EXPECTED_PACKED[i]) {
                printf("  Packed[%d] MISMATCH: got %010llx expected %010llx\n",
                    i, (unsigned long long)packed_out[i], (unsigned long long)EXPECTED_PACKED[i]);
                all_match = 0;
            }
        }
        if (all_match) printf("ALL PACKED OUTPUT MATCHES GOLDEN DATA!\n");
        else printf("PACKED OUTPUT MISMATCH - see above.\n");
    }

    trace->close(); delete trace; delete dut;
    return 0;
}
