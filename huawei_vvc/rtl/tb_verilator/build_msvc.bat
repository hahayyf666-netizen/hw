@echo off
cd /d "D:\成员C第1周\huawei_vvc\rtl\tb_verilator"
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64
cd /d "D:\成员C第1周\huawei_vvc\rtl\tb_verilator"

set VR=C:\verilator_tmp
set OD=obj_dir

echo === Compiling ===
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\verilated.cpp" /Fo"%OD%\verilated.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\verilated_vcd_c.cpp" /Fo"%OD%\verilated_vcd_c.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top.cpp" /Fo"%OD%\Vits_top.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top___024root__0.cpp" /Fo"%OD%\Vits_top___024root__0.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top_trans_matrix_rom__0.cpp" /Fo"%OD%\Vits_top_trans_matrix_rom__0.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top__ConstPool__0__Slow.cpp" /Fo"%OD%\Vits_top__ConstPool__0__Slow.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top___024root__Slow.cpp" /Fo"%OD%\Vits_top___024root__Slow.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top___024root__0__Slow.cpp" /Fo"%OD%\Vits_top___024root__0__Slow.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top_trans_matrix_rom__Slow.cpp" /Fo"%OD%\Vits_top_trans_matrix_rom__Slow.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top_trans_matrix_rom__0__Slow.cpp" /Fo"%OD%\Vits_top_trans_matrix_rom__0__Slow.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top__Trace__0.cpp" /Fo"%OD%\Vits_top__Trace__0.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top__Syms__Slow.cpp" /Fo"%OD%\Vits_top__Syms__Slow.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top__Trace__0__Slow.cpp" /Fo"%OD%\Vits_top__Trace__0__Slow.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c "%OD%\Vits_top__TraceDecls__0__Slow.cpp" /Fo"%OD%\Vits_top__TraceDecls__0__Slow.obj"
cl /nologo /O2 /std:c++17 /EHsc /w /I"%VR%\include" /I"%OD%" /DWIN32 /D_CRT_SECURE_NO_WARNINGS /DVL_THREADED=0 /c sim_main.cpp /Fo"%OD%\sim_main.obj"

echo === Linking ===
link /nologo /OUT:Vits_top.exe "%OD%\verilated.obj" "%OD%\verilated_vcd_c.obj" "%OD%\Vits_top.obj" "%OD%\Vits_top___024root__0.obj" "%OD%\Vits_top_trans_matrix_rom__0.obj" "%OD%\Vits_top__ConstPool__0__Slow.obj" "%OD%\Vits_top___024root__Slow.obj" "%OD%\Vits_top___024root__0__Slow.obj" "%OD%\Vits_top_trans_matrix_rom__Slow.obj" "%OD%\Vits_top_trans_matrix_rom__0__Slow.obj" "%OD%\Vits_top__Trace__0.obj" "%OD%\Vits_top__Syms__Slow.obj" "%OD%\Vits_top__Trace__0__Slow.obj" "%OD%\Vits_top__TraceDecls__0__Slow.obj" "%OD%\sim_main.obj"

echo === Running ===
Vits_top.exe
