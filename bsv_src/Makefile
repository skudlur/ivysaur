# Makefile for IntNets BSV simulation
# Usage:
#   make        — compile and run
#   make sim    — same as make
#   make build  — compile only
#   make clean  — remove generated files

BSC       = bsc
TOP       = mkTestIntNets
SIM_OUT   = sim_out
BSC_FLAGS = -u -sim

.PHONY: all sim build clean

all: sim

sim: build
	$(BSC) -sim -e $(TOP) -o $(SIM_OUT)
	./$(SIM_OUT)

build:
	$(BSC) $(BSC_FLAGS) -g $(TOP) TestIntNets.bsv

clean:
	rm -f *.ba *.bo *.o *.h *.so $(SIM_OUT)
