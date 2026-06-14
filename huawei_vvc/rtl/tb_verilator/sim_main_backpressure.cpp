//===========================================================================
// sim_main_backpressure.cpp - 输出反压测试
// 功能: 在输出阶段随机拉低 it_data_out_req，验证:
//   1. req=0 时 vld 不应为 1
//   2. req=1 时输出数据顺序和内容与 golden 完全一致
//   3. 总输出组数不变
//===========================================================================
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vits_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <cstdint>

vluint64_t sim_time = 0;
double sc_time_stamp() { return (double)sim_time; }

struct StimCase {
    int id;
    std::string name;
    int width, height;
    int tr_hor, tr_ver;
    int lfnst_idx, lfnst_set;
    std::vector<std::pair<int,int>> sparse_input;
    std::vector<uint64_t> expected_packed;
};

bool read_stim(const char* path, StimCase& sc) {
    FILE* f = fopen(path, "r");
    if (!f) return false;
    if (fscanf(f, "%d %d %d %d %d %d",
        &sc.width, &sc.height, &sc.tr_hor, &sc.tr_ver,
        &sc.lfnst_idx, &sc.lfnst_set) != 6) { fclose(f); return false; }
    int n_sparse;
    if (fscanf(f, "%d", &n_sparse) != 1) { fclose(f); return false; }
    sc.sparse_input.clear();
    for (int i = 0; i < n_sparse; i++) {
        int addr, val;
        if (fscanf(f, "%d %d", &addr, &val) != 2) { fclose(f); return false; }
        sc.sparse_input.push_back({addr, val});
    }
    sc.expected_packed.clear();
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char* p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\n' || *p == '\r' || *p == 0) continue;
        uint64_t val = strtoull(p, nullptr, 16);
        sc.expected_packed.push_back(val);
    }
    fclose(f);
    return true;
}

#define CLK     clk
#define RST_N   rst_n

void reset_dut(Vits_top* dut, VerilatedVcdC* trace, int cycles) {
    dut->CLK = 0;
    dut->RST_N = 0;
    dut->it_info = 0;
    dut->it_info_vld = 0;
    dut->it_data_in_vld = 0;
    dut->it_data_addr = 0;
    dut->it_data_in = 0;
    dut->it_data_end = 0;
    dut->it_data_out_req = 1;
    for (int i = 0; i < cycles; i++) {
        dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
        dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
    }
    dut->RST_N = 1;
    for (int i = 0; i < 5; i++) {
        dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
        dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
    }
}

// PRNG for backpressure pattern
static uint32_t bp_rng = 0x12345678;
uint32_t bp_rand() {
    bp_rng ^= bp_rng << 13;
    bp_rng ^= bp_rng >> 17;
    bp_rng ^= bp_rng << 5;
    return bp_rng;
}

int run_case_with_backpressure(Vits_top* dut, VerilatedVcdC* trace,
                                const StimCase& sc, int max_cycles,
                                int bp_mode) {
    // Send config
    uint32_t it_info = ((uint32_t)sc.width << 0) |
                       ((uint32_t)sc.height << 7) |
                       ((uint32_t)sc.tr_hor << 14) |
                       ((uint32_t)sc.tr_ver << 16) |
                       ((uint32_t)sc.lfnst_set << 18) |
                       ((uint32_t)sc.lfnst_idx << 20);
    dut->it_info = it_info;
    dut->it_info_vld = 1;
    dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
    dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
    dut->it_info_vld = 0;
    dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
    dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;

    // Wait for it_data_in_req
    for (int i = 0; i < 5000; i++) {
        dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
        dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
        if (dut->it_data_in_req) break;
    }

    // Send sparse input
    for (int i = 0; i < (int)sc.sparse_input.size(); i++) {
        int addr = sc.sparse_input[i].first;
        int val = sc.sparse_input[i].second;
        dut->it_data_in_vld = 1;
        dut->it_data_addr = addr;
        dut->it_data_in = (uint16_t)val;
        dut->it_data_end = (i == (int)sc.sparse_input.size() - 1) ? 1 : 0;
        dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
        dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
    }
    dut->it_data_in_vld = 0;
    dut->it_data_end = 0;

    // Collect output WITH backpressure
    std::vector<uint64_t> packed_out;
    int bp_counter = 0;
    int bp_hold_cycles = 0;
    int req_was_1 = 1;

    for (int i = 0; i < max_cycles; i++) {
        // Generate backpressure pattern
        int req;
        switch (bp_mode) {
            case 0: // Periodic: 3 cycles req=1, 2 cycles req=0
                req = (bp_counter % 5 < 3) ? 1 : 0;
                break;
            case 1: // Random ~50% backpressure
                req = (bp_rand() & 1) ? 1 : 0;
                break;
            case 2: // Random ~25% backpressure (mostly ready)
                req = (bp_rand() % 4 != 0) ? 1 : 0;
                break;
            case 3: // Heavy: 1 cycle req=1, 4 cycles req=0
                req = (bp_counter % 5 == 0) ? 1 : 0;
                break;
            default:
                req = 1;
                break;
        }
        dut->it_data_out_req = req;
        bp_counter++;

        // Rising edge
        dut->CLK = 1; dut->eval(); trace->dump(sim_time); sim_time++;

        // Check protocol: vld should only be high when req is high
        if (dut->it_data_out_vld && !dut->it_data_out_req) {
            printf("\n  PROTOCOL VIOLATION: vld=1 while req=0 at cycle %d\n", i);
            return 2;
        }

        // Sample output only when both vld and req are high
        if (dut->it_data_out_vld && dut->it_data_out_req &&
            packed_out.size() < sc.expected_packed.size()) {
            packed_out.push_back((uint64_t)dut->it_data_out);
        }

        if (dut->it_done) break;

        // Falling edge
        dut->CLK = 0; dut->eval(); trace->dump(sim_time); sim_time++;
    }

    // Compare
    if (packed_out.size() != sc.expected_packed.size()) {
        printf("\n  FAIL: got %zu output groups, expected %zu\n",
            packed_out.size(), sc.expected_packed.size());
        return 1;
    }
    for (size_t i = 0; i < packed_out.size(); i++) {
        if (packed_out[i] != sc.expected_packed[i]) {
            printf("\n  FAIL group %zu: got %010llx expected %010llx\n",
                i, (unsigned long long)packed_out[i], (unsigned long long)sc.expected_packed[i]);
            return 1;
        }
    }
    return 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    const char* index_path = "regression_stim/case_index.txt";
    FILE* idx = fopen(index_path, "r");
    if (!idx) {
        printf("ERROR: Cannot open %s\n", index_path);
        return 1;
    }

    struct CaseEntry { int id; char name[256]; int w, h, groups; char stim[256]; };
    std::vector<CaseEntry> entries;
    while (!feof(idx)) {
        CaseEntry ce;
        if (fscanf(idx, "%d %s %d %d %d %s", &ce.id, ce.name, &ce.w, &ce.h, &ce.groups, ce.stim) == 6) {
            entries.push_back(ce);
        }
    }
    fclose(idx);

    // Select a subset for backpressure testing (diverse sizes/types)
    // Test every 50th case + first 5 + last 5 = ~38 cases x 4 modes = ~152 tests
    std::vector<CaseEntry> selected;
    for (int i = 0; i < 5 && i < (int)entries.size(); i++)
        selected.push_back(entries[i]);
    for (int i = 50; i < (int)entries.size(); i += 50)
        selected.push_back(entries[i]);
    for (int i = (int)entries.size() - 5; i < (int)entries.size(); i++)
        if (i >= 5) selected.push_back(entries[i]);

    // Deduplicate by id
    std::vector<CaseEntry> unique;
    std::vector<bool> seen(entries.size(), false);
    for (auto& sel : selected) {
        for (size_t j = 0; j < entries.size(); j++) {
            if (entries[j].id == sel.id && !seen[j]) {
                unique.push_back(entries[j]);
                seen[j] = true;
            }
        }
    }
    selected = unique;

    const char* bp_names[] = {"periodic_3on2off", "random_50pct", "random_75pct", "heavy_1on4off"};
    printf("Backpressure test: %zu cases x 4 modes = %zu tests\n",
        selected.size(), selected.size() * 4);

    Vits_top* dut = new Vits_top;
    VerilatedVcdC* trace = new VerilatedVcdC;
    dut->trace(trace, 99);
    trace->open("backpressure.vcd");

    int total = 0, passed = 0, failed = 0, protocol_err = 0;

    for (auto& entry : selected) {
        char stim_path[512];
        snprintf(stim_path, sizeof(stim_path), "regression_stim/%s", entry.stim);

        StimCase sc;
        sc.id = entry.id;
        sc.name = entry.name;
        if (!read_stim(stim_path, sc)) continue;

        for (int mode = 0; mode < 4; mode++) {
            bp_rng = 0x12345678 + mode * 1000 + entry.id;  // deterministic seed

            reset_dut(dut, trace, 10);

            printf("[%04d] %s bp=%s: ", entry.id, entry.name, bp_names[mode]);
            fflush(stdout);

            int result = run_case_with_backpressure(dut, trace, sc, 500000, mode);
            total++;
            if (result == 0) {
                printf("PASS");
                passed++;
            } else if (result == 2) {
                printf("PROTOCOL_ERR");
                protocol_err++;
                failed++;
            } else {
                printf("FAIL");
                failed++;
            }
            printf("\n");
        }
    }

    printf("\n=== Backpressure Test Summary ===\n");
    printf("Total: %d, Passed: %d, Failed: %d (protocol_err: %d)\n",
        total, passed, failed, protocol_err);
    if (failed == 0 && total > 0) {
        printf("ALL BACKPRESSURE TESTS PASSED!\n");
    }

    trace->close(); delete trace; delete dut;
    return (failed == 0) ? 0 : 1;
}
