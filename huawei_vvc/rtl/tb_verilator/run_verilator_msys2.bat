@echo off
setlocal

set "MSYS2_ROOT=D:\msys2"
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR_POSIX=%SCRIPT_DIR:\=/%"
set "SCRIPT_DIR_POSIX=%SCRIPT_DIR_POSIX:D:=/d%"

if not exist "%MSYS2_ROOT%\usr\bin\bash.exe" (
  echo ERROR: MSYS2 bash not found: %MSYS2_ROOT%\usr\bin\bash.exe
  exit /b 1
)

"%MSYS2_ROOT%\usr\bin\bash.exe" -lc "cd '%SCRIPT_DIR_POSIX%' && ./run.sh"
if errorlevel 1 exit /b %errorlevel%

endlocal
