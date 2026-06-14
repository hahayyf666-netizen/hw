//===========================================================================
// sim_main_input_protocol.cpp - 输入协议验证
// 测试1: it_data_in_vld 插空验证 (sparse输入可间断)
// 测试2: it_data_end 两种时序 (同拍 / 后一拍)
// 测试3: 连续多TU不reset
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

void tick(Vits_top* dut, VerilatedVcdC* trace) {
    dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
    dut->CLK = !dut->CLK; dut->eval(); trace->dump(sim_time); sim_time++;
}

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

// PRNG
static uint32_t rng_state = 0xDEADBEEF;
uint32_t my_rand() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

//===========================================================================
// 发送配置
//===========================================================================
void send_config(Vits_top* dut, VerilatedVcdC* trace, const StimCase& sc) {
    uint32_t it_info = ((uint32_t)sc.width << 0) |
                       ((uint32_t)sc.height << 7) |
                       ((uint32_t)sc.tr_hor << 14) |
                       ((uint32_t)sc.tr_ver << 16) |
                       ((uint32_t)sc.lfnst_set << 18) |
                       ((uint32_t)sc.lfnst_idx << 20);
    dut->it_info = it_info;
    dut->it_info_vld = 1;
    tick(dut, trace);
    dut->it_info_vld = 0;
    tick(dut, trace);
}

//===========================================================================
// 等待 it_data_in_req
//===========================================================================
void wait_input_req(Vits_top* dut, VerilatedVcdC* trace, int max_cycles = 5000) {
    for (int i = 0; i < max_cycles; i++) {
        tick(dut, trace);
        if (dut->it_data_in_req) return;
        if (i == 10 || i == 100) {
            printf("  DBG wait_input_req: cycle=%d state=%d\n", i, dut->debug_state);
        }
    }
    printf("  WARN: it_data_in_req not asserted within %d cycles, state=%d\n",
           max_cycles, dut->debug_state);
}

//===========================================================================
// 发送sparse输入 (基础版: 连续送, 同拍end)
//===========================================================================
void send_sparse_basic(Vits_top* dut, VerilatedVcdC* trace, const StimCase& sc) {
    for (int i = 0; i < (int)sc.sparse_input.size(); i++) {
        dut->it_data_in_vld = 1;
        dut->it_data_addr = sc.sparse_input[i].first;
        dut->it_data_in = (uint16_t)sc.sparse_input[i].second;
        dut->it_data_end = (i == (int)sc.sparse_input.size() - 1) ? 1 : 0;
        tick(dut, trace);
    }
    dut->it_data_in_vld = 0;
    dut->it_data_end = 0;
}

//===========================================================================
// 收集输出
//===========================================================================
std::vector<uint64_t> collect_output(Vits_top* dut, VerilatedVcdC* trace,
                                      int expected_groups, int max_cycles = 500000) {
    std::vector<uint64_t> packed_out;
    for (int i = 0; i < max_cycles; i++) {
        dut->CLK = 1; dut->eval(); trace->dump(sim_time); sim_time++;
        if (dut->it_data_out_vld && dut->it_data_out_req &&
            (int)packed_out.size() < expected_groups) {
            packed_out.push_back((uint64_t)dut->it_data_out);
        }
        if (dut->it_done) {
            // Complete the falling edge so clock is in a known state
            dut->CLK = 0; dut->eval(); trace->dump(sim_time); sim_time++;
            break;
        }
        dut->CLK = 0; dut->eval(); trace->dump(sim_time); sim_time++;
    }
    return packed_out;
}

//===========================================================================
// 比较输出
//===========================================================================
int compare_output(const std::vector<uint64_t>& packed_out,
                   const std::vector<uint64_t>& expected,
                   const char* label) {
    if (packed_out.size() != expected.size()) {
        printf("  %s FAIL: got %zu groups, expected %zu\n",
            label, packed_out.size(), expected.size());
        return 1;
    }
    for (size_t i = 0; i < packed_out.size(); i++) {
        if (packed_out[i] != expected[i]) {
            printf("  %s FAIL group %zu: got %010llx expected %010llx\n",
                label, i, (unsigned long long)packed_out[i], (unsigned long long)expected[i]);
            return 1;
        }
    }
    return 0;
}

//===========================================================================
// 测试1: 输入插空验证
//===========================================================================
enum GapMode { GAP_EVERY_2, GAP_RANDOM_30PCT, GAP_HEAVY };

int test_input_gap(Vits_top* dut, VerilatedVcdC* trace,
                   const StimCase& sc, GapMode mode, const char* mode_name) {
    rng_state = 0x12345678 + mode + sc.id * 7;

    reset_dut(dut, trace, 10);
    send_config(dut, trace, sc);
    wait_input_req(dut, trace);

    // Send sparse input with gaps
    int gap_count = 0;
    for (int i = 0; i < (int)sc.sparse_input.size(); i++) {
        // Decide whether to insert gap
        bool insert_gap = false;
        switch (mode) {
            case GAP_EVERY_2:
                insert_gap = (i > 0 && i % 2 == 0);
                break;
            case GAP_RANDOM_30PCT:
                insert_gap = (my_rand() % 100 < 30);
                break;
            case GAP_HEAVY: {
                int n_gaps = 1 + (my_rand() % 4);
                for (int g = 0; g < n_gaps; g++) {
                    dut->it_data_in_vld = 0;
                    dut->it_data_end = 0;
                    tick(dut, trace);
                    gap_count++;
                }
                insert_gap = false; // already inserted above
                break;
            }
        }
        if (insert_gap && mode != GAP_HEAVY) {
            dut->it_data_in_vld = 0;
            dut->it_data_end = 0;
            tick(dut, trace);
            gap_count++;
        }

        dut->it_data_in_vld = 1;
        dut->it_data_addr = sc.sparse_input[i].first;
        dut->it_data_in = (uint16_t)sc.sparse_input[i].second;
        dut->it_data_end = (i == (int)sc.sparse_input.size() - 1) ? 1 : 0;
        tick(dut, trace);
    }
    dut->it_data_in_vld = 0;
    dut->it_data_end = 0;

    auto packed_out = collect_output(dut, trace, (int)sc.expected_packed.size());
    int result = compare_output(packed_out, sc.expected_packed, mode_name);
    if (result == 0) {
        printf("  %s PASS (gaps=%d)\n", mode_name, gap_count);
    }
    return result;
}

//===========================================================================
// 测试2: it_data_end 两种时序
//===========================================================================

// 2a: 同拍模式 (it_data_in_vld=1 && it_data_end=1)
int test_end_same_cycle(Vits_top* dut, VerilatedVcdC* trace, const StimCase& sc) {
    reset_dut(dut, trace, 10);
    send_config(dut, trace, sc);
    wait_input_req(dut, trace);

    // Send all sparse points, last one with end=1 same cycle
    send_sparse_basic(dut, trace, sc);

    auto packed_out = collect_output(dut, trace, (int)sc.expected_packed.size());
    return compare_output(packed_out, sc.expected_packed, "end_same_cycle");
}

// 2b: 后一拍模式 (last point with vld=1,end=0; then next cycle vld=0,end=1)
int test_end_next_cycle(Vits_top* dut, VerilatedVcdC* trace, const StimCase& sc) {
    reset_dut(dut, trace, 10);
    send_config(dut, trace, sc);
    wait_input_req(dut, trace);

    // Send all but last
    for (int i = 0; i < (int)sc.sparse_input.size() - 1; i++) {
        dut->it_data_in_vld = 1;
        dut->it_data_addr = sc.sparse_input[i].first;
        dut->it_data_in = (uint16_t)sc.sparse_input[i].second;
        dut->it_data_end = 0;
        tick(dut, trace);
    }
    // Last point: vld=1, end=0
    int last = (int)sc.sparse_input.size() - 1;
    dut->it_data_in_vld = 1;
    dut->it_data_addr = sc.sparse_input[last].first;
    dut->it_data_in = (uint16_t)sc.sparse_input[last].second;
    dut->it_data_end = 0;
    tick(dut, trace);

    // Next cycle: end alone
    dut->it_data_in_vld = 0;
    dut->it_data_end = 1;
    tick(dut, trace);
    dut->it_data_end = 0;

    auto packed_out = collect_output(dut, trace, (int)sc.expected_packed.size());
    return compare_output(packed_out, sc.expected_packed, "end_next_cycle");
}

//===========================================================================
// 测试3: 连续多TU不reset
//===========================================================================
int test_continuous_tu(Vits_top* dut, VerilatedVcdC* trace,
                       const std::vector<StimCase*>& cases) {
    // First case gets a reset, subsequent cases don't
    bool first = true;
    int total_fail = 0;

    for (auto* sc : cases) {
        if (first) {
            reset_dut(dut, trace, 10);
            first = false;
        } else {
            // No reset - wait for FSM to return to IDLE (debug_state == 0)
            dut->it_info_vld = 0;
            dut->it_data_in_vld = 0;
            dut->it_data_end = 0;
            int fsm_seen_idle = 0;
            for (int i = 0; i < 200; i++) {
                tick(dut, trace);
                if (dut->debug_state == 0) {
                    fsm_seen_idle = 1;
                    break;
                }
            }
            if (!fsm_seen_idle) {
                printf("  WARN: FSM stuck at state=%d after 200 cycles\n", dut->debug_state);
            } else {
                printf("  DBG: FSM returned to IDLE\n");
            }
            // Extra settling cycles
            for (int i = 0; i < 5; i++) tick(dut, trace);
        }

        send_config(dut, trace, *sc);
        wait_input_req(dut, trace);
        send_sparse_basic(dut, trace, *sc);

        // Collect output
        std::vector<uint64_t> packed_out;
        for (int i = 0; i < 500000; i++) {
            dut->CLK = 1; dut->eval(); trace->dump(sim_time); sim_time++;
            if (dut->it_data_out_vld && dut->it_data_out_req &&
                (int)packed_out.size() < (int)sc->expected_packed.size()) {
                packed_out.push_back((uint64_t)dut->it_data_out);
            }
            // Debug: if stuck in LOAD (1d=1) or LOAD_WAIT (1d=5) in COL_1D, print once
            if (dut->debug_state == 5 && i == 10) {
                printf("  [DBG@10] cyc=%d fsm=%d rd=%d 1d=%d start=%d ready=%d done=%d\n",
                    i, dut->debug_state, (int)dut->debug_rd_state_o,
                    (int)dut->debug_1d_state_o, (int)dut->debug_it1d_start_o,
                    (int)dut->debug_it1d_ready_o, (int)dut->debug_it1d_done_o);
            }
            if (dut->it_done) {
                dut->CLK = 0; dut->eval(); trace->dump(sim_time); sim_time++;
                break;
            }
            dut->CLK = 0; dut->eval(); trace->dump(sim_time); sim_time++;
        }
        int result = compare_output(packed_out, sc->expected_packed, sc->name.c_str());
        if (result == 0) {
            printf("  continuous [%04d] %s PASS\n", sc->id, sc->name.c_str());
        } else {
            printf("  continuous [%04d] %s FAIL (state=%d)\n", sc->id, sc->name.c_str(), dut->debug_state);
            total_fail++;
        }
    }
    return total_fail;
}

//===========================================================================
// Main
//===========================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    // Read case index
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
    printf("Loaded %zu cases\n", entries.size());

    // Select representative subset (diverse sizes/types/LFNST modes)
    std::vector<int> selected_ids;
    // First 5
    for (int i = 0; i < 5 && i < (int)entries.size(); i++)
        selected_ids.push_back(entries[i].id);
    // Every 50th
    for (int i = 50; i < (int)entries.size(); i += 50)
        selected_ids.push_back(entries[i].id);
    // Last 5
    for (int i = (int)entries.size() - 5; i < (int)entries.size(); i++)
        if (i >= 5) selected_ids.push_back(entries[i].id);

    // Load selected cases
    std::vector<StimCase> cases(selected_ids.size());
    for (size_t i = 0; i < selected_ids.size(); i++) {
        char stim_path[512];
        snprintf(stim_path, sizeof(stim_path), "regression_stim/case_%04d.stim", selected_ids[i]);
        cases[i].id = selected_ids[i];
        if (!read_stim(stim_path, cases[i])) {
            printf("WARN: Cannot read %s\n", stim_path);
            cases.resize(i);
            break;
        }
    }
    printf("Selected %zu cases for protocol testing\n", cases.size());
    printf("Selected IDs: ");
    for (size_t i = 0; i < cases.size(); i++) printf("%d ", cases[i].id);
    printf("\n");

    Vits_top* dut = new Vits_top;
    VerilatedVcdC* trace = new VerilatedVcdC;
    dut->trace(trace, 99);
    trace->open("input_protocol.vcd");

    int total = 0, passed = 0, failed = 0;

    //=== Test 1: Input gap ===
    printf("\n=== Test 1: Input Gap Tests ===\n");
    const char* gap_names[] = {"gap_every_2", "gap_random_30pct", "gap_heavy"};
    GapMode gap_modes[] = {GAP_EVERY_2, GAP_RANDOM_30PCT, GAP_HEAVY};
    for (auto& sc : cases) {
        for (int m = 0; m < 3; m++) {
            total++;
            int r = test_input_gap(dut, trace, sc, gap_modes[m], gap_names[m]);
            if (r == 0) passed++; else failed++;
        }
    }

    //=== Test 2: it_data_end timing ===
    printf("\n=== Test 2: it_data_end Same-Cycle Tests ===\n");
    for (auto& sc : cases) {
        total++;
        reset_dut(dut, trace, 10);
        int r = test_end_same_cycle(dut, trace, sc);
        if (r == 0) {
            printf("  [%04d] end_same_cycle PASS\n", sc.id);
            passed++;
        } else {
            printf("  [%04d] end_same_cycle FAIL\n", sc.id);
            failed++;
        }
    }

    printf("\n=== Test 2: it_data_end Next-Cycle Tests ===\n");
    for (auto& sc : cases) {
        total++;
        reset_dut(dut, trace, 10);
        int r = test_end_next_cycle(dut, trace, sc);
        if (r == 0) {
            printf("  [%04d] end_next_cycle PASS\n", sc.id);
            passed++;
        } else {
            printf("  [%04d] end_next_cycle FAIL\n", sc.id);
            failed++;
        }
    }

    //=== Test 3: Continuous TU no-reset (debug run) ===
    printf("\n=== Test 3: Continuous TU No-Reset Tests ===\n");

    // Use same case twice (4x4 DCT2 lfnst0)
    int lfnst0_a = 0;
    int lfnst0_b = 0;

    // Sub-test A: two non-LFNST TUs back-to-back
    if (lfnst0_a >= 0 && lfnst0_b >= 0) {
        total++;
        reset_dut(dut, trace, 10);
        printf("  [lfnst0_pair] TU1=case[%d] TU2=case[%d]\n", lfnst0_a, lfnst0_b);

        auto& sc1 = cases[lfnst0_a];
        send_config(dut, trace, sc1);
        wait_input_req(dut, trace);
        send_sparse_basic(dut, trace, sc1);
        auto out1 = collect_output(dut, trace, (int)sc1.expected_packed.size());
        int r1 = compare_output(out1, sc1.expected_packed, "TU1");
        printf("  [lfnst0_pair] TU1 result: %s\n", r1==0?"PASS":"FAIL");

        // Wait for IDLE, trace clearing signal
        dut->it_info_vld = 0; dut->it_data_in_vld = 0; dut->it_data_end = 0;
        int idle_cycle = -1;
        for (int i = 0; i < 500; i++) {
            tick(dut, trace);
            if (i < 30) {
                printf("  [wait] cycle=%d state=%d clearing=%d\n", i, dut->debug_state, dut->debug_buf_clearing);
            }
            if (dut->debug_state == 0) { idle_cycle = i; break; }
        }
        printf("  [lfnst0_pair] FSM IDLE at cycle %d\n", idle_cycle);
        // Extra settling - ensure all pipeline stages are quiescent
        for (int i = 0; i < 50; i++) tick(dut, trace);

        auto& sc2 = cases[lfnst0_b];
        send_config(dut, trace, sc2);
        int req_seen = 0;
        for (int i = 0; i < 100; i++) {
            tick(dut, trace);
            if (dut->it_data_in_req) { req_seen = 1; break; }
            if (i < 20) printf("  [lfnst0_pair] TU2 wait cycle=%d state=%d\n", i, dut->debug_state);
        }
        if (!req_seen) {
            printf("  [lfnst0_pair] TU2 FAIL: it_data_in_req never asserted, state=%d\n", dut->debug_state);
        } else {
            printf("  [lfnst0_pair] TU2 it_data_in_req seen, sending %d sparse points\n", (int)sc2.sparse_input.size());

            // Send sparse data with debug tracing
            for (int i = 0; i < (int)sc2.sparse_input.size(); i++) {
                int addr = sc2.sparse_input[i].first;
                int val = sc2.sparse_input[i].second;
                dut->it_data_in_vld = 1;
                dut->it_data_addr = addr;
                dut->it_data_in = (uint16_t)val;
                dut->it_data_end = (i == (int)sc2.sparse_input.size() - 1) ? 1 : 0;
                dut->CLK = 1; dut->eval(); trace->dump(sim_time); sim_time++;
                printf("  [TU2 input] cycle=%d wr_en=%d clearing=%d state=%d\n",
                    i, dut->debug_buf_wr_en, dut->debug_buf_clearing, dut->debug_state);
                dut->CLK = 0; dut->eval(); trace->dump(sim_time); sim_time++;
            }
            dut->it_data_in_vld = 0;
            dut->it_data_end = 0;

            auto out2 = collect_output(dut, trace, (int)sc2.expected_packed.size());
            int r2 = compare_output(out2, sc2.expected_packed, "TU2");
            printf("  [lfnst0_pair] TU2 result: %s (groups=%zu expected=%zu)\n",
                   r2==0?"PASS":"FAIL", out2.size(), sc2.expected_packed.size());
            if (out2.size() > 0) {
                printf("  [lfnst0_pair] TU2 first group: got=%010llx expected=%010llx\n",
                    (unsigned long long)out2[0], (unsigned long long)sc2.expected_packed[0]);
            }
            if (r1 == 0 && r2 == 0) { printf("  [lfnst0_pair] PASS\n"); passed++; }
            else { printf("  [lfnst0_pair] FAIL\n"); failed++; }
        }
    }

    // Sub-test B: original sequence (includes LFNST cases)
    {
        total++;
        std::vector<StimCase*> seq;
        for (auto& sc : cases) seq.push_back(&sc);
        reset_dut(dut, trace, 10);
        int r = test_continuous_tu(dut, trace, seq);
        if (r == 0) {
            printf("  continuous_tu PASS (%zu TUs)\n", seq.size());
            passed++;
        } else {
            printf("  continuous_tu FAIL (%d/%zu failures)\n", r, seq.size());
            failed++;
        }
    }

    // Sub-test C: same sequence but with reset between each TU (baseline)
    {
        total++;
        int r = 0;
        for (size_t i = 0; i < cases.size(); i++) {
            reset_dut(dut, trace, 10);
            send_config(dut, trace, cases[i]);
            wait_input_req(dut, trace);
            send_sparse_basic(dut, trace, cases[i]);
            auto out = collect_output(dut, trace, (int)cases[i].expected_packed.size());
            if (compare_output(out, cases[i].expected_packed, "with_reset") != 0) {
                printf("  with_reset [%04d] FAIL\n", cases[i].id);
                r++;
            }
        }
        if (r == 0) {
            printf("  with_reset PASS (%zu TUs)\n", cases.size());
            passed++;
        } else {
            printf("  with_reset FAIL (%d/%zu failures)\n", r, cases.size());
            failed++;
        }
    }

    // Summary
    printf("\n=== Input Protocol Test Summary ===\n");
    printf("Total: %d, Passed: %d, Failed: %d\n", total, passed, failed);
    if (failed == 0 && total > 0) {
        printf("ALL PROTOCOL TESTS PASSED!\n");
    }

    trace->close(); delete trace; delete dut;
    return (failed == 0) ? 0 : 1;
}
