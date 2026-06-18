// sim_main.cpp
// Verilator simulation harness for mkTestIntNets.
// Drives clock and reset, runs until $finish is called from BSV.

#include "VmkTestIntNets.h"
#include "verilated.h"
#include <iostream>

static const int MAX_CYCLES = 500;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    VmkTestIntNets* top = new VmkTestIntNets;

    // Reset for 5 cycles
    top->CLK   = 0;
    top->RST_N = 0;
    for (int i = 0; i < 10; i++) {
        top->CLK = !top->CLK;
        top->eval();
    }
    top->RST_N = 1;

    // Run until $finish or MAX_CYCLES
    int cycle = 0;
    while (!Verilated::gotFinish() && cycle < MAX_CYCLES) {
        top->CLK = 0; top->eval();
        top->CLK = 1; top->eval();
        cycle++;
    }

    if (cycle >= MAX_CYCLES)
        std::cerr << "TIMEOUT after " << MAX_CYCLES << " cycles" << std::endl;

    top->final();
    delete top;
    return 0;
}
