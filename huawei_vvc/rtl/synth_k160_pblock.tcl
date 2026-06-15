# Vivado Synthesis - xc7k160tfbg484-3 with Pblock constraint
set rtl_dir "D:/HW_WORK/huawei_vvc/rtl"

read_xdc ${rtl_dir}/constraints_pblock.xdc

read_verilog -sv ${rtl_dir}/top/its_top.v
read_verilog -sv ${rtl_dir}/top/output_packer.v
read_verilog -sv ${rtl_dir}/ctrl/config_decode.v
read_verilog -sv ${rtl_dir}/ctrl/its_ctrl_fsm.v
read_verilog -sv ${rtl_dir}/ctrl/addr_gen.v
read_verilog -sv ${rtl_dir}/buffer/tu_buffer.v
read_verilog -sv ${rtl_dir}/buffer/tu_buffer_bank.v
read_verilog -sv ${rtl_dir}/buffer/tu_buffer_regbank.v
read_verilog -sv ${rtl_dir}/buffer/tu_pre_buffer.v
read_verilog -sv ${rtl_dir}/buffer/tu_post_buffer.v
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

synth_design -top its_top -part xc7k160tfbg484-3 -flatten_hierarchy rebuilt
opt_design -directive ExploreArea
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive AggressiveFanoutOpt
route_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore

report_timing_summary -delay_type min_max -max_paths 10
report_utilization
report_timing -max_paths 50 -sort_by group -file ${rtl_dir}/critical_paths_k160_pblock.rpt
report_timing_summary -file ${rtl_dir}/timing_k160_pblock.rpt
report_utilization -file ${rtl_dir}/utilization_k160_pblock.rpt

puts "=========================================="
puts "  K160-3 PBLOCK SYNTHESIS COMPLETE"
puts "=========================================="
exit
