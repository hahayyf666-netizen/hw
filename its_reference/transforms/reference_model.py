"""
ITS（Inverse Transform）完整反变换流程集成
第2周的目标：把 A、B 的 DCT 变换模块集成进来

当前状态（第1周末）：
- LFNST 部分已实装（C完成）
- DCT2 已接入 transforms/dct2.py
- DST7/DCT8 已接入 transforms/dct8_dst7.py
- 流程框架已搭建

第2周集成时需要做的：
- 使用统一 list[int] 1D 接口生成 golden data
"""

import sys
import os

# 添加上级目录到路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from transforms.lfnst import lfnst_inverse, get_nTrs, get_nonZeroSize
from transforms.dct2 import idct2_1d
from transforms.dct8_dst7 import idct8_1d, idst7_1d
from common.utils import raster_to_matrix, matrix_to_raster, transpose, split_into_groups, pack_4_points
from common.fixed_point import FIRST_1D_SHIFT, SECOND_1D_SHIFT, FIRST_1D_CLIP_BITS, clip_final_output


def dispatch_1d_transform(coeffs, tr_type, length, shift, clip_bits=None):
    """
    Unified 1D inverse transform dispatcher.

    Args:
        coeffs: One row or column in list[int] form.
        tr_type: Transform type, 0=DCT2, 1=DST7, 2=DCT8.
        length: Transform length.
        shift: Right shift for this 1D stage.
        clip_bits: Optional signed saturation width after rounding.

    Returns:
        list[int] with exactly length points.
    """
    if tr_type == 0:
        return idct2_1d(coeffs, length, shift, clip_bits)
    if tr_type == 1:
        return idst7_1d(coeffs, length, shift, clip_bits)
    if tr_type == 2:
        return idct8_1d(coeffs, length, shift, clip_bits)
    raise ValueError(f"unsupported tr_type: {tr_type}")

def rebuild_dense_tu(sparse_coeffs, tu_width, tu_height):
    """
    从稀疏输入重建dense TU（修正新增）

    赛题输入形式：it_data_in + it_data_addr，只输入非零点
    格式：[(地址, 值), (地址, 值), ...]

    参数：
        sparse_coeffs: 稀疏系数列表，格式[(addr, value), ...]
        tu_width: TU 宽度
        tu_height: TU 高度

    返回：
        dense系数列表（长度 = tu_width × tu_height，未输入位置为0）

    示例：
        sparse_coeffs = [(0, 100), (4, 200), (1, 50)]
        rebuild_dense_tu(sparse_coeffs, 4, 4) → [100, 50, 0, 0, 200, 0, 0, 0, ...]
    """
    total_size = tu_width * tu_height
    dense_coeffs = [0] * total_size

    for addr, value in sparse_coeffs:
        if addr < total_size:
            dense_coeffs[addr] = value

    return dense_coeffs


def its_inverse_sparse(tu_width, tu_height, tr_type_hor, tr_type_ver,
                       lfnst_tr_set_idx, lfnst_idx, sparse_coeffs):
    """
    ITS完整反变换流程（稀疏输入版本，修正新增）

    参数：
        sparse_coeffs: 稀疏系数列表，格式[(addr, value), ...]
        其他参数同its_inverse()

    返回：
        输出数据列表（光栅扫描顺序，每4个点一组）

    用途：
        对接赛题真实输入格式（it_data_in + it_data_addr）
    """
    # Step 1: 从稀疏输入重建dense TU
    dense_coeffs = rebuild_dense_tu(sparse_coeffs, tu_width, tu_height)

    # Step 2: 调用dense版本的its_inverse
    return its_inverse(tu_width, tu_height, tr_type_hor, tr_type_ver,
                       lfnst_tr_set_idx, lfnst_idx, dense_coeffs)


def its_inverse(tu_width, tu_height, tr_type_hor, tr_type_ver,
                lfnst_tr_set_idx, lfnst_idx, input_coeffs):
    """
    ITS 完整反变换流程

    流程：
        Step 1: LFNST 反变换（可选）
        Step 2: 光栅顺序转二维矩阵
        Step 3: 第一遍 1D：列方向（垂直）反变换，shift=7
        Step 4: 第二遍 1D：行方向（水平）反变换，shift=10
        Step 5: 输出格式化（光栅顺序，一拍4点）

    参数：
        tu_width: TU 宽度（4~64）
        tu_height: TU 高度（4~64）
        tr_type_hor: 水平变换类型（0=DCT2, 1=DST7, 2=DCT8）
        tr_type_ver: 垂直变换类型（0=DCT2, 1=DST7, 2=DCT8）
        lfnst_tr_set_idx: LFNST 变换类型集索引（0~3）
        lfnst_idx: LFNST 变换核索引（0=直通, 1~2=变换）
        input_coeffs: 输入系数列表（光栅扫描顺序）

    返回：
        输出数据列表（光栅扫描顺序，每4个点一组）

    示例：
        # 4x4 TU, LFNST+DCT2
        result = its_inverse(4, 4, 0, 0, 0, 1, coeffs)
    """
    # ========================================
    # Step 1: LFNST 反变换（预处理）
    # ========================================
    if lfnst_idx != 0:
        # 做 LFNST 变换
        lfnst_result = lfnst_inverse(
            input_coeffs,
            tu_width,
            tu_height,
            lfnst_tr_set_idx,
            lfnst_idx
        )

        # LFNST 输出需要填充到完整 TU 大小
        # LFNST 只处理左上角区域，其余位置补0
        full_coeffs = fill_lfnst_output(lfnst_result, tu_width, tu_height, lfnst_idx)
    else:
        # 不做 LFNST，直接使用输入数据
        full_coeffs = input_coeffs

    # ========================================
    # Step 2: 光栅顺序 → 二维矩阵
    # ========================================
    # 把光栅顺序的系数转成 height × width 的矩阵
    matrix = raster_to_matrix(full_coeffs, tu_width, tu_height)

    # ========================================
    # Step 3: 第一遍 1D 反变换（列方向 / 垂直方向）
    # ========================================
    # VTM inverse transform 第一遍使用垂直方向 tr_type_ver，shift=7
    # 第一遍输出写回同一列位置，避免 4x8 / 8x4 等非方块 TU 转置错位
    tmp = [[0] * tu_width for _ in range(tu_height)]

    for col_idx in range(tu_width):
        col = [matrix[row_idx][col_idx] for row_idx in range(tu_height)]
        transformed_col = dispatch_1d_transform(
            col,
            tr_type_ver,
            tu_height,
            shift=FIRST_1D_SHIFT,
            clip_bits=FIRST_1D_CLIP_BITS
        )

        for row_idx in range(tu_height):
            tmp[row_idx][col_idx] = transformed_col[row_idx]

    # ========================================
    # Step 4: 第二遍 1D 反变换（行方向 / 水平方向）
    # ========================================
    # VTM inverse transform 第二遍使用水平方向 tr_type_hor，shift=10
    final_matrix = [[0] * tu_width for _ in range(tu_height)]

    for row_idx in range(tu_height):
        row = tmp[row_idx]
        transformed_row = dispatch_1d_transform(
            row,
            tr_type_hor,
            tu_width,
            shift=SECOND_1D_SHIFT,
            clip_bits=None
        )
        final_matrix[row_idx] = transformed_row

    # ========================================
    # Step 5: 二维矩阵 → 光栅顺序
    # ========================================
    output_coeffs = [clip_final_output(value) for value in matrix_to_raster(final_matrix)]

    # ========================================
    # Step 6: 输出格式化（一拍4点）
    # ========================================
    # 按光栅顺序，每4个点一组
    output_groups = split_into_groups(output_coeffs, 4)

    # 可选：拼接成40bit格式（用于RTL比对）
    # packed_output = [pack_4_points(group) for group in output_groups]

    return output_groups


def fill_lfnst_output(lfnst_coeffs, tu_width, tu_height, lfnst_idx):
    """
    把 LFNST 输出填充到完整 TU 大小（修正版）

    LFNST 只处理左上角区域（修正）：
        - nTrs=16 时：左上角 4×4（地址用tu_width计算）
        - nTrs=48 时：左上角 8×8 倒L型区域（地址用tu_width计算）

    其余位置补0

    参数：
        lfnst_coeffs: LFNST 输出系数列表（数量=nTrs）
        tu_width: TU 宽度
        tu_height: TU 高度
        lfnst_idx: LFNST 索引（0=直通，此时不会调用这个函数）

    返回：
        填充后的完整系数列表（长度 = tu_width × tu_height）

    注意（修正）：
        - 所有地址都用实际tu_width计算，不是固定地址
        - nTrs=48写回左上8x8倒L型，不是前48个连续位置
    """
    nTrs = get_nTrs(tu_width, tu_height)
    total_size = tu_width * tu_height

    # 初始化全0列表
    full_coeffs = [0] * total_size

    if nTrs == 16:
        # 填充左上角 4×4 区域（修正：用tu_width计算地址）
        # Y[0..15] → 左上4x4
        for i in range(min(len(lfnst_coeffs), 16)):
            row = i // 4
            col = i % 4
            addr = row * tu_width + col  # 用tu_width计算地址
            if addr < total_size:
                full_coeffs[addr] = lfnst_coeffs[i]

    elif nTrs == 48:
        # 填充左上角 8×8 倒L型区域（修正）
        # Y[0..31] → row 0..3, col 0..7（上半部分，8列）
        # Y[32..47] → row 4..7, col 0..3（下半部分，只有4列）
        for i in range(min(len(lfnst_coeffs), 48)):
            if i < 32:
                # 前32个：row 0..3, col 0..7
                row = i // 8
                col = i % 8
            else:
                # 后16个：row 4..7, col 0..3（倒L型）
                k = i - 32
                row = 4 + k // 4
                col = k % 4

            addr = row * tu_width + col  # 用tu_width计算地址
            if addr < total_size:
                full_coeffs[addr] = lfnst_coeffs[i]

    return full_coeffs


def test_reference_model():
    """
    测试集成模型（当前只测试流程，不测试正确性）（修正版）
    """
    print("测试 ITS 集成模型...")

    # 测试1：不做 LFNST，DCT2 真实 1D 流程
    print("  测试1: 4x4 TU, 无LFNST")
    coeffs = [100, 200, 50, -50, 30, -30, 10, -10, 0, 0, 0, 0, 0, 0, 0, 0]
    result = its_inverse(4, 4, 0, 0, 0, 0, coeffs)
    print(f"    输入长度: {len(coeffs)}, 输出组数: {len(result)}")
    assert len(result) == 4  # 16个点 ÷ 4 = 4组

    # 测试2：做 LFNST
    print("  测试2: 4x4 TU, 有LFNST")
    coeffs = [100, 200, 50, -50, 30, -30, 10, -10]
    result = its_inverse(4, 4, 0, 0, 0, 1, coeffs)
    print(f"    输入长度: {len(coeffs)}, 输出组数: {len(result)}")
    assert len(result) == 4

    # 测试3：大块
    print("  测试3: 8x8 TU, 有LFNST")
    coeffs = [100] * 64
    result = its_inverse(8, 8, 0, 0, 0, 1, coeffs)
    print(f"    输入长度: {len(coeffs)}, 输出组数: {len(result)}")
    assert len(result) == 16  # 64个点 ÷ 4 = 16组

    # 测试4：非正方形
    print("  测试4: 4x8 TU, 有LFNST")
    coeffs = [100] * 32
    result = its_inverse(4, 8, 0, 0, 0, 1, coeffs)
    print(f"    输入长度: {len(coeffs)}, 输出组数: {len(result)}")
    assert len(result) == 8  # 32个点 ÷ 4 = 8组

    # 测试5：稀疏输入（修正新增）
    print("  测试5: 稀疏输入形式")
    sparse_coeffs = [(0, 100), (4, 200), (1, 50), (8, -30)]  # 只输入4个非零点
    result = its_inverse_sparse(4, 4, 0, 0, 0, 1, sparse_coeffs)
    print(f"    稀疏输入点数: {len(sparse_coeffs)}, 输出组数: {len(result)}")
    assert len(result) == 4
    # 验证重建正确性
    dense = rebuild_dense_tu(sparse_coeffs, 4, 4)
    assert dense[0] == 100 and dense[4] == 200 and dense[1] == 50 and dense[8] == -30
    print("    稀疏输入重建测试通过")

    print("ITS 集成模型测试通过（修正版）！")


def demonstrate_its_flow():
    """
    演示完整的 ITS 流程
    """
    print("\n=== ITS 反变换完整流程演示 ===")

    # 示例1：4x4 TU, LFNST + DCT2
    print("\n示例1: 4x4 TU")
    print(f"  配置:")
    print(f"    - TU尺寸: 4×4")
    print(f"    - LFNST: tr_set=0, idx=1")
    print(f"    - 变换: DCT2(列, shift={FIRST_1D_SHIFT}) + DCT2(行, shift={SECOND_1D_SHIFT})")
    print(f"    - nTrs: {get_nTrs(4, 4)}")
    print(f"    - nonZeroSize: {get_nonZeroSize(4, 4)}")

    coeffs = [100, 200, 50, -50, 30, -30, 10, -10]
    print(f"  输入系数（前8个）: {coeffs}")

    result = its_inverse(4, 4, 0, 0, 0, 1, coeffs)
    print(f"  输出组数: {len(result)}")
    print(f"  前2组: {result[0]}, {result[1]}")

    # 示例2：8x8 TU, 不做 LFNST
    print("\n示例2: 8x8 TU, 无LFNST")
    print(f"  配置:")
    print(f"    - TU尺寸: 8×8")
    print(f"    - LFNST: idx=0（直通）")
    print(f"    - 变换: DCT2(列, shift={FIRST_1D_SHIFT}) + DCT2(行, shift={SECOND_1D_SHIFT})")

    coeffs = [100] * 16  # 只给前16个非零系数
    print(f"  输入系数长度: {len(coeffs)}（实际TU大小64）")

    # 补充到64个系数
    coeffs_full = coeffs + [0] * (64 - len(coeffs))
    result = its_inverse(8, 8, 0, 0, 0, 0, coeffs_full)
    print(f"  输出组数: {len(result)}")


def show_week2_integration_plan():
    """
    展示第2周集成计划
    """
    print("\n=== 第2周集成计划 ===")
    print("\n当前状态（第1周末）：")
    print("  [完成] reference_model.py 骨架完成")
    print("  [完成] LFNST 流程实装")
    print("  [完成] A 的 DCT2 入口已接入")
    print("  [完成] B 的 DST7/DCT8 入口已接入")
    print("  [完成] 输入输出格式化完成")

    print("\n第2周要做的事：")
    print("  1. A/B/C 用同一套 list[int] 1D 接口、shift、clip_bits")
    print("  2. 使用已接入的 DCT2/DST7/DCT8 生成 golden data")
    print("  3. dispatch_1d_transform 当前调度：")
    print("     - trType=0 调用 transforms.dct2.idct2_1d")
    print("     - 从 transforms.dct8_dst7 import idct8_1d, idst7_1d")
    print("     - 根据 tr_type 选择调用哪个函数，并传入 shift/clip_bits")

    print("\n修改示例：")
    print("```python")
    print("from transforms.dct2 import idct2_1d")
    print("from transforms.dct8_dst7 import idst7_1d, idct8_1d")
    print("")
    print("def dispatch_1d_transform(coeffs, tr_type, length, shift, clip_bits=None):")
    print("    if tr_type == 0:")
    print("        return idct2_1d(coeffs, length, shift, clip_bits)")
    print("    elif tr_type == 1:")
    print("        return idst7_1d(coeffs, length, shift, clip_bits)")
    print("    elif tr_type == 2:")
    print("        return idct8_1d(coeffs, length, shift, clip_bits)")
    print("```")

    print("\n第2周末目标：")
    print("  - 全流程可用（LFNST + DCT2/8/7）")
    print("  - 生成 golden data")
    print("  - 接口协议签署")


if __name__ == "__main__":
    print("开始测试 reference_model.py...")

    # 测试流程
    test_reference_model()

    # 演示流程
    demonstrate_its_flow()

    # 展示第2周计划
    show_week2_integration_plan()

    print("\n=== reference_model.py 总结（修正版）===")
    print("1. LFNST 流程已实装（修正：低频扫描、nTrs输出、真实地址写回）")
    print("2. DCT2/DST7/DCT8 1D 函数已接入")
    print("3. 输入输出格式化完成")
    print("4. 稀疏输入支持已添加（修正新增：对接赛题接口）")
    print("5. 第2周可以开始生成含 DCT2/DST7/DCT8 的 golden data")
