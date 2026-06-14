"""
通用工具函数
所有变换模块都会用到的基础工具
"""

def Clip3(min_val, max_val, val):
    """
    限幅函数，保证数值在 [min_val, max_val] 范围内
    对应文档公式：Clip3(-32768, 32767, 计算结果)

    参数：
        min_val: 下界
        max_val: 上界
        val: 要限幅的值

    返回：
        限幅后的值

    示例：
        Clip3(-100, 100, 150) → 100
        Clip3(-100, 100, -200) → -100
        Clip3(-100, 100, 50) → 50
    """
    if val < min_val:
        return min_val
    elif val > max_val:
        return max_val
    else:
        return val


def transpose(matrix):
    """
    行列转置
    把二维矩阵的行变成列，列变成行

    参数：
        matrix: 二维列表，例如 [[1,2,3], [4,5,6]]

    返回：
        转置后的矩阵，例如 [[1,4], [2,5], [3,6]]

    用途：
        ITS流程中，行变换完成后要转置，再进行列变换
    """
    if not matrix:
        return []

    rows = len(matrix)
    cols = len(matrix[0])

    # 创建转置矩阵
    result = []
    for j in range(cols):
        new_row = []
        for i in range(rows):
            new_row.append(matrix[i][j])
        result.append(new_row)

    return result


def raster_to_matrix(coeffs, width, height):
    """
    光栅扫描顺序 → 二维矩阵

    光栅扫描顺序：从左到右、从上到下逐行扫描
    例如 4x4 块的光栅顺序：0,1,2,3,4,5,6,7,...,15
    对应位置：
        [0  1  2  3]
        [4  5  6  7]
        [8  9 10 11]
        [12 13 14 15]

    参数：
        coeffs: 光栅扫描顺序的系数列表
        width: TU 宽度
        height: TU 高度

    返回：
        二维矩阵 matrix[row][col]

    用途：
        输入数据按光栅顺序给出，要转成行×列的矩阵才能做行变换
    """
    matrix = []
    for row in range(height):
        row_data = []
        for col in range(width):
            # 光栅扫描地址 = row * width + col
            addr = row * width + col
            if addr < len(coeffs):
                row_data.append(coeffs[addr])
            else:
                row_data.append(0)  # 超出范围的位置补0
        matrix.append(row_data)

    return matrix


def matrix_to_raster(matrix):
    """
    二维矩阵 → 光栅扫描顺序

    参数：
        matrix: 二维矩阵 matrix[row][col]

    返回：
        光栅扫描顺序的系数列表

    用途：
        输出要求按光栅顺序，把变换后的矩阵转回列表形式
    """
    coeffs = []
    for row in matrix:
        for val in row:
            coeffs.append(val)
    return coeffs


def split_into_groups(coeffs, group_size=4):
    """
    把系数列表按 group_size 分组
    用于输出时"一拍4个点"的拼接

    参数：
        coeffs: 系数列表
        group_size: 每组的点数（文档要求是4）

    返回：
        分组后的列表，例如 [[0,1,2,3], [4,5,6,7], ...]

    用途：
        输出格式要求一拍4个点，需要把结果分成4点一组
    """
    groups = []
    for i in range(0, len(coeffs), group_size):
        group = coeffs[i:i+group_size]
        # 如果最后一组不足4个，补0
        while len(group) < group_size:
            group.append(0)
        groups.append(group)
    return groups


def pack_4_points(points):
    """
    把4个点拼接成40bit输出格式
    每点10bit，4点 = 40bit

    参数：
        points: [p0, p1, p2, p3] 列表，每个点是10bit有符号数

    返回：
        40bit 整数，格式：
        [9:0]   = 第1个点
        [19:10] = 第2个点
        [29:20] = 第3个点
        [39:30] = 第4个点

    用途：
        RTL输出接口要求一拍40bit（4个点拼接）
    """
    # 每点限制在10bit范围：-512 ~ 511
    p0 = Clip3(-512, 511, points[0])
    p1 = Clip3(-512, 511, points[1])
    p2 = Clip3(-512, 511, points[2])
    p3 = Clip3(-512, 511, points[3])

    # 拼接成40bit
    # 注意：10bit有符号数要转换成无符号表示才能拼接
    result = (p0 & 0x3FF) | ((p1 & 0x3FF) << 10) | ((p2 & 0x3FF) << 20) | ((p3 & 0x3FF) << 30)
    return result


def test_utils():
    """
    测试函数，验证各个工具函数的正确性
    """
    # 测试 Clip3
    assert Clip3(-100, 100, 150) == 100
    assert Clip3(-100, 100, -200) == -100
    assert Clip3(-100, 100, 50) == 50
    print("Clip3 测试通过")

    # 测试 transpose
    matrix = [[1, 2, 3], [4, 5, 6]]
    trans = transpose(matrix)
    assert trans == [[1, 4], [2, 5], [3, 6]]
    print("transpose 测试通过")

    # 测试 raster_to_matrix
    coeffs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    matrix = raster_to_matrix(coeffs, 4, 4)
    assert matrix[0] == [0, 1, 2, 3]
    assert matrix[3] == [12, 13, 14, 15]
    print("raster_to_matrix 测试通过")

    # 测试 matrix_to_raster
    coeffs_back = matrix_to_raster(matrix)
    assert coeffs_back == coeffs
    print("matrix_to_raster 测试通过")

    # 测试 split_into_groups
    coeffs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    groups = split_into_groups(coeffs, 4)
    assert groups == [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 0, 0]]
    print("split_into_groups 测试通过")

    # 测试 pack_4_points
    points = [100, -200, 300, -400]
    packed = pack_4_points(points)
    # 验证拼接正确性
    p0_back = packed & 0x3FF
    p1_back = (packed >> 10) & 0x3FF
    p2_back = (packed >> 20) & 0x3FF
    p3_back = (packed >> 30) & 0x3FF
    # -200 转成10bit无符号：1024-200=824，取后10bit=824
    # -400 转成10bit无符号：1024-400=624，取后10bit=624
    assert p0_back == 100
    assert p1_back == ((-200) & 0x3FF)
    assert p2_back == 300
    assert p3_back == ((-400) & 0x3FF)
    print("pack_4_points 测试通过")


if __name__ == "__main__":
    # 运行测试
    print("开始测试工具函数...")
    test_utils()
    print("所有测试通过！")