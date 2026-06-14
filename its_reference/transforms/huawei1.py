import os
import numpy as np


class VVC_ITS_GoldenModel_MemberB:
    """
    第九届中国研究生创“芯”大赛 - 华为第一题 (ITS反变换模块)
    成员B专用版：专注于 DST7 + DCT8 (支持 4, 8, 16, 32 尺寸自由组合)
    严格对齐类命名逻辑与官方附件定点化/移位规范
    """

    def __init__(self):
        # 视频标准中 10-bit 输入对应的基本参数
        self.bit_depth = 10

    def clip(self, value, min_val=-32768, max_val=32767):
        """模拟 Verilog 中的 16bit 有符号饱和限幅函数"""
        return max(min_val, min(value, max_val))

    def clip_to_16bit(self, arr):
        """将数组限制在 16-bit 有符号整数范围内"""
        return np.clip(arr, -32768, 32767).astype(np.int16)

    def generate_dst7_matrix(self, N):
        """
        生成 N 点 DST-VII 放大 64 倍的整数变换矩阵 (严格对齐 VVC 标准说明)
        范围: N = 4, 8, 16, 32
        """
        mat = np.zeros((N, N), dtype=np.int64)
        scale = 64.0
        for i in range(N):
            for j in range(N):
                val = scale * np.sin(((2 * i + 1) * (j + 1) * np.pi) / (2 * N + 1))
                mat[i, j] = int(np.round(val))
        return mat

    def generate_dct8_matrix(self, N):
        """
        生成 N 点 DCT-VIII 放大 64 倍的整数变换矩阵 (严格对齐 VVC 标准说明)
        范围: N = 4, 8, 16, 32
        """
        mat = np.zeros((N, N), dtype=np.int64)
        scale = 64.0
        for i in range(N):
            for j in range(N):
                val = scale * np.cos(((2 * i + 1) * (2 * j + 1) * np.pi) / (2 * (2 * N + 1)))
                mat[i, j] = int(np.round(val))
        return mat

    def shift_rounding(self, value, shift):
        """严格对齐硬件的带舍入（四舍五入占优）右移操作"""
        if shift <= 0:
            return value
        offset = 1 << (shift - 1)
        return (value + offset) // (1 << shift)

    def integer_idct_1d(self, input_vec, transform_type='DST7', shift=0, is_stage2=False):
        """
        核心 1D 反变换：支持 DST7 和 DCT8
        采用官方指定的整数矩阵乘法与移位策略
        """
        N = len(input_vec)

        # 1. 检查是否全零，全零则直接返回零向量（跳过变换，完美对齐您的代码逻辑）
        if np.all(input_vec == 0):
            return np.zeros(N, dtype=np.int64)

        # 2. 获取对应的变换矩阵 (反变换使用正向矩阵的转置 T)
        if transform_type == 'DST7':
            basis_mat = self.generate_dst7_matrix(N).T
        elif transform_type == 'DCT8':
            basis_mat = self.generate_dct8_matrix(N).T
        else:
            raise ValueError(f"成员B模块不支持的变换类型: {transform_type}")

        # 3. 矩阵点乘累加 (纯整数运算，对齐硬件有符号乘法器)
        result_vec = np.zeros(N, dtype=np.int64)
        for c in range(N):
            sum_val = 0
            for k in range(N):
                sum_val += int(input_vec[k]) * int(basis_mat[k, c])
            
            # 4. 执行带舍入的右移
            shifted_val = self.shift_rounding(sum_val, shift)
            
            # 5. 限幅保护
            if not is_stage2:
                # 第一级（水平）后，必须强行卡在 16-bit 有符号数内，优化转置 Buffer 面积
                result_vec[c] = np.clip(shifted_val, -32768, 32767)
            else:
                # 第二级（垂直）后，同样进行有符号 16 位限幅
                result_vec[c] = np.clip(shifted_val, -32768, 32767)

        return result_vec

    def integer_idct_2d(self, input_matrix, transform_type_hor='DST7', transform_type_ver='DST7'):
        """
        通用二维反变换 (支持 4x4 到 32x32 任意 DST7/DCT8 矩形块组合)
        先行（水平）后列（垂直）的分离算法，完美融合全零行/列跳过逻辑
        """
        rows, cols = input_matrix.shape  # rows = 高(H), cols = 宽(W)

        # 1. 输入数据限制在 16-bit 有符号整数范围
        input_matrix = self.clip_to_16bit(input_matrix)

        # 2. 根据官方附件，动态计算两级的移位量 shift1 和 shift2
        log2_W = int(np.log2(cols))
        log2_H = int(np.log2(rows))
        shift1 = log2_W + self.bit_depth - 10 + 2
        shift2 = log2_H + 2

        # ---------------- 第一步：水平 1D 反变换（按行处理，全零行跳过） ----------------
        temp_matrix = np.zeros((rows, cols), dtype=np.int64)
        for i in range(rows):
            if np.all(input_matrix[i, :] == 0):
                temp_matrix[i, :] = 0
            else:
                # 对行做反变换，长度为 W (cols)，移位量为 shift1
                temp_matrix[i, :] = self.integer_idct_1d(
                    input_matrix[i, :], transform_type=transform_type_hor, shift=shift1, is_stage2=False
                )

        # ---------------- 第二步：垂直 1D 反变换（按列处理，全零列跳过） ----------------
        # 硬件中这里会经过转置缓存（Transpose Buffer）
        output_matrix = np.zeros((rows, cols), dtype=np.int64)
        for j in range(cols):
            if np.all(temp_matrix[:, j] == 0):
                output_matrix[:, j] = 0
            else:
                # 对列做反变换，长度为 H (rows)，移位量为 shift2
                output_matrix[:, j] = self.integer_idct_1d(
                    temp_matrix[:, j], transform_type=transform_type_ver, shift=shift2, is_stage2=True
                )

        # 3. 强制转换为 16-bit 有符号整数类型输出 (完美对齐 Verilog 的 reg signed [15:0])
        return output_matrix.astype(np.int16)

    # ==============================================================================
    # 自动化测试与测试向量（Test Vectors）导出接口
    # ==============================================================================
    def export_test_vectors(self, H, W, tr_hor, tr_ver, output_dir="its_memberB_vectors"):
        """自动化生成契合华为官方接口规格（1拍进1点，1拍出4点拼接）的测试集"""
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)

        # 构造输入稀疏残差阵
        np.random.seed(H * W + 2026)
        coeff_in = np.zeros((H, W), dtype=np.int16)
        act_h, act_w = max(1, H // 2), max(1, W // 2)
        coeff_in[:act_h, :act_w] = np.random.randint(-150, 150, size=(act_h, act_w))

        # 运行模型计算
        golden_out = self.integer_idct_2d(coeff_in, tr_hor, tr_ver)

        # 1. 导出输入激励 (it_data_in, 单点16位)
        in_file = f"{output_dir}/input_{H}x{W}_{tr_hor}_{tr_ver}.txt"
        with open(in_file, "w") as f_in:
            for val in coeff_in.flatten():
                f_in.write(f"{int(val) & 0xFFFF:04X}\n")

        # 2. 导出输出标准答案 (4点拼接为40位并行总线: it_data_out[39:0])
        out_file = f"{output_dir}/golden_{H}x{W}_{tr_hor}_{tr_ver}.txt"
        with open(out_file, "w") as f_out:
            flat_out = golden_out.flatten()
            for i in range(0, len(flat_out), 4):
                p0 = int(flat_out[i]) & 0x3FF
                p1 = int(flat_out[i + 1]) & 0x3FF
                p2 = int(flat_out[i + 2]) & 0x3FF
                p3 = int(flat_out[i + 3]) & 0x3FF
                combined = (p3 << 30) | (p2 << 20) | (p1 << 10) | p0
                f_out.write(f"{combined:010X}\n")

        print(f"  [SUCCESS] 尺寸: {H}x{W} ({tr_hor}+{tr_ver}) 官方对齐标准集已导出。")


# ==============================================================================
# 执行主测试套件
# ==============================================================================
if __name__ == "__main__":
    print("==================================================================")
    print("   正在运行对齐队友命名规范与官方定点化标准的 成员B 黄金模型        ")
    print("==================================================================")

    model = VVC_ITS_GoldenModel_MemberB()

    # 大赛规定的属于成员B负责的所有典型非对称/对称尺寸组合 (4到32)
    memberB_test_suites = [
        (4, 4, 'DST7', 'DST7'),  # 经典 4x4
        (4, 8, 'DCT8', 'DST7'),  # 细长矩形
        (8, 16, 'DST7', 'DCT8'),  # 宽大矩形
        (32, 32, 'DCT8', 'DCT8'),  # 成员B负责的最大尺寸上限
    ]

    for tc in memberB_test_suites:
        model.export_test_vectors(tc[0], tc[1], tc[2], tc[3])

    print("\n==================================================================")
    print(" ✅ 专属标准答案库已全部成功生成！可直接合并或交予硬件同学对齐波形！")
    print("==================================================================")