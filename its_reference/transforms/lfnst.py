"""
LFNST（Low-frequency non-separable transform）反变换（修正版）
VVC 协议的二次变换，进一步压缩低频系数

算法流程（修正版）：
1. 判断 nTrs（16 或 48）和 nonZeroSize（8 或 16）
2. 从输入按左上4x4低频扫描顺序取nonZeroSize个系数
3. 矩阵乘：Y = T × X（T 是变换核矩阵）
4. 输出数量等于nTrs（不是nonZeroSize）
5. 限幅输出：y[i] = Clip3(-32768, 32767, (Y[i] + 64) >> 7)

关键点（修正）：
- lfnst_idx=0 时直通，不做变换
- 输入按左上4x4低频扫描顺序取数（不是直接取前nonZeroSize个）
- 输出数量 = nTrs（16或48），不是nonZeroSize
- 所有地址都用实际tu_width计算
"""

import sys
import os

# 添加上级目录到路径，方便导入
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from matrices.lfnst_kernels import LFNST_KERNELS
from common.utils import Clip3
from common.fixed_point import round_shift


# 左上4x4低频扫描坐标表（修正新增）
# 按照对角线顺序：row+col从小到大，同一条对角线从上到下
LOW_FREQ_COORDS_4x4 = [
    (0, 0),  # row+col=0
    (1, 0), (0, 1),  # row+col=1
    (2, 0), (1, 1), (0, 2),  # row+col=2
    (3, 0), (2, 1), (1, 2), (0, 3),  # row+col=3
    (3, 1), (2, 2), (1, 3),  # row+col=4
    (3, 2), (2, 3),  # row+col=5
    (3, 3),  # row+col=6
]


def get_nTrs(tu_width, tu_height):
    """
    判断 nTrs 的值

    规则：
        nTrs = (tu_width >= 8 && tu_height >= 8) ? 48 : 16

    参数：
        tu_width: TU 宽度
        tu_height: TU 高度

    返回：
        nTrs（16 或 48）

    示例：
        get_nTrs(4, 4) → 16
        get_nTrs(4, 8) → 16
        get_nTrs(8, 8) → 48
        get_nTrs(16, 16) → 48
    """
    if tu_width >= 8 and tu_height >= 8:
        return 48
    else:
        return 16


def get_nonZeroSize(tu_width, tu_height):
    """
    判断 nonZeroSize 的值

    规则：
        nonZeroSize = ((tu_width == 4 && tu_height == 4) ||
                       (tu_width == 8 && tu_height == 8)) ? 8 : 16

    参数：
        tu_width: TU 宽度
        tu_height: TU 高度

    返回：
        nonZeroSize（8 或 16）

    示例：
        get_nonZeroSize(4, 4) → 8
        get_nonZeroSize(8, 8) → 8
        get_nonZeroSize(4, 8) → 16
        get_nonZeroSize(16, 16) → 16
    """
    if (tu_width == 4 and tu_height == 4) or (tu_width == 8 and tu_height == 8):
        return 8
    else:
        return 16


def normalize_lfnst_matrix(matrix, nTrs, nonZeroSize):
    """
    Return LFNST matrix in VTM inverse layout: [input_idx][output_idx].

    Some generated 8x8 tables are stored as 48x16 after parsing; each VTM row
    is split into three 16-column segments, so concatenate those segments.
    """
    if len(matrix) >= nonZeroSize and all(len(row) == nTrs for row in matrix):
        return matrix[:nonZeroSize]

    if nTrs == 48 and len(matrix) == 48 and all(len(row) == 16 for row in matrix):
        return [
            matrix[row] + matrix[row + 16] + matrix[row + 32]
            for row in range(nonZeroSize)
        ]

    flat = []
    for row in matrix:
        flat.extend(row)

    full_input_size = 16
    expected_full = full_input_size * nTrs
    expected_used = nonZeroSize * nTrs
    if len(flat) == expected_full:
        reshaped = [
            flat[row * nTrs:(row + 1) * nTrs]
            for row in range(full_input_size)
        ]
        return reshaped[:nonZeroSize]
    if len(flat) != expected_used:
        raise ValueError(
            f"LFNST matrix shape mismatch: expected {nonZeroSize}x{nTrs}, "
            f"got {len(matrix)} rows and {len(flat)} values"
        )

    return [
        flat[row * nTrs:(row + 1) * nTrs]
        for row in range(nonZeroSize)
    ]


def lfnst_inverse(coeffs, tu_width, tu_height, lfnst_tr_set_idx, lfnst_idx):
    """
    LFNST 反变换主函数（修正版）

    流程：
        1. lfnst_idx=0 → 直通返回
        2. 判断 nTrs 和 nonZeroSize
        3. 按左上4x4低频扫描坐标取nonZeroSize个系数（修正）
        4. 查表获取变换核矩阵
        5. 矩阵乘：Y = T × X，输出数量=nTrs（修正）
        6. 限幅输出

    参数：
        coeffs: 输入系数列表（光栅扫描顺序）
        tu_width: TU 宽度
        tu_height: TU 高度
        lfnst_tr_set_idx: 变换类型集索引（0~3）
        lfnst_idx: 变换核索引（1~3，0表示直通）

    返回：
        变换后的系数列表（数量=nTrs，修正）

    注意（修正）：
        - 输入按左上4x4低频扫描坐标取数，地址用tu_width计算
        - 输出数量 = nTrs（16或48），不是nonZeroSize
        - nTrs=48时需要tu_width>=8且tu_height>=8保护
    """
    # Step 1: lfnst_idx=0 直通
    if lfnst_idx == 0:
        return coeffs  # 不做变换，直接返回

    # Step 2: 判断 nTrs 和 nonZeroSize
    nTrs = get_nTrs(tu_width, tu_height)
    nonZeroSize = get_nonZeroSize(tu_width, tu_height)

    # 保护检查（修正）
    if nTrs == 48:
        if not (tu_width >= 8 and tu_height >= 8):
            raise ValueError(f"nTrs=48要求tu_width>=8且tu_height>=8，实际: {tu_width}x{tu_height}")

    # Step 3: 按低频扫描坐标取系数（修正）
    # 使用左上4x4低频扫描坐标表，转换为真实地址
    input_coeffs = []
    for i in range(min(nonZeroSize, len(LOW_FREQ_COORDS_4x4))):
        row, col = LOW_FREQ_COORDS_4x4[i]
        addr = row * tu_width + col  # 用tu_width计算地址
        if addr < len(coeffs):
            input_coeffs.append(coeffs[addr])
        else:
            input_coeffs.append(0)  # 超出范围补0

    # 补齐到nonZeroSize
    while len(input_coeffs) < nonZeroSize:
        input_coeffs.append(0)

    # Step 4: 查表获取变换核矩阵
    try:
        matrix = LFNST_KERNELS[nTrs][lfnst_tr_set_idx][lfnst_idx]
        matrix = normalize_lfnst_matrix(matrix, nTrs, nonZeroSize)
    except KeyError:
        raise ValueError(f"找不到矩阵：nTrs={nTrs}, tr_set={lfnst_tr_set_idx}, idx={lfnst_idx}")

    # Step 5: 矩阵乘（修正）
    # 输出数量 = nTrs，遍历nTrs行、nonZeroSize列
    output_size = nTrs
    output_coeffs = []

    for i in range(output_size):
        # 第 i 行：Y[i] = sum(T[i][j] × X[j])
        sum_val = 0
        for j in range(nonZeroSize):
            sum_val += matrix[j][i] * input_coeffs[j]

        # Step 6: 限幅输出
        # 公式：y[i] = Clip3(-32768, 32767, (sum + 64) >> 7)
        output_val = round_shift(sum_val, 7)
        output_val = Clip3(-32768, 32767, output_val)

        output_coeffs.append(output_val)

    return output_coeffs


def test_lfnst():
    """
    测试 LFNST 反变换（修正版）
    """
    print("测试 LFNST 反变换...")

    # 测试1：直通（lfnst_idx=0）
    print("  测试直通...")
    coeffs = [100, 200, 300, -100, -200, -300, 50, -50]
    result = lfnst_inverse(coeffs, 4, 4, lfnst_tr_set_idx=0, lfnst_idx=0)
    assert result == coeffs
    print("    直通测试通过")

    # 测试2：nTrs=16, nonZeroSize=8（4x4 TU）- 输出数量=16（修正）
    print("  测试 nTrs=16, nonZeroSize=8...")
    coeffs = [100, 200, 300, -100, -200, -300, 50, -50, 0, 0, 0, 0, 0, 0, 0, 0]
    result = lfnst_inverse(coeffs, 4, 4, lfnst_tr_set_idx=0, lfnst_idx=1)
    assert len(result) == 16  # 修正：输出数量=nTrs=16
    # 验证输出在有效范围内
    for val in result:
        assert -32768 <= val <= 32767
    print(f"    输出长度: {len(result)}, 输出范围正常")

    # 测试3：nTrs=16, nonZeroSize=16（4x8 TU）- 输出数量=16（修正）
    print("  测试 nTrs=16, nonZeroSize=16...")
    coeffs = [100] * 32  # 32个系数（4x8）
    result = lfnst_inverse(coeffs, 4, 8, lfnst_tr_set_idx=0, lfnst_idx=1)
    assert len(result) == 16  # 修正：输出数量=nTrs=16
    for val in result:
        assert -32768 <= val <= 32767
    print(f"    输出长度: {len(result)}, 输出范围正常")

    # 测试4：nTrs=48（8x8 TU）- 输出数量=48（修正）
    print("  测试 nTrs=48...")
    coeffs = [100] * 64  # 64个系数（8x8）
    result = lfnst_inverse(coeffs, 8, 8, lfnst_tr_set_idx=0, lfnst_idx=1)
    assert len(result) == 48  # 修正：输出数量=nTrs=48
    for val in result:
        assert -32768 <= val <= 32767
    print(f"    输出长度: {len(result)}, 输出范围正常")

    # 测试5：低频扫描地址验证（修正新增）
    print("  测试低频扫描地址...")
    # tu_width=4时，验证地址序列
    expected_addresses = []
    for i in range(8):  # nonZeroSize=8 for 4x4
        row, col = LOW_FREQ_COORDS_4x4[i]
        addr = row * 4 + col
        expected_addresses.append(addr)
    assert expected_addresses == [0, 4, 1, 8, 5, 2, 12, 9]
    print(f"    低频扫描地址序列（tu_width=4）: {expected_addresses}")

    # 测试6：全零输入
    print("  测试全零输入...")
    coeffs = [0] * 16
    result = lfnst_inverse(coeffs, 4, 4, lfnst_tr_set_idx=0, lfnst_idx=1)
    assert len(result) == 16
    print(f"    输出长度: {len(result)}, 全零输入测试通过")

    # 测试7：极值输入（最大最小值）
    print("  测试极值输入...")
    coeffs = [32767] * 16  # 全部最大值
    result = lfnst_inverse(coeffs, 4, 4, lfnst_tr_set_idx=0, lfnst_idx=1)
    assert len(result) == 16
    for val in result:
        assert -32768 <= val <= 32767
    print(f"    输出长度: {len(result)}, 极值输入测试通过")

    # 测试8：不同 tr_set_idx
    print("  测试不同 tr_set_idx...")
    for tr_set in [0, 1, 2, 3]:
        coeffs = [100] * 16
        result = lfnst_inverse(coeffs, 4, 4, lfnst_tr_set_idx=tr_set, lfnst_idx=1)
        assert len(result) == 16
        for val in result:
            assert -32768 <= val <= 32767
    print("    所有 tr_set_idx 测试通过")

    # 测试9：不同 lfnst_idx
    print("  测试不同 lfnst_idx...")
    for idx in [1, 2]:  # 注意：华为附件只提供了 idx=1 和 2
        coeffs = [100] * 16
        result = lfnst_inverse(coeffs, 4, 4, lfnst_tr_set_idx=0, lfnst_idx=idx)
        assert len(result) == 16
        for val in result:
            assert -32768 <= val <= 32767
    print("    所有 lfnst_idx (1,2) 测试通过")

    # 测试10：nTrs判断验证（修正）
    print("  测试 nTrs判断...")
    assert get_nTrs(4, 4) == 16
    assert get_nTrs(4, 8) == 16  # width<8，所以是16（不是48）
    assert get_nTrs(8, 4) == 16  # height<8，所以是16（不是48）
    assert get_nTrs(8, 8) == 48  # both>=8，才是48
    assert get_nTrs(16, 16) == 48
    print("    nTrs判断逻辑正确")

    print("所有 LFNST 测试通过（修正版）！")


def demonstrate_lfnst():
    """
    演示 LFNST 的实际计算过程
    方便理解算法细节
    """
    print("\n=== LFNST 反变换演示 ===")

    # 示例1：4x4 TU, nTrs=16, nonZeroSize=8
    print("\n示例1: 4x4 TU")
    print(f"  nTrs: {get_nTrs(4, 4)}")
    print(f"  nonZeroSize: {get_nonZeroSize(4, 4)}")

    coeffs = [100, 200, 50, -50, 30, -30, 10, -10]
    print(f"  输入系数（前8个）: {coeffs}")

    result = lfnst_inverse(coeffs, 4, 4, lfnst_tr_set_idx=0, lfnst_idx=1)
    print(f"  输出系数: {result}")

    # 示例2：8x8 TU, nTrs=48, nonZeroSize=8
    print("\n示例2: 8x8 TU")
    print(f"  nTrs: {get_nTrs(8, 8)}")
    print(f"  nonZeroSize: {get_nonZeroSize(8, 8)}")

    coeffs = [100, 200, 50, -50, 30, -30, 10, -10]
    print(f"  输入系数（前8个）: {coeffs}")

    result = lfnst_inverse(coeffs, 8, 8, lfnst_tr_set_idx=0, lfnst_idx=1)
    print(f"  输出系数: {result}")

    # 示例3：4x8 TU, nTrs=16, nonZeroSize=16
    print("\n示例3: 4x8 TU")
    print(f"  nTrs: {get_nTrs(4, 8)}")
    print(f"  nonZeroSize: {get_nonZeroSize(4, 8)}")

    coeffs = [100] * 16
    print(f"  输入系数（前16个）: {coeffs}")

    result = lfnst_inverse(coeffs, 4, 8, lfnst_tr_set_idx=0, lfnst_idx=1)
    print(f"  输出系数: {result}")


if __name__ == "__main__":
    print("开始测试 LFNST 模块...")
    test_lfnst()

    print("\n演示 LFNST 计算过程...")
    demonstrate_lfnst()

    print("\n=== LFNST 算法要点总结（修正版）===")
    print("1. lfnst_idx=0 时直通，不做变换")
    print("2. nTrs 判断：tu_width>=8 && tu_height>=8 → 48，否则 16")
    print("3. nonZeroSize 判断：")
    print("   - (4x4 或 8x8) → 8")
    print("   - 其他尺寸 → 16")
    print("4. 输入：按左上4x4低频扫描顺序取nonZeroSize个系数（修正）")
    print("5. 输出限幅：Clip3(-32768, 32767, round_shift(sum, 7))")
    print("6. 输出长度 = nTrs（修正：不是nonZeroSize）")
