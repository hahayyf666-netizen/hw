# Clock constraint: 2ns period (500MHz target)
create_clock -period 2.0 -name clk [get_ports clk]

# Input delay (placeholder - adjust based on actual interface)
# set_input_delay -clock clk -max 0.5 [get_ports {it_data_in_* cfg_*}]
# set_input_delay -clock clk -min 0.1 [get_ports {it_data_in_* cfg_*}]

# Output delay (placeholder - adjust based on actual interface)
# set_output_delay -clock clk -max 0.5 [get_ports {it_data_out_* it_done}]
# set_output_delay -clock clk -min 0.1 [get_ports {it_data_out_* it_done}]
