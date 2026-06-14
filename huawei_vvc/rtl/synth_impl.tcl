# Vivado Synthesis + Implementation (high effort)
# Clock constraint BEFORE synth_design for clean optimization start
set rtl_dir "D:/HW_WORK/huawei_vvc/rtl"

read_verilog -sv ${rtl_dir}/top/its_top.v
read_verilog -sv ${rtl_dir}/top/output_packer.v
read_verilog -sv ${rtl_dir}/ctrl/config_decode.v
read_verilog -sv ${rtl_dir}/ctrl/its_ctrl_fsm.v
read_verilog -sv ${rtl_dir}/ctrl/addr_gen.v
read_verilog -sv ${rtl_dir}/buffer/tu_buffer.v
read_verilog -sv ${rtl_dir}/buffer/intermediate_buffer.v
read_verilog -sv ${rtl_dir}/transform_1d/it_1d_core.v
read_verilog -sv ${rtl_dir}/transform_1d/dct2_1d.v
read_verilog -sv ${rtl_dir}/transform_1d/dst7_1d.v
read_verilog -sv ${rtl_dir}/transform_1d/dct8_1d.v
read_verilog -sv ${rtl_dir}/lfnst/lfnst_core.v
read_verilog -sv ${rtl_dir}/lfnst/lfnst_scan.v
read_verilog -sv ${rtl_dir}/lfnst/lfnst_writeback.v
read_verilog -sv ${rtl_dir}/lfnst/lfnst_config.v
read_verilog -sv ${rtl_dir}/mem/trans_matrix_rom.v
read_verilog -sv ${rtl_dir}/mem/lfnst_matrix_rom.v
read_verilog -sv ${rtl_dir}/common/clip.v
read_verilog -sv ${rtl_dir}/common/round_shift.v

synth_design -top its_top -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt

# Clock constraint AFTER synth_design (non-project mode requires open design)
create_clock -period 2.0 -name clk [get_ports clk]

# Global retiming after clock is defined
phys_opt_design -retiming

# High-effort optimization
opt_design -directive ExploreArea
place_design -directive Explore

# Physical optimization: multiple aggressive passes
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive AggressiveFanoutOpt
phys_opt_design -directive AlternateFlowWithRetiming
phys_opt_design -directive AggressiveExplore

route_design -directive Explore

# === Reports ===
report_timing_summary -delay_type min_max -max_paths 10
report_utilization

# Detailed reports
report_timing -max_paths 50 -sort_by group -file ${rtl_dir}/critical_paths.rpt
report_drc -file ${rtl_dir}/drc_impl.rpt
report_methodology -file ${rtl_dir}/methodology_impl.rpt
report_power -file ${rtl_dir}/power_impl.rpt
report_control_sets -file ${rtl_dir}/control_sets.rpt
report_utilization -hierarchical -file ${rtl_dir}/utilization_hier_impl.rpt

# Summary reports
report_timing_summary -file ${rtl_dir}/timing_impl_report.rpt
report_utilization -file ${rtl_dir}/utilization_impl_report.rpt

puts "=========================================="
puts "  IMPLEMENTATION COMPLETE"
puts "=========================================="
exit
