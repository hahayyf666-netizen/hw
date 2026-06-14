"""
Independent checker for generated ITS golden data.

This script intentionally does not import transforms.reference_model,
generate_golden_data, common.utils, or common.fixed_point.  It re-implements
the datapath and only reuses the matrix tables from matrices/.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Any


ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
GOLDEN_DIR = os.path.join(ROOT_DIR, "golden_data", "generated")

REQUIRED_FILES = (
    "config.json",
    "input_sparse.txt",
    "input_dense.txt",
    "output_signed.txt",
    "output_packed.txt",
)

LOW_FREQ_COORDS_4X4 = [
    (0, 0),
    (1, 0), (0, 1),
    (2, 0), (1, 1), (0, 2),
    (3, 0), (2, 1), (1, 2), (0, 3),
    (3, 1), (2, 2), (1, 3),
    (3, 2), (2, 3),
    (3, 3),
]


sys.path.append(ROOT_DIR)
from matrices.lfnst_kernels import LFNST_KERNELS  # noqa: E402
from matrices.trans_matrix import (  # noqa: E402
    TRANS_MATRIX,
    TR_DCT2,
    TR_DCT8,
    TR_DST7,
)


@dataclass
class CaseResult:
    case_name: str
    ok: bool
    message: str


class VerifyError(Exception):
    pass


def round_shift(val: int, shift: int) -> int:
    return (val + (1 << (shift - 1))) >> shift


def saturate(val: int, bits: int) -> int:
    min_val = -(1 << (bits - 1))
    max_val = (1 << (bits - 1)) - 1
    if val < min_val:
        return min_val
    if val > max_val:
        return max_val
    return val


def raster_to_matrix(coeffs: list[int], width: int, height: int) -> list[list[int]]:
    matrix = []
    for row in range(height):
        row_values = []
        for col in range(width):
            addr = row * width + col
            row_values.append(coeffs[addr] if addr < len(coeffs) else 0)
        matrix.append(row_values)
    return matrix


def matrix_to_raster(matrix: list[list[int]]) -> list[int]:
    values = []
    for row in matrix:
        values.extend(row)
    return values


def split_groups(values: list[int], group_size: int = 4) -> list[list[int]]:
    groups = []
    for start in range(0, len(values), group_size):
        group = values[start:start + group_size]
        while len(group) < group_size:
            group.append(0)
        groups.append(group)
    return groups


def pack_4_points(points: list[int]) -> int:
    clipped = [saturate(value, 10) for value in points]
    return (
        (clipped[0] & 0x3FF)
        | ((clipped[1] & 0x3FF) << 10)
        | ((clipped[2] & 0x3FF) << 20)
        | ((clipped[3] & 0x3FF) << 30)
    )


def get_ntrs(width: int, height: int) -> int:
    return 48 if width >= 8 and height >= 8 else 16


def get_nonzero_size(width: int, height: int) -> int:
    return 8 if (width, height) in ((4, 4), (8, 8)) else 16


def get_matrix(tr_type: int, length: int) -> list[list[int]]:
    if tr_type not in (TR_DCT2, TR_DST7, TR_DCT8):
        raise VerifyError(f"unsupported tr_type={tr_type}")
    if length not in TRANS_MATRIX[tr_type]:
        raise VerifyError(f"unsupported transform length={length} for tr_type={tr_type}")
    return TRANS_MATRIX[tr_type][length]


def normalize_lfnst_matrix(
    matrix: list[list[int]],
    ntrs: int,
    nonzero_size: int,
) -> list[list[int]]:
    """Return LFNST matrix in VTM inverse layout: [input_idx][output_idx]."""
    if len(matrix) >= nonzero_size and all(len(row) == ntrs for row in matrix):
        return matrix[:nonzero_size]

    if ntrs == 48 and len(matrix) == 48 and all(len(row) == 16 for row in matrix):
        return [
            matrix[row] + matrix[row + 16] + matrix[row + 32]
            for row in range(nonzero_size)
        ]

    flat = []
    for row in matrix:
        flat.extend(row)

    full_input_size = 16
    expected_full = full_input_size * ntrs
    expected_used = nonzero_size * ntrs
    if len(flat) == expected_full:
        reshaped = [
            flat[row * ntrs:(row + 1) * ntrs]
            for row in range(full_input_size)
        ]
        return reshaped[:nonzero_size]
    if len(flat) != expected_used:
        raise VerifyError(
            f"LFNST matrix shape mismatch: expected={nonzero_size}x{ntrs}, "
            f"actual_rows={len(matrix)}, actual_values={len(flat)}"
        )

    return [
        flat[row * ntrs:(row + 1) * ntrs]
        for row in range(nonzero_size)
    ]


def lfnst_inverse_slow(
    coeffs: list[int],
    width: int,
    height: int,
    lfnst_tr_set_idx: int,
    lfnst_idx: int,
) -> list[int]:
    if lfnst_idx == 0:
        return list(coeffs)

    ntrs = get_ntrs(width, height)
    nonzero_size = get_nonzero_size(width, height)

    input_coeffs = []
    for row, col in LOW_FREQ_COORDS_4X4[:nonzero_size]:
        addr = row * width + col
        input_coeffs.append(coeffs[addr] if addr < len(coeffs) else 0)

    try:
        matrix = LFNST_KERNELS[ntrs][lfnst_tr_set_idx][lfnst_idx]
    except KeyError as exc:
        raise VerifyError(
            "missing LFNST matrix: "
            f"nTrs={ntrs}, tr_set={lfnst_tr_set_idx}, idx={lfnst_idx}"
        ) from exc
    matrix = normalize_lfnst_matrix(matrix, ntrs, nonzero_size)

    output = []
    for out_idx in range(ntrs):
        acc = 0
        for in_idx in range(nonzero_size):
            acc += matrix[in_idx][out_idx] * input_coeffs[in_idx]
        output.append(saturate(round_shift(acc, 7), 16))
    return output


def fill_lfnst_output_slow(lfnst_coeffs: list[int], width: int, height: int) -> list[int]:
    ntrs = get_ntrs(width, height)
    full_coeffs = [0] * (width * height)

    if ntrs == 16:
        for idx, value in enumerate(lfnst_coeffs[:16]):
            row = idx // 4
            col = idx % 4
            addr = row * width + col
            if addr < len(full_coeffs):
                full_coeffs[addr] = value
        return full_coeffs

    if ntrs == 48:
        for idx, value in enumerate(lfnst_coeffs[:48]):
            if idx < 32:
                row = idx // 8
                col = idx % 8
            else:
                local = idx - 32
                row = 4 + local // 4
                col = local % 4
            addr = row * width + col
            if addr < len(full_coeffs):
                full_coeffs[addr] = value
        return full_coeffs

    raise VerifyError(f"unsupported nTrs={ntrs}")


def inverse_1d_slow(
    coeffs: list[int],
    tr_type: int,
    length: int,
    shift: int,
    clip_bits: int | None = None,
) -> list[int]:
    if len(coeffs) != length:
        raise VerifyError(f"1D input length mismatch: expected {length}, got {len(coeffs)}")

    matrix = get_matrix(tr_type, length)
    output = []
    for out_idx in range(length):
        acc = 0
        for in_idx in range(length):
            acc += matrix[in_idx][out_idx] * coeffs[in_idx]
        value = round_shift(acc, shift)
        if clip_bits is not None:
            value = saturate(value, clip_bits)
        output.append(value)
    return output


def recompute_case(config: dict[str, Any], input_dense: list[int]) -> dict[str, Any]:
    width = int(config["tu_width"])
    height = int(config["tu_height"])
    tr_type_hor = int(config["tr_type_hor"])
    tr_type_ver = int(config["tr_type_ver"])
    lfnst_tr_set_idx = int(config["lfnst_tr_set_idx"])
    lfnst_idx = int(config["lfnst_idx"])

    if len(input_dense) != width * height:
        raise VerifyError(
            f"input_dense length mismatch: expected {width * height}, got {len(input_dense)}"
        )

    if lfnst_idx == 0:
        lfnst_output = list(input_dense)
        full_coeffs = list(input_dense)
    else:
        lfnst_output = lfnst_inverse_slow(
            input_dense,
            width,
            height,
            lfnst_tr_set_idx,
            lfnst_idx,
        )
        full_coeffs = fill_lfnst_output_slow(lfnst_output, width, height)

    matrix = raster_to_matrix(full_coeffs, width, height)

    col_matrix = [[0] * width for _ in range(height)]
    for col in range(width):
        vector = [matrix[row][col] for row in range(height)]
        transformed = inverse_1d_slow(
            vector,
            tr_type_ver,
            height,
            shift=7,
            clip_bits=16,
        )
        for row in range(height):
            col_matrix[row][col] = transformed[row]

    row_matrix = []
    for row in range(height):
        row_matrix.append(
            inverse_1d_slow(
                col_matrix[row],
                tr_type_hor,
                width,
                shift=10,
                clip_bits=None,
            )
        )

    final_values = [saturate(value, 10) for value in matrix_to_raster(row_matrix)]
    signed_groups = split_groups(final_values, 4)
    packed_words = [pack_4_points(group) for group in signed_groups]

    return {
        "lfnst_output": lfnst_output,
        "full_coeffs": full_coeffs,
        "col_matrix": col_matrix,
        "row_matrix": row_matrix,
        "final_values": final_values,
        "signed_groups": signed_groups,
        "packed_words": packed_words,
    }


def read_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as file:
        return json.load(file)


def read_dense(path: str) -> list[int]:
    values = []
    with open(path, "r", encoding="utf-8") as file:
        for line_no, line in enumerate(file, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                values.append(int(text))
            except ValueError as exc:
                raise VerifyError(f"bad integer in {path}:{line_no}: {text!r}") from exc
    return values


def read_sparse(path: str) -> list[tuple[int, int]]:
    pairs = []
    with open(path, "r", encoding="utf-8") as file:
        for line_no, line in enumerate(file, start=1):
            text = line.strip()
            if not text:
                continue
            parts = text.split()
            if len(parts) != 2:
                raise VerifyError(f"bad sparse row in {path}:{line_no}: {text!r}")
            try:
                pairs.append((int(parts[0]), int(parts[1])))
            except ValueError as exc:
                raise VerifyError(f"bad sparse integer in {path}:{line_no}: {text!r}") from exc
    return pairs


def read_signed_groups(path: str) -> list[list[int]]:
    groups = []
    with open(path, "r", encoding="utf-8") as file:
        for line_no, line in enumerate(file, start=1):
            text = line.strip()
            if not text:
                continue
            parts = text.split()
            if len(parts) != 4:
                raise VerifyError(f"bad signed group in {path}:{line_no}: {text!r}")
            try:
                groups.append([int(part) for part in parts])
            except ValueError as exc:
                raise VerifyError(f"bad signed integer in {path}:{line_no}: {text!r}") from exc
    return groups


def read_packed_words(path: str) -> list[int]:
    words = []
    with open(path, "r", encoding="utf-8") as file:
        for line_no, line in enumerate(file, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                words.append(int(text, 16))
            except ValueError as exc:
                raise VerifyError(f"bad packed word in {path}:{line_no}: {text!r}") from exc
    return words


def flatten(groups: list[list[int]]) -> list[int]:
    values = []
    for group in groups:
        values.extend(group)
    return values


def first_mismatch(expected: list[Any], actual: list[Any]) -> tuple[int, Any, Any] | None:
    common = min(len(expected), len(actual))
    for idx in range(common):
        if expected[idx] != actual[idx]:
            return idx, expected[idx], actual[idx]
    if len(expected) != len(actual):
        exp = expected[common] if common < len(expected) else "<missing>"
        got = actual[common] if common < len(actual) else "<missing>"
        return common, exp, got
    return None


def validate_sparse_matches_dense(sparse: list[tuple[int, int]], dense: list[int]) -> None:
    expected_sparse = [(idx, value) for idx, value in enumerate(dense) if value != 0]
    if sparse != expected_sparse:
        mismatch = first_mismatch(expected_sparse, sparse)
        if mismatch is None:
            raise VerifyError("input_sparse mismatch")
        idx, expected, actual = mismatch
        raise VerifyError(
            "input_sparse mismatch: "
            f"entry={idx}, expected={expected}, actual={actual}"
        )


def print_trace(case_name: str, config: dict[str, Any], recomputed: dict[str, Any]) -> None:
    width = int(config["tu_width"])
    height = int(config["tu_height"])
    print(f"case: {case_name}")
    print("trace:")
    print(
        "  config: "
        f"{width}x{height}, tr_hor={config['tr_type_hor']}, "
        f"tr_ver={config['tr_type_ver']}, lfnst_idx={config['lfnst_idx']}"
    )
    lfnst = recomputed["lfnst_output"]
    print(f"  stage: LFNST output, length={len(lfnst)}, head={lfnst[:8]}")
    col_flat = matrix_to_raster(recomputed["col_matrix"])
    row_flat = matrix_to_raster(recomputed["row_matrix"])
    final = recomputed["final_values"]
    print(f"  stage: col 1D output, head={col_flat[:8]}")
    print(f"  stage: row 1D output, head={row_flat[:8]}")
    print(f"  stage: final clip10, head={final[:8]}")


def validate_case_dir(case_dir: str, trace: bool) -> CaseResult:
    case_name = os.path.basename(case_dir)
    try:
        for filename in REQUIRED_FILES:
            path = os.path.join(case_dir, filename)
            if not os.path.exists(path):
                raise VerifyError(f"missing required file: {filename}")

        config = read_json(os.path.join(case_dir, "config.json"))
        input_dense = read_dense(os.path.join(case_dir, "input_dense.txt"))
        input_sparse = read_sparse(os.path.join(case_dir, "input_sparse.txt"))
        expected_signed_groups = read_signed_groups(os.path.join(case_dir, "output_signed.txt"))
        expected_packed_words = read_packed_words(os.path.join(case_dir, "output_packed.txt"))

        width = int(config["tu_width"])
        height = int(config["tu_height"])
        total = width * height
        expected_group_count = (total + 3) // 4

        if len(input_dense) != total:
            raise VerifyError(
                f"input_dense length mismatch: expected={total}, actual={len(input_dense)}"
            )
        validate_sparse_matches_dense(input_sparse, input_dense)

        if len(expected_signed_groups) != expected_group_count:
            raise VerifyError(
                "output_signed group count mismatch: "
                f"expected={expected_group_count}, actual={len(expected_signed_groups)}"
            )
        if len(expected_packed_words) != expected_group_count:
            raise VerifyError(
                "output_packed line count mismatch: "
                f"expected={expected_group_count}, actual={len(expected_packed_words)}"
            )

        recomputed = recompute_case(config, input_dense)

        expected_signed = flatten(expected_signed_groups)[:total]
        actual_signed = recomputed["final_values"]
        mismatch = first_mismatch(expected_signed, actual_signed)
        if mismatch is not None:
            idx, expected, actual = mismatch
            row = idx // width if isinstance(idx, int) else "?"
            col = idx % width if isinstance(idx, int) else "?"
            if trace:
                print_trace(case_name, config, recomputed)
            raise VerifyError(
                "stage: final clip10 / output_signed, "
                f"addr={idx}, row={row}, col={col}, expected={expected}, actual={actual}"
            )

        actual_packed = recomputed["packed_words"]
        mismatch = first_mismatch(expected_packed_words, actual_packed)
        if mismatch is not None:
            idx, expected, actual = mismatch
            if trace:
                print_trace(case_name, config, recomputed)
            raise VerifyError(
                "stage: output_packed, "
                f"line={idx}, expected={expected:010X}, actual={actual:010X}"
            )

        return CaseResult(case_name, True, "OK")
    except Exception as exc:
        return CaseResult(case_name, False, str(exc))


def load_case_dirs(golden_dir: str, only_case: str | None) -> list[str]:
    if not os.path.isdir(golden_dir):
        raise VerifyError(f"golden data directory not found: {golden_dir}")

    if only_case:
        case_dir = os.path.join(golden_dir, only_case)
        if not os.path.isdir(case_dir):
            raise VerifyError(f"case not found: {only_case}")
        return [case_dir]

    case_dirs = []
    for name in sorted(os.listdir(golden_dir)):
        path = os.path.join(golden_dir, name)
        if os.path.isdir(path):
            case_dirs.append(path)
    return case_dirs


def verify_all(golden_dir: str, only_case: str | None, trace: bool) -> int:
    case_dirs = load_case_dirs(golden_dir, only_case)
    if not case_dirs:
        raise VerifyError("no golden case directories found")

    results = [validate_case_dir(case_dir, trace) for case_dir in case_dirs]

    failed = [result for result in results if not result.ok]
    for result in results:
        status = "PASS" if result.ok else "FAIL"
        print(f"[{status}] {result.case_name}: {result.message}")

    print(f"\nchecked {len(results)} case(s), passed {len(results) - len(failed)}, failed {len(failed)}")
    return 1 if failed else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify generated ITS golden data independently.")
    parser.add_argument("--case", help="verify one generated case directory by name")
    parser.add_argument("--trace", action="store_true", help="print intermediate recompute trace on failure")
    parser.add_argument(
        "--golden-dir",
        default=GOLDEN_DIR,
        help="path to golden_data/generated (defaults to this project)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        return verify_all(args.golden_dir, args.case, args.trace)
    except VerifyError as exc:
        print(f"[ERROR] {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
