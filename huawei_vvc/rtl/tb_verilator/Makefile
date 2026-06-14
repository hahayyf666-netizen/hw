# Verilator Makefile
#
# Use the MSYS2 MinGW Verilator binary directly. The Perl wrapper named
# "verilator" is fragile in this Windows setup because it can infer mixed
# Windows/MSYS include paths.
#
# Usage:
#   make run              # default: DEBUG=1, debug ports enabled
#   make run DEBUG=0      # delivery build: no debug ports
#   make proto_run        # protocol test with debug
#   make proto_run DEBUG=0
#   make lint DEBUG=0     # quick syntax check for delivery

TOP = its_top
MSYS2_ROOT ?= /mingw64
VERILATOR_ROOT ?= $(MSYS2_ROOT)/share/verilator
VERILATOR ?= $(MSYS2_ROOT)/bin/verilator_bin.exe
MAKE ?= mingw32-make

# Debug switch: 1=enable ITS_DEBUG macro (default), 0=strip debug ports
DEBUG ?= 1

DEFINES =
ifeq ($(DEBUG),1)
DEFINES += -DITS_DEBUG
endif

export VERILATOR_ROOT
export MAKE
# Ensure MSYS /usr/bin/python3 is preferred over /mingw64/bin/python3
# to avoid DLL issues during verilator_includer step
export PATH := /usr/bin:/mingw64/bin:$(PATH)

RTL_FILES = \
    ../top/its_top.v \
    ../top/output_packer.v \
    ../ctrl/config_decode.v \
    ../ctrl/its_ctrl_fsm.v \
    ../ctrl/addr_gen.v \
    ../buffer/tu_buffer.v \
    ../buffer/intermediate_buffer.v \
    ../transform_1d/it_1d_core.v \
    ../transform_1d/dct2_1d.v \
    ../transform_1d/dst7_1d.v \
    ../transform_1d/dct8_1d.v \
    ../transform_1d/mac_array.v \
    ../lfnst/lfnst_core.v \
    ../lfnst/lfnst_scan.v \
    ../lfnst/lfnst_writeback.v \
    ../lfnst/lfnst_config.v \
    ../mem/trans_matrix_rom.v \
    ../mem/lfnst_matrix_rom.v \
    ../common/clip.v \
    ../common/round_shift.v

VERILATOR_FLAGS = \
    --cc \
    --exe \
    --build \
    --trace \
    -Wno-fatal \
    $(DEFINES) \
    --top-module $(TOP)

.PHONY: all clean run bp bp_run proto proto_run lint

all: obj_dir/V$(TOP)

obj_dir/V$(TOP): sim_main_regression.cpp $(RTL_FILES)
	$(VERILATOR) $(VERILATOR_FLAGS) -Mdir obj_dir $(RTL_FILES) sim_main_regression.cpp

run: obj_dir/V$(TOP)
	@if [ -x ./obj_dir/V$(TOP).exe ]; then ./obj_dir/V$(TOP).exe; else ./obj_dir/V$(TOP); fi

# Backpressure test target
bp: obj_dir_bp/V$(TOP)

obj_dir_bp/V$(TOP): sim_main_backpressure.cpp $(RTL_FILES)
	$(VERILATOR) $(VERILATOR_FLAGS) -Mdir obj_dir_bp $(RTL_FILES) sim_main_backpressure.cpp

bp_run: bp
	@if [ -x ./obj_dir_bp/V$(TOP).exe ]; then ./obj_dir_bp/V$(TOP).exe; else ./obj_dir_bp/V$(TOP); fi

# Input protocol test target
proto: obj_dir_proto/V$(TOP)

obj_dir_proto/V$(TOP): sim_main_input_protocol.cpp $(RTL_FILES)
	$(VERILATOR) $(VERILATOR_FLAGS) -Mdir obj_dir_proto $(RTL_FILES) sim_main_input_protocol.cpp

proto_run: proto
	@if [ -x ./obj_dir_proto/V$(TOP).exe ]; then ./obj_dir_proto/V$(TOP).exe; else ./obj_dir_proto/V$(TOP); fi

# Lint check (syntax only, no exe needed) - use with DEBUG=0 before delivery
lint:
	$(VERILATOR) --lint-only -Wno-fatal $(DEFINES) --top-module $(TOP) $(RTL_FILES)

clean:
	rm -rf obj_dir obj_dir_bp obj_dir_proto waveform.vcd backpressure.vcd input_protocol.vcd
