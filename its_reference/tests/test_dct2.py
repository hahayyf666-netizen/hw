import os
import sys

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from transforms.dct2 import VALID_DCT2_LENGTHS, idct2_1d


def _expect_value_error(func):
    try:
        func()
    except ValueError:
        return
    raise AssertionError("ValueError was not raised")


def test_idct2_1d_interface():
    assert idct2_1d([0] * 4, 4, 7, 16) == [0, 0, 0, 0]

    for length in VALID_DCT2_LENGTHS:
        output = idct2_1d([1] * length, length, 7, 16)
        assert len(output) == length
        assert all(-32768 <= value <= 32767 for value in output)

    _expect_value_error(lambda: idct2_1d([0, 0, 0], 3, 7, 16))
    _expect_value_error(lambda: idct2_1d([0, 0, 0], 4, 7, 16))


if __name__ == "__main__":
    test_idct2_1d_interface()
    print("test_dct2 passed")
