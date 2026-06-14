"""
定点化运算公共函数

所有变换模块（A/B/C）都要使用这里的常量和函数，保证 Python reference、
golden data 和 RTL 的舍入、右移、限幅规则一致。
"""

# 赛题/VTM 对齐的公共定点参数
INPUT_BITS = 16
LFNST_SHIFT = 7
LFNST_OUTPUT_BITS = 16

# VTM inverse transform: 第一遍 1D shift=7，第二遍 1D shift=10
FIRST_1D_SHIFT = 7
SECOND_1D_SHIFT = 10
FIRST_1D_CLIP_BITS = 16

FINAL_OUTPUT_BITS = 10


def round_shift(val, shift_bits):
    """
    通用带舍入右移。

    统一公式：
        (val + 2^(shift_bits-1)) >> shift_bits

    不再对负数做对称舍入，正负数统一处理

    参数：
        val: 要舍入移位的值（可以是负数）
        shift_bits: 右移位数

    返回：
        舍入右移后的结果

    示例：
        LFNST: round_shift(sum, LFNST_SHIFT)
        第一遍1D: round_shift(sum, FIRST_1D_SHIFT)
        第二遍1D: round_shift(sum, SECOND_1D_SHIFT)
    """
    offset = 1 << (shift_bits - 1)
    return (val + offset) >> shift_bits


def saturate(val, bits):
    """
    按 bit 数饱和（限幅）
    限制数值在 [-2^(bits-1), 2^(bits-1)-1] 范围内

    为什么是这个范围？
    - bits 位有符号数的表示范围
    - 例如 10bit：最小 -512 (-2^9)，最大 511 (2^9-1)

    参数：
        val: 要饱和的值
        bits: 位宽（例如10、16、32）

    返回：
        饱和后的值

    示例：
        saturate(600, 10) → 511（10bit最大值）
        saturate(-600, 10) → -512（10bit最小值）
        saturate(100, 10) → 100（在范围内）
    """
    min_val = -(1 << (bits - 1))
    max_val = (1 << (bits - 1)) - 1

    if val < min_val:
        return min_val
    elif val > max_val:
        return max_val
    else:
        return val


def mul_fp(a, b, precision_bits=8):
    """
    定点乘法
    两个定点数相乘，结果需要调整精度

    为什么需要调整？
    - 两个 Q8.8 的数相乘，结果是 Q16.16（精度翻倍）
    - 要恢复成 Q8.8，需要右移8位
    - 这里的 precision_bits 就是"小数部分的位数"

    参数：
        a: 第一个数（定点格式）
        b: 第二个数（定点格式）
        precision_bits: 定点数的小数位数（默认8）

    返回：
        乘法结果（保持相同精度）

    示例：
        假设定点格式 Q8.8（整数部分8bit，小数部分8bit）
        mul_fp(100, 50, 8) → (100 * 50) >> 8 = 5000 >> 8 = 19

    注意：
        这个函数主要用于 DCT 的常数乘法优化（常数用定点表示）
    """
    # 乘法
    product = a * b

    # 右移恢复精度
    result = round_shift(product, precision_bits)

    return result


def clip_output(val, output_bits=10):
    """
    输出限幅
    文档要求最终输出每点 10bit，范围 [-512, 511]

    参数：
        val: 要限幅的值
        output_bits: 输出位宽（默认10）

    返回：
        限幅后的值

    用途：
        ITS 流程最后的输出限幅
    """
    return saturate(val, output_bits)


def clip_lfnst_output(val):
    """LFNST 输出限幅：16bit signed。"""
    return saturate(val, LFNST_OUTPUT_BITS)


def clip_first_1d_output(val):
    """第一遍 1D 输出限幅：VTM 中间动态范围按 16bit signed 对齐。"""
    return saturate(val, FIRST_1D_CLIP_BITS)


def clip_final_output(val):
    """最终 it_data_out 输出限幅：10bit signed。"""
    return saturate(val, FINAL_OUTPUT_BITS)


def lfnst_round(val):
    """LFNST 舍入右移：shift=7。"""
    return round_shift(val, LFNST_SHIFT)


def first_1d_round(val):
    """第一遍 1D 舍入右移：shift=7。"""
    return round_shift(val, FIRST_1D_SHIFT)


def second_1d_round(val):
    """第二遍 1D 舍入右移：shift=10。"""
    return round_shift(val, SECOND_1D_SHIFT)


def test_fixed_point():
    """
    测试定点化函数
    """
    print("测试 round_shift:")
    # 测试正数舍入
    assert round_shift(100, 7) == 1
    assert round_shift(200, 7) == 2
    assert round_shift(127, 7) == 1  # 刚好一半
    # 测试负数舍入
    assert round_shift(-100, 7) == -1
    assert round_shift(-200, 7) == -2
    print("  round_shift 测试通过")

    print("测试 saturate:")
    # 测试10bit饱和
    assert saturate(600, 10) == 511
    assert saturate(-600, 10) == -512
    assert saturate(100, 10) == 100
    # 测试16bit饱和
    assert saturate(40000, 16) == 32767
    assert saturate(-40000, 16) == -32768
    print("  saturate 测试通过")

    print("测试 mul_fp:")
    # 测试定点乘法
    # 假设精度8bit
    result = mul_fp(100, 50, 8)
    expected = (100 * 50 + 128) >> 8  # 手动计算
    assert result == expected
    print("  mul_fp 测试通过")

    print("测试 clip_output:")
    assert clip_output(600) == 511
    assert clip_output(-600) == -512
    assert clip_output(100) == 100
    print("  clip_output 测试通过")

    print("测试公共定点常量:")
    assert LFNST_SHIFT == 7
    assert FIRST_1D_SHIFT == 7
    assert SECOND_1D_SHIFT == 10
    assert clip_lfnst_output(40000) == 32767
    assert clip_first_1d_output(-40000) == -32768
    assert clip_final_output(600) == 511
    print("  公共定点常量测试通过")


if __name__ == "__main__":
    print("开始测试定点化函数...")
    test_fixed_point()
    print("所有测试通过！")

    print("\n周一会议要确定的定点化方案：")
    print("================================")
    print("1. 舍入方式：round_shift(val, shift) = (val + 2^(shift-1)) >> shift")
    print("2. 固定 shift：")
    print(f"   - LFNST_SHIFT = {LFNST_SHIFT}")
    print(f"   - FIRST_1D_SHIFT = {FIRST_1D_SHIFT}")
    print(f"   - SECOND_1D_SHIFT = {SECOND_1D_SHIFT}")
    print("3. 饱和方式：saturate(val, bits)")
    print("   - 10bit 输出：[-512, 511]")
    print("   - 16bit 输入：[-32768, 32767]")
    print("   - 第一遍1D输出：16bit signed")
    print("4. 定点乘法：mul_fp(a, b, precision_bits)")
    print("   - 常数乘法用定点表示，精度位数需要确定")
    print("5. 变换核系数：以华为附件 transMatrix/lowFreqTransMatrix 为准")
    print("================================")
