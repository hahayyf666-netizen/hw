"""
Generate representative golden data for the ITS reference model.

Each generated case contains:
    config.json       Metadata for TU size, trType and LFNST settings.
    input_sparse.txt  Non-zero input coefficients as "addr value".
    input_dense.txt   Full raster input coefficients, one value per line.
    output_signed.txt Final 10-bit signed outputs, four points per line.
    output_packed.txt Packed it_data_out[39:0] words, one 10-hex-digit word per line.
"""

import json
import os
import random
import shutil
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from common.utils import pack_4_points
from transforms.reference_model import its_inverse


TR_DCT2 = 0
TR_DST7 = 1
TR_DCT8 = 2

TRANSFORM_NAMES = {
    TR_DCT2: "DCT2",
    TR_DST7: "DST7",
    TR_DCT8: "DCT8",
}

GOLDEN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden_data", "generated")
SEED_BASE = 20260527


LOW_FREQ_COORDS_4X4 = [
    (0, 0),
    (1, 0), (0, 1),
    (2, 0), (1, 1), (0, 2),
    (3, 0), (2, 1), (1, 2), (0, 3),
    (3, 1), (2, 2), (1, 3),
    (3, 2), (2, 3),
    (3, 3),
]


def dense_to_sparse(coeffs):
    return [(addr, value) for addr, value in enumerate(coeffs) if value != 0]


def make_all_zero(width, height, _case_id):
    return [0] * (width * height)


def make_single_dc(width, height, _case_id):
    coeffs = [0] * (width * height)
    coeffs[0] = 256
    return coeffs


def make_low_freq(width, height, _case_id):
    coeffs = [0] * (width * height)
    values = [100, -80, 60, -40, 25, -25, 12, -12, 7, -7, 5, -5, 3, -3, 2, -2]

    for (row, col), value in zip(LOW_FREQ_COORDS_4X4, values):
        if row < height and col < width:
            coeffs[row * width + col] = value
    return coeffs


def make_random_sparse(width, height, case_id):
    rng = random.Random(SEED_BASE + case_id)
    coeffs = [0] * (width * height)
    nonzero_count = min(16, max(4, (width * height) // 8))

    for addr in rng.sample(range(width * height), nonzero_count):
        value = rng.randint(-256, 256)
        coeffs[addr] = value if value != 0 else 1
    return coeffs


def make_extreme_low_freq(width, height, _case_id):
    coeffs = [0] * (width * height)
    values = [32767, -32768] * 8

    for (row, col), value in zip(LOW_FREQ_COORDS_4X4, values):
        if row < height and col < width:
            coeffs[row * width + col] = value
    return coeffs


PATTERN_BUILDERS = {
    "all_zero": make_all_zero,
    "single_dc": make_single_dc,
    "low_freq": make_low_freq,
    "random_sparse": make_random_sparse,
    "extreme_low_freq": make_extreme_low_freq,
}


def build_cases():
    """
    Generate test cases covering all transform block sizes and type combinations.

    Theoretical valid complete combinations: 1377

    Calculation:
    - Base combos = 25 (DCT2 sizes x DCT2xDCT2) + 16x8 (MTS sizes x 8 MTS combos) = 153
    - LFNST configs = 1 (idx=0) + 4 (idx=1, tr_set=0/1/2/3) + 4 (idx=2, tr_set=0/1/2/3) = 9
    - Total = 153 x 9 = 1377

    Key points:
    - lfnst_idx=0: tr_set is meaningless, only 1 config
    - DCT2xDCT2 only covered in DCT2 block sizes, not duplicated in MTS sizes
    - MTS combos exclude DCT2xDCT2 (already covered)
    """
    raw_cases = []

    # ========================================
    # DCT2 block sizes (25 types): only support DCT2xDCT2
    # ========================================
    dct2_sizes = [
        (4, 4), (4, 8), (4, 16), (4, 32), (4, 64),
        (8, 4), (16, 4), (32, 4), (64, 4),
        (8, 8), (8, 16), (8, 32), (8, 64),
        (16, 8), (32, 8), (64, 8),
        (16, 16), (16, 32), (16, 64),
        (32, 16), (32, 32), (32, 64),
        (64, 16), (64, 32), (64, 64),
    ]

    for width, height in dct2_sizes:
        # lfnst_idx=0: 1 config (tr_set meaningless)
        raw_cases.append((width, height, TR_DCT2, TR_DCT2, 0, 0, "random_sparse"))
        # lfnst_idx=1: 4 tr_set configs
        for tr_set in [0, 1, 2, 3]:
            raw_cases.append((width, height, TR_DCT2, TR_DCT2, tr_set, 1, "low_freq"))
        # lfnst_idx=2: 4 tr_set configs
        for tr_set in [0, 1, 2, 3]:
            raw_cases.append((width, height, TR_DCT2, TR_DCT2, tr_set, 2, "extreme_low_freq"))

    # ========================================
    # MTS block sizes (16 types): support 8 MTS combos (excluding DCT2xDCT2)
    # ========================================
    mts_sizes = [
        (4, 4), (4, 8), (4, 16), (4, 32),
        (8, 4), (16, 4), (32, 4),
        (8, 8), (8, 16), (8, 32),
        (16, 8), (32, 8),
        (16, 16), (16, 32),
        (32, 16), (32, 32),
    ]

    # 8 MTS combos (excluding DCT2xDCT2)
    mts_combos = [
        (TR_DCT8, TR_DST7),   # DCT8 x DST7
        (TR_DST7, TR_DCT8),   # DST7 x DCT8
        (TR_DST7, TR_DST7),   # DST7 x DST7
        (TR_DCT8, TR_DCT8),   # DCT8 x DCT8
        (TR_DCT2, TR_DST7),   # DCT2 x DST7
        (TR_DST7, TR_DCT2),   # DST7 x DCT2
        (TR_DCT2, TR_DCT8),   # DCT2 x DCT8
        (TR_DCT8, TR_DCT2),   # DCT8 x DCT2
    ]

    for width, height in mts_sizes:
        for tr_hor, tr_ver in mts_combos:
            # lfnst_idx=0: 1 config (tr_set meaningless)
            raw_cases.append((width, height, tr_hor, tr_ver, 0, 0, "random_sparse"))
            # lfnst_idx=1: 4 tr_set configs
            for tr_set in [0, 1, 2, 3]:
                raw_cases.append((width, height, tr_hor, tr_ver, tr_set, 1, "low_freq"))
            # lfnst_idx=2: 4 tr_set configs
            for tr_set in [0, 1, 2, 3]:
                raw_cases.append((width, height, tr_hor, tr_ver, tr_set, 2, "extreme_low_freq"))

    cases = []
    for case_id, (width, height, tr_hor, tr_ver, tr_set, lfnst_idx, pattern) in enumerate(raw_cases):
        cases.append({
            "id": case_id,
            "tu_width": width,
            "tu_height": height,
            "tr_type_hor": tr_hor,
            "tr_type_ver": tr_ver,
            "tr_type_hor_name": TRANSFORM_NAMES[tr_hor],
            "tr_type_ver_name": TRANSFORM_NAMES[tr_ver],
            "lfnst_tr_set_idx": tr_set,
            "lfnst_idx": lfnst_idx,
            "pattern": pattern,
        })
    return cases


def case_dir_name(case):
    size = f"{case['tu_width']}x{case['tu_height']}"
    transforms = f"{case['tr_type_hor_name']}x{case['tr_type_ver_name']}"
    lfnst = f"lfnst{case['lfnst_idx']}"
    tr_set = f"set{case['lfnst_tr_set_idx']}"
    return f"{case['id']:03d}_{size}_{transforms}_{lfnst}_{tr_set}_{case['pattern']}"


def write_lines(path, lines):
    with open(path, "w", encoding="utf-8") as file:
        for line in lines:
            file.write(f"{line}\n")


def write_case(case, coeffs, output_groups):
    out_dir = os.path.join(GOLDEN_DIR, case_dir_name(case))
    os.makedirs(out_dir, exist_ok=True)

    sparse = dense_to_sparse(coeffs)
    packed_words = [pack_4_points(group) for group in output_groups]

    config = dict(case)
    config.update({
        "tr_type_encoding": {
            "0": "DCT2",
            "1": "DST7",
            "2": "DCT8",
        },
        "seed_base": SEED_BASE,
        "addr_rule": "addr = row * tu_width + col",
        "input_total_count": len(coeffs),
        "input_nonzero_count": len(sparse),
        "output_total_count": sum(len(group) for group in output_groups),
        "output_group_count": len(output_groups),
        "output_signed_format": "final 10-bit signed values, raster order, four points per line",
        "output_packed_format": "it_data_out[39:0], p0 bits[9:0], p3 bits[39:30]",
        "note": "it_info packed encoding is not emitted yet; use these explicit fields until RTL it_info layout is signed off.",
    })

    with open(os.path.join(out_dir, "config.json"), "w", encoding="utf-8") as file:
        json.dump(config, file, indent=2, ensure_ascii=False)

    write_lines(os.path.join(out_dir, "input_sparse.txt"), [f"{addr} {value}" for addr, value in sparse])
    write_lines(os.path.join(out_dir, "input_dense.txt"), [str(value) for value in coeffs])
    write_lines(os.path.join(out_dir, "output_signed.txt"), [" ".join(str(value) for value in group) for group in output_groups])
    write_lines(os.path.join(out_dir, "output_packed.txt"), [f"{word:010X}" for word in packed_words])

    return {
        "name": case_dir_name(case),
        "input_nonzero_count": len(sparse),
        "output_group_count": len(output_groups),
    }


def generate_golden_data():
    # 生成前清空旧目录，确保干净生成
    if os.path.exists(GOLDEN_DIR):
        shutil.rmtree(GOLDEN_DIR)
    os.makedirs(GOLDEN_DIR, exist_ok=True)

    summary = []
    for case in build_cases():
        coeffs = PATTERN_BUILDERS[case["pattern"]](case["tu_width"], case["tu_height"], case["id"])
        output_groups = its_inverse(
            case["tu_width"],
            case["tu_height"],
            case["tr_type_hor"],
            case["tr_type_ver"],
            case["lfnst_tr_set_idx"],
            case["lfnst_idx"],
            coeffs,
        )
        summary.append(write_case(case, coeffs, output_groups))

    with open(os.path.join(GOLDEN_DIR, "summary.json"), "w", encoding="utf-8") as file:
        json.dump(summary, file, indent=2, ensure_ascii=False)

    return summary


if __name__ == "__main__":
    generated = generate_golden_data()
    print(f"generated {len(generated)} golden cases")
    for item in generated:
        print(f"{item['name']}: nonzero={item['input_nonzero_count']}, groups={item['output_group_count']}")
