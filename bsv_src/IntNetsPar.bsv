// IntNetsPar.bsv
// Parallel interaction-net reduction core — a proof-of-concept that the
// Bluespec scheduler fires non-conflicting rewrite rules in the SAME cycle.
//
// Why this module exists
// ----------------------
// IntNets.bsv proves the rewrite *semantics* but runs a sequential FSM:
// one active pair at a time. The note.org claim is that interaction-net
// parallelism "falls out for free" because rules touching disjoint heap
// addresses don't conflict. This module demonstrates that claim concretely.
//
// The key hardware insight made explicit here:
//   A `Vector#(n, Reg#(Node))` indexed *dynamically* from two rules makes
//   bsc conservatively assume both rules might touch the same element, so
//   it serialises them — you get NO parallelism. To let the scheduler
//   prove independence, the heap must be split into separate banks, each
//   owned by one lane. This is exactly the memory-banking problem a real
//   parallel graph-reduction accelerator has to solve.
//
// So: two banks (heapA / heapB), two lane rules. Each lane reduces one
// arithmetic redex per cycle, single-cycle and atomic. Because the lanes
// write disjoint registers, bsc schedules rl_laneA and rl_laneB
// concurrently — both fire on the same clock edge (visible in the trace).
//
// Scope: this core handles the arithmetic-redex subset (fn+ext with the
// result forwarded along its result wire to the next op's operand). That
// is enough to run two independent arithmetic chains side by side and
// measure the concurrency. The full rule set (annihilation, commutation,
// erasure) still lives in IntNets.bsv.

package IntNetsPar;

import IvyTypes::*;
import Vector::*;

// A single-cycle reduction plan computed combinationally from a redex.
typedef struct {
    NodeId   f;       // fn node      (freed)
    NodeId   e;       // ext node     (freed)
    NodeId   a;       // operand a    (freed)
    NodeId   b;       // operand b    (freed)
    NodeId   r;       // result wire slot
    NodeId   target;  // where the result value is written
    Bool     clearR;  // forwarded? then the r slot is also freed
    Bit#(32) val;     // computed result
    PortRef  keep;    // port0 to preserve on the target slot
} Plan deriving (Bits);

interface IntNetsPar_IFC;
    method Action   loadA(NodeId id, Node n);
    method Action   loadB(NodeId id, Node n);
    method Action   start();
    method Bool     done();
    method Node     readA(NodeId id);
    method Node     readB(NodeId id);
    method Bit#(32) interactions();
endinterface

(* synthesize *)
module mkIntNetsPar(IntNetsPar_IFC);

    // Each bank is ONE register holding the whole node vector. A lane reads
    // it, computes the next vector functionally, and writes it back in a
    // single register write — so a lane's whole rewrite commits in one
    // cycle, and the two banks are provably independent registers.
    Reg#(Vector#(HEAP_SIZE, Node)) heapA <- mkReg(replicate(invalidNode()));
    Reg#(Vector#(HEAP_SIZE, Node)) heapB <- mkReg(replicate(invalidNode()));

    Reg#(Bool)     running  <- mkReg(False);
    Reg#(Bool)     finished <- mkReg(False);
    Reg#(Bit#(32)) cycle    <- mkReg(0);
    Reg#(Bit#(32)) interA   <- mkReg(0);
    Reg#(Bit#(32)) interB   <- mkReg(0);


    // Find the lowest-numbered arithmetic redex that is ready to fire:
    // a valid fn whose two operands are N32 literals and whose partner
    // is an ext node. Slot 0 is the reserved null node, so scanning from 1.
    function Maybe#(NodeId) findRedex(Vector#(HEAP_SIZE, Node) h);
        Maybe#(NodeId) res = tagged Invalid;
        for (Integer i = 1; i < valueOf(HEAP_SIZE); i = i + 1) begin
            let fn = h[i];
            Node na = h[fn.port1.node];
            Node nb = h[fn.port2.node];
            Node ne = h[fn.port3.node];
            Bool ready = fn.valid && fn.tag == TAG_FN
                      && na.valid && na.tag == TAG_N32
                      && nb.valid && nb.tag == TAG_N32
                      && ne.valid && ne.tag == TAG_EXT;
            if (!isValid(res) && ready)
                res = tagged Valid fromInteger(i);
        end
        return res;
    endfunction

    // Compute the reduction plan for the redex at fn slot f.
    function Plan mkPlan(Vector#(HEAP_SIZE, Node) h, NodeId f);
        let fn = h[f];
        NodeId e = fn.port3.node;
        NodeId a = fn.port1.node;
        NodeId b = fn.port2.node;
        NodeId r = fn.port0.node;
        Bit#(32) av = h[a].val;
        Bit#(32) bv = h[b].val;
        ExtOp op = unpack(truncate(h[e].val));
        Bit#(32) v = case (op)
            EXT_ADD: av + bv;
            EXT_SUB: av - bv;
            EXT_MUL: av * bv;
            EXT_DIV: av / bv;
            EXT_REM: av % bv;
            default: 0;
        endcase;
        // The result wire r points at the next op's operand slot (or at
        // null for the final op). Forward the value straight into that
        // operand so the downstream op becomes ready next cycle.
        NodeId d   = h[r].port0.node;
        Bool   fwd = (d != 0);
        NodeId tgt = fwd ? d : r;
        PortRef kp = fwd ? h[d].port0 : h[r].port0;
        return Plan { f: f, e: e, a: a, b: b, r: r,
                      target: tgt, clearR: fwd, val: v, keep: kp };
    endfunction

    // Apply a plan: return the next bank vector with the result written and
    // the consumed nodes freed. Pure functional update over the snapshot.
    function Vector#(HEAP_SIZE, Node) applyPlan(Vector#(HEAP_SIZE, Node) h, Plan p);
        h[p.target] = mkN32Node(p.val, p.keep);
        if (p.clearR) h[p.r] = invalidNode();
        h[p.f] = invalidNode();
        h[p.e] = invalidNode();
        h[p.a] = invalidNode();
        h[p.b] = invalidNode();
        return h;
    endfunction

    rule rl_tick;
        cycle <= cycle + 1;
    endrule

    // Lane A — owns heapA only.
    // Lanes self-gate on the presence of a redex in their own bank, and do
    // NOT read anything rl_finish writes. That keeps the schedule acyclic:
    // rl_finish reads the heaps (so it is ordered before the lanes), and
    // nothing orders the lanes before rl_finish.
    rule rl_laneA (running && isValid(findRedex(heapA)));
        let h = heapA;
        let f = fromMaybe(0, findRedex(h));
        let p = mkPlan(h, f);
        heapA <= applyPlan(h, p);
        interA <= interA + 1;
        $display("[cycle %0d] LANE A reduce fn %0d -> %0d (slot %0d)",
                 cycle, f, p.val, p.target);
    endrule

    // Lane B — owns heapB only. Disjoint register from lane A, so bsc
    // schedules this rule concurrently with rl_laneA.
    rule rl_laneB (running && isValid(findRedex(heapB)));
        let h = heapB;
        let f = fromMaybe(0, findRedex(h));
        let p = mkPlan(h, f);
        heapB <= applyPlan(h, p);
        interB <= interB + 1;
        $display("[cycle %0d] LANE B reduce fn %0d -> %0d (slot %0d)",
                 cycle, f, p.val, p.target);
    endrule

    // Finished when neither bank has a remaining redex (and we have started).
    rule rl_finish (running && !finished && (interA + interB) > 0
                    && !isValid(findRedex(heapA))
                    && !isValid(findRedex(heapB)));
        finished <= True;
        $display("[cycle %0d] PAR DONE total interactions %0d",
                 cycle, interA + interB);
    endrule

    method Action loadA(NodeId id, Node n) if (!running && !finished);
        let v = heapA; v[id] = n; heapA <= v;
    endmethod
    method Action loadB(NodeId id, Node n) if (!running && !finished);
        let v = heapB; v[id] = n; heapB <= v;
    endmethod
    method Action start() if (!running && !finished);
        running <= True;
    endmethod
    method Bool done();
        return finished;
    endmethod
    method Node readA(NodeId id) if (finished);
        return heapA[id];
    endmethod
    method Node readB(NodeId id) if (finished);
        return heapB[id];
    endmethod
    method Bit#(32) interactions();
        return interA + interB;
    endmethod

endmodule

endpackage
