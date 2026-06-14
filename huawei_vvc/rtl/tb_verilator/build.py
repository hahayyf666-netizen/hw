import subprocess, os, glob

os.chdir(r"D:\HW_WORK\huawei_vvc\rtl\tb_verilator")

MSVC = r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207"
cl = MSVC + r"\bin\Hostx64\x64\cl.exe"
link = MSVC + r"\bin\Hostx64\x64\link.exe"

env = os.environ.copy()
env["PATH"] = MSVC + r"\bin\Hostx64\x64;" + env.get("PATH", "")
sdk = sorted(glob.glob(r"C:\Program Files (x86)\Windows Kits\10\Include\10.0.*"))[-1]
slib = sorted(glob.glob(r"C:\Program Files (x86)\Windows Kits\10\Lib\10.0.*"))[-1]
env["INCLUDE"] = MSVC + r"\include;" + sdk + r"\ucrt;" + sdk + r"\um;" + sdk + r"\shared"
env["LIB"] = MSVC + r"\lib\x64;" + slib + r"\ucrt\x64;" + slib + r"\um\x64"
env["LIBPATH"] = MSVC + r"\lib\x64"

# Use forward slashes to avoid \v escape issues
VR = "D:/msys2/mingw64/share/verilator"
OD = "obj_dir"

cpp_files = [
    f"{OD}/verilated.cpp",
    f"{OD}/verilated_vcd_c.cpp",
    f"{OD}/verilated_threads.cpp",
    f"{OD}/Vits_top.cpp",
    f"{OD}/Vits_top___024root__0.cpp",
    f"{OD}/Vits_top_trans_matrix_rom__0.cpp",
    f"{OD}/Vits_top__ConstPool__0__Slow.cpp",
    f"{OD}/Vits_top___024root__Slow.cpp",
    f"{OD}/Vits_top___024root__0__Slow.cpp",
    f"{OD}/Vits_top_trans_matrix_rom__Slow.cpp",
    f"{OD}/Vits_top_trans_matrix_rom__0__Slow.cpp",
    f"{OD}/Vits_top__Trace__0.cpp",
    f"{OD}/Vits_top__Syms__Slow.cpp",
    f"{OD}/Vits_top__Trace__0__Slow.cpp",
    f"{OD}/Vits_top__TraceDecls__0__Slow.cpp",
    "sim_main.cpp",
]

obj_files = []
for cpp in cpp_files:
    basename = os.path.splitext(os.path.basename(cpp))[0]
    obj = f"{OD}/{basename}.obj"
    obj_files.append(obj)
    cmd = [cl, "/nologo", "/O2", "/std:c++17", "/EHsc", "/w",
           f"/I{VR}/include", f"/I{OD}",
           "/DWIN32", "/D_CRT_SECURE_NO_WARNINGS", "/DVL_THREADED=0",
           "/c", cpp, f"/Fo{obj}"]
    print(f"Compiling {os.path.basename(cpp)}...")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60, env=env)
    if r.returncode != 0:
        print(f"  FAILED: rc={r.returncode}")
        print(f"  out: {r.stdout[:300]}")
        print(f"  err: {r.stderr[:500]}")
        exit(1)
    print(f"  OK")

print("Linking...")
link_cmd = [link, "/nologo", "/OUT:Vits_top.exe"] + obj_files
r = subprocess.run(link_cmd, capture_output=True, text=True, timeout=60, env=env)
if r.returncode != 0:
    print(f"Link FAILED: rc={r.returncode}")
    print(f"  out: {r.stdout[:500]}")
    print(f"  err: {r.stderr[:500]}")
    exit(1)
print("Link OK!")

print("\n=== Running simulation ===\n")
r = subprocess.run(["Vits_top.exe"], capture_output=True, text=True, timeout=60)
print(r.stdout)
if r.stderr:
    print("STDERR:", r.stderr[-1000:])
print(f"Return code: {r.returncode}")
