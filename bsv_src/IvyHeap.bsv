// IvyHeap.bsv
// Parameterised node heap for the Ivy interaction net reduction engine.
//
// Implemented as a Vector of registers — each slot starts invalid,
// no init loop needed. Linear scan for free slots is fine at small
// heap sizes (LOG_HEAP_SIZE <= 4, i.e. 16 slots).
//
// For larger heaps, replace findFreeSlot with a free-list FIFO.

package IvyHeap;

import IvyTypes::*;
import Vector::*;

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------
interface IvyHeap_IFC;
    method Node             read(NodeId id);
    method Action           write(NodeId id, Node n);
    method ActionValue#(NodeId) alloc(Node n);
    method Action           free(NodeId id);
    method Bit#(16)         usedSlots();
endinterface

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------
(* synthesize *)
module mkIvyHeap(IvyHeap_IFC);

    // Vector of registers — all start as invalidNode()
    Vector#(HEAP_SIZE, Reg#(Node)) heap <-
        replicateM(mkReg(invalidNode()));

    Reg#(Bit#(16)) slotCount <- mkReg(0);

    // Linear scan for a free slot
    // Fine for HEAP_SIZE <= 16; replace with free-list for larger heaps
    function Maybe#(NodeId) findFreeSlot();
        Maybe#(NodeId) result = tagged Invalid;
        for (Integer i = 0; i < valueOf(HEAP_SIZE); i = i + 1) begin
            if (!heap[i].valid && !isValid(result))
                result = tagged Valid fromInteger(i);
        end
        return result;
    endfunction

    // -----------------------------------------------------------------------
    // Interface methods
    // -----------------------------------------------------------------------

    method Node read(NodeId id);
        return heap[id];
    endmethod

    method Action write(NodeId id, Node n);
        heap[id] <= n;
    endmethod

    method ActionValue#(NodeId) alloc(Node n);
        let mslot = findFreeSlot();
        let slot = fromMaybe(0, mslot);
        Node newNode  = n;
        newNode.valid = True;
        heap[slot]   <= newNode;
        slotCount    <= slotCount + 1;
        return slot;
    endmethod

    method Action free(NodeId id);
        heap[id] <= invalidNode();
        slotCount <= slotCount - 1;
    endmethod

    method Bit#(16) usedSlots();
        return slotCount;
    endmethod

endmodule

endpackage
