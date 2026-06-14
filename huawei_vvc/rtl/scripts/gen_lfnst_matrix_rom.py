#!/usr/bin/env python3
"""
Generate lfnst_matrix_rom.v from reference LFNST_KERNELS.
Replaces placeholder ROM with complete LFNST matrix data.

ROM structure:
  sel = {sel_nTrs, sel_set, sel_idx} → selects one of 16 matrices
  nTrs=16: matrix is 16 rows x 16 cols
  nTrs=48: matrix is 48 rows x 16 cols

Reference: LFNST_KERNELS[nTrs][set][idx] = matrix[row][col]
  nTrs: 16 or 48
  set: 0-3
  idx: 1 or 2
"""

import sys
import os

REF_DIR = r"D:\HW_WORK\its_reference"
sys.path.insert(0, REF_DIR)

from matrices.lfnst_kernels import LFNST_KERNELS

OUT_PATH = r"D:\HW_WORK\huawei_vvc\rtl\mem\lfnst_matrix_rom.v"


def generate():
    # Build all matrices indexed by (nTrs, set, idx)
    configs = []
    for nTrs in [16, 48]:
        for sel_set in range(4):
            for sel_idx in [1, 2]:
                configs.append((nTrs, sel_set, sel_idx))

    # Verify all matrices exist and check coefficient range
    for nTrs, sel_set, sel_idx in configs:
        matrix = LFNST_KERNELS[nTrs][sel_set][sel_idx]
        rows = len(matrix)
        cols = len(matrix[0]) if rows > 0 else 0
        expected_rows = nTrs
        expected_cols = 16
        assert rows == expected_rows, f"nTrs={nTrs} set={sel_set} idx={sel_idx}: got {rows} rows, expected {expected_rows}"
        assert cols == expected_cols, f"nTrs={nTrs} set={sel_set} idx={sel_idx}: got {cols} cols, expected {expected_cols}"

        all_vals = [v for row in matrix for v in row]
        vmin, vmax = min(all_vals), max(all_vals)
        assert -128 <= vmin and vmax <= 127, f"nTrs={nTrs} set={sel_set} idx={sel_idx}: range [{vmin}, {vmax}] out of int8"
        print(f"  nTrs={nTrs} set={sel_set} idx={sel_idx}: {rows}x{cols}, range [{vmin}, {vmax}]")

    # Generate Verilog
    lines = []
    lines.append("//===========================================================================")
    lines.append("// lfnst_matrix_rom.v - LFNST矩阵ROM (auto-generated)")
    lines.append(f"// Generated from lfnst_kernels.py reference model")
    lines.append("// 矩阵组织: matrix[sel_nTrs][sel_set][sel_idx][row][col]")
    lines.append("//   sel_nTrs: 0=nTrs16, 1=nTrs48")
    lines.append("//   sel_set: 0~3")
    lines.append("//   sel_idx: 0=idx1, 1=idx2")
    lines.append("//===========================================================================")
    lines.append("")
    lines.append("/* verilator lint_off UNUSEDSIGNAL */")
    lines.append("")
    lines.append("module lfnst_matrix_rom (")
    lines.append("    input  wire        clk,")
    lines.append("    input  wire [5:0]  rd_addr,      // 行地址 (0~47)")
    lines.append("    input  wire [5:0]  rd_col,       // 列地址 (0~15)")
    lines.append("    input  wire        sel_nTrs,     // 选择nTrs: 0=16, 1=48")
    lines.append("    input  wire [1:0]  sel_set,      // 选择set: 0~3")
    lines.append("    input  wire        sel_idx,      // 选择idx: 0=idx1, 1=idx2")
    lines.append("    output reg  [7:0]  rd_data       // 矩阵系数(8bit有符号)")
    lines.append(");")
    lines.append("")
    lines.append("    //===========================================================================")
    lines.append("    // ROM选择信号组合")
    lines.append("    //===========================================================================")
    lines.append("    wire [3:0] rom_sel = {sel_nTrs, sel_set, sel_idx};")
    lines.append("")

    # Generate localparam arrays for each configuration
    for nTrs, sel_set, sel_idx in configs:
        matrix = LFNST_KERNELS[nTrs][sel_set][sel_idx]
        sel_idx_str = "1" if sel_idx == 1 else "2"
        name = f"LFNST_{nTrs}_SET{sel_set}_IDX{sel_idx_str}"
        lines.append(f"    // {name}: {nTrs}x16, LFNST_KERNELS[{nTrs}][{sel_set}][{sel_idx}]")
        lines.append(f"    localparam signed [7:0] {name} [0:{nTrs-1}][0:15] = '{{")
        for r in range(nTrs):
            vals = []
            for c in range(16):
                vals.append(f"{matrix[r][c]:>4d}")
            comma = "," if r < nTrs - 1 else ""
            lines.append(f"        '{{{', '.join(vals)}}}{comma}")
        lines.append("    };")
        lines.append("")

    # Generate read logic with case statement
    lines.append("    //===========================================================================")
    lines.append("    // 读逻辑 - 截断索引位宽")
    lines.append("    //===========================================================================")
    lines.append(f"    wire [3:0] row_idx = rd_addr[3:0];  // 4bit索引(0-15), nTrs=48时用[5:0]")
    lines.append(f"    wire [3:0] col_idx = rd_col[3:0];   // 4bit索引(0-15)")
    lines.append("")
    lines.append("    always @(posedge clk) begin")
    lines.append("        case (rom_sel)")

    for nTrs, sel_set, sel_idx in configs:
        sel_idx_str = "1" if sel_idx == 1 else "2"
        name = f"LFNST_{nTrs}_SET{sel_set}_IDX{sel_idx_str}"
        # rom_sel encoding: {sel_nTrs, sel_set[1:0], sel_idx}
        nTrs_bit = 1 if nTrs == 48 else 0
        sel_idx_bit = 0 if sel_idx == 1 else 1  # idx1→0, idx2→1
        rom_val = (nTrs_bit << 3) | (sel_set << 1) | sel_idx_bit
        rom_str = f"4'b{rom_val:04b}"

        if nTrs == 16:
            lines.append(f"            {rom_str}: rd_data <= {name}[row_idx][col_idx];")
        else:
            # nTrs=48: need 6-bit row address, but row_idx is only 4-bit
            # Actually rd_addr is 6-bit, so use rd_addr[5:0] directly
            lines.append(f"            {rom_str}: rd_data <= {name}[rd_addr][col_idx];")

    lines.append("            default:  rd_data <= 8'd0;")
    lines.append("        endcase")
    lines.append("    end")
    lines.append("")
    lines.append("endmodule")

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"\nGenerated: {OUT_PATH}")

    # Print ROM sel mapping summary
    print("\nROM sel mapping:")
    for nTrs, sel_set, sel_idx in configs:
        nTrs_bit = 1 if nTrs == 48 else 0
        sel_idx_bit = 0 if sel_idx == 1 else 1
        rom_val = (nTrs_bit << 3) | (sel_set << 1) | sel_idx_bit
        print(f"  {rom_val:04b} ({rom_val}) -> nTrs={nTrs}, set={sel_set}, idx={sel_idx}")


if __name__ == "__main__":
    generate()
