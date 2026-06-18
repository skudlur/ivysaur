// IvyTypes.bsv
// Shared types for the Ivy interaction net reduction engine.
//
// Key change from wire-as-node model:
//   Each port stores a PortRef = (NodeId, PortIndex) pair.
//   This means every connection knows:
//     1. Which node it connects to
//     2. Which port of that node points back
//   This eliminates wire slots and chain-following entirely.
//   fn+fn annihilation updates PortRef fields directly.
//
// Ivy -> BSV mapping:
//   vi:fn        -> TAG_FN
//   vi:n32#V     -> TAG_N32  (val = V)
//   vi:eraser    -> TAG_ERASER
//   vi:dup       -> TAG_DUP
//   vi:ext#2[op] -> TAG_EXT  (val encodes op)

package IvyTypes;

// ---------------------------------------------------------------------------
// Heap sizing
// ---------------------------------------------------------------------------
typedef 4 LOG_HEAP_SIZE;
typedef Bit#(LOG_HEAP_SIZE) NodeId;
typedef TExp#(LOG_HEAP_SIZE) HEAP_SIZE;

// ---------------------------------------------------------------------------
// PortIndex: which port of a node a connection points back through
// ---------------------------------------------------------------------------
typedef Bit#(2) PortIndex;

function PortIndex pPRINCIPAL(); return 2'b00; endfunction
function PortIndex pAUX0();      return 2'b01; endfunction
function PortIndex pAUX1();      return 2'b10; endfunction
function PortIndex pAUX2();      return 2'b11; endfunction

// ---------------------------------------------------------------------------
// PortRef: a directed connection to a specific port of a specific node
// ---------------------------------------------------------------------------
typedef struct {
    NodeId    node;  // which node
    PortIndex port;  // which port of that node points back here
} PortRef deriving (Bits, Eq);

function PortRef mkPortRef(NodeId n, PortIndex p);
    return PortRef { node: n, port: p };
endfunction

function PortRef nullRef();
    return PortRef { node: 0, port: 0 };
endfunction

// ---------------------------------------------------------------------------
// Tag: node type discriminator
// ---------------------------------------------------------------------------
typedef enum {
    TAG_FN,       // vi:fn      — lambda / application
    TAG_N32,      // vi:n32#V   — 32-bit integer literal
    TAG_ERASER,   // vi:eraser  — discard
    TAG_DUP,      // vi:dup     — explicit fan-out
    TAG_EXT,      // vi:ext#2   — extrinsic / host primitive
    TAG_INVALID   // free slot
} Tag deriving (Bits, Eq);

// ---------------------------------------------------------------------------
// ExtOp: which extrinsic operation a TAG_EXT node performs
// ---------------------------------------------------------------------------
typedef enum {
    EXT_ADD,
    EXT_SUB,
    EXT_MUL,
    EXT_DIV,
    EXT_REM,
    EXT_NE
} ExtOp deriving (Bits, Eq);

// ---------------------------------------------------------------------------
// Node: one entry in the heap.
//
// port0 = principal port — PortRef to the connected node + back-port
// port1 = first auxiliary port
// port2 = second auxiliary port
//
// Example: vi:fn(result_wire input_wire)
//   port0 = PortRef { node=result_consumer, port=pWHICHEVER }
//   port1 = PortRef { node=input_producer,  port=pWHICHEVER }
//
// valid = False means free slot
// ---------------------------------------------------------------------------
typedef struct {
    Tag      tag;
    Bit#(32) val;
    PortRef  port0;  // principal port connection
    PortRef  port1;  // aux port 0
    PortRef  port2;  // aux port 1
    PortRef  port3;  // aux port 2 (needed for 3-aux fn nodes)
    Bool     valid;
} Node deriving (Bits);

// ---------------------------------------------------------------------------
// ActivePair: two NodeIds whose principal ports face each other
// ---------------------------------------------------------------------------
typedef struct {
    NodeId left;
    NodeId right;
} ActivePair deriving (Bits);

// ---------------------------------------------------------------------------
// PendingOp: deferred heap operation drained one per cycle
//
// Free         — invalidate a slot
// UpdatePort0  — update port0 of a slot to a new PortRef
// UpdatePort1  — update port1 of a slot to a new PortRef
// UpdatePort2  — update port2 of a slot to a new PortRef
// ---------------------------------------------------------------------------
typedef union tagged {
    NodeId   Free;
    struct { NodeId slot; PortRef tgt; } UpdatePort0;
    struct { NodeId slot; PortRef tgt; } UpdatePort1;
    struct { NodeId slot; PortRef tgt; } UpdatePort2;
    struct { NodeId slot; PortRef tgt; } UpdatePort3;
} PendingOp deriving (Bits);

// fn+fn worst case: 8 port updates + 2 frees = 10
typedef 10 MAX_OPS;

// ---------------------------------------------------------------------------
// Node constructors
// ---------------------------------------------------------------------------
function Node mkN32Node(Bit#(32) v, PortRef p0);
    return Node { tag: TAG_N32, val: v,
                  port0: p0, port1: nullRef(),
                  port2: nullRef(), port3: nullRef(),
                  valid: True };
endfunction

function Node mkFnNode(PortRef p0, PortRef p1, PortRef p2);
    return Node { tag: TAG_FN, val: 0,
                  port0: p0, port1: p1,
                  port2: p2, port3: nullRef(),
                  valid: True };
endfunction

function Node mkFn3Node(PortRef p0, PortRef p1, PortRef p2, PortRef p3);
    return Node { tag: TAG_FN, val: 0,
                  port0: p0, port1: p1,
                  port2: p2, port3: p3,
                  valid: True };
endfunction

function Node mkExtNode(ExtOp op, PortRef p0, PortRef p1, PortRef p2);
    return Node { tag: TAG_EXT, val: zeroExtend(pack(op)),
                  port0: p0, port1: p1,
                  port2: p2, port3: nullRef(),
                  valid: True };
endfunction

function Node mkEraserNode(PortRef p0);
    return Node { tag: TAG_ERASER, val: 0,
                  port0: p0, port1: nullRef(),
                  port2: nullRef(), port3: nullRef(),
                  valid: True };
endfunction

function Node invalidNode();
    return Node { tag: TAG_INVALID, val: 0,
                  port0: nullRef(), port1: nullRef(),
                  port2: nullRef(), port3: nullRef(),
                  valid: False };
endfunction

// ---------------------------------------------------------------------------
// Port access helpers
// ---------------------------------------------------------------------------
function PortRef getPort(Node n, PortIndex p);
    case (p)
        pPRINCIPAL(): return n.port0;
        pAUX0():      return n.port1;
        pAUX1():      return n.port2;
        pAUX2():      return n.port3;
        default:      return nullRef();
    endcase
endfunction

endpackage
