// IntNets.bsv
// Proof-of-concept interaction net reduction engine for the Ivy IR.
// Implements one complete reduction: the N32::add active pair.
//
// Ivy source:
//   :root::numeric::N32::add {
//     ^ = vi:fn(vi:ext#2[vi:n32:add](0 1) 0 1)
//   }
//
// Mapping:
//   Net block       -> module
//   Wire variable N -> Reg#(Token) wireN
//   Active pair     -> rule guard
//   Rewrite         -> rule body (atomic register writes)
//   vi:ext#2[add]   -> let result = a + b

package IntNets;

// ---------------------------------------------------------------------------
// Token: the value that travels along a wire.
// Every wire register holds one Token.
// tag  = what kind of node is sitting on this wire's principal port
// val  = payload (meaningful for N32; zero for structural nodes)
// ---------------------------------------------------------------------------

typedef enum {
    TAG_FN,       // vi:fn   — lambda / application node
    TAG_N32,      // vi:n32  — 32-bit integer value
    TAG_ERASER,   // vi:eraser — discard
    TAG_INVALID   // uninitialised / consumed
} Tag deriving (Bits, Eq, FShow);

typedef struct {
    Tag      tag;
    Bit#(32) val;
} Token deriving (Bits, FShow);

// Convenience constructors
function Token mkFn();
    return Token { tag: TAG_FN, val: 0 };
endfunction

function Token mkN32(Bit#(32) v);
    return Token { tag: TAG_N32, val: v };
endfunction

function Token mkEraser();
    return Token { tag: TAG_ERASER, val: 0 };
endfunction

function Token invalid();
    return Token { tag: TAG_INVALID, val: 0 };
endfunction

// ---------------------------------------------------------------------------
// Module: IvyAdd
//
// Models the reduction of:
//   vi:graft[:root::numeric::N32::add] = vi:fn(vi:n32#15 vi:n32#12 result)
//
// Wires:
//   wire0  -- operand a  (carries vi:n32#15)
//   wire1  -- operand b  (carries vi:n32#12)
//   result -- output     (receives vi:n32#27 after reduction)
//
// The active pair fires when:
//   the caller fn meets the add net's principal fn
//   -> guard: wire0 and wire1 both carry N32 tokens
// ---------------------------------------------------------------------------

interface IvyAdd_IFC;
    method Bool   done();
    method Bit#(32) readResult();
endinterface

(* synthesize *)
module mkIvyAdd(IvyAdd_IFC);

    // Wire registers: each holds the token on that wire
    Reg#(Token) wire0  <- mkReg(mkN32(15));   // operand a = vi:n32#15
    Reg#(Token) wire1  <- mkReg(mkN32(12));   // operand b = vi:n32#12
    Reg#(Token) result <- mkReg(invalid());   // output wire, initially empty

    // State flag: reduction complete
    Reg#(Bool) reduced <- mkReg(False);

    // -----------------------------------------------------------------------
    // Rule: rl_n32_add
    //
    // Fires when both operand wires carry N32 tokens.
    // This is the active pair: fn(ext#2[add](0 1) 0 1) meeting fn(n32#15 n32#12 result)
    //
    // Body:
    //   1. Read operands from wire0 and wire1
    //   2. Compute sum (the vi:ext#2[vi:n32:add] extrinsic)
    //   3. Write result token to result wire
    //   4. Consume (invalidate) the operand wires
    // -----------------------------------------------------------------------
    rule rl_n32_add (wire0.tag == TAG_N32 &&
                     wire1.tag == TAG_N32 &&
                     !reduced);

        let a = wire0.val;
        let b = wire1.val;
        let sum = a + b;

        result <= mkN32(sum);   // rewrite: result wire now carries vi:n32#27
        wire0  <= invalid();    // operands consumed — linearity enforced
        wire1  <= invalid();
        reduced <= True;

        $display("rl_n32_add fired: %0d + %0d = %0d", a, b, sum);

    endrule

    // -----------------------------------------------------------------------
    // Rule: rl_erase
    //
    // vi:eraser annihilates anything. Fires when an eraser meets any token.
    // Included to show the erase interaction; not triggered in this program.
    // -----------------------------------------------------------------------
    rule rl_erase (wire0.tag == TAG_ERASER && wire1.tag != TAG_INVALID);
        wire1 <= invalid();
        wire0 <= invalid();
        $display("rl_erase fired: discarded token on wire1");
    endrule

    // -----------------------------------------------------------------------
    // Interface methods
    // -----------------------------------------------------------------------
    method Bool done();
        return reduced;
    endmethod

    method Bit#(32) readResult() if (reduced);
        return result.val;
    endmethod

endmodule

endpackage
