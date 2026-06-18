// IvyQueue.bsv
// Active pair queue for the Ivy interaction net reduction engine.
//
// The queue holds (NodeId, NodeId) pairs whose principal ports face
// each other — these are ready to reduce. The reduction engine dequeues
// one pair per cycle and fires the appropriate rewrite rule.
//
// Design:
//   - N enqueue ports (one per potential new pair created by a rewrite)
//   - 1 dequeue port (one pair fires per cycle)
//   - Implemented as a circular FIFO over a register vector
//   - Parameterised depth via LOG_QUEUE_DEPTH

package IvyQueue;

import IvyTypes::*;
import Vector::*;

// ---------------------------------------------------------------------------
// Queue sizing
// ---------------------------------------------------------------------------
typedef 4 LOG_QUEUE_DEPTH;
typedef TExp#(LOG_QUEUE_DEPTH) QUEUE_DEPTH;

// Number of enqueue ports — a single rewrite can create at most
// 3 new active pairs (conservative upper bound for fn-fn annihilation)
typedef 3 NUM_ENQ_PORTS;

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------
interface IvyQueue_IFC;
    // Enqueue a new active pair (called when a rewrite creates a new connection)
    method Action enq(ActivePair pair);

    // Dequeue the next active pair to reduce
    method ActionValue#(ActivePair) deq();

    // Peek at the head without removing
    method ActivePair first();

    // Status
    method Bool isEmpty();
    method Bool isFull();
    method Bit#(32) count();
endinterface

// ---------------------------------------------------------------------------
// Module: circular FIFO over a register vector
// ---------------------------------------------------------------------------
(* synthesize *)
module mkIvyQueue(IvyQueue_IFC);

    Vector#(QUEUE_DEPTH, Reg#(ActivePair)) storage <-
        replicateM(mkReg(ActivePair { left: 0, right: 0 }));

    Reg#(Bit#(LOG_QUEUE_DEPTH)) head  <- mkReg(0);  // dequeue pointer
    Reg#(Bit#(LOG_QUEUE_DEPTH)) tail  <- mkReg(0);  // enqueue pointer
    Reg#(Bit#(32))              cnt   <- mkReg(0);  // element count

    function Bool full();
        return cnt == fromInteger(valueOf(QUEUE_DEPTH));
    endfunction

    function Bool empty();
        return cnt == 0;
    endfunction

    // -----------------------------------------------------------------------
    // Interface methods
    // -----------------------------------------------------------------------

    method Action enq(ActivePair pair) if (!full());
        storage[tail] <= pair;
        tail <= tail + 1;
        cnt  <= cnt + 1;
    endmethod

    method ActionValue#(ActivePair) deq() if (!empty());
        let pair = storage[head];
        head <= head + 1;
        cnt  <= cnt - 1;
        return pair;
    endmethod

    method ActivePair first() if (!empty());
        return storage[head];
    endmethod

    method Bool isEmpty();
        return empty();
    endmethod

    method Bool isFull();
        return full();
    endmethod

    method Bit#(32) count();
        return cnt;
    endmethod

endmodule

endpackage
