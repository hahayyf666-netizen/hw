# VVC 反变换模块 (ITS) — RTL 实现

第九届中国研究生创芯大赛 · 华为赛题一 | v2.0 (2026-06-15)

---

## 1. 项目概述

本项目实现了 VVC (H.266) 视频编码标准的反变换模块 (Inverse Transform Subsystem, ITS)，用于解码端将频域系数还原为时域残差信号。

### 核心能力

| 特性 | 说明 |
|------|------|
| 变换类型 | DCT2、DCT8、DST7 三种反变换核 |
| 块大小 | DCT2: 4x4 ~ 64x64 (25种)；DCT8/DST7: 4x4 ~ 32x32 (各16种) |
| LFNST | 支持 nTrs=16 (4x4/8x8 TU) 和 nTrs=48 (其他 TU)，4 setIdx x 2 idx |
| 计算性能 | 4 个并行 MAC，每周期产出 4 个结果点 |
| 接口 | 22-bit it_info，符合赛题规范 |
| 反压 | 输入/输出均支持按点反压 (backpressure) |

### 处理流程

```
输入数据 → [LFNST 反变换] → 列方向 1D IDCT/IDST → 转置(中间Buffer) → 行方向 1D IDCT/IDST → 光栅扫描输出
```

---

## 2. 目录结构

```
HW_WORK/
├── huawei_vvc/
│   ├── rtl/                              # RTL 源代码
│   │   ├── top/
│   │   │   ├── its_top.v                 # 顶层模块 (FSM + 数据通路整合)
│   │   │   └── output_packer.v           # 输出打包 (4x10-bit 拼接)
│   │   ├── ctrl/
│   │   │   ├── its_ctrl_fsm.v            # 顶层控制状态机
│   │   │   ├── config_decode.v           # it_info 配置解码
│   │   │   └── addr_gen.v               # 地址生成器
│   │   ├── transform_1d/
│   │   │   ├── it_1d_core.v             # 统一 1D 变换入口 (调度 DCT2/DST7/DCT8)
│   │   │   ├── dct2_1d.v                # DCT2 1D 反变换
│   │   │   ├── dct8_1d.v                # DCT8 1D 反变换
│   │   │   ├── dst7_1d.v                # DST7 1D 反变换
│   │   │   └── mac_array.v             # 4 MAC 并行乘累加阵列
│   │   ├── lfnst/
│   │   │   ├── lfnst_core.v             # LFNST 主模块 (扫描取数 + 矩阵乘 + 写回)
│   │   │   ├── lfnst_scan.v             # LFNST 系数扫描
│   │   │   ├── lfnst_writeback.v        # LFNST 结果写回
│   │   │   └── lfnst_config.v           # LFNST 配置解码
│   │   ├── buffer/
│   │   │   ├── tu_buffer.v              # TU 数据缓冲 (双端口 RAM)
│   │   │   ├── tu_pre_buffer.v          # 预缓冲 (4-bank LUTRAM + epoch/tag 清零)
│   │   │   ├── tu_post_buffer.v         # 后缓冲 (平坦 LUTRAM, 无清零)
│   │   │   └── intermediate_buffer.v    # 中间结果缓冲 (列→行转置)
│   │   ├── mem/
│   │   │   ├── trans_matrix_rom.v       # 变换核系数 ROM
│   │   │   └── lfnst_matrix_rom.v       # LFNST 系数 ROM (8192 条目)
│   │   ├── common/
│   │   │   ├── clip.v                   # 饱和截断
│   │   │   └── round_shift.v            # 舍入移位
│   │   ├── scripts/                     # 系数生成与回归测试脚本
│   │   ├── tb_verilator/                # Verilator C++ 测试平台
│   │   ├── constraints_pblock.xdc       # Pblock 约束 (布局优化)
│   │   ├── synth_k160_pblock.tcl        # K160T-3 综合脚本
│   │   └── filelist.f                   # 文件列表
│   └── VCC分析报告.md                    # 赛题分析报告
│
├── its_reference/                        # Python 参考模型
│   ├── transforms/
│   │   ├── dct2.py                      # DCT2 变换实现
│   │   ├── dct8_dst7.py                 # DCT8/DST7 变换实现
│   │   ├── lfnst.py                     # LFNST 变换实现
│   │   └── reference_model.py           # 统一参考模型入口
│   ├── common/                          # 定点运算工具
│   ├── matrices/                        # 变换矩阵定义
│   ├── tests/                           # 单元测试
│   ├── golden_data/generated/           # 1377 组 golden 测试数据
│   ├── generate_golden_data.py          # golden data 生成脚本
│   └── verify_golden_data.py            # golden data 验证脚本
│
├── 12.docx                              # 参考文档
├── ITS参考模型说明.md                     # 参考模型说明
├── RTL第一份 问题汇总.docx                # RTL 问题记录
├── 华为附件.docx                          # 赛题附件
├── 成员C的工作理解.docx                   # 工作理解文档
└── implementation_status_report.md       # 实现状态报告
```

---

## 3. 接口定义

### 3.1 顶层端口

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `clk` | 1 | I | 时钟 |
| `rst_n` | 1 | I | 异步复位，低有效 |
| `it_info` | 22 | I | TU 信息总线 (见下表) |
| `it_info_vld` | 1 | I | 信息有效，脉冲 |
| `it_data_in` | 16 | I | 输入系数 (有符号，只送非零点) |
| `it_data_addr` | 12 | I | 系数在 TU 内的光栅扫描地址 |
| `it_data_in_vld` | 1 | I | 输入数据有效 |
| `it_data_end` | 1 | I | 输入数据结束，脉冲 |
| `it_data_in_req` | 1 | O | 输入请求 (为 1 时才允许送数据) |
| `it_data_out` | 40 | O | 输出结果，4 个 10-bit 有符号值拼接 |
| `it_data_out_vld` | 1 | O | 输出有效 |
| `it_data_out_req` | 1 | I | 输出反压 (为 1 时才允许输出) |
| `it_done` | 1 | O | 当前 TU 处理完成，脉冲 |

### 3.2 it_info 位域定义

```
it_info [21:0]
├── [6:0]      tu_width          — TU 宽度 (4/8/16/32/64)
├── [13:7]     tu_height         — TU 高度 (4/8/16/32/64)
├── [15:14]    tr_type_hor       — 水平变换类型 (0=DCT2, 1=DCT8, 2=DST7)
├── [17:16]    tr_type_ver       — 垂直变换类型
├── [19:18]    lfnst_tr_set_idx  — LFNST 变换集索引 (0..3)
└── [21:20]    lfnst_idx         — LFNST 核索引 (0=不启用, 1/2)
```

### 3.3 输出数据格式

`it_data_out[39:0]` 按光栅扫描顺序打包 4 个结果点：

```
[9:0]    — 第 1 个点 (有符号 10-bit)
[19:10]  — 第 2 个点
[29:20]  — 第 3 个点
[39:30]  — 第 4 个点
```

---

## 4. 架构设计

### 4.1 顶层状态机

```
  S_IDLE → S_CLEAR → S_LFNST(可选) → S_COL_1D → S_ROW_1D → S_OUTPUT → S_DONE → S_IDLE
            (tag清零)  (LFNST反变换)   (列变换)    (行变换)    (光栅输出)
```

**状态说明**：
- `S_CLEAR`: 激活 tu_pre_buffer 的 tag 清零，等待 clear_done 信号
- `S_LFNST`: 可选，当 lfnst_idx != 0 时执行 LFNST 反变换
- `S_COL_1D`: 列方向 1D IDCT/IDST，从 tu_pre_buffer 读取数据
- `S_ROW_1D`: 行方向 1D IDCT/IDST，结果写入 tu_post_buffer
- `S_OUTPUT`: 从 tu_post_buffer 读取，光栅扫描输出

### 4.2 LFNST 模块 (`lfnst_core.v`)

执行 LFNST 反变换：`y[i] = clip3(-32768, 32767, (Σ_j T[i][j]·x[j] + 64) >> 7)`

**nTrs 定义（VVC 标准）：**
- `nTrs = (tu_width >= 8 && tu_height >= 8) ? 48 : 16`
- nTrs=16: 16 个输入，16x16 矩阵，16 个输出（写回左上 4x4）
- nTrs=48: 16 个输入（左上 4x4），48x16 矩阵，48 个输出（写回 3 个 4x4 子块）

**nTrs=48 子块布局：**
```
┌───────┬───────┐
│ blk 0 │ blk 1 │  rows 0-3, cols 0-7
│ (4x4) │ (4x4) │
├───────┤       │
│ blk 2 │       │  rows 4-7, cols 0-3
│ (4x4) │       │
└───────┴───────┘
```

**ROM 布局（8192 条目）：**
- nTrs=16 [0..2047]: 4 setIdx x 2 idx x 16x16
- nTrs=48 [2048..8191]: 4 setIdx x 2 idx x 48x16

### 4.3 1D 变换核心 (`it_1d_core.v`)

统一入口，根据 `tr_type` 调度到具体变换实现：
- `tr_type=0`: DCT2 1D 反变换 (支持 4/8/16/32/64 长度)
- `tr_type=1`: DST7 1D 反变换 (支持 4/8/16/32 长度)
- `tr_type=2`: DCT8 1D 反变换 (支持 4/8/16/32 长度)

4 个并行 MAC 执行 `y = T^T * x`，每周期产出 4 个输出点。

### 4.4 Buffer 架构 (`tu_pre_buffer.v` + `tu_post_buffer.v`)

采用拆分设计，优化清零性能：

**tu_pre_buffer (预缓冲)**：
- 4-bank LUTRAM 结构，每 bank 1024x16-bit
- Epoch/tag 机制：8-bit epoch 计数器，每 TU 开始递增
- 独立 tag 清零路径：1024 周期完成全部 tag 清零，不阻塞写入
- 读取时检查 tag==epoch，不匹配则返回 0

**tu_post_buffer (后缓冲)**：
- 平坦 LUTRAM 4096x16-bit
- ROW_1D 阶段写入，OUTPUT 阶段读取
- 无需清零逻辑

**时序优势**：
- 传统方案：清零 4096 个地址需 4096 周期
- 新方案：tag 清零仅需 1024 周期 (减少 75%)
- 写入与 tag 清零可并行执行

### 4.5 MAC 阵列 (`mac_array.v`)

4 路并行乘累加单元，2 级流水线：
- Stage 1: `product = a * b` (16x16 → 32-bit signed)
- Stage 2: `result += sign_ext(product)` (40-bit accumulator)

---

## 5. 仿真与验证

### 5.1 验证方法

使用 Verilator 进行 RTL 仿真，与 Python 参考模型 (its_reference) 逐点比对输出值。

### 5.2 运行仿真

```bash
cd huawei_vvc/rtl/tb_verilator
make -f Makefile regression
```

### 5.3 测试用例覆盖 (共 1713 个)

| 类别 | 数量 | 覆盖范围 |
|------|------|---------|
| DCT2 (Layer 1) | 25 | 4x4 ~ 64x64 全部 25 种块大小 |
| DCT8/DST7 (Layer 2) | 153 | 4x4 ~ 32x32，含各种变换组合 |
| LFNST (Layer 3) | 1199 | 4 setIdx x 2 idx x 2 nTrs，覆盖全场景 |
| 协议测试 | 188 | it_info_vld、it_data_in、it_data_end 时序 |
| 反压测试 | 148 | it_data_in_req、it_data_out_req 反压场景 |

**验证结果：1713/1713 全部 PASS**，golden data 已通过 VTM 核心反变换路径的权威抽查。

### 5.4 参考模型

`its_reference/` 目录包含 Python 定点参考模型，结构如下：
- `transforms/` — DCT2、DCT8/DST7、LFNST 变换实现
- `golden_data/generated/` — 1377 组测试向量 (输入 + 期望输出)
- `tests/` — 单元测试 (test_dct2.py, test_dct8_dst7.py)
- `generate_golden_data.py` — 测试向量生成
- `verify_golden_data.py` — 测试向量验证

---

## 6. 综合与 PPA

### 6.1 综合结果 (v2.0 最优)

**目标器件**: Kintex-7 xc7k160tfbg484-3
**时钟约束**: 500MHz (2ns)
**优化策略**: Pblock 布局约束 + 多轮 phys_opt

| 资源 | 使用 | 可用 | 利用率 |
|------|------|------|--------|
| LUTs | 10,396 | 101,400 | 10.25% |
| Registers | 4,924 | 202,800 | 2.43% |
| LUTRAM | 2,176 | - | - |
| Block RAM | 4 | 325 | 1.23% |
| DSPs | 4 | 360 | 1.11% |

| 指标 | 值 |
|------|-----|
| WNS (Setup) @ 500MHz | -1.658 ns |
| WPWS (Pulse Width) | +0.107 ns |
| 实际最高频率 | ~273 MHz |

**关键优化**：
- Pblock 约束将 lfnst_core 和 tu_pre_buffer 放置在同一区域，减少路由延迟
- 路由延迟从 2.864ns 降至 0.790ns (减少 72%)
- DSP48E1 逻辑延迟 (2.651ns) 成为新瓶颈
- 综合脚本采用多轮 phys_opt_design 优化

**500MHz 可行性分析**：
- 7 系列 FPGA 受 DSP48E1 固有延迟限制，500MHz 不可行
- UltraScale/UltraScale+ 器件可支持 500MHz，但需额外许可证
- 当前方案在 7 系列中已接近最优

### 6.2 运行综合

```bash
cd huawei_vvc/rtl
vivado -mode batch -source synth_k160_pblock.tcl
```

---

## 7. 赛题要求对照

| 赛题要求 | 实现状态 | 说明 |
|---------|---------|------|
| DCT2 4x4~64x64 | ✅ | 25 种组合全部支持 |
| DCT8 4x4~32x32 | ✅ | 16 种组合全部支持 |
| DST7 4x4~32x32 | ✅ | 16 种组合全部支持 |
| LFNST (全部 16 场景) | ✅ | 4 setIdx x 2 idx x 2 nTrs |
| 22-bit it_info 接口 | ✅ | 符合赛题位域定义 |
| 一拍 4 点计算 | ✅ | 4 MAC 并行 |
| 一拍 4 点输出 | ✅ | 光栅扫描顺序 |
| 输入反压 | ✅ | it_data_in_req |
| 输出反压 | ✅ | it_data_out_req |
| it_data_end 接口 | ✅ | 赛题更新要求 |
| Verilog 实现 | ✅ | |
| 量化定标分析 | ✅ | 见实现状态报告 |
| PPA 报告 | ✅ | 见综合结果 |
| 设计文档 | ✅ | 见项目文档 |

---

## 8. 工具与环境

| 工具 | 版本 | 用途 |
|------|------|------|
| Verilator | 4.x+ | RTL 功能仿真 (C++ testbench) |
| Vivado | 2025.2 | 综合与实现 |
| Python | 3.x | 参考模型、系数生成、golden data |
| Git + Git LFS | - | 版本管理 |

---

## 9. 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v1.0 | 2026-06-14 | 初始版本，1377/1377 全 PASS，LFNST writeback 寄存器延迟 bug 已修复 |
| v2.0 | 2026-06-15 | Buffer 拆分优化 (4-bank epoch/tag)，K160T-3 综合，WNS=-1.658ns，1713/1713 全 PASS |
