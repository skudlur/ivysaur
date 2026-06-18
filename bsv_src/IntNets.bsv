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

    // Result for detect: the NodeId written by exec
    // and the NodeId of the node it's now connected to
    Reg#(NodeId) resultNode    <- mkReg(0);
    Reg#(NodeId) resultConnect <- mkReg(0);

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
            state    <= STATE_EXEC;
            $display("fetch pair %0d %0d ltag %0d rtag %0d",
                     pair.left, pair.right,
                     pack(l.tag), pack(r.tag));
        end
    endrule

    // -----------------------------------------------------------------------
    // rl_exec
    // -----------------------------------------------------------------------
    rule rl_exec (state == STATE_EXEC);
        let pair  = pairReg;
        let left  = leftReg;
        let right = rightReg;

        // ------------------------------------------------------------------
        // FN + EXT: arithmetic
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
            resultConnect <= right.port0.node;

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

            function PendingOp mkUpdate(NodeId s, PortRef t);
                case (t.port)
                    pAUX0(): return tagged UpdatePort1 { slot: s, tgt: t };
                    pAUX1(): return tagged UpdatePort2 { slot: s, tgt: t };
                    pAUX2(): return tagged UpdatePort3 { slot: s, tgt: t };
                    default: return tagged UpdatePort0 { slot: s, tgt: t };
                endcase
            endfunction

            ops[0] <= mkUpdate(l0.node, r0);
            ops[1] <= mkUpdate(r0.node, l0);
            ops[2] <= mkUpdate(l1.node, r1);
            ops[3] <= mkUpdate(r1.node, l1);
            ops[4] <= mkUpdate(l2.node, r2);
            ops[5] <= mkUpdate(r2.node, l2);
            ops[6] <= mkUpdate(l3.node, r3);
            ops[7] <= mkUpdate(r3.node, l3);
            ops[8] <= tagged Free pair.left;
            ops[9] <= tagged Free pair.right;
            opCount <= 10;
            opIdx   <= 0;

            resultNode    <= l0.node;
            resultConnect <= r0.node;

            interCount <= interCount + 1;
            $display("exec annihilate fn fn %0d %0d",
                     pair.left, pair.right);

        // ------------------------------------------------------------------
        // ERASER: discard both
        // ------------------------------------------------------------------
        end else if (left.tag == TAG_ERASER || right.tag == TAG_ERASER) begin
            ops[0] <= tagged Free pair.left;
            ops[1] <= tagged Free pair.right;
            opCount       <= 2;
            opIdx         <= 0;
            resultNode    <= 0;
            resultConnect <= 0;
            interCount    <= interCount + 1;
            $display("exec erase %0d %0d", pair.left, pair.right);

        end else begin
            opCount       <= 0;
            opIdx         <= 0;
            resultNode    <= 0;
            resultConnect <= 0;
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
        if (resultNode != 0 && resultConnect != 0) begin
            let a = heap[resultNode];
            let b = heap[resultConnect];

            // Check if b's port0 points back to resultNode
            Bool facingBack = (b.port0.node == resultNode);
            Bool bothValid  = (a.valid && b.valid);
            Bool notSelf    = (resultNode != resultConnect);

            if (facingBack && bothValid && notSelf) begin
                queue.enq(ActivePair { left: resultNode, right: resultConnect });
                $display("detect new pair %0d %0d tags %0d %0d",
                         resultNode, resultConnect,
                         pack(a.tag), pack(b.tag));
            end else begin
                $display("detect no pair rn %0d rc %0d fb %0d bv %0d ns %0d",
                         resultNode, resultConnect,
                         facingBack ? 1 : 0,
                         bothValid  ? 1 : 0,
                         notSelf    ? 1 : 0);
            end
        end else begin
            $display("detect skip");
        end

        if (queue.isEmpty()) begin
            state <= STATE_DONE;
            $display("done interactions %0d", interCount);
        end else begin
            state <= STATE_FETCH;
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
