// TestIntNetsPar.bsv
// Drives mkIntNetsPar with two INDEPENDENT arithmetic chains, one per bank:
//   Bank A:  (5 + 3) * 2  = 16
//   Bank B:  (10 + 20) * 3 = 90
// Both chains use the same slot layout (the gen.py chain2 layout). Because
// the banks are disjoint, the two lanes reduce in lockstep: watch the
// trace — LANE A and LANE B fire on the SAME cycle number.

package TestIntNetsPar;

import IvyTypes::*;
import IntNetsPar::*;

(* synthesize *)
module mkTestIntNetsPar(Empty);

    IntNetsPar_IFC dut <- mkIntNetsPar();
    Reg#(Bit#(6)) i <- mkReg(0);

    // op1 fn/ext/res, op2 fn/ext/res shared structure across both banks
    function Node fn1();  return Node { tag: TAG_FN, val: 0,
        port0: PortRef{node:3,port:pPRINCIPAL()},
        port1: PortRef{node:4,port:pPRINCIPAL()},
        port2: PortRef{node:5,port:pPRINCIPAL()},
        port3: PortRef{node:2,port:pPRINCIPAL()}, valid: True }; endfunction
    function Node ext1(); return Node { tag: TAG_EXT, val: zeroExtend(pack(EXT_ADD)),
        port0: PortRef{node:1,port:pPRINCIPAL()},
        port1: PortRef{node:4,port:pAUX0()},
        port2: PortRef{node:5,port:pAUX1()},
        port3: nullRef(), valid: True }; endfunction
    function Node res1(); return Node { tag: TAG_INVALID, val: 0,
        port0: PortRef{node:9,port:pPRINCIPAL()},  // wires to op2 operand a (slot9)
        port1: nullRef(), port2: nullRef(), port3: nullRef(), valid: False }; endfunction
    function Node fn2();  return Node { tag: TAG_FN, val: 0,
        port0: PortRef{node:8,port:pPRINCIPAL()},
        port1: PortRef{node:9,port:pPRINCIPAL()},
        port2: PortRef{node:10,port:pPRINCIPAL()},
        port3: PortRef{node:7,port:pPRINCIPAL()}, valid: True }; endfunction
    function Node ext2(); return Node { tag: TAG_EXT, val: zeroExtend(pack(EXT_MUL)),
        port0: PortRef{node:6,port:pPRINCIPAL()},
        port1: PortRef{node:9,port:pAUX0()},
        port2: PortRef{node:10,port:pAUX1()},
        port3: nullRef(), valid: True }; endfunction
    function Node res2(); return Node { tag: TAG_INVALID, val: 0,
        port0: nullRef(),  // final result lives here
        port1: nullRef(), port2: nullRef(), port3: nullRef(), valid: False }; endfunction
    // Literal operand. Its port0 back-ref is not consulted by the parallel
    // core (the reducer reads the value directly), so nullRef is fine.
    function Node lit(Bit#(32) v); return Node { tag: TAG_N32, val: v,
        port0: nullRef(),
        port1: nullRef(), port2: nullRef(), port3: nullRef(), valid: True }; endfunction
    function Node opWire(); return Node { tag: TAG_INVALID, val: 0,
        port0: PortRef{node:6,port:pAUX0()},  // op2 operand a, filled by op1
        port1: nullRef(), port2: nullRef(), port3: nullRef(), valid: False }; endfunction

    rule rl_load (i < 12);
        case (i)
            0: begin dut.loadA(0, invalidNode());        dut.loadB(0, invalidNode());        end
            1: begin dut.loadA(1, fn1());                dut.loadB(1, fn1());                end
            2: begin dut.loadA(2, ext1());               dut.loadB(2, ext1());               end
            3: begin dut.loadA(3, res1());               dut.loadB(3, res1());               end
            // operand a of op1
            4: begin dut.loadA(4, lit(5));     dut.loadB(4, lit(10));     end
            // operand b of op1
            5: begin dut.loadA(5, lit(3));     dut.loadB(5, lit(20));     end
            6: begin dut.loadA(6, fn2());                dut.loadB(6, fn2());                end
            7: begin dut.loadA(7, ext2());               dut.loadB(7, ext2());               end
            8: begin dut.loadA(8, res2());               dut.loadB(8, res2());               end
            9: begin dut.loadA(9, opWire());             dut.loadB(9, opWire());             end
            // operand b of op2 (the multiplier)
            10: begin dut.loadA(10, lit(2));    dut.loadB(10, lit(3));     end
            11: begin dut.start(); $display("PAR start"); end
        endcase
        i <= i + 1;
    endrule

    Reg#(Bit#(2)) phase <- mkReg(0);
    Reg#(Node) ra <- mkReg(invalidNode());

    rule rl_r0 (dut.done() && phase == 0);
        ra <= dut.readA(8);
        phase <= 1;
    endrule
    rule rl_r1 (dut.done() && phase == 1);
        let rb = dut.readB(8);
        $display("PAR result A slot8 = %0d (expect 16)", ra.val);
        $display("PAR result B slot8 = %0d (expect 90)", rb.val);
        if (ra.tag == TAG_N32 && ra.val == 16 && rb.tag == TAG_N32 && rb.val == 90)
            $display("PAR PASS  total interactions %0d", dut.interactions());
        else
            $display("PAR FAIL");
        $finish();
    endrule

endmodule

endpackage
