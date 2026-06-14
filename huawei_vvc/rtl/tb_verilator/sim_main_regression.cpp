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
        // Skip whitespace-only lines
        char* p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\n' || *p == '\r' || *p == 0) continue;
        uint64_t val = strtoull(p, nullptr, 16);
        sc.expected_packed.push_back(val);
    }
    fclose(f);
    return true;
}

// Verilator 5.x signal access macros
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

int run_case(Vits_top* dut, VerilatedVcdC* trace, const StimCase& sc, int max_cycles) {
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
    int total_pixels = sc.width * sc.height;
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

    // Collect output
    std::vector<uint64_t> packed_out;
    for (int i = 0; i < max_cycles; i++) {
        dut->CLK = 1; dut->eval(); trace->dump(sim_time); sim_time++;

        if (dut->it_data_out_vld && packed_out.size() < sc.expected_packed.size()) {
            packed_out.push_back((uint64_t)dut->it_data_out);
        }
        if (dut->it_done) break;

        dut->CLK = 0; dut->eval(); trace->dump(sim_time); sim_time++;
    }

    // Compare
    if (packed_out.size() != sc.expected_packed.size()) {
        printf("  FAIL: got %zu output groups, expected %zu\n",
            packed_out.size(), sc.expected_packed.size());
        return 1;
    }
    for (size_t i = 0; i < packed_out.size(); i++) {
        if (packed_out[i] != sc.expected_packed[i]) {
            printf("  FAIL group %zu: got %010llx expected %010llx\n",
                i, (unsigned long long)packed_out[i], (unsigned long long)sc.expected_packed[i]);
            return 1;
        }
    }
    return 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    // Read case index
    const char* index_path = "regression_stim/case_index.txt";
    FILE* idx = fopen(index_path, "r");
    if (!idx) {
        printf("ERROR: Cannot open %s\n", index_path);
        printf("Run gen_regression_stim.py first.\n");
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
    printf("Found %zu regression cases\n", entries.size());

    Vits_top* dut = new Vits_top;
    VerilatedVcdC* trace = new VerilatedVcdC;
    dut->trace(trace, 99);
    trace->open("regression.vcd");

    int total = 0, passed = 0, failed = 0;

    for (auto& entry : entries) {
        char stim_path[512];
        snprintf(stim_path, sizeof(stim_path), "regression_stim/%s", entry.stim);

        StimCase sc;
        sc.id = entry.id;
        sc.name = entry.name;
        if (!read_stim(stim_path, sc)) {
            printf("[%04d] %s: SKIP (cannot read stim)\n", entry.id, entry.name);
            continue;
        }

        // Reset and run (don't reset sim_time — keep monotonic for VCD)
        reset_dut(dut, trace, 10);

        printf("[%04d] %s (%dx%d): ", entry.id, entry.name, entry.w, entry.h);
        fflush(stdout);

        int result = run_case(dut, trace, sc, 500000);
        total++;
        if (result == 0) {
            printf("PASS\n");
            passed++;
        } else {
            failed++;
        }
    }

    printf("\n=== Regression Summary ===\n");
    printf("Total: %d, Passed: %d, Failed: %d\n", total, passed, failed);
    if (failed == 0 && total > 0) {
        printf("ALL CASES PASSED!\n");
    }

    trace->close(); delete trace; delete dut;
    return (failed == 0) ? 0 : 1;
}
