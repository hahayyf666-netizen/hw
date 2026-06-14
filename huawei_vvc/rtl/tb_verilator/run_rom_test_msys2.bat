@echo off
REM Run trans_matrix_rom unit test with MSYS2 environment
set PATH=D:\msys2\mingw64\bin;D:\msys2\usr\bin;%PATH%
cd /d %~dp0
rom_test.exe
