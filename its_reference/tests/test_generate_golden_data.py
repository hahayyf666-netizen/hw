import os
import sys

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from generate_golden_data import GOLDEN_DIR, generate_golden_data


def test_generate_golden_data_smoke():
    summary = generate_golden_data()
    assert len(summary) == 12
    assert all(item["output_group_count"] > 0 for item in summary)
    assert os.path.exists(os.path.join(GOLDEN_DIR, "summary.json"))


if __name__ == "__main__":
    test_generate_golden_data_smoke()
    print("test_generate_golden_data passed")
