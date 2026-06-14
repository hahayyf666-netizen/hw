#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export PATH="/mingw64/bin:/usr/bin:${PATH}"
export VERILATOR_ROOT="/mingw64/share/verilator"
export MAKE="mingw32-make"

RTL_FILES=(
  ../top/its_top.v
  ../top/output_packer.v
  ../ctrl/config_decode.v
  ../ctrl/its_ctrl_fsm.v
  ../ctrl/addr_gen.v
  ../buffer/tu_buffer.v
  ../buffer/intermediate_buffer.v
  ../transform_1d/it_1d_core.v
  ../transform_1d/dct2_1d.v
  ../transform_1d/dst7_1d.v
  ../transform_1d/dct8_1d.v
  ../transform_1d/mac_array.v
  ../lfnst/lfnst_core.v
  ../lfnst/lfnst_scan.v
  ../lfnst/lfnst_writeback.v
  ../lfnst/lfnst_config.v
  ../mem/trans_matrix_rom.v
  ../mem/lfnst_matrix_rom.v
  ../common/clip.v
  ../common/round_shift.v
)

echo "=== Cleaning old Verilator output ==="
rm -rf obj_dir waveform.vcd

echo "=== Verilator: generate and build C++ model ==="
/mingw64/bin/verilator_bin.exe \
  --cc \
  --exe \
  --build \
  --trace \
  -Wno-fatal \
  -Mdir obj_dir \
  --top-module its_top \
  "${RTL_FILES[@]}" \
  sim_main.cpp

echo "=== Running simulation ==="
if [[ -x ./obj_dir/Vits_top.exe ]]; then
  ./obj_dir/Vits_top.exe
else
  ./obj_dir/Vits_top
fi
