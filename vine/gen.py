#!/usr/bin/env python3
"""
gen.py — Ivy IR to BSV loader generator
Reads Ivy --target none IR, extracts arithmetic subgraph,
emits BSV testbench loader calls for IntNets reduction engine.

Handles:
  vi:graft[:root::numeric::N32::add]  -> fn+ext[ADD]
  vi:graft[:root::numeric::N32::mul]  -> fn+ext[MUL]
  vi:graft[:root::numeric::N32::sub]  -> fn+ext[SUB]
  vi:graft[:root::numeric::N32::div]  -> fn+ext[DIV]
  vi:graft[:root::numeric::N32::rem]  -> fn+ext[REM]
  vi:n32#V                            -> TAG_N32 literal
  wire variables (bare integers)      -> result slots

Usage:
  python3 gen.py arith.vi.ir > TestIntNets.bsv
  python3 gen.py --show arith.vi.ir   # show analysis only
"""

import re
import sys
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# IR parsing
# ---------------------------------------------------------------------------

# Map graft names to ExtOp
GRAFT_TO_EXTOP = {
    ':root::numeric::N32::add': 'EXT_ADD',
    ':root::numeric::N32::sub': 'EXT_SUB',
    ':root::numeric::N32::mul': 'EXT_MUL',
    ':root::numeric::N32::div': 'EXT_DIV',
    ':root::numeric::N32::rem': 'EXT_REM',
}

@dataclass
class ArithOp:
    """One arithmetic operation extracted from the IR."""
    op:     str          # EXT_ADD, EXT_MUL, etc.
    op_a:   object       # int literal or wire_id (str)
    op_b:   object       # int literal or wire_id (str)
    result: str          # wire_id for result (str)

def parse_fn_args(s):
    """
    Parse top-level args of vi:fn(...) — respects nested parens.
    Returns list of arg strings.
    e.g. 'vi:n32#5 vi:n32#3 2' -> ['vi:n32#5', 'vi:n32#3', '2']
    """
    args = []
    depth = 0
    current = ''
    for ch in s.strip():
        if ch == '(':
            depth += 1
            current += ch
        elif ch == ')':
            depth -= 1
            current += ch
        elif ch == ' ' and depth == 0:
            if current.strip():
                args.append(current.strip())
            current = ''
        else:
            current += ch
    if current.strip():
        args.append(current.strip())
    return args

def parse_literal(s):
    """
    Parse vi:n32#V -> integer V
    Returns int or None
    """
    m = re.match(r'vi:n32#(\d+)', s)
    if m:
        return int(m.group(1))
    return None

def parse_graft_line(line):
    """
    Parse: vi:graft[:name] = vi:fn(arg0 arg1 arg2...)
    Returns (graft_name, [args]) or None
    """
    m = re.match(r'\s*vi:graft\[([^\]]+)\]\s*=\s*vi:fn\((.+)\)\s*$', line.rstrip())
    if not m:
        # Handle multi-line fn — just skip for now
        return None
    name = m.group(1)
    args_str = m.group(2)
    args = parse_fn_args(args_str)
    return (name, args)

def extract_arith_ops(ir_text, target_net=''):
    """
    Extract arithmetic operations from the IR.
    Looks for vi:graft[:N32::add/mul/etc] = vi:fn(a b result) patterns.
    """
    ops = []

    # Find the main net block (first non-iv:main net or specified target)
    # For simplicity, scan all lines for graft patterns
    lines = ir_text.split('\n')

    i = 0
    while i < len(lines):
        line = lines[i]

        result = parse_graft_line(line)
        if result:
            name, args = result
            if name in GRAFT_TO_EXTOP:
                extop = GRAFT_TO_EXTOP[name]
                # args: [operand_a, operand_b, result_wire]
                if len(args) >= 3:
                    op_a_str = args[0]
                    op_b_str = args[1]
                    result_str = args[2]

                    # Parse operands — literal or wire
                    op_a = parse_literal(op_a_str)
                    if op_a is None:
                        op_a = op_a_str  # wire variable

                    op_b = parse_literal(op_b_str)
                    if op_b is None:
                        op_b = op_b_str  # wire variable

                    ops.append(ArithOp(
                        op=extop,
                        op_a=op_a,
                        op_b=op_b,
                        result=result_str
                    ))
                    print(f"[gen] found: {extop}({op_a}, {op_b}) -> wire {result_str}",
                          file=sys.stderr)
        i += 1

    return ops

# ---------------------------------------------------------------------------
# BSV code generation
# ---------------------------------------------------------------------------

def op_to_str(op):
    return {
        'EXT_ADD': 'add',
        'EXT_SUB': 'sub',
        'EXT_MUL': 'mul',
        'EXT_DIV': 'div',
        'EXT_REM': 'rem',
    }.get(op, op)

def generate_bsv(ops, result_val=None):
    """
    Generate BSV testbench for the given arithmetic operations.
    Each op gets: caller_fn, op_a_slot, op_b_slot, ext_slot, result_slot
    """
    if not ops:
        print("[gen] no arithmetic operations found", file=sys.stderr)
        return ""

    lines = []
    slot = 0
    load_calls = []
    pair_calls = []

    # Map wire variables to result slots
    wire_to_slot = {}

    # For each op, allocate slots
    op_info = []  # (fn_slot, a_slot, b_slot, ext_slot, res_slot, op)

    for op in ops:
        fn_slot  = slot;     slot += 1
        a_slot   = slot;     slot += 1
        b_slot   = slot;     slot += 1
        ext_slot = slot;     slot += 1
        res_slot = slot;     slot += 1

        # Map result wire to result slot
        wire_to_slot[op.result] = res_slot

        op_info.append((fn_slot, a_slot, b_slot, ext_slot, res_slot, op))

    # Generate load calls
    for (fn_slot, a_slot, b_slot, ext_slot, res_slot, op) in op_info:
        a_val = op.op_a if isinstance(op.op_a, int) else 0  # TODO: wire lookup
        b_val = op.op_b if isinstance(op.op_b, int) else 0

        load_calls.append(f"""
            // {op_to_str(op.op)}({a_val}, {b_val}) -> slot {res_slot}
            {fn_slot}: dut.load({fn_slot}, Node {{ tag: TAG_FN, val: 0,
                    port0: PortRef {{ node: {res_slot}, port: pPRINCIPAL() }},
                    port1: PortRef {{ node: {a_slot},   port: pPRINCIPAL() }},
                    port2: PortRef {{ node: {b_slot},   port: pPRINCIPAL() }},
                    port3: nullRef(), valid: True }});
            {a_slot}: dut.load({a_slot}, Node {{ tag: TAG_N32, val: {a_val},
                    port0: PortRef {{ node: {fn_slot}, port: pAUX0() }},
                    port1: nullRef(), port2: nullRef(),
                    port3: nullRef(), valid: True }});
            {b_slot}: dut.load({b_slot}, Node {{ tag: TAG_N32, val: {b_val},
                    port0: PortRef {{ node: {fn_slot}, port: pAUX1() }},
                    port1: nullRef(), port2: nullRef(),
                    port3: nullRef(), valid: True }});
            {ext_slot}: dut.load({ext_slot}, Node {{ tag: TAG_EXT,
                    val: zeroExtend(pack({op.op})),
                    port0: PortRef {{ node: {fn_slot}, port: pPRINCIPAL() }},
                    port1: PortRef {{ node: {a_slot},  port: pAUX0() }},
                    port2: PortRef {{ node: {b_slot},  port: pAUX1() }},
                    port3: nullRef(), valid: True }});
            {res_slot}: dut.load({res_slot}, Node {{ tag: TAG_INVALID, val: 0,
                    port0: nullRef(), port1: nullRef(),
                    port2: nullRef(), port3: nullRef(),
                    valid: False }});""")

        pair_calls.append(
            f"dut.enqPair(ActivePair {{ left: {fn_slot}, right: {ext_slot} }});"
        )

    total_slots = slot
    enq_idx = total_slots
    start_idx = total_slots + len(pair_calls)
    total_load = total_slots + len(pair_calls) + 1  # +1 for startReduction

    # Last result slot
    last_res = op_info[-1][4]
    last_op  = op_info[-1][5]
    a_val    = op_info[-1][5].op_a
    b_val    = op_info[-1][5].op_b

    load_cases = '\n'.join(load_calls)
    pair_cases = '\n'.join([
        f"            {enq_idx + i}: begin\n"
        f"                dut.enqPair(ActivePair {{ left: {fn}, right: {ext} }});\n"
        f"                $display(\"enq pair {fn} {ext} {op_to_str(op_info[i][5].op)}\");\n"
        f"            end"
        for i, (fn, a, b, ext, res, _) in enumerate(op_info)
    ])

    bsv = f"""// TestIntNets.bsv — generated by gen.py
// Source: Ivy IR arithmetic subgraph
// Operations: {', '.join(f"{op_to_str(o.op)}({o.op_a},{o.op_b})" for o in ops)}

package TestIntNets;

import IvyTypes::*;
import IvyHeap::*;
import IvyQueue::*;
import IntNets::*;

(* synthesize *)
module mkTestIntNets(Empty);

    IntNets_IFC dut <- mkIntNets();

    Reg#(Bit#(32)) cycle   <- mkReg(0);
    Reg#(Bit#(6))  loadIdx <- mkReg(0);

    rule rl_tick;
        cycle <= cycle + 1;
    endrule

    rule rl_load (loadIdx < {total_load});
        case (loadIdx)
{load_cases}
{pair_cases}
            {start_idx}: begin
                dut.startReduction();
                $display("starting reduction");
            end
            default: noAction;
        endcase
        loadIdx <= loadIdx + 1;
    endrule

    Reg#(Bool) checkPending <- mkReg(False);
    Reg#(Node) resultReg    <- mkReg(invalidNode());

    rule rl_read (dut.done() && !checkPending);
        resultReg    <= dut.readNode({last_res});
        checkPending <= True;
    endrule

    rule rl_check (dut.done() && checkPending);
        let result = resultReg;
        $display("DONE cycle %0d interactions %0d",
                 cycle, dut.interactions());
        $display("result slot {last_res} tag %0d val %0d",
                 pack(result.tag), result.val);
        if (result.tag == TAG_N32)
            $display("RESULT %0d", result.val);
        else
            $display("FAIL result slot is not N32 tag %0d", pack(result.tag));
        $finish();
    endrule

endmodule

endpackage
"""
    return bsv

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    show_only = '--show' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]

    if not args:
        print("Usage: gen.py [--show] <ivy_ir_file>", file=sys.stderr)
        sys.exit(1)

    with open(args[0]) as f:
        ir_text = f.read()

    ops = extract_arith_ops(ir_text)

    if not ops:
        print("[gen] no arithmetic operations found in IR", file=sys.stderr)
        sys.exit(1)

    print(f"[gen] extracted {len(ops)} arithmetic operation(s)", file=sys.stderr)

    if show_only:
        for op in ops:
            print(f"  {op.op}({op.op_a}, {op.op_b}) -> wire {op.result}")
        return

    bsv = generate_bsv(ops)
    print(bsv)

if __name__ == '__main__':
    main()
