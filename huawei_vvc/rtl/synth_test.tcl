# Vivado Synthesis - non-project mode
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

create_clock -period 2.0 -name clk [get_ports clk]

synth_design -top its_top -part xc7a200tsbg484-1

report_timing_summary -delay_type min_max -max_paths 10
report_utilization

report_timing_summary -file ${rtl_dir}/timing_report.rpt
report_utilization -file ${rtl_dir}/utilization_report.rpt

puts "=========================================="
puts "  SYNTHESIS COMPLETE"
puts "=========================================="
exit
