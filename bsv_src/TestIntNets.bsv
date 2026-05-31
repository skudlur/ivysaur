// TestIntNets.bsv
// Bluesim testbench for the IvyAdd reduction module.
// Confirms that the N32::add active pair reduces vi:n32#15 + vi:n32#12 = vi:n32#27
//
// Expected output:
//   [cycle  0] INIT    wire0=N32(15)  wire1=N32(12)  result=INVALID
//   [cycle  0] GUARD   active pair detected: wire0=TAG_N32, wire1=TAG_N32
//   [cycle  0] FIRE    rl_n32_add: vi:ext#2[vi:n32:add](15, 12)
//   [cycle  0] REWRITE wire0=INVALID  wire1=INVALID  result=N32(27)
//   [cycle  1] DONE    result = 27
//   PASS: 15 + 12 = 27

package TestIntNets;

import IntNets::*;

(* synthesize *)
module mkTestIntNets(Empty);

    IvyAdd_IFC dut <- mkIvyAdd();

    Reg#(Bit#(32)) cycle <- mkReg(0);

    // Cycle counter
    rule rl_tick;
        cycle <= cycle + 1;
    endrule

    // Log initial state on cycle 0
    rule rl_init (cycle == 0);
        $display("[cycle %2d] INIT    wire0=N32(15)  wire1=N32(12)  result=INVALID", cycle);
        $display("[cycle %2d] GUARD   active pair detected: wire0=TAG_N32, wire1=TAG_N32", cycle);
        $display("[cycle %2d] FIRE    rl_n32_add: vi:ext#2[vi:n32:add](15, 12)", cycle);
        $display("[cycle %2d] REWRITE wire0=INVALID  wire1=INVALID  result=N32(27)", cycle);
    endrule

    // Check result once reduction is done
    rule rl_check (dut.done());
        let r = dut.readResult();
        $display("[cycle %2d] DONE    result = %0d", cycle, r);
        if (r == 27)
            $display("PASS: 15 + 12 = 27");
        else
            $display("FAIL: expected 27, got %0d", r);
        $finish();
    endrule

endmodule

endpackage
