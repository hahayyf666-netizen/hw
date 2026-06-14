"""
Integer transform matrices used by the Python ITS reference model.

The coefficients are generated from VTM/Huawei integer base tables, not from
floating point formulas.  The generated rows match the transMatrix entries:
    trType = 0: DCT-II
    trType = 1: DST-VII
    trType = 2: DCT-VIII
"""

TR_DCT2 = 0
TR_DST7 = 1
TR_DCT8 = 2

VALID_TRANSFORM_LENGTHS = (4, 8, 16, 32, 64)
VALID_MTS_LENGTHS = (4, 8, 16, 32)

# VTM integer values for round(64 * cos(k*pi/128)), k = 0..64.
_COSPI = [0] * 65
_COSPI[0] = 64
_COSPI[64] = 0

_COSPI_VALUES = {
    1: 91, 2: 90, 3: 90, 4: 90, 5: 90, 6: 90, 7: 90,
    8: 89, 9: 88, 10: 88, 11: 87, 12: 87, 13: 86, 14: 85,
    15: 84, 16: 83, 17: 83, 18: 82, 19: 81, 20: 80, 21: 79,
    22: 78, 23: 77, 24: 75, 25: 73, 26: 73, 27: 71, 28: 70,
    29: 69, 30: 67, 31: 65, 32: 64, 33: 62, 34: 61, 35: 59,
    36: 57, 37: 56, 38: 54, 39: 52, 40: 50, 41: 48, 42: 46,
    43: 44, 44: 43, 45: 41, 46: 38, 47: 37, 48: 36, 49: 33,
    50: 31, 51: 28, 52: 25, 53: 24, 54: 22, 55: 20, 56: 18,
    57: 15, 58: 13, 59: 11, 60: 9, 61: 7, 62: 4, 63: 2,
}
for _idx, _value in _COSPI_VALUES.items():
    _COSPI[_idx] = _value


def _cospi(index):
    """Return the VTM integer cospi value for index*pi/128."""
    index %= 256
    if index <= 64:
        return _COSPI[index]
    if index <= 128:
        return -_COSPI[128 - index]
    if index <= 192:
        return -_COSPI[index - 128]
    return _COSPI[256 - index]


def _build_dct2_matrix(length):
    if length not in VALID_TRANSFORM_LENGTHS:
        raise ValueError(f"unsupported DCT2 length: {length}")

    step = 64 // length
    matrix = []
    for out_idx in range(length):
        row = []
        for in_idx in range(length):
            angle_index = (2 * in_idx + 1) * out_idx * step
            row.append(_cospi(angle_index))
        matrix.append(row)
    return matrix


_DCT8_BASE = {
    4: [84, 74, 55, 29],
    8: [86, 85, 78, 71, 60, 46, 32, 17],
    16: [88, 88, 87, 85, 81, 77, 73, 68, 62, 55, 48, 40, 33, 25, 17, 8],
    32: [
        90, 90, 89, 88, 87, 86, 85, 84,
        82, 80, 78, 77, 74, 72, 68, 66,
        63, 60, 56, 53, 50, 46, 42, 38,
        34, 30, 26, 21, 17, 13, 9, 4,
    ],
}

_DST7_BASE = {
    4: [29, 55, 74, 84],
    8: [17, 32, 46, 60, 71, 78, 85, 86],
    16: [8, 17, 25, 33, 40, 48, 55, 62, 68, 73, 77, 81, 85, 87, 88, 88],
    32: [
        4, 9, 13, 17, 21, 26, 30, 34,
        38, 42, 46, 50, 53, 56, 60, 63,
        66, 68, 72, 74, 77, 78, 80, 82,
        84, 85, 86, 87, 88, 89, 90, 90,
    ],
}


def _dct8_value(base, length, odd_index):
    denominator = 4 * length + 2
    period = 2 * denominator
    odd_index %= period

    if odd_index > denominator:
        return -_dct8_value(base, length, odd_index - denominator)
    if odd_index == 2 * length + 1:
        return 0
    if odd_index < 2 * length + 1:
        return base[(odd_index - 1) // 2]
    return -base[(denominator - odd_index - 1) // 2]


def _dst7_value(base, length, index):
    denominator = 2 * length + 1
    period = 2 * denominator
    index %= period

    if index == 0 or index == denominator:
        return 0
    if index > denominator:
        return -_dst7_value(base, length, index - denominator)
    if index <= length:
        return base[index - 1]
    return base[denominator - index - 1]


def _build_dct8_matrix(length):
    if length not in VALID_MTS_LENGTHS:
        raise ValueError(f"unsupported DCT8 length: {length}")

    base = _DCT8_BASE[length]
    matrix = []
    for out_idx in range(length):
        row = []
        for in_idx in range(length):
            index = (2 * out_idx + 1) * (2 * in_idx + 1)
            row.append(_dct8_value(base, length, index))
        matrix.append(row)
    return matrix


def _build_dst7_matrix(length):
    if length not in VALID_MTS_LENGTHS:
        raise ValueError(f"unsupported DST7 length: {length}")

    base = _DST7_BASE[length]
    matrix = []
    for out_idx in range(length):
        row = []
        for in_idx in range(length):
            index = (2 * out_idx + 1) * (in_idx + 1)
            row.append(_dst7_value(base, length, index))
        matrix.append(row)
    return matrix


TRANS_MATRIX = {
    TR_DCT2: {length: _build_dct2_matrix(length) for length in VALID_TRANSFORM_LENGTHS},
    TR_DST7: {length: _build_dst7_matrix(length) for length in VALID_MTS_LENGTHS},
    TR_DCT8: {length: _build_dct8_matrix(length) for length in VALID_MTS_LENGTHS},
}


def get_trans_matrix(tr_type, length):
    if tr_type not in TRANS_MATRIX:
        raise ValueError(f"unsupported transform type: {tr_type}")
    if length not in TRANS_MATRIX[tr_type]:
        raise ValueError(f"unsupported transform length: {length}")
    return TRANS_MATRIX[tr_type][length]


def _test_dct2_matrices():
    assert get_trans_matrix(TR_DCT2, 4) == [
        [64, 64, 64, 64],
        [83, 36, -36, -83],
        [64, -64, -64, 64],
        [36, -83, 83, -36],
    ]
    assert get_trans_matrix(TR_DCT2, 8)[1] == [89, 75, 50, 18, -18, -50, -75, -89]
    assert get_trans_matrix(TR_DCT2, 64)[0] == [64] * 64
    assert len(get_trans_matrix(TR_DCT2, 64)) == 64
    assert len(get_trans_matrix(TR_DCT2, 64)[0]) == 64
    assert get_trans_matrix(TR_DCT8, 4) == [
        [84, 74, 55, 29],
        [74, 0, -74, -74],
        [55, -74, -29, 84],
        [29, -74, 84, -55],
    ]
    assert get_trans_matrix(TR_DST7, 4) == [
        [29, 55, 74, 84],
        [74, 74, 0, -74],
        [84, -29, -74, 55],
        [55, -84, 74, -29],
    ]
    assert len(get_trans_matrix(TR_DCT8, 32)) == 32
    assert len(get_trans_matrix(TR_DST7, 32)[0]) == 32


if __name__ == "__main__":
    _test_dct2_matrices()
    print("trans_matrix self-test passed")
