"""
DST-VII and DCT-VIII 1D inverse transform module delivered by member B.

Official interfaces:
    idst7_1d(coeffs, length, shift, clip_bits=None) -> list[int]
    idct8_1d(coeffs, length, shift, clip_bits=None) -> list[int]
"""

import os
import sys

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from common.fixed_point import round_shift, saturate
from matrices.trans_matrix import TR_DCT8, TR_DST7, VALID_MTS_LENGTHS, get_trans_matrix


VALID_MTS_1D_LENGTHS = VALID_MTS_LENGTHS


def _inverse_1d(coeffs, length, shift, clip_bits, tr_type, name):
    if length not in VALID_MTS_1D_LENGTHS:
        raise ValueError(f"{name} length must be one of {VALID_MTS_1D_LENGTHS}, got {length}")
    if len(coeffs) != length:
        raise ValueError(f"{name} input length mismatch: expected {length}, got {len(coeffs)}")

    matrix = get_trans_matrix(tr_type, length)
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


def idst7_1d(coeffs, length, shift, clip_bits=None):
    """Run one DST-VII inverse 1D transform."""
    return _inverse_1d(coeffs, length, shift, clip_bits, TR_DST7, "DST7")


def idct8_1d(coeffs, length, shift, clip_bits=None):
    """Run one DCT-VIII inverse 1D transform."""
    return _inverse_1d(coeffs, length, shift, clip_bits, TR_DCT8, "DCT8")


def _test_dct8_dst7_1d():
    assert idst7_1d([0] * 4, 4, 7, 16) == [0, 0, 0, 0]
    assert idct8_1d([0] * 4, 4, 7, 16) == [0, 0, 0, 0]

    for length in VALID_MTS_1D_LENGTHS:
        dst7_result = idst7_1d([1] * length, length, 7, 16)
        dct8_result = idct8_1d([1] * length, length, 7, 16)
        assert len(dst7_result) == length
        assert len(dct8_result) == length
        assert all(-32768 <= value <= 32767 for value in dst7_result)
        assert all(-32768 <= value <= 32767 for value in dct8_result)

    for func in (idst7_1d, idct8_1d):
        try:
            func([0] * 64, 64, 7, 16)
            raise AssertionError("invalid length did not raise ValueError")
        except ValueError:
            pass

        try:
            func([0, 0, 0], 4, 7, 16)
            raise AssertionError("input length mismatch did not raise ValueError")
        except ValueError:
            pass


if __name__ == "__main__":
    _test_dct8_dst7_1d()
    print("dct8_dst7 self-test passed")
