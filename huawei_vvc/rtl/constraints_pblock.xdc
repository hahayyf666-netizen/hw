# Clock constraint: 2ns period (500MHz target)
create_clock -period 2.0 -name clk [get_ports clk]

# Pblock: force lfnst_core and tu_pre_buffer into same region for routing
create_pblock pblock_its_buf
add_cells_to_pblock [get_pblocks pblock_its_buf] [get_cells {u_lfnst_core u_tu_pre_buffer}]
resize_pblock [get_pblocks pblock_its_buf] -add {SLICE_X0Y0:SLICE_X80Y80}
