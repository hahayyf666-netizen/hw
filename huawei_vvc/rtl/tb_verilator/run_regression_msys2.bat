@echo off
REM Build and run regression test with MSYS2 environment
set PATH=D:\msys2\mingw64\bin;D:\msys2\usr\bin;%PATH%
set VERILATOR_ROOT=D:\msys2\mingw64\share\verilator
cd /d %~dp0

echo [BUILD] Compiling with Verilator...
D:\msys2\mingw64\bin\verilator_bin.exe --cc --exe --trace -Wno-fatal -Mdir obj_dir --top-module its_top ^
    ../top/its_top.v ../top/output_packer.v ^
    ../ctrl/config_decode.v ../ctrl/its_ctrl_fsm.v ../ctrl/addr_gen.v ^
    ../buffer/tu_buffer.v ../buffer/intermediate_buffer.v ^
    ../transform_1d/it_1d_core.v ../transform_1d/dct2_1d.v ../transform_1d/dst7_1d.v ../transform_1d/dct8_1d.v ^
    ../transform_1d/mac_array.v ^
    ../lfnst/lfnst_core.v ../lfnst/lfnst_scan.v ../lfnst/lfnst_writeback.v ../lfnst/lfnst_config.v ^
    ../mem/trans_matrix_rom.v ../mem/lfnst_matrix_rom.v ^
    ../common/clip.v ../common/round_shift.v ^
    sim_main_regression.cpp
if errorlevel 1 (
    echo [BUILD] FAILED!
    exit /b 1
)

echo [BUILD] Linking...
mingw32-make -C obj_dir -f Vits_top.mk -j 1
if errorlevel 1 (
    echo [BUILD] Link FAILED!
    exit /b 1
)

echo [RUN] Running regression...
obj_dir\Vits_top.exe
