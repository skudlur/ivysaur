# Makefile for IntNets — BSC compile to Verilog, simulate with Verilator
#
# Usage:
#   make        — compile BSV to Verilog, build Verilator sim, run
#   make bsv    — compile BSV to Verilog only
#   make vsim   — build and run Verilator simulation
#   make clean  — remove all generated files

BSC        = bsc
TOP        = mkTestIntNets
VDIR       = verilog_out
SIM_OUT    = sim_out
BSC_FLAGS  = -verilog -u -g $(TOP)

# Verilator flags
VL         = verilator
VL_FLAGS   = --cc --exe --build --timing \
             --Wno-UNUSED --Wno-UNDRIVEN --Wno-PINMISSING \
             --Wno-PINCONNECTEMPTY --Wno-SYNCASYNCNET \
             -I$(VDIR)

.PHONY: all bsv vsim clean

all: vsim

# Step 1: compile BSV -> Verilog
bsv:
	mkdir -p $(VDIR)
	$(BSC) $(BSC_FLAGS) TestIntNets.bsv
	mv *.v $(VDIR)/ 2>/dev/null || true

# Step 2: build Verilator sim and run
vsim: bsv
	$(VL) $(VL_FLAGS) \
	    -o ../$(SIM_OUT) \
	    $(VDIR)/$(TOP).v \
	    sim/sim_main.cpp
	./$(SIM_OUT)

clean:
	rm -f *.ba *.bo *.v *.h *.o *.so *.cxx $(SIM_OUT)
	rm -rf $(VDIR) obj_dir
