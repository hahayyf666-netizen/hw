import os
import sys

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from transforms.dct8_dst7 import VALID_MTS_1D_LENGTHS, idct8_1d, idst7_1d


def _expect_value_error(func):
    try:
        func()
    except ValueError:
        return
    raise AssertionError("ValueError was not raised")


def test_dct8_dst7_1d_interface():
    assert idst7_1d([0] * 4, 4, 7, 16) == [0, 0, 0, 0]
    assert idct8_1d([0] * 4, 4, 7, 16) == [0, 0, 0, 0]

    for length in VALID_MTS_1D_LENGTHS:
        dst7_output = idst7_1d([1] * length, length, 7, 16)
        dct8_output = idct8_1d([1] * length, length, 7, 16)
        assert len(dst7_output) == length
        assert len(dct8_output) == length
        assert all(-32768 <= value <= 32767 for value in dst7_output)
        assert all(-32768 <= value <= 32767 for value in dct8_output)

    _expect_value_error(lambda: idst7_1d([0] * 64, 64, 7, 16))
    _expect_value_error(lambda: idct8_1d([0] * 64, 64, 7, 16))
    _expect_value_error(lambda: idst7_1d([0, 0, 0], 4, 7, 16))
    _expect_value_error(lambda: idct8_1d([0, 0, 0], 4, 7, 16))


if __name__ == "__main__":
    test_dct8_dst7_1d_interface()
    print("test_dct8_dst7 passed")
