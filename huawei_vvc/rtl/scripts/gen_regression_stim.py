#!/usr/bin/env python3
"""
Generate regression stimulus files from golden data.
For each case, generates a .stim file with:
  Line 1: tu_width tu_height tr_type_hor tr_type_ver lfnst_idx lfnst_tr_set_idx
  Line 2: number_of_nonzero_inputs
  Lines 3+: addr value (sparse input)
  Line N: expected_packed_output (one hex per line, 40-bit)

Generates lfnst0 cases (all transform types) for Layer 1+2.
"""

import sys
import os
import json

GOLDEN_DIR = r"D:\HW_WORK\its_reference\golden_data\generated"
OUT_DIR = r"D:\HW_WORK\huawei_vvc\rtl\tb_verilator\regression_stim"

def generate():
    os.makedirs(OUT_DIR, exist_ok=True)

    cases = []
    for d in sorted(os.listdir(GOLDEN_DIR)):
        case_path = os.path.join(GOLDEN_DIR, d)
        if not os.path.isdir(case_path):
            continue
        config_path = os.path.join(case_path, "config.json")
        if not os.path.exists(config_path):
            continue
        with open(config_path) as f:
            cfg = json.load(f)

        # Layer 1+2+3: all lfnst, all transform types

        # Read sparse input
        sparse_path = os.path.join(case_path, "input_sparse.txt")
        sparse = []
        with open(sparse_path) as f:
            for line in f:
                line = line.strip()
                if line:
                    parts = line.split()
                    sparse.append((int(parts[0]), int(parts[1])))

        # Read expected packed output
        packed_path = os.path.join(case_path, "output_packed.txt")
        expected_packed = []
        with open(packed_path) as f:
            for line in f:
                line = line.strip()
                if line:
                    expected_packed.append(line)

        # Write stimulus file
        case_id = cfg["id"]
        stim_name = f"case_{case_id:04d}.stim"
        stim_path = os.path.join(OUT_DIR, stim_name)

        with open(stim_path, "w") as f:
            f.write(f"{cfg['tu_width']} {cfg['tu_height']} {cfg['tr_type_hor']} {cfg['tr_type_ver']} {cfg['lfnst_idx']} {cfg['lfnst_tr_set_idx']}\n")
            f.write(f"{len(sparse)}\n")
            for addr, val in sparse:
                f.write(f"{addr} {val}\n")
            for packed in expected_packed:
                f.write(f"{packed}\n")

        cases.append({
            "id": case_id,
            "name": d,
            "width": cfg["tu_width"],
            "height": cfg["tu_height"],
            "stim": stim_name,
            "groups": len(expected_packed),
        })

    # Write case index
    index_path = os.path.join(OUT_DIR, "case_index.txt")
    with open(index_path, "w") as f:
        for c in cases:
            f.write(f"{c['id']} {c['name']} {c['width']} {c['height']} {c['groups']} {c['stim']}\n")

    print(f"Generated {len(cases)} stimulus files in {OUT_DIR}")
    print(f"Case index: {index_path}")

    # Print summary
    sizes = {}
    for c in cases:
        key = f"{c['width']}x{c['height']}"
        sizes[key] = sizes.get(key, 0) + 1
    print("Size distribution:")
    for size, count in sorted(sizes.items()):
        print(f"  {size}: {count} cases")


if __name__ == "__main__":
    generate()
