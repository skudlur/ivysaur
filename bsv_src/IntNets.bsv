// IntNets.bsv
// Ivy interaction net reduction engine — direct pointer model.
//
// Each node port stores a PortRef = (NodeId, PortIndex).
// This means every connection knows which node AND which port
// points back. No wire slots, no chain-following.
//
// Pipeline:
//   FETCH  — dequeue active pair, read left+right nodes
//   EXEC   — dispatch on tag pair, push pending ops
//   DRAIN  — execute pending ops one per cycle
//   DETECT — check if new active pairs formed, enqueue
//
// Rewrite rules:
//   FN + EXT  — arithmetic: read operands via port1/port2 PortRefs,
//               compute result, write N32 to port0.node
//   FN + FN   — annihilation: zip port connections using PortRefs,
//               update the back-ports of connected nodes directly
//   ERASER+*  — free both nodes

package IntNets;

import IvyTypes::*;
import IvyQueue::*;
import Vector::*;

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------
interface IntNets_IFC;
    method Action   load(NodeId id, Node n);
    method Action   startReduction();
    method Action   enqPair(ActivePair pair);
    method Bool     done();
    method Node     readNode(NodeId id);
    method Bit#(32) interactions();
endinterface

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------
typedef enum {
    STATE_LOADING,
    STATE_FETCH,
    STATE_EXEC,
    STATE_ALLOC,   // scan heap for free slots (needed for fn+dup growth)
    STATE_DRAIN,
    STATE_DETECT,
    STATE_DONE
} EngineState deriving (Bits, Eq);

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------
(* synthesize *)
module mkIntNets(IntNets_IFC);

    Vector#(HEAP_SIZE, Reg#(Node)) heap <-
        replicateM(mkReg(invalidNode()));

    IvyQueue_IFC queue <- mkIvyQueue();

    Reg#(EngineState) state      <- mkReg(STATE_LOADING);
    Reg#(Bit#(32))    interCount <- mkReg(0);

    // Pipeline regs
    Reg#(ActivePair) pairReg <- mkReg(ActivePair { left: 0, right: 0 });
    Reg#(Node) leftReg  <- mkReg(invalidNode());
    Reg#(Node) rightReg <- mkReg(invalidNode());

    // Pending ops
    Vector#(MAX_OPS, Reg#(PendingOp)) ops <-
        replicateM(mkReg(tagged Free 0));
    Reg#(Bit#(4)) opCount <- mkReg(0);
    Reg#(Bit#(4)) opIdx   <- mkReg(0);

    // Result pairs for detect — up to 3 new pairs per rewrite
    // fn+fn can create 3 new connections (port0, port1, port2 zips)
    // fn+ext creates 1, n32+dup creates 1, wire prop creates 1
    Vector#(3, Reg#(NodeId)) detectNodes <-
        replicateM(mkReg(0));
    Vector#(3, Reg#(NodeId)) detectConnects <-
        replicateM(mkReg(0));
    Reg#(Bit#(2)) detectCount <- mkReg(0);  // how many pairs to check
    Reg#(Bit#(2)) detectIdx   <- mkReg(0);  // current pair being checked
    Reg#(Bool)    detectFoundAny <- mkReg(False); // enqueued anything this sweep

    // Keep single resultNode/resultConnect for backward compat
    // They now alias detectNodes[0]/detectConnects[0]
    Reg#(NodeId) resultNode    <- mkReg(0);
    Reg#(NodeId) resultConnect <- mkReg(0);

    // Pre-found free slots for fn+dup allocation
    // Set by rl_alloc which checks 4 candidate slots
    Vector#(4, Reg#(NodeId)) freeFound <- replicateM(mkReg(0));

    // -----------------------------------------------------------------------
    // rl_fetch
    // -----------------------------------------------------------------------
    rule rl_fetch (state == STATE_FETCH);
        if (queue.isEmpty()) begin
            state <= STATE_DONE;
        end else begin
            let pair <- queue.deq();
            let l = heap[pair.left];
            let r = heap[pair.right];
            pairReg  <= pair;
            leftReg  <= l;
            rightReg <= r;
            // fn+dup commutation needs new nodes — scan heap first
            if ((l.tag == TAG_FN && r.tag == TAG_DUP) ||
                (l.tag == TAG_DUP && r.tag == TAG_FN))
                state <= STATE_ALLOC;
            else
                state <= STATE_EXEC;
            $display("fetch pair %0d %0d ltag %0d rtag %0d",
                     pair.left, pair.right,
                     pack(l.tag), pack(r.tag));
        end
    endrule

    // -----------------------------------------------------------------------
    // rl_alloc: find 4 free slots for fn+dup commutation
    // Scans heap slots 2..15 for invalid entries
    // Saves the first 4 found into freeFound registers
    // -----------------------------------------------------------------------
    Reg#(Bit#(4)) allocScanIdx   <- mkReg(2);
    Reg#(Bit#(3)) allocFoundCount <- mkReg(0);

    rule rl_alloc (state == STATE_ALLOC);
        // Scan one slot per cycle until we have 4
        // This takes up to 14 cycles in the worst case
        // For our small heap (16 slots) this is fast enough
        if (allocFoundCount < 4) begin
            if (!heap[allocScanIdx].valid) begin
                freeFound[allocFoundCount] <= allocScanIdx;
                allocFoundCount <= allocFoundCount + 1;
            end
            allocScanIdx <= (allocScanIdx == 15) ? 2 : allocScanIdx + 1;
        end else begin
            // Found all 4 slots — proceed to exec
            allocScanIdx    <= 2;
            allocFoundCount <= 0;
            state <= STATE_EXEC;
            $display("alloc found slots %0d %0d %0d %0d",
                     freeFound[0], freeFound[1],
                     freeFound[2], freeFound[3]);
        end
    endrule

    // -----------------------------------------------------------------------
    // rl_exec
    // -----------------------------------------------------------------------
    rule rl_exec (state == STATE_EXEC);
        let pair  = pairReg;
        let left  = leftReg;
        let right = rightReg;

        // Helper: create UpdatePortN op based on which port to update
        function PendingOp mkUpdate(NodeId s, PortRef t, PortIndex p);
            case (p)
                pAUX0(): return tagged UpdatePort1 { slot: s, tgt: t };
                pAUX1(): return tagged UpdatePort2 { slot: s, tgt: t };
                pAUX2(): return tagged UpdatePort3 { slot: s, tgt: t };
                default: return tagged UpdatePort0 { slot: s, tgt: t };
            endcase
        endfunction
        // left  = fn node:  port0=result_ref, port1=opA_ref, port2=opB_ref
        // right = ext node: port0=result_ref, port1=opA_ref, port2=opB_ref
        //
        // Operands are at left.port1.node and left.port2.node
        // Result goes to left.port0.node at port left.port0.port
        // ------------------------------------------------------------------
        if (left.tag == TAG_FN && right.tag == TAG_EXT) begin
            let nodeA   = heap[left.port1.node];
            let nodeB   = heap[left.port2.node];
            let a       = nodeA.val;
            let b       = nodeB.val;
            ExtOp extOp = unpack(truncate(right.val));

            Bit#(32) result = case (extOp)
                EXT_ADD: a + b;
                EXT_SUB: a - b;
                EXT_MUL: a * b;
                EXT_DIV: a / b;
                EXT_REM: a % b;
                default: 0;
            endcase;

            // Write N32 result directly to the result slot
            // port0 of result node points to whoever was connected
            // to left.port0 (the consumer of the result)
            NodeId resSlot = left.port0.node;
            heap[resSlot] <= Node {
                tag:   TAG_N32,
                val:   result,
                port0: right.port0,
                port1: nullRef(),
                port2: nullRef(),
                port3: nullRef(),
                valid: True
            };

            // Free consumed nodes
            ops[0] <= tagged Free pair.left;
            ops[1] <= tagged Free pair.right;
            ops[2] <= tagged Free left.port1.node;
            ops[3] <= tagged Free left.port2.node;
            opCount <= 4;
            opIdx   <= 0;

            // For detect: result node is resSlot
            // its consumer is right.port0.node
            resultNode    <= resSlot;
            resultConnect <= heap[resSlot].port0.node;
            detectNodes[0]    <= resSlot;
            detectConnects[0] <= heap[resSlot].port0.node;
            detectCount    <= 1;
            detectIdx      <= 0;
            detectFoundAny <= False;

            interCount <= interCount + 1;
            $display("exec arith %0d op %0d result %0d slot %0d",
                     a, b, result, resSlot);

        // ------------------------------------------------------------------
        // FN + FN: annihilation (beta reduction)
        //
        // left  = fn(port0=L0 port1=L1 port2=L2)
        // right = fn(port0=R0 port1=R1 port2=R2)
        //
        // Connect each port pair directly:
        //   L0.node's (L0.port) field <- R0
        //   R0.node's (R0.port) field <- L0
        //   L1.node's (L1.port) field <- R1
        //   R1.node's (R1.port) field <- L1
        //   L2.node's (L2.port) field <- R2
        //   R2.node's (R2.port) field <- L2
        // Free left and right fn nodes.
        //
        // Each UpdatePortN op updates the correct port field of
        // a specific node to a new PortRef.
        // ------------------------------------------------------------------
        end else if (left.tag == TAG_FN && right.tag == TAG_FN) begin
            let l0 = left.port0;   let r0 = right.port0;
            let l1 = left.port1;   let r1 = right.port1;
            let l2 = left.port2;   let r2 = right.port2;
            let l3 = left.port3;   let r3 = right.port3;

            ops[0] <= mkUpdate(l0.node, r0, l0.port);
            ops[1] <= mkUpdate(r0.node, l0, r0.port);
            ops[2] <= mkUpdate(l1.node, r1, l1.port);
            ops[3] <= mkUpdate(r1.node, l1, r1.port);
            ops[4] <= mkUpdate(l2.node, r2, l2.port);
            ops[5] <= mkUpdate(r2.node, l2, r2.port);
            ops[6] <= mkUpdate(l3.node, r3, l3.port);
            ops[7] <= mkUpdate(r3.node, l3, r3.port);
            ops[8] <= tagged Free pair.left;
            ops[9] <= tagged Free pair.right;
            opCount <= 10;
            opIdx   <= 0;

            // Save all three zipped port connections for multi-pair detect
            detectNodes[0]    <= l0.node;
            detectConnects[0] <= r0.node;
            detectNodes[1]    <= l1.node;
            detectConnects[1] <= r1.node;
            detectNodes[2]    <= l2.node;
            detectConnects[2] <= r2.node;
            detectCount    <= 3;
            detectIdx      <= 0;
            detectFoundAny <= False;
            // Keep backward compat
            resultNode    <= l0.node;
            resultConnect <= r0.node;

            interCount <= interCount + 1;
            $display("exec annihilate fn fn %0d %0d",
                     pair.left, pair.right);

        // ------------------------------------------------------------------
        // N32 + DUP: duplication of a literal value
        //
        // When an N32 value meets a dup node's principal port,
        // the value is copied to both outputs:
        //   dup.port1.node ← N32(val)  first copy
        //   dup.port0's back-connection ← N32(val)  second copy
        //     (back-connection = whoever pointed at dup's principal port)
        //
        // This is the simple case of the commutation rule for leaf nodes.
        // No new nodes created — just write the value to two existing slots.
        // ------------------------------------------------------------------
        end else if (left.tag == TAG_N32 && right.tag == TAG_DUP) begin
            let val = left.val;
            NodeId copy1Slot = right.port1.node;
            NodeId copy2Slot = right.port2.node;

            // Write first copy directly — one heap write in exec
            heap[copy1Slot] <= Node {
                tag:   TAG_N32,
                val:   val,
                port0: heap[copy1Slot].port0,
                port1: nullRef(),
                port2: nullRef(),
                port3: nullRef(),
                valid: True
            };

            // Stage second copy and frees through drain
            ops[0] <= tagged WriteN32 { slot: copy2Slot, val: val,
                                        back: heap[copy2Slot].port0 };
            ops[1] <= tagged Free pair.left;
            ops[2] <= tagged Free pair.right;
            opCount <= 3;
            opIdx   <= 0;

            resultNode    <= copy1Slot;
            resultConnect <= heap[copy1Slot].port0.node;
            detectNodes[0]    <= copy1Slot;
            detectConnects[0] <= heap[copy1Slot].port0.node;
            detectCount    <= 1;
            detectIdx      <= 0;
            detectFoundAny <= False;

            interCount <= interCount + 1;
            $display("exec dup n32 val %0d copy1 %0d copy2 %0d",
                     val, copy1Slot, copy2Slot);

        end else if (left.tag == TAG_DUP && right.tag == TAG_N32) begin
            let val = right.val;
            NodeId copy1Slot = left.port1.node;
            NodeId copy2Slot = left.port2.node;

            heap[copy1Slot] <= Node {
                tag:   TAG_N32,
                val:   val,
                port0: heap[copy1Slot].port0,
                port1: nullRef(),
                port2: nullRef(),
                port3: nullRef(),
                valid: True
            };

            ops[0] <= tagged WriteN32 { slot: copy2Slot, val: val,
                                        back: heap[copy2Slot].port0 };
            ops[1] <= tagged Free pair.left;
            ops[2] <= tagged Free pair.right;
            opCount <= 3;
            opIdx   <= 0;

            resultNode    <= copy1Slot;
            resultConnect <= heap[copy1Slot].port0.node;
            detectNodes[0]    <= copy1Slot;
            detectConnects[0] <= heap[copy1Slot].port0.node;
            detectCount    <= 1;
            detectIdx      <= 0;
            detectFoundAny <= False;

            interCount <= interCount + 1;
            $display("exec dup n32 val %0d copy1 %0d copy2 %0d",
                     val, copy1Slot, copy2Slot);
        // ------------------------------------------------------------------
        // N32 + INVALID: wire propagation
        // When an N32 value faces an INVALID wire slot, propagate
        // the value through — the wire slot becomes N32 with the same value.
        // This handles cross-op wire connections in chained programs.
        // ------------------------------------------------------------------
        end else if (left.tag == TAG_N32 && right.tag == TAG_INVALID) begin
            let val = left.val;
            heap[pair.right] <= Node {
                tag:   TAG_N32,
                val:   val,
                port0: right.port0,
                port1: nullRef(),
                port2: nullRef(),
                port3: nullRef(),
                valid: True
            };
            ops[0] <= tagged Free pair.left;
            opCount <= 1;
            opIdx   <= 0;
            // After wire prop, check if the fn that owns this slot
            // now has both operands ready — if so its ext pair can fire
            // right.port0 points to the fn node via pAUX0 or pAUX1
            // The fn's principal port (port0) points to the ext node
            // We set resultNode to the fn and resultConnect to the ext
            // so detect can enqueue (fn, ext) as a new active pair
            let ownerFnSlot = right.port0.node;
            let ownerFn     = heap[right.port0.node];
            let extSlot     = ownerFn.port3.node;
            resultNode    <= ownerFnSlot;
            resultConnect <= extSlot;
            detectNodes[0]    <= ownerFnSlot;
            detectConnects[0] <= extSlot;
            detectCount    <= 1;
            detectIdx      <= 0;
            detectFoundAny <= False;
            interCount    <= interCount + 1;
            $display("exec wire prop n32 val %0d to slot %0d owner fn %0d ext %0d",
                     val, pair.right, ownerFnSlot, extSlot);

        end else if (left.tag == TAG_INVALID && right.tag == TAG_N32) begin
            let val = right.val;
            heap[pair.left] <= Node {
                tag:   TAG_N32,
                val:   val,
                port0: left.port0,
                port1: nullRef(),
                port2: nullRef(),
                port3: nullRef(),
                valid: True
            };
            ops[0] <= tagged Free pair.right;
            opCount <= 1;
            opIdx   <= 0;
            let ownerFnSlot = left.port0.node;
            let ownerFn     = heap[left.port0.node];
            let extSlot     = ownerFn.port3.node;
            resultNode    <= ownerFnSlot;
            resultConnect <= extSlot;
            detectNodes[0]    <= ownerFnSlot;
            detectConnects[0] <= extSlot;
            detectCount    <= 1;
            detectIdx      <= 0;
            detectFoundAny <= False;
            interCount    <= interCount + 1;
            $display("exec wire prop n32 val %0d to slot %0d owner fn %0d ext %0d",
                     val, pair.left, ownerFnSlot, extSlot);
        //
        // fn(port0=A port1=B port2=C) >< dup(port0=fn port1=D port2=E)
        //
        // Creates 4 new nodes (2 new fn + 2 new dup) using pre-scanned
        // free slots from rl_alloc:
        //   slot0 = new_dup0: duplicates A's connection
        //   slot1 = new_dup1: duplicates B's connection
        //   slot2 = new_fn1: first copy of fn, result goes to D
        //   slot3 = new_fn2: second copy of fn, result goes to E
        //
        // For 2-aux fn (ignoring port3 for now):
        //   new_dup0.port0 = A (back-connects to A's node)
        //   new_dup0.port1 = {new_fn1, pPRINCIPAL}
        //   new_dup0.port2 = {new_fn2, pPRINCIPAL}
        //   new_dup1.port0 = B
        //   new_dup1.port1 = {new_fn1, pAUX0}
        //   new_dup1.port2 = {new_fn2, pAUX0}
        //   new_fn1.port0  = {new_dup0, pAUX0}
        //   new_fn1.port1  = {new_dup1, pAUX0}
        //   new_fn2.port0  = {new_dup0, pAUX1}
        //   new_fn2.port1  = {new_dup1, pAUX1}
        //
        // Back-pointer updates (via drain ops):
        //   A.node's A.port <- {new_dup0, pPRINCIPAL}
        //   B.node's B.port <- {new_dup1, pPRINCIPAL}
        //   D.node's D.port <- {new_fn1, pPRINCIPAL}
        //   E.node's E.port <- {new_fn2, pPRINCIPAL}
        // ------------------------------------------------------------------
        end else if ((left.tag == TAG_FN && right.tag == TAG_DUP) ||
                     (left.tag == TAG_DUP && right.tag == TAG_FN)) begin

            // Normalise: fn on left, dup on right
            Node fnNode  = (left.tag == TAG_FN) ? left  : right;
            Node dupNode = (left.tag == TAG_DUP) ? left : right;

            PortRef a = fnNode.port0;   // fn's principal connection
            PortRef b = fnNode.port1;   // fn's aux0 connection
            PortRef d = dupNode.port1;  // dup's first output
            PortRef e = dupNode.port2;  // dup's second output

            NodeId s0 = freeFound[0];  // new_dup0
            NodeId s1 = freeFound[1];  // new_dup1
            NodeId s2 = freeFound[2];  // new_fn1
            NodeId s3 = freeFound[3];  // new_fn2

            // Push all 4 new nodes + 4 back-updates + 2 frees as drain ops
            // new_dup0
            ops[0] <= tagged AllocDup { slot: s0,
                p0: a,
                p1: PortRef { node: s2, port: pPRINCIPAL() },
                p2: PortRef { node: s3, port: pPRINCIPAL() }};
            // new_dup1
            ops[1] <= tagged AllocDup { slot: s1,
                p0: b,
                p1: PortRef { node: s2, port: pAUX0() },
                p2: PortRef { node: s3, port: pAUX0() }};
            // new_fn1
            ops[2] <= tagged AllocFn { slot: s2,
                p0: PortRef { node: s0, port: pAUX0() },
                p1: PortRef { node: s1, port: pAUX0() }};
            // new_fn2
            ops[3] <= tagged AllocFn { slot: s3,
                p0: PortRef { node: s0, port: pAUX1() },
                p1: PortRef { node: s1, port: pAUX1() }};
            // Back-pointer updates
            ops[4] <= mkUpdate(a.node, PortRef { node: s0, port: pPRINCIPAL() }, a.port);
            ops[5] <= mkUpdate(b.node, PortRef { node: s1, port: pPRINCIPAL() }, b.port);
            ops[6] <= mkUpdate(d.node, PortRef { node: s2, port: pPRINCIPAL() }, d.port);
            ops[7] <= mkUpdate(e.node, PortRef { node: s3, port: pPRINCIPAL() }, e.port);
            // Free old nodes
            ops[8] <= tagged Free pair.left;
            ops[9] <= tagged Free pair.right;
            opCount <= 10;
            opIdx   <= 0;

            // Detect: new_fn1 and new_fn2 may form active pairs with D and E
            resultNode    <= s2;
            resultConnect <= d.node;
            detectNodes[0]    <= s2;
            detectConnects[0] <= d.node;
            detectNodes[1]    <= s3;
            detectConnects[1] <= e.node;
            detectCount    <= 2;
            detectIdx      <= 0;
            detectFoundAny <= False;

            interCount <= interCount + 1;
            $display("exec fn dup commute fn %0d dup %0d new %0d %0d %0d %0d",
                     pair.left, pair.right, s0, s1, s2, s3);

        end else if (left.tag == TAG_ERASER || right.tag == TAG_ERASER) begin
            ops[0] <= tagged Free pair.left;
            ops[1] <= tagged Free pair.right;
            opCount        <= 2;
            opIdx          <= 0;
            resultNode     <= 0;
            resultConnect  <= 0;
            detectCount    <= 0;
            detectIdx      <= 0;
            detectFoundAny <= False;
            interCount     <= interCount + 1;
            $display("exec erase %0d %0d", pair.left, pair.right);

        end else begin
            opCount        <= 0;
            opIdx          <= 0;
            resultNode     <= 0;
            resultConnect  <= 0;
            detectCount    <= 0;
            detectIdx      <= 0;
            detectFoundAny <= False;
            $display("exec unhandled ltag %0d rtag %0d",
                     pack(left.tag), pack(right.tag));
        end

        state <= STATE_DRAIN;
    endrule

    // -----------------------------------------------------------------------
    // rl_drain: execute one pending op per cycle
    // Handles Free and UpdatePort0/1/2
    // UpdatePort0 used for all port updates — the PortRef carries
    // which port to update via the port field in the ref
    // -----------------------------------------------------------------------
    rule rl_drain (state == STATE_DRAIN);
        if (opIdx < opCount) begin
            let op = ops[opIdx];
            case (op) matches
                tagged Free .id: begin
                    heap[id] <= invalidNode();
                    $display("drain free slot %0d", id);
                end
                tagged UpdatePort0 .u: begin
                    let n = heap[u.slot];
                    heap[u.slot] <= Node {
                        tag:   n.tag, val: n.val,
                        port0: u.tgt,
                        port1: n.port1, port2: n.port2, port3: n.port3,
                        valid: n.valid };
                    $display("drain upd slot %0d port0 node %0d",
                             u.slot, u.tgt.node);
                end
                tagged UpdatePort1 .u: begin
                    let n = heap[u.slot];
                    heap[u.slot] <= Node {
                        tag:   n.tag, val: n.val,
                        port0: n.port0,
                        port1: u.tgt,
                        port2: n.port2, port3: n.port3,
                        valid: n.valid };
                    $display("drain upd slot %0d port1 node %0d",
                             u.slot, u.tgt.node);
                end
                tagged UpdatePort2 .u: begin
                    let n = heap[u.slot];
                    heap[u.slot] <= Node {
                        tag:   n.tag, val: n.val,
                        port0: n.port0, port1: n.port1,
                        port2: u.tgt,
                        port3: n.port3,
                        valid: n.valid };
                    $display("drain upd slot %0d port2 node %0d",
                             u.slot, u.tgt.node);
                end
                tagged WriteN32 .u: begin
                    heap[u.slot] <= Node {
                        tag:   TAG_N32,
                        val:   u.val,
                        port0: u.back,
                        port1: nullRef(),
                        port2: nullRef(),
                        port3: nullRef(),
                        valid: True
                    };
                    $display("drain write n32 val %0d slot %0d",
                             u.val, u.slot);
                end
                tagged AllocFn .u: begin
                    heap[u.slot] <= Node {
                        tag: TAG_FN, val: 0,
                        port0: u.p0, port1: u.p1,
                        port2: nullRef(), port3: nullRef(),
                        valid: True };
                    $display("drain alloc fn slot %0d", u.slot);
                end
                tagged AllocDup .u: begin
                    heap[u.slot] <= Node {
                        tag: TAG_DUP, val: 0,
                        port0: u.p0, port1: u.p1, port2: u.p2,
                        port3: nullRef(), valid: True };
                    $display("drain alloc dup slot %0d", u.slot);
                end
                tagged UpdatePort3 .u: begin
                    let n = heap[u.slot];
                    heap[u.slot] <= Node {
                        tag:   n.tag, val: n.val,
                        port0: n.port0, port1: n.port1, port2: n.port2,
                        port3: u.tgt,
                        valid: n.valid };
                    $display("drain upd slot %0d port3 node %0d",
                             u.slot, u.tgt.node);
                end
            endcase
            opIdx <= opIdx + 1;
        end else begin
            state <= STATE_DETECT;
        end
    endrule

    // -----------------------------------------------------------------------
    // rl_detect: check if result node and its connection form active pair
    //
    // With direct PortRef model:
    //   resultNode    = node we just wrote or connected
    //   resultConnect = the node resultNode.port0 now points to
    //
    // Active pair condition:
    //   heap[resultConnect].port0.node == resultNode
    //   AND both are valid
    //   AND tags form a reducible pair
    // -----------------------------------------------------------------------
    rule rl_detect (state == STATE_DETECT);

        if (detectIdx < detectCount) begin
            NodeId rn = detectNodes[detectIdx];
            NodeId rc = detectConnects[detectIdx];

            if (rn != 0 && rc != 0) begin
                let a = heap[rn];
                let b = heap[rc];

                Bool facingBack = (b.port0.node == rn);
                Bool notSelf    = (rn != rc);
                Bool bothValid  = (a.valid && b.valid);
                Bool wireProp   = (a.valid && !b.valid && a.tag == TAG_N32);

                Bool fnExtReady = False;
                if (a.tag == TAG_FN && b.tag == TAG_EXT && bothValid) begin
                    let opA = heap[a.port1.node];
                    let opB = heap[a.port2.node];
                    fnExtReady = (opA.valid && opA.tag == TAG_N32 &&
                                  opB.valid && opB.tag == TAG_N32);
                end

                if (notSelf && (
                    (facingBack && bothValid) ||
                    wireProp ||
                    fnExtReady
                )) begin
                    queue.enq(ActivePair { left: rn, right: rc });
                    detectFoundAny <= True;
                    $display("detect new pair %0d %0d tags %0d %0d",
                             rn, rc, pack(a.tag), pack(b.tag));
                end else begin
                    $display("detect no pair rn %0d rc %0d fb %0d bv %0d wp %0d fe %0d",
                             rn, rc,
                             facingBack ? 1 : 0,
                             bothValid  ? 1 : 0,
                             wireProp   ? 1 : 0,
                             fnExtReady ? 1 : 0);
                end
            end

            detectIdx <= detectIdx + 1;

        end else begin
            // Sweep complete
            if (detectFoundAny || !queue.isEmpty()) begin
                state          <= STATE_FETCH;
                detectFoundAny <= False;
            end else begin
                state <= STATE_DONE;
                $display("done interactions %0d", interCount);
            end
        end
    endrule

    // -----------------------------------------------------------------------
    // Interface
    // -----------------------------------------------------------------------
    method Action load(NodeId id, Node n) if (state == STATE_LOADING);
        heap[id] <= n;
    endmethod

    method Action startReduction() if (state == STATE_LOADING);
        state <= STATE_FETCH;
    endmethod

    method Action enqPair(ActivePair pair) if (state == STATE_LOADING);
        queue.enq(pair);
    endmethod

    method Bool done();
        return state == STATE_DONE;
    endmethod

    method Node readNode(NodeId id) if (state == STATE_DONE);
        return heap[id];
    endmethod

    method Bit#(32) interactions();
        return interCount;
    endmethod

endmodule

endpackage
