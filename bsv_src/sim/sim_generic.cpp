// sim_generic.cpp
// Generic Verilator harness. The top module is selected at compile time:
//   -DTOP_HEADER='"VmkFoo.h"' -DTOP_TYPE=VmkFoo
// Drives clock and reset, runs until $finish or MAX_CYCLES.

#define STR2(x) #x
#define STR(x) STR2(x)
#include STR(TOP_HEADER)
#include "verilated.h"
#include <iostream>

static const int MAX_CYCLES = 2000;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    TOP_TYPE* top = new TOP_TYPE;

    top->CLK   = 0;
    top->RST_N = 0;
    for (int i = 0; i < 10; i++) {
        top->CLK = !top->CLK;
        top->eval();
    }
    top->RST_N = 1;

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
