"""
DCT-II 1D inverse transform module delivered by member A.

Official interface:
    idct2_1d(coeffs, length, shift, clip_bits=None) -> list[int]
"""

import os
import sys

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from common.fixed_point import round_shift, saturate
from matrices.trans_matrix import TR_DCT2, VALID_TRANSFORM_LENGTHS, get_trans_matrix


VALID_DCT2_LENGTHS = VALID_TRANSFORM_LENGTHS


def idct2_1d(coeffs, length, shift, clip_bits=None):
    """
    Run one DCT-II inverse 1D transform.

    Args:
        coeffs: input coefficients in list[int] form.
        length: transform length, one of 4/8/16/32/64.
        shift: right shift passed by the top-level reference model.
        clip_bits: optional signed saturation width after round_shift.

    Returns:
        list[int] with exactly length points.
    """
    if length not in VALID_DCT2_LENGTHS:
        raise ValueError(f"DCT2 length must be one of {VALID_DCT2_LENGTHS}, got {length}")
    if len(coeffs) != length:
        raise ValueError(f"DCT2 input length mismatch: expected {length}, got {len(coeffs)}")

    matrix = get_trans_matrix(TR_DCT2, length)
    output = []

    for out_idx in range(length):
        acc = 0
        for in_idx in range(length):
            acc += matrix[in_idx][out_idx] * int(coeffs[in_idx])

        value = round_shift(acc, shift)
        if clip_bits is not None:
            value = saturate(value, clip_bits)
        output.append(value)

    return output


def _test_idct2_1d():
    assert idct2_1d([0] * 4, 4, 7, 16) == [0, 0, 0, 0]

    for length in VALID_DCT2_LENGTHS:
        result = idct2_1d([1] * length, length, 7, 16)
        assert len(result) == length
        assert all(-32768 <= value <= 32767 for value in result)

    try:
        idct2_1d([0, 0, 0], 3, 7, 16)
        raise AssertionError("invalid length did not raise ValueError")
    except ValueError:
        pass

    try:
        idct2_1d([0, 0, 0], 4, 7, 16)
        raise AssertionError("input length mismatch did not raise ValueError")
    except ValueError:
        pass


if __name__ == "__main__":
    _test_idct2_1d()
    print("dct2 self-test passed")
