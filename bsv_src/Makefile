# Makefile for the Ivy interaction-net reduction cores.
# BSC compiles BSV to Verilog; Verilator builds and runs the simulation.
#
# Usage:
#   make            — build + run the sequential core (TestIntNets, chain3)
#   make par        — build + run the parallel core (two concurrent chains)
#   make gen FILE=../vine/chain2.ir
#                   — regenerate TestIntNets.bsv from an Ivy IR file
#   make clean      — remove all generated files

BSC        = bsc
VDIR       = verilog_out

TOP        = mkTestIntNets
SIM_OUT    = sim_out

PAR_TOP    = mkTestIntNetsPar
PAR_OUT    = par_sim

BSC_FLAGS  = -verilog -u -g
RTS        = +RTS -K64M -RTS

VL         = verilator
VL_FLAGS   = --cc --exe --build --timing \
             --Wno-UNUSED --Wno-UNDRIVEN --Wno-PINMISSING \
             --Wno-PINCONNECTEMPTY --Wno-SYNCASYNCNET \
             -I$(VDIR)

.PHONY: all bsv vsim par gen clean

all: vsim

# --- sequential core ---------------------------------------------------------
bsv:
	mkdir -p $(VDIR)
	$(BSC) $(BSC_FLAGS) $(TOP) $(RTS) TestIntNets.bsv
	mv *.v $(VDIR)/ 2>/dev/null || true

vsim: bsv
	$(VL) $(VL_FLAGS) -o ../$(SIM_OUT) $(VDIR)/$(TOP).v sim/sim_main.cpp
	./$(SIM_OUT)

# --- parallel core -----------------------------------------------------------
par:
	mkdir -p $(VDIR)
	$(BSC) $(BSC_FLAGS) $(PAR_TOP) $(RTS) TestIntNetsPar.bsv
	mv *.v $(VDIR)/ 2>/dev/null || true
	$(VL) $(VL_FLAGS) \
	    -CFLAGS "-DTOP_HEADER=V$(PAR_TOP).h -DTOP_TYPE=V$(PAR_TOP)" \
	    -o ../$(PAR_OUT) $(VDIR)/$(PAR_TOP).v sim/sim_generic.cpp
	./$(PAR_OUT)

# --- regenerate the sequential testbench from an Ivy IR file -----------------
# e.g. make gen FILE=../vine/dup_add.ir
FILE ?= ../vine/chain3.ir
gen:
	python3 ../vine/gen.py $(FILE) > TestIntNets.bsv
	@echo "Wrote TestIntNets.bsv from $(FILE)"

clean:
	rm -f *.ba *.bo *.v *.h *.o *.so *.cxx *.sched *.dot $(SIM_OUT) $(PAR_OUT)
	rm -rf $(VDIR) obj_dir
