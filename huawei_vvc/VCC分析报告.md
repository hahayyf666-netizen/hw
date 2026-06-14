# VVC 反变换模块 (ITS) 分析报告

## 1. 项目概述

### 1.1 赛题背景

本项目为**第九届中国研究生创芯大赛 —— 华为赛题一**：VVC (Versatile Video Coding) 反变换模块 ITS 设计。要求实现一个支持多种变换类型、多种 TU 尺寸、可选 LFNST 的硬件反变换模块，工作频率 500MHz。

---

## 2. 目录结构

```
D:\HW_WORK\huawei_vvc\
├── README.md                           # 项目说明
├── VCC分析报告.md                      # 本文档
├── 赛题和分工/
│   ├── 第九届中国研究生创芯大赛-华为赛题.docx
│   ├── 华为附件.docx
│   └── RTL 三人分工与接口方案_副本1_改善版.md
└── rtl/
    ├── top/
    │   ├── its_top.v                   # 顶层模块
    │   └── output_packer.v             # 输出打包模块
    ├── ctrl/
    │   ├── its_ctrl_fsm.v              # 主控 FSM
    │   ├── config_decode.v             # 配置解码
    │   └── addr_gen.v                  # 地址生成器
    ├── buffer/
    │   ├── tu_buffer.v                 # TU 系数缓存 (4096×16bit)
    │   └── intermediate_buffer.v       # 中间结果缓存 (4096×32bit)
    ├── transform_1d/
    │   ├── it_1d_core.v                # 统一 1D 变换入口
    │   ├── dct2_1d.v                   # DCT2 1D 核
    │   ├── dst7_1d.v                   # DST7 1D 核
    │   ├── dct8_1d.v                   # DCT8 1D 核
    │   └── mac_array.v                 # 8 路并行 MAC 阵列
    ├── lfnst/
    │   ├── lfnst_core.v                # LFNST 主控
    │   ├── lfnst_scan.v                # 对角线扫描地址生成
    │   ├── lfnst_writeback.v           # 写回地址生成 (nTrs=16/48)
    │   └── lfnst_config.v              # LFNST 参数计算
    ├── mem/
    │   ├── trans_matrix_rom.v          # DCT2/DST7/DCT8 变换矩阵 ROM
    │   └── lfnst_matrix_rom.v          # LFNST 核矩阵 ROM (16 种组合)
    ├── common/
    │   ├── clip.v                      # 通用限幅 (Clip10/Clip16)
    │   └── round_shift.v               # 舍入右移
    ├── scripts/
    │   ├── gen_trans_matrix_rom.py     # 从参考模型生成变换矩阵 ROM
    │   ├── gen_lfnst_matrix_rom.py     # 从参考模型生成 LFNST 矩阵 ROM
    │   ├── gen_regression_stim.py      # 生成回归测试激励
    │   ├── gen_rom_golden.py           # 生成 ROM 比对头文件
    │   └── gen_lfnst_rom_golden.py     # 生成 LFNST ROM 比对头文件
    └── tb_verilator/
        ├── Makefile                    # 构建脚本 (Verilator + MSYS2)
        ├── sim_main_regression.cpp     # 主回归测试 (1377 cases)
        ├── sim_main.cpp                # 单 case 硬编码测试
        ├── sim_main_backpressure.cpp   # 输出反压测试
        ├── sim_main_input_protocol.cpp # 输入协议压力测试
        ├── sim_main_rom_test.cpp       # 变换矩阵 ROM 单测
        ├── sim_main_lfnst_rom_test.cpp # LFNST 矩阵 ROM 单测
        ├── regression_stim/            # 1377 个 .stim 激励文件
        ├── trans_matrix_golden.h       # 变换矩阵 golden 数据
        └── lfnst_matrix_golden.h       # LFNST 矩阵 golden 数据
```

---

## 3. 参考模型

### 3.1 概述

参考模型为纯 Python 实现，位于 `D:\HW_WORK\its_reference\`，负责生成全部 1377 组 golden data。

### 3.2 核心文件

| 文件 | 功能 |
|------|------|
| `transforms/reference_model.py` | 主函数 `its_inverse()`，编排完整反变换流水线 |
| `transforms/dct2.py` | DCT2 一维反变换 |
| `transforms/dct8_dst7.py` | DST7 / DCT8 一维反变换 |
| `transforms/lfnst.py` | LFNST 逆变换 |
| `matrices/trans_matrix.py` | 全部变换矩阵 `TRANS_MATRIX[tr_type][length][out][in]` |
| `matrices/lfnst_kernels.py` | 全部 LFNST 核 `LFNST_KERNELS[nTrs][set][idx]` |
| `common/utils.py` | Clip3、转置、raster↔matrix 转换、打包 |
| `common/fixed_point.py` | 定点移位/限幅常量 |
| `generate_golden_data.py` | 生成 1377 组测试用例 |

### 3.3 参考模型处理流程

```
输入系数 (raster order)
    │
    ▼
[Step 1] LFNST 逆变换 (若 lfnst_idx != 0)
    │
    ▼
[Step 2] raster_to_matrix → 二维矩阵
    │
    ▼
[Step 3] 列 1D 反变换 (shift=7, Clip16)
    │
    ▼
[Step 4] 行 1D 反变换 (shift=10, 不限幅)
    │
    ▼
[Step 5] Clip10 最终限幅
    │
    ▼
[Step 6] 4 点一组打包为 40-bit
```

### 3.4 测试用例覆盖

| 类别 | 数量 | 说明 |
|------|------|------|
| DCT2×DCT2 | 225 | 25 种 TU 尺寸 (4×4 ~ 64×64)，每种 9 种 LFNST 配置 |
| MTS (DST7/DCT8 混合) | 1152 | 16 种 TU 尺寸 (4×4 ~ 32×32)，8 种变换组合，9 种 LFNST 配置 |
| **合计** | **1377** | 覆盖赛题全部要求的 TU 尺寸和变换类型组合 |

### 3.5 Golden Data 格式

每组测试用例目录包含：

| 文件 | 内容 |
|------|------|
| `config.json` | TU 尺寸、变换类型、LFNST 配置 |
| `input_sparse.txt` | 稀疏输入 (addr value 对) |
| `input_dense.txt` | 全系数 raster 顺序 |
| `output_signed.txt` | 10-bit 有符号输出值 |
| `output_packed.txt` | 40-bit 打包输出 (hex) |

打包格式：`[39:30]=p3, [29:20]=p2, [19:10]=p1, [9:0]=p0`，每 10-bit 为有符号二进制补码。

---

## 4. RTL 架构总览

### 4.1 模块层次

```
its_top
├── config_decode          — 22-bit it_info 解码
├── its_ctrl_fsm           — 主控状态机
├── tu_buffer              — TU 系数缓存 (4096×16)
├── intermediate_buffer    — 中间结果缓存 (4096×32)
├── addr_gen               — 地址生成器
├── lfnst_core             — LFNST 主控
│   ├── lfnst_scan         — 对角线扫描
│   ├── lfnst_writeback    — 写回地址 + Clip16
│   ├── lfnst_config       — 参数计算
│   └── lfnst_matrix_rom   — LFNST 核 ROM (16 种)
├── it_1d_core             — 统一 1D 变换入口
│   ├── dct2_1d            — DCT2 核 (4×trans_matrix_rom + MAC + shift/clip)
│   ├── dst7_1d            — DST7 核
│   └── dct8_1d            — DCT8 核
├── output_packer          — Clip10 + 40-bit 打包输出
└── trans_matrix_rom       — 变换系数 ROM (13 种矩阵)
```

### 4.2 数据流图

```
it_data_in ──→ [TU Buffer] ──→ [LFNST] (可选) ──→ [TU Buffer]
                                        │
                         ┌──────────────┘
                         ▼
               [it_1d_core: 列变换]
               tr_type_ver, len=tu_height
               shift=7, Clip16
                         │
                         ▼  (128-bit → 4×32 反序列化)
                         │
               [Intermediate Buffer]  (列主序存储)
                         │
                         ▼
               [it_1d_core: 行变换]
               tr_type_hor, len=tu_width
               shift=10, 不限幅
                         │
                         ▼  (128-bit → 4×16 反序列化, 截断为 16-bit)
                         │
               [TU Buffer]  (写回行变换结果)
                         │
                         ▼
               [Output Packer]
               Clip10 → 10-bit/点 → 4 点打包 40-bit
                         │
                         ▼
               it_data_out (40-bit)
```

### 4.3 关键设计决策

1. **单核复用**：列变换和行变换共用同一个 `it_1d_core`，通过 FSM 分时调度
2. **3 路写入仲裁**：TU Buffer 写入优先级 —— 行变换写回 > LFNST 写 > 输入写
3. **128-bit 并行输出**：1D 核每次输出 4 个结果 (128-bit)，由 `its_top` 内部反序列化为逐拍写入
4. **列主序中间存储**：Intermediate Buffer 使用 `addr = col * tu_height + row` 布局，行变换按列读取实现转置
5. **配置队列**：FSM 内置深度 2 的配置 FIFO，支持流水处理连续 TU

---

## 5. 各模块详细说明

### 5.1 `its_top` — 顶层模块

**文件**：`top/its_top.v`

整合全部子模块，管理：
- 3 路 TU Buffer 写入仲裁 (input / LFNST writeback / row-transform output)
- 128-bit → 4×32-bit 反序列化器 (两套：列变换写中间缓存、行变换写 TU Buffer)
- 读状态机 (`rd_state`)：驱动 1D 核输入数据，处理 TU Buffer / Intermediate Buffer 的 1 拍读延迟
- 中间缓存预取逻辑

### 5.2 `its_ctrl_fsm` — 主控状态机

**文件**：`ctrl/its_ctrl_fsm.v`

**状态编码**：

| 状态 | 值 | 说明 |
|------|---|------|
| IDLE | 0 | 等待配置入队，出队并触发 TU Buffer 清零 |
| CLEAR | 9 | 等待 TU Buffer 清零完成 |
| INPUT | 1 | 接收输入系数，计数到 tu_width×tu_height |
| LFNST_WAIT | 2 | 等待 LFNST 就绪 |
| LFNST_RUN | 3 | LFNST 执行中，Buffer 所有权转给 LFNST |
| WAIT_1CYCLE | 4 | LFNST 完成后 1 拍等待 |
| COL_1D | 5 | 列 1D 变换，逐列启动 it1d_start |
| COL_1D_DONE | 10 | 列变换全部完成，等中间缓存写入排空 |
| ROW_1D | 6 | 行 1D 变换，逐行启动 it1d_start |
| ROW_1D_DONE | 11 | 行变换全部完成，等 TU Buffer 行写入排空 |
| OUTPUT | 7 | 启动 output_packer，等待 packer_done |
| DONE | 8 | 发出 it_done 脉冲，返回 IDLE |

**流水控制**：
- 3 个忙标志：`pipe_input_busy`、`pipe_compute_busy`、`pipe_output_busy`
- INPUT 阶段完成后，若配置队列有下一个 TU 且流水线空闲，立即接受新配置

### 5.3 `config_decode` — 配置解码

**文件**：`ctrl/config_decode.v`

将 22-bit `it_info` 解码为独立字段，1 拍寄存器延迟输出：

| 位域 | 宽度 | 字段 | 取值 |
|------|------|------|------|
| [6:0] | 7 | `tu_width` | 4 ~ 64 |
| [13:7] | 7 | `tu_height` | 4 ~ 64 |
| [15:14] | 2 | `tr_type_hor` | 0=DCT2, 1=DST7, 2=DCT8 |
| [17:16] | 2 | `tr_type_ver` | 0=DCT2, 1=DST7, 2=DCT8 |
| [19:18] | 2 | `lfnst_tr_set_idx` | 0 ~ 3 |
| [21:20] | 2 | `lfnst_idx` | 0=直通, 1~2=LFNST 变换 |

### 5.4 `addr_gen` — 地址生成器

**文件**：`ctrl/addr_gen.v`

纯组合逻辑，为各阶段生成读写地址：

| 输出 | 公式 | 用途 |
|------|------|------|
| `input_addr_out` | = `input_addr_in` | 输入写入直通 |
| `col_rd_addr` | `row_idx * tu_width + col_idx` | 列变换从 TU Buffer 读 |
| `col_wr_addr` | = `col_rd_addr` | 列变换写入中间缓存 |
| `row_rd_addr` | `col_idx * tu_height + row_idx` | 行变换从中间缓存读 (列主序) |
| `output_rd_addr` | = `output_idx` | 输出从 TU Buffer 读 |

地址宽度 12-bit，支持最大 4096 地址 (64×64 TU)。

### 5.5 `tu_buffer` — TU 系数缓存

**文件**：`buffer/tu_buffer.v`

- **容量**：4096×16-bit 单端口 RAM
- **读延迟**：1 拍 (寄存器输出)
- **清零机制**：收到 `clear` 脉冲后逐地址填零，完成时发出 `clear_done` 脉冲
- **写保护**：清零期间普通写入被屏蔽

### 5.6 `intermediate_buffer` — 中间结果缓存

**文件**：`buffer/intermediate_buffer.v`

- **容量**：4096×32-bit 单端口 RAM
- **读延迟**：1 拍
- **存储布局**：列主序 `addr = col * tu_height + row`
- **无清零机制**：每次使用前被列变换结果覆盖

### 5.7 `it_1d_core` — 统一 1D 变换入口

**文件**：`transform_1d/it_1d_core.v`

**内部状态机**：

| 状态 | 说明 |
|------|------|
| IDLE | 空闲，等待 `it1d_start` 脉冲 |
| LOAD_WAIT | 1 拍等待，补偿 Buffer 读延迟 |
| LOAD | 逐个接收系数到 `coeff_mem[0..63]` |
| COMPUTE | 调用子变换核处理，4 结果/拍输出 |
| DONE | 发出 `it1d_done` 脉冲，返回 IDLE |

**输出格式**：128-bit 并行输出 = 4 × 32-bit，由顶层反序列化为逐拍写入。

**子变换选择**：根据 `tr_type` MUX 选择 `dct2_1d` / `dst7_1d` / `dct8_1d` 的输出。

### 5.8 `dct2_1d` / `dst7_1d` / `dct8_1d` — 1D 变换核

**文件**：`transform_1d/dct2_1d.v`, `dst7_1d.v`, `dct8_1d.v`

三者架构完全相同，仅 `tr_type` 常量不同 (0/1/2)。

**架构**：
- 4 个并行 `trans_matrix_rom` 实例，分别读取 4 个输出行
- 4 组 generate-block MAC：`signed_coeff × signed_matrix → 24-bit → 符号扩展 32-bit → 累加`
- 4 条 `round_shift + clip` 后处理链
- 3 状态 FSM：IDLE → COMPUTE (遍历 col_cnt 0..length-1) → OUTPUT (发射 4 结果，row_base += 4)

**处理模式**：对 N 点变换，row_base 步进 4 (0, 4, 8, ..., N-4)，每步计算 N 拍列贡献，产出 4 行结果。

**支持的变换长度**：

| 变换类型 | 支持长度 |
|----------|----------|
| DCT2 | 4, 8, 16, 32, 64 |
| DST7 | 4, 8, 16, 32 |
| DCT8 | 4, 8, 16, 32 |

### 5.9 `mac_array` — 8 路并行 MAC 阵列

**文件**：`transform_1d/mac_array.v`

可复用的 8 路并行 MAC，3 级流水线归约树：
- Level 1：4 个寄存器加法器 `mult[2i] + mult[2i+1]` → 25-bit
- Level 2：2 个寄存器加法器 → 26-bit，符号扩展 32-bit
- Level 3：1 个寄存器加法器 → 32-bit `final_sum`
- 累加器：`acc_reg` 跨 8 元素分块累加

**注意**：当前顶层设计未直接实例化此模块，各变换核使用内联 generate-block MAC。

### 5.10 `lfnst_core` — LFNST 主控

**文件**：`lfnst/lfnst_core.v`

**状态机**：IDLE → SCAN → LOAD → FETCH → COMPUTE → WRITEBACK → DONE

**处理流程**：
1. **SCAN**：通过 `lfnst_scan` 生成对角线扫描地址，从 TU Buffer 读取 16 个低频系数
2. **LOAD**：设置矩阵行列计数器，清零累加器
3. **FETCH**：1 拍启动 ROM 读取
4. **COMPUTE**：矩阵-向量乘法。对每个输出行 (0..nTrs-1)，遍历列 (0..nonZeroSize-1)，使用同步 ROM (1 拍延迟)
5. **WRITEBACK**：通过 `lfnst_writeback` 写回 TU Buffer，应用 `(val+64)>>>7` + Clip16

**关键参数**：
- `nTrs`：48 (宽高均 ≥ 8) 或 16 (其他)
- `nonZeroSize`：8 (4×4 或 8×8) 或 16 (其他)

### 5.11 `lfnst_scan` — 对角线扫描

**文件**：`lfnst/lfnst_scan.v`

硬编码 16 个对角线扫描位置的 (x, y) 坐标查找表。地址计算：`scan_addr = scan_y * tu_width + scan_x`。`scan_valid` 信号延伸 3 拍以补偿流水线预热。

### 5.12 `lfnst_writeback` — LFNST 写回

**文件**：`lfnst/lfnst_writeback.v`

- **nTrs=16**：填充左上 4×4 区域
- **nTrs=48**：填充倒 L 型区域 —— 行 0-3 列 0-7 (32 点) + 行 4-7 列 0-3 (16 点)

后处理：`Clip16((val + 64) >>> 7)`

### 5.13 `lfnst_config` — LFNST 参数计算

**文件**：`lfnst/lfnst_config.v`

纯组合逻辑：
- `nTrs`：48 (宽高均 ≥ 8) 或 16
- `nonZeroSize`：8 (4×4 或 8×8) 或 16
- `sbSize`：16 (宽高均 ≥ 16) / 8 (宽高均 ≥ 8) / 4 (其他)

### 5.14 `trans_matrix_rom` — 变换矩阵 ROM

**文件**：`mem/trans_matrix_rom.v`

- **存储**：全部 13 种矩阵，`localparam signed [7:0]` 二维数组
- **索引约定**：`ROM[col_addr][row_addr]` = `TRANS_MATRIX[col][row]` = `matrix[in][out]`
- **读取**：组合逻辑 MUX，按 `tr_type` + `length` 选择矩阵子表
- **系数范围**：[-91, 91]

| 变换类型 | 矩阵数量 | 尺寸 |
|----------|----------|------|
| DCT2 | 5 | 4×4, 8×8, 16×16, 32×32, 64×64 |
| DST7 | 4 | 4×4, 8×8, 16×16, 32×32 |
| DCT8 | 4 | 4×4, 8×8, 16×16, 32×32 |

### 5.15 `lfnst_matrix_rom` — LFNST 核矩阵 ROM

**文件**：`mem/lfnst_matrix_rom.v`

- **存储**：16 种组合 = {nTrs=16, 48} × {set 0..3} × {idx 1, 2}
- **容量**：nTrs=16 时 16×16，nTrs=48 时 48×16
- **读取**：同步 (1 拍延迟)，`rom_sel = {sel_nTrs, sel_set, sel_idx}` 选择子表

### 5.16 `clip` — 通用限幅模块

**文件**：`common/clip.v`

纯组合逻辑：
- `clip_en=0`：直通
- `clip_bits=10`：Clip10 — 钳位到 [0, 1023]
- `clip_bits=16`：Clip16 — 钳位到 [-32768, 32767]

### 5.17 `round_shift` — 舍入右移

**文件**：`common/round_shift.v`

纯组合逻辑：`(val + (1 << (shift-1))) >>> shift`，支持 shift 0~31。

### 5.18 `output_packer` — 输出打包

**文件**：`top/output_packer.v`

**状态机**：IDLE → SETUP → CAPTURE → OUTPUT (循环)

**处理流程**：
1. **SETUP**：驱动 TU Buffer 读地址
2. **CAPTURE**：Buffer 数据到达 (1 拍延迟)，Clip10 限幅后存入 `pixel_buf`
3. **OUTPUT**：4 像素打包为 40-bit `{p3, p2, p1, p0}`，等待 `it_data_out_req` 握手

**吞吐量**：每像素 2 拍 (SETUP + CAPTURE)，每 40-bit 输出需 8 拍 + 握手时间。

---

## 6. 外部接口定义

### 6.1 顶层端口列表

```verilog
module its_top (
    // 全局信号
    input  wire        clk,              // 500MHz 工作时钟
    input  wire        rst_n,            // 低电平异步复位

    // 配置接口
    input  wire [21:0] it_info,          // 22-bit 配置信息
    input  wire        it_info_vld,      // 配置有效 (1 拍脉冲)

    // 数据输入接口
    input  wire        it_data_in_vld,   // 输入数据有效
    input  wire [11:0] it_data_addr,     // 输入数据地址 (raster 扫描)
    input  wire [15:0] it_data_in,       // 输入数据 (16-bit 有符号)
    input  wire        it_data_end,      // TU 输入完成指示

    // 输入反压
    output wire        it_data_in_req,   // 模块准备好接收数据

    // 数据输出接口
    output wire [39:0] it_data_out,      // 40-bit 打包输出 (4×10-bit)
    output wire        it_data_out_vld,  // 输出数据有效
    input  wire        it_data_out_req,  // 下游准备好接收

    // 完成指示
    output wire        it_done,          // TU 计算完成 (单拍脉冲)

    // 调试端口 (可选)
    output wire [7:0]  debug_state,
    output wire [3:0]  debug_stage,
    output wire [15:0] debug_count,
    output wire        debug_buf_wr_en,
    output wire [11:0] debug_buf_wr_addr,
    output wire [15:0] debug_buf_wr_data,
    output wire        debug_buf_clearing,
    output wire [1:0]  debug_rd_state_o,
    output wire [2:0]  debug_1d_state_o,
    output wire        debug_it1d_ready_o,
    output wire        debug_it1d_start_o,
    output wire        debug_it1d_done_o
);
```

### 6.2 输入协议

1. 外部先发送 `it_info` + `it_info_vld` 配置 TU 参数
2. 等待 `it_data_in_req` 为高
3. 逐拍发送稀疏输入：`it_data_addr` + `it_data_in` + `it_data_in_vld`
4. 最后一拍同时或之后一拍拉高 `it_data_end`
5. 支持输入间隙：`it_data_in_vld` 可以任意间隔拉高

### 6.3 输出协议

1. 模块计算完成后拉高 `it_data_out_vld`，驱动 `it_data_out`
2. 下游通过 `it_data_out_req` 反压
3. **约束**：`it_data_out_vld=1` 时 `it_data_out_req` 必须为高 (不允许 vld 高而 req 低)
4. 输出完成后发出 `it_done` 脉冲

### 6.4 连续 TU 协议

- TU 间无需全局复位
- 前一个 TU 的 `it_done` 脉冲后，可立即发送下一个 TU 的 `it_info`
- FSM 内置深度 2 配置队列，支持流水重叠

---

## 7. 处理流水线

### 7.1 FSM 状态转移图

```
        ┌──────────────────────────────────────────────────────┐
        │                                                      │
        ▼                                                      │
     [IDLE] ──→ [CLEAR] ──→ [INPUT] ──→ (lfnst_idx==0?)       │
        │                      │              │                │
        │                      │         Yes  │  No            │
        │                      │              ▼                │
        │                      │      [LFNST_WAIT]             │
        │                      │              │                │
        │                      │      [LFNST_RUN]              │
        │                      │              │                │
        │                      │      [WAIT_1CYCLE]            │
        │                      │              │                │
        │                      └──────┬───────┘                │
        │                             ▼                        │
        │                         [COL_1D] ──→ [COL_1D_DONE]   │
        │                             │                        │
        │                             ▼                        │
        │                         [ROW_1D] ──→ [ROW_1D_DONE]   │
        │                             │                        │
        │                             ▼                        │
        │                         [OUTPUT]                     │
        │                             │                        │
        │                             ▼                        │
        │                          [DONE] ──→ it_done          │
        │                                                      │
        └──────────────────────────────────────────────────────┘
```

### 7.2 各阶段时序参数

| 阶段 | 持续周期 (以 4×4 为例) | 说明 |
|------|----------------------|------|
| IDLE→CLEAR | ~17 拍 | TU Buffer 清零 (4×4=16 地址) |
| INPUT | ~17 拍 | 接收稀疏输入 (取决于非零系数数量) |
| LFNST (若启用) | ~50-200 拍 | 对角扫描 + 矩阵乘 + 写回 |
| COL_1D | 4×(4+1)=20 拍 | 4 列，每列 4 点变换 + 1 拍启动 |
| COL_1D_DONE | 1-2 拍 | 等中间缓存写入排空 |
| ROW_1D | 4×(4+1)=20 拍 | 4 行，每行 4 点变换 + 1 拍启动 |
| ROW_1D_DONE | 2-3 拍 | 等 TU Buffer 写入排空 |
| OUTPUT | ~32 拍 | 16 像素 × 2 拍/像素 |
| DONE | 1 拍 | it_done 脉冲 |

### 7.3 列变换与行变换参数对比

| 参数 | 列变换 (第一维) | 行变换 (第二维) |
|------|----------------|----------------|
| 变换类型 | `tr_type_ver` | `tr_type_hor` |
| 变换长度 | `tu_height` | `tu_width` |
| 移位值 | 7 | 10 |
| 后处理 | Clip16 (-32768~32767) | 无 (最终限幅在 output_packer) |

---

## 8. 验证环境

### 8.1 测试平台架构

使用 **Verilator 5.046** (MSYS2 MinGW64) 将 RTL 转为 C++ 模型，配合自编 C++ testbench 进行仿真验证。

### 8.2 测试用例一览

| 测试文件 | 功能 | 覆盖范围 |
|----------|------|----------|
| `sim_main_regression.cpp` | 主回归测试 | 全部 1377 个 case，逐个比对 golden |
| `sim_main.cpp` | 单 case 硬编码 | 4×4 DCT2 lfnst0，开发调试用 |
| `sim_main_backpressure.cpp` | 输出反压测试 | 4 种反压模式 × 代表 case 子集 |
| `sim_main_input_protocol.cpp` | 输入协议压力测试 | 输入间隙 + it_data_end 时序 + 连续 TU 无复位 |
| `sim_main_rom_test.cpp` | 变换矩阵 ROM 单测 | 13 种矩阵逐元素比对 |
| `sim_main_lfnst_rom_test.cpp` | LFNST 矩阵 ROM 单测 | 16 种组合逐元素比对 |

### 8.3 输入协议测试详情

**Test 1 — 输入间隙测试**：
- `gap_every_2`：每发 2 个系数暂停 1 拍
- `gap_random_30pct`：30% 概率暂停
- `gap_heavy`：大量间隙

**Test 2 — it_data_end 时序测试**：
- `end_same_cycle`：`it_data_end` 与最后一个数据同拍
- `end_next_cycle`：`it_data_end` 在数据后一拍

**Test 3 — 连续 TU 无复位测试**：
- 37 个 case 子集，TU 间无全局复位，验证 FSM 正确返回 IDLE

### 8.4 构建命令

```bash
# MSYS2 环境下
cd D:/HW_WORK/huawei_vvc/rtl/tb_verilator

# 回归测试
MSYS2_ROOT=/d/msys2/mingw64 mingw32-make all

# 协议测试
MSYS2_ROOT=/d/msys2/mingw64 mingw32-make proto

# 反压测试
MSYS2_ROOT=/d/msys2/mingw64 mingw32-make bp
```

### 8.5 辅助脚本

| 脚本 | 功能 |
|------|------|
| `gen_trans_matrix_rom.py` | 从 Python 参考模型生成 `trans_matrix_rom.v` |
| `gen_lfnst_matrix_rom.py` | 从 Python 参考模型生成 `lfnst_matrix_rom.v` |
| `gen_regression_stim.py` | 将 golden data 转换为 `.stim` 激励文件 |
| `gen_rom_golden.py` | 生成 C++ 头文件用于 ROM 比对 |
| `gen_lfnst_rom_golden.py` | 生成 C++ 头文件用于 LFNST ROM 比对 |

---

## 9. 赛题对齐度分析

### 9.1 功能覆盖

| 赛题要求 | 实现状态 | 说明 |
|----------|----------|------|
| DCT2 变换 (4~64 点) | **已覆盖** | 5 种尺寸全部支持 |
| DST7 变换 (4~32 点) | **已覆盖** | 4 种尺寸全部支持 |
| DCT8 变换 (4~32 点) | **已覆盖** | 4 种尺寸全部支持 |
| 2D 可分离变换 (列+行) | **已覆盖** | 列 1D → 转置 → 行 1D |
| LFNST (lfnst_idx=1,2) | **已覆盖** | nTrs=16/48，4 种 set |
| 非方形 TU | **已覆盖** | 4×8, 8×4, 16×32 等 |
| 稀疏输入 | **已覆盖** | addr+value 对输入 |
| 40-bit 打包输出 | **已覆盖** | 4×10-bit Clip10 打包 |
| 输入反压 (it_data_in_req) | **已覆盖** | FSM 在非 INPUT 状态时 req=0 |
| 输出反压 (it_data_out_req) | **已覆盖** | 握手协议，vld 高时 req 必须高 |
| 连续 TU (无全局复位) | **已覆盖** | 配置队列 + 流水控制 |
| 500MHz 时序目标 | **待综合验证** | Verilator 功能仿真已通过，需综合后时序分析 |

### 9.2 验证覆盖

| 验证维度 | 状态 | 数据 |
|----------|------|------|
| 功能回归 | **PASS** | 1377/1377 |
| 输出反压 | **PASS** | 4 种模式 × 代表 case |
| 输入间隙 | **PASS** | 3 种间隙模式 × 37 case |
| it_data_end 时序 | **PASS** | 2 种模式 × 37 case |
| 连续 TU 无复位 | **PASS** | 37 case 连续发送 |
| ROM 一致性 | **PASS** | 变换矩阵 + LFNST 矩阵逐元素比对 |
| 综合 / PPA | **未开始** | 需 Yosys / Design Compiler |

---

## 10. 已修复的 Bug 列表

### 10.1 早期集成 Bug (Fix 1~5)

| # | 问题 | 文件 | 严重程度 |
|---|------|------|----------|
| 1 | 变换矩阵索引方向错误 `[row][col]` 应为 `[col][row]` | `trans_matrix_rom.v` | 根因 |
| 2 | Testbench golden data 手算错误 | `sim_main.cpp` | 高 |
| 3 | 行变换写入被截断 (缺少 ROW_1D_DONE 状态) | `its_ctrl_fsm.v` | 高 |
| 4 | Testbench 双采样 (negedge + posedge) | `sim_main.cpp` | 中 |
| 5 | 调试 $display 残留 | 多文件 | 低 |

### 10.2 连续 TU Bug (Fix 6)

| # | 问题 | 文件 | 严重程度 |
|---|------|------|----------|
| 6 | ROW_1D 最后一行缺少 `it1d_start` 保护条件 | `its_ctrl_fsm.v` | 高 |

**根因**：`COL_1D` 状态有 `!(it1d_done && col_cnt >= r_tu_width - 1)` 保护，但 `ROW_1D` 缺少对应保护。当最后一行 `it1d_done` 与 `it1d_ready` 同拍为高时，`it1d_start` 被错误触发，1D 核进入 LOAD 状态却无数据喂入，导致后续 TU 永久卡死。

**修复**：
```diff
- if (it1d_ready && !it1d_start) begin
+ if (it1d_ready && !it1d_start && !(it1d_done && row_cnt >= r_tu_height - 1)) begin
```

---

## 11. 待完善内容与后续目标

### 11.1 功能完善

| 项目 | 优先级 | 说明 |
|------|--------|------|
| 综合与时序分析 | **高** | 使用 Yosys 或 DC 综合，验证 500MHz 目标能否满足 |
| PPA 评估 | **高** | 面积、功耗、性能数据，赛题核心评分项 |
| 清理调试端口 | 中 | `debug_*` 端口在综合前应移除或条件编译 |
| 清理未使用模块 | 低 | `mac_array.v` 当前未实例化，可考虑移除或集成 |

### 11.2 验证完善

| 项目 | 优先级 | 说明 |
|------|--------|------|
| 更多反压场景 | 中 | 极端反压 (1 拍 on / N 拍 off)、输出端饥饿 |
| 边界饱和测试 | 中 | 最大 TU (64×64)、最大系数值 |
| 流水重叠压测 | 中 | 连续发送大量 TU，验证配置队列不会溢出 |
| 功耗仿真 | 低 | 基于 VCD 的开关活动功耗分析 |

### 11.3 文档完善

| 项目 | 优先级 | 说明 |
|------|--------|------|
| 设计文档 | 高 | 赛题要求提交的 RTL 设计说明 |
| 验证报告 | 高 | 测试策略、覆盖率、结果汇总 |
| 时序约束文件 | 中 | SDC 约束，综合/STA 输入 |
| 接口时序图 | 中 | 各阶段信号波形示意 |

### 11.4 后续修正目标

1. **综合流程搭建**：建立 Yosys 综合脚本，生成面积/时序报告
2. **关键路径优化**：识别 500MHz 瓶颈，优化 MAC 链或流水级数
3. **面积优化**：评估是否可以合并 DCT2/DST7/DCT8 三个核为一个可配置核
4. **功耗优化**：未使用模块的时钟门控、Buffer 读写的使能优化
5. **FPGA 原型验证**：在 FPGA 上跑通全功能，验证实际时序

---

## 12. 测试结果汇总

### 12.1 回归测试

```
Total: 1377, Passed: 1377, Failed: 0
ALL CASES PASSED!
```

覆盖：4×4 ~ 64×64 全部 TU 尺寸、DCT2/DST7/DCT8 全部变换组合、LFNST 0/1/2 全部模式。

### 12.2 协议测试

```
=== Input Protocol Test Summary ===
Total: 188, Passed: 188, Failed: 0
ALL PROTOCOL TESTS PASSED!
```

| 子测试 | 结果 |
|--------|------|
| Input Gap (3 模式 × 37 case) | 111/111 PASS |
| it_data_end same-cycle (37 case) | 37/37 PASS |
| it_data_end next-cycle (37 case) | 37/37 PASS |
| Continuous TU no-reset (37 case) | 37/37 PASS |

### 12.3 ROM 一致性测试

| 测试项 | 结果 |
|--------|------|
| 变换矩阵 ROM (13 种矩阵) | PASS |
| LFNST 矩阵 ROM (16 种组合) | PASS |

---

## 附录 A：关键信号速查表

| 信号 | 方向 | 说明 |
|------|------|------|
| `it_info[21:0]` | in | 22-bit 配置 |
| `it_data_in_vld` | in | 输入数据有效 |
| `it_data_addr[11:0]` | in | 输入地址 |
| `it_data_in[15:0]` | in | 输入数据 |
| `it_data_end` | in | 输入结束 |
| `it_data_in_req` | out | 输入就绪 |
| `it_data_out[39:0]` | out | 40-bit 打包输出 |
| `it_data_out_vld` | out | 输出有效 |
| `it_data_out_req` | in | 输出就绪 |
| `it_done` | out | TU 完成脉冲 |
| `it1d_start` | 内部 | 1D 核启动脉冲 |
| `it1d_ready` | 内部 | 1D 核空闲 |
| `it1d_done` | 内部 | 1D 核完成脉冲 |
| `lfnst_start` | 内部 | LFNST 启动脉冲 |
| `lfnst_done` | 内部 | LFNST 完成脉冲 |
| `packer_start` | 内部 | 输出打包启动 |
| `packer_done` | 内部 | 输出打包完成 |

## 附录 B：矩阵索引约定

**参考模型**：`TRANS_MATRIX[tr_type][length][out_idx][in_idx]`

**RTL ROM**：`ROM[col_addr][row_addr]` = `TRANS_MATRIX[in_idx][out_idx]`

**MAC 计算**：`output[row] += input[col] × ROM[col][row]`

这是整个设计中最容易出错的地方——矩阵的行列方向必须与参考模型一致。早期的 Fix 1 就是索引方向反了导致全部输出错误。
