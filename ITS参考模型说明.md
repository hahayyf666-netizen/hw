# ITS Python 参考模型说明

这份文档说明当前 `its_reference` 参考模型的整体处理流程、关键原理、相关文件，以及它为什么对后续 RTL 实现和对拍是必要的。

一句话结论：**第 1-2 周 Python reference 主线已经完成，DCT2 / DST7 / DCT8 / LFNST 已接入，golden data v1 已生成，可以作为后续 RTL 的标准答案。**

---

## 1. 这个参考模型现在做到什么程度

当前已经完成的内容：

- C 的 LFNST Python reference 已完成并接入顶层流程。
- A 的 DCT2 1D Python 函数已整理成标准接口。
- B 的 DST7 / DCT8 1D Python 函数已整理成标准接口。
- 顶层 `reference_model.py` 已经把 LFNST 和三种 1D 变换串起来。
- 定点规则已经统一：
  - 第一遍 1D：`shift=7`，输出 clip 到 16bit。
  - 第二遍 1D：`shift=10`。
  - 最终输出：clip 到 10bit signed。
- 已生成 12 组代表性 golden data，路径是：

```text
C:\Users\不知道叫什么那就叫叶耶耶\Desktop\成员C第1周\its_reference\golden_data\generated
```

还没有完全定死的内容：

- `it_info` 的 packed 位段编码还没有生成。
- 当前 golden data 是代表性测试集，不是所有尺寸、所有模式的全量穷举。
- RTL 内部累加器位宽还要后续结合硬件实现确认。

---

## 2. 整体处理流程先看大图

参考模型做的事情，就是把赛题输入一路算到最终输出：

```text
it_info + it_data_addr + it_data_in
  ↓
重建 dense TU
  ↓
可选 LFNST
  ↓
第一遍：列方向 1D，shift=7，clip16
  ↓
第二遍：行方向 1D，shift=10
  ↓
final clip10
  ↓
output_signed / output_packed
```

这条流程对应到代码里，核心入口是：

```text
transforms/reference_model.py
```

它负责把 C 的 LFNST、A 的 DCT2、B 的 DST7/DCT8 串成一个完整的 Python reference。

### 顶层 1D 调度设置

当前 `reference_model.py` 已经不是 mock 或旧占位逻辑，而是使用正式调度入口：

```python
dispatch_1d_transform(coeffs, tr_type, length, shift, clip_bits=None)
```

这个函数的输入和输出都统一为 `list[int]`：

```text
输入：  [x0, x1, x2, ...]
输出：  [y0, y1, y2, ...]
```

也就是说，顶层现在不再使用 `[[vector]]` 这种旧接口形状。列方向和行方向都会直接把一条 1D 向量传给调度函数。

当前 `tr_type` 编码固定为：

```text
tr_type = 0  -> DCT2  -> idct2_1d()
tr_type = 1  -> DST7  -> idst7_1d()
tr_type = 2  -> DCT8  -> idct8_1d()
```

两遍 1D 的调用规则是：

```text
第一遍：列方向，使用 tr_type_ver，length=tu_height，shift=7，clip_bits=16
第二遍：行方向，使用 tr_type_hor，length=tu_width，shift=10，clip_bits=None
```

完整顶层链路因此固定为：

```text
LFNST -> 列 1D -> 行 1D -> Clip10 -> 4 点分组
```

---

## 3. 每一步到底在干什么

### Step 1：赛题输入为什么是稀疏的

赛题接口不是直接给完整 TU 矩阵，而是给：

```text
it_info
it_data_addr
it_data_in
```

可以理解为：

- `it_info`：说明这次 TU 的配置，比如宽高、变换类型、LFNST 开关等。
- `it_data_addr`：这个输入系数应该写到 TU 的哪个地址。
- `it_data_in`：这个地址上的系数值。

因为很多变换系数是 0，赛题可以只输入非零点。这就是“稀疏输入”。

但是后面的 LFNST 和 1D 变换都需要知道完整 TU 里每个位置的值，所以参考模型第一步要把稀疏输入重建成完整列表：

```python
dense = [0] * (tu_width * tu_height)
for addr, value in sparse_coeffs:
    dense[addr] = value
```

对应文件：

```text
transforms/reference_model.py
```

里面的相关函数：

```text
rebuild_dense_tu()
its_inverse_sparse()
```

输入：

```text
[(addr0, value0), (addr1, value1), ...]
```

输出：

```text
完整 TU 的光栅顺序系数列表
```

---

### Step 2：TU 地址规则

TU 是 Transform Unit，也就是一块要做反变换的二维系数块。

虽然 Python 里常用一维列表存储它，但逻辑上它是二维矩阵。地址规则统一为：

```text
addr = row * tu_width + col
```

例如一个 `4x8 TU`，宽度是 4，高度是 8，那么地址排布是：

```text
row 0:  0   1   2   3
row 1:  4   5   6   7
row 2:  8   9  10  11
row 3: 12  13  14  15
row 4: 16  17  18  19
row 5: 20  21  22  23
row 6: 24  25  26  27
row 7: 28  29  30  31
```

所以 `row=2, col=1` 的地址是：

```text
addr = 2 * 4 + 1 = 9
```

这个规则非常重要。不能把地址写死成 `4x4` 的固定地址，否则 `4x8`、`8x8`、`16x16` 都会错。

对应文件：

```text
common/utils.py
transforms/reference_model.py
transforms/lfnst.py
```

---

### Step 3：LFNST 为什么在 1D 前面

LFNST 是 Low Frequency Non-Separable Transform，低频非分离变换。

它的作用是：在普通二维反变换之前，先对左上角低频系数做一次额外变换。低频区域通常承载主要能量，所以这里的处理会影响后面整个 TU 的结果。

参考模型里的规则是：

```text
lfnst_idx = 0：不做 LFNST，直接进入 1D 变换
lfnst_idx = 1/2：做 LFNST 矩阵乘
```

对应文件：

```text
transforms/lfnst.py
matrices/lfnst_kernels.py
```

#### LFNST 输入不是简单取前几个地址

LFNST 输入只看左上 `4x4` 的低频区域，而且顺序不是光栅顺序，而是低频扫描顺序。

低频扫描前 8 个坐标是：

```text
(0,0), (1,0), (0,1), (2,0),
(1,1), (0,2), (3,0), (2,1)
```

如果 `tu_width=4`，这些坐标换成地址就是：

```text
0, 4, 1, 8, 5, 2, 12, 9
```

这就是为什么 `4x4` 时 LFNST 输入不是：

```text
0, 1, 2, 3, 4, 5, 6, 7
```

而是：

```text
0, 4, 1, 8, 5, 2, 12, 9
```

#### nonZeroSize 是 LFNST 输入数量

`nonZeroSize` 表示 LFNST 矩阵乘时取多少个输入系数：

```text
4x4 或 8x8：nonZeroSize = 8
其他情况：nonZeroSize = 16
```

它是矩阵乘的列数，不是输出数量。

#### nTrs 是 LFNST 输出数量

`nTrs` 表示 LFNST 输出多少个系数：

```text
tu_width >= 8 且 tu_height >= 8：nTrs = 48
否则：nTrs = 16
```

例如：

```text
4x4  → nTrs=16
4x8  → nTrs=16
8x4  → nTrs=16
8x8  → nTrs=48
16x16 → nTrs=48
```

#### nTrs=16 怎么写回

`nTrs=16` 时，LFNST 输出 `Y[0..15]` 写回左上 `4x4` 区域：

```text
Y0   Y1   Y2   Y3
Y4   Y5   Y6   Y7
Y8   Y9   Y10  Y11
Y12  Y13  Y14  Y15
```

真实地址仍然用：

```text
addr = row * tu_width + col
```

所以在 `4x8 TU` 里，`Y5` 写到：

```text
row = 1
col = 1
addr = 1 * 4 + 1 = 5
```

#### nTrs=48 怎么写回

`nTrs=48` 时，输出写回左上 `8x8` 的倒 L 型区域：

```text
Y0   Y1   Y2   Y3   Y4   Y5   Y6   Y7
Y8   Y9   Y10  Y11  Y12  Y13  Y14  Y15
Y16  Y17  Y18  Y19  Y20  Y21  Y22  Y23
Y24  Y25  Y26  Y27  Y28  Y29  Y30  Y31
Y32  Y33  Y34  Y35  0    0    0    0
Y36  Y37  Y38  Y39  0    0    0    0
Y40  Y41  Y42  Y43  0    0    0    0
Y44  Y45  Y46  Y47  0    0    0    0
```

例如 `8x8 TU` 中：

```text
Y36 → row=5, col=0 → addr=5*8+0=40
Y47 → row=7, col=3 → addr=7*8+3=59
```

这个地方很容易错写成 `Y36 → addr36`，所以参考模型专门按倒 L 型规则写回。

---

### Step 4：为什么要做两遍 1D

二维反变换可以拆成两个方向的 1D 变换。

当前参考模型采用 VTM 对齐的顺序：

```text
第一遍：垂直方向，也就是逐列做 1D
第二遍：水平方向，也就是逐行做 1D
```

流程是：

```text
LFNST 后的 matrix
  ↓
每一列取出来做 1D
  ↓
列结果写回 tmp[row][col]
  ↓
每一行取出来做 1D
  ↓
得到 final_matrix
```

关键点是：第一遍列变换后，结果要写回原来的列位置：

```python
tmp[row_idx][col_idx] = transformed_col[row_idx]
```

这样 `4x8`、`8x4` 这种非正方形 TU 不会因为转置处理而错位。

对应文件：

```text
transforms/reference_model.py
```

---

### Step 5：DCT2 / DST7 / DCT8 矩阵从哪里来

三种 1D 变换类型编码统一为：

```text
trType = 0：DCT2
trType = 1：DST7
trType = 2：DCT8
```

对应文件：

```text
transforms/dct2.py
transforms/dct8_dst7.py
matrices/trans_matrix.py
```

这里的矩阵系数不是用 `numpy`、浮点 `cos()`、浮点 `sin()` 运行时生成的，而是来自 Huawei 附件 / VTM 的整数 `transMatrix`。

为什么必须用整数矩阵？

因为 RTL 最终做的是整数定点运算。如果 Python 用浮点矩阵，哪怕数学上看起来接近，也可能出现 1 LSB 误差。参考模型必须和 RTL 使用同一套整数系数，才能作为 golden 标准。

例如 DCT2 的 `4x4` 整数矩阵是：

```text
[ 64,  64,  64,  64]
[ 83,  36, -36, -83]
[ 64, -64, -64,  64]
[ 36, -83,  83, -36]
```

这些数可以理解为余弦系数放大后的整数近似，约等于放大 64 倍。

---

### Step 6：为什么要 round_shift 和 clip

变换矩阵系数大约是原始小数系数放大 64 倍后的整数。

举个直观例子：

```text
原本系数大概是 1.0
整数矩阵里可能写成 64
```

这样做的好处是硬件可以只做整数乘法，不需要浮点。

但乘累加之后，结果也会被放大，所以必须右移缩放回来。

统一舍入公式是：

```text
round_shift(value, shift) = (value + 2^(shift-1)) >> shift
```

例如：

```text
shift = 7
offset = 64
结果 = (value + 64) >> 7
```

注意：负数也使用同一个公式，不单独做“对称舍入”。

当前两遍 1D 的规则是：

```text
第一遍 1D：round_shift(sum, 7)，然后 clip 到 16bit signed
第二遍 1D：round_shift(sum, 10)
```

LFNST 的规则是：

```text
Clip3(-32768, 32767, (sum + 64) >> 7)
```

对应文件：

```text
common/fixed_point.py
```

所有 A/B/C 的变换函数都必须调用这里的统一函数，不能各写一套舍入逻辑。

---

### Step 7：最终输出为什么是 10bit

赛题最终输出 `it_data_out` 是每点 10bit signed，范围是：

```text
[-512, 511]
```

所以第二遍 1D 做完后，参考模型会做最终限幅：

```text
final = Clip3(-512, 511, value)
```

对应文件：

```text
common/fixed_point.py
transforms/reference_model.py
```

输出有两种形式：

#### 1. signed 输出

`output_signed.txt` 里每行 4 个 signed 数：

```text
9 -2 -1 17
23 7 2 0
...
```

这种形式方便人看，也方便 Python debug。

#### 2. packed 输出

RTL 接口通常是一拍输出 4 个点，每个点 10bit，一共 40bit：

```text
it_data_out[39:0]
```

打包规则是：

```text
bits [9:0]   = p0
bits [19:10] = p1
bits [29:20] = p2
bits [39:30] = p3
```

例如一组输出：

```text
[p0, p1, p2, p3]
```

会打包成一个 40bit hex，写到：

```text
output_packed.txt
```

对应文件：

```text
common/utils.py
generate_golden_data.py
```

---

## 4. 当前相关文件和作用

| 文件或目录 | 作用 |
|---|---|
| `its_reference/common/fixed_point.py` | 统一定点规则，包括 `round_shift`、16bit clip、最终 10bit clip。 |
| `its_reference/common/utils.py` | 通用工具，包括光栅/矩阵转换、4 点分组、40bit 打包。 |
| `its_reference/matrices/lfnst_kernels.py` | Huawei 附件里的 LFNST 整数矩阵。 |
| `its_reference/matrices/trans_matrix.py` | DCT2 / DST7 / DCT8 的整数变换矩阵。 |
| `its_reference/transforms/lfnst.py` | C 的 LFNST 反变换实现，包括低频扫描、nTrs、倒 L 写回。 |
| `its_reference/transforms/dct2.py` | A 的 DCT2 1D 标准接口。 |
| `its_reference/transforms/dct8_dst7.py` | B 的 DST7 / DCT8 1D 标准接口。 |
| `its_reference/transforms/reference_model.py` | 顶层 reference，负责 `LFNST -> 列 1D -> 行 1D -> Clip10 -> 4点分组`；列方向使用 `tr_type_ver, shift=7, clip16`，行方向使用 `tr_type_hor, shift=10`。 |
| `its_reference/generate_golden_data.py` | 生成 golden data 的脚本。 |
| `its_reference/golden_data/generated/` | 已生成的 golden data v1。 |

---

## 5. Golden Data 是什么，为什么必须有

Golden data 就是 RTL 的标准答案。

后续 A/B/C 写 Verilog 时，不能只看波形“差不多”，必须把 RTL 输出逐点和 Python reference 输出比较。

流程是：

```text
Python reference
  ↓
生成 golden data
  ↓
RTL 仿真读同一组输入
  ↓
RTL 输出和 golden data 逐点比较
```

如果不做 golden data，会出现几个问题：

- A/B/C 可能对 `trType` 编码理解不同。
- LFNST 低频扫描顺序可能写错。
- 负数右移可能有人做成对称舍入。
- `nTrs=48` 的倒 L 型写回可能错成连续地址。
- RTL 输出错了也很难定位是哪一步错。

当前已经生成 12 组代表性 case，覆盖：

- `DCT2`
- `DST7`
- `DCT8`
- `lfnst_idx = 0 / 1 / 2`
- `4x4`
- `4x8`
- `8x4`
- `8x8`
- `16x16`
- 全零、单 DC、低频、随机稀疏、极值低频

生成目录：

```text
its_reference/golden_data/generated/
```

当前修复后的参考模型已经重新生成 12 个 golden case，并完成以下验证：

```text
transforms/dct2.py                 通过
transforms/dct8_dst7.py            通过
transforms/lfnst.py                通过
transforms/reference_model.py      顶层流程测试通过
tests/test_generate_golden_data.py 通过
verify_golden_data.py              12 个 case 全部通过
VTM ItsGoldenCheckApp              4 个关键 case 全部通过
```

同时检查过 `golden_data/generated/summary.json` 和每个 case 目录，均包含下面 5 个文件。

每个 case 目录里有：

| 文件 | 作用 |
|---|---|
| `config.json` | 记录 TU 宽高、trType、LFNST 配置、输入输出数量等。 |
| `input_sparse.txt` | 稀疏输入，格式是 `addr value`。 |
| `input_dense.txt` | 完整 TU 输入，光栅顺序，每行一个值。 |
| `output_signed.txt` | 最终 10bit signed 输出，每行 4 点。 |
| `output_packed.txt` | 40bit packed 输出，每行一个 10 位 hex。 |

注意：当前还没有生成 `it_info.hex`，因为 `it_info` 的 packed 位段还没有最终确认。

### Golden Data 如何验证

当前工程新增了独立验证脚本：

```text
its_reference/verify_golden_data.py
```

它的定位不是重新调用 `reference_model.py`，而是作为 independent checker 对 `golden_data/generated/` 做二次复算。这样可以避免“自己生成、自己验证自己”的问题。

验证边界如下：

| 模块 | 复用 | 独立实现 |
|---|---|---|
| 矩阵系数 | `matrices/lfnst_kernels.py`、`matrices/trans_matrix.py` | - |
| LFNST 流程 | - | 低频扫描、矩阵乘、`nTrs=16/48` 写回、`nTrs=48` 倒 L 写回 |
| 1D 变换 | - | 逐元素乘累加、`round_shift`、中间 clip |
| 输出打包 | - | 4 点分组、10bit signed clip、40bit packed |

可运行命令：

```text
python verify_golden_data.py
python verify_golden_data.py --case 005_8x8_DCT2xDCT2_lfnst1_low_freq
python verify_golden_data.py --trace
```

当前验证结果：

```text
12 个 golden case 全部通过
output_signed.txt 逐点一致
output_packed.txt 重新打包后一致
```

`verify_golden_data.py` 主要承担自动回归验证职责，保证每次 golden data 重新生成后，文件完整性、输入输出长度、signed 输出、packed 输出都能被独立检查。

VTM 参考软件仍然是最权威的外部对照。当前已经用 `ItsGoldenCheckApp` 完成 4 个关键 case 的权威抽查：

| case | 验证重点 |
|---|---|
| `000_4x4_DCT2xDCT2_lfnst0_all_zero` | 零输入边界，最简单路径 |
| `001_4x4_DCT2xDCT2_lfnst1_low_freq` | LFNST `nTrs=16` |
| `005_8x8_DCT2xDCT2_lfnst1_low_freq` | LFNST `nTrs=48` 倒 L 写回 |
| `002_4x4_DST7xDCT8_lfnst2_low_freq` | DST7 / DCT8 MTS 变换核 |

VTM 抽查时只比较反变换阶段输出，不比较完整解码后的像素值。这样比较对象和 Python reference / golden data 的边界一致。

本轮 VTM 抽查结论：

```text
000_4x4_DCT2xDCT2_lfnst0_all_zero      PASS
001_4x4_DCT2xDCT2_lfnst1_low_freq      PASS
005_8x8_DCT2xDCT2_lfnst1_low_freq      PASS
002_4x4_DST7xDCT8_lfnst2_low_freq      PASS
```

另外额外抽查了无 LFNST 的非零输入 case `007`、`008`，也都通过。说明当前 golden data 已经从原来的 Python 内部自洽，进一步对齐到 VTM inverse transform 约定。

---



## 7. 现在还没完全定死的地方

### 1. it_info packed 位段还没生成

当前 `config.json` 里记录的是显式字段：

```text
tu_width
tu_height
tr_type_hor
tr_type_ver
lfnst_idx
lfnst_tr_set_idx
```

但赛题真实接口是 `it_info`。

后续 A 确认 `it_info` 每个字段的 bit 位置后，可以再从 `config.json` 生成：

```text
it_info.hex
```

### 2. 当前 golden data 是代表性集，不是全量穷举

当前 v1 主要用于第 2 周交付和第 3 周 RTL 初步对拍。

它覆盖关键路径，但没有穷举所有：

- TU 尺寸
- trType 组合
- lfnst_tr_set_idx
- 输入数值组合

后续 RTL 稳定后，可以扩展更大的测试集。

### 3. RTL 内部累加器位宽还要确认

Python 使用 `int`，不会溢出。

RTL 不能无限宽，所以后续需要根据最坏情况估算：

```text
输入位宽
矩阵系数最大值
乘法结果位宽
累加项数量
安全余量
```

这属于第 3 周以后 RTL 实现阶段要定的内容。

---

## 8. 最后总结

这套 Python reference 的价值不是“写一个能跑的 Python 程序”这么简单。

它真正的作用是：

```text
统一算法理解
统一矩阵来源
统一地址规则
统一舍入和 clip
统一 A/B/C 接口
为 RTL 提供 golden 标准答案
```

后续 RTL 只要和这套 reference 逐点对拍一致，就说明算法、定点、地址映射和输出格式基本闭环。

如果 RTL 和 golden data 不一致，也可以沿着这条流程定位：

```text
稀疏输入重建是否错
↓
LFNST 输入扫描是否错
↓
LFNST 写回是否错
↓
列 1D 是否错
↓
行 1D 是否错
↓
最终 clip 或 packed 是否错
```

这就是第 1-2 周参考模型最重要的意义。
