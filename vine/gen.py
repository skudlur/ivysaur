#!/usr/bin/env python3
"""
gen.py v3 — Ivy IR to BSV loader generator with correct wire resolution

Wire resolution rules:
  Each wire variable appears exactly twice in the IR.
  Wire table maps wire_id -> [(slot, port_idx), (slot, port_idx)]
  The two endpoints of a wire point at each other via PortRef.

For chained arithmetic:
  vi:graft[:N32::add] = vi:fn(vi:n32#5 vi:n32#3 2)  -- result on wire 2
  vi:graft[:N32::mul] = vi:fn(2 vi:n32#2 3)          -- operand a = wire 2

  Wire 2 connects: add's result slot <-> mul's operand_a slot
  After wire resolution:
    add_result.port0 = {mul_a_slot, pPRINCIPAL}
    mul_a.port0      = {add_result_slot, pPRINCIPAL}
"""

import re
import sys
from dataclasses import dataclass, field
from typing import Optional, List, Tuple, Dict

# Port indices
pPRINCIPAL = 0
pAUX0      = 1
pAUX1      = 2
pAUX2      = 3

PORT_BSV = {
    pPRINCIPAL: 'pPRINCIPAL()',
    pAUX0:      'pAUX0()',
    pAUX1:      'pAUX1()',
    pAUX2:      'pAUX2()',
}

GRAFT_TO_EXTOP = {
    ':root::numeric::N32::add': ('EXT_ADD', 0),
    ':root::numeric::N32::sub': ('EXT_SUB', 1),
    ':root::numeric::N32::mul': ('EXT_MUL', 2),
    ':root::numeric::N32::div': ('EXT_DIV', 3),
    ':root::numeric::N32::rem': ('EXT_REM', 4),
}

EXTOP_STR = ['EXT_ADD', 'EXT_SUB', 'EXT_MUL', 'EXT_DIV', 'EXT_REM']

def portref(slot, port_idx):
    return f'PortRef {{ node: {slot}, port: {PORT_BSV[port_idx]} }}'

def nullref():
    return 'nullRef()'

# ---------------------------------------------------------------------------
# IR parsing helpers
# ---------------------------------------------------------------------------

def parse_fn_args(s):
    args = []
    depth = 0
    current = ''
    for ch in s.strip():
        if ch in '([':
            depth += 1
            current += ch
        elif ch in ')]':
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
    m = re.match(r'^vi:n32#(\d+)$', s.strip())
    return int(m.group(1)) if m else None

def is_wire(s):
    return re.match(r'^\d+$', s.strip()) is not None

def parse_graft_line(line):
    m = re.match(r'\s*vi:graft\[([^\]]+)\]\s*=\s*vi:fn\((.+)\)\s*$',
                 line.rstrip())
    if not m:
        return None
    return (m.group(1), parse_fn_args(m.group(2)))

def parse_dup_line(line):
    """
    Parse a fan-out equation of the form:
        vi:dup(<w0> <w1>) = vi:n32#<V>
    meaning: literal V is duplicated onto wires w0 and w1 (each of which
    is an operand of a downstream op). Returns (w0, w1, V) or None.
    """
    m = re.match(r'\s*vi:dup\((\d+)\s+(\d+)\)\s*=\s*vi:n32#(\d+)\s*$',
                 line.rstrip())
    if not m:
        return None
    return (m.group(1), m.group(2), int(m.group(3)))

# ---------------------------------------------------------------------------
# Graph nodes
# ---------------------------------------------------------------------------

@dataclass
class Node:
    slot:  int
    tag:   str          # TAG_FN TAG_N32 TAG_EXT TAG_INVALID
    val:   int = 0
    valid: bool = True
    # PortRefs — filled in during wire resolution
    port0: str = ''
    port1: str = ''
    port2: str = ''
    port3: str = 'nullRef()'

# ---------------------------------------------------------------------------
# Build graph from IR
# ---------------------------------------------------------------------------

def build_graph(ir_text):
    """
    Parse IR, allocate slots, build wire table.
    Wire table: wire_id -> [(slot, port_idx), ...]
    Only registers the TWO meaningful endpoints per wire.
    """
    nodes     = []         # list of Node
    wires     = {}         # wire_id -> [(slot, port_idx)]
    pairs     = []         # arithmetic pairs (fn, ext, res, a, b)
    dup_pairs = []         # fan-out pairs (lit_slot, dup_slot)
    slot_ctr  = [0]

    def alloc():
        s = slot_ctr[0]
        slot_ctr[0] += 1
        return s

    def reg_wire(wire_id, slot, port_idx):
        """Register one endpoint of a wire."""
        if wire_id not in wires:
            wires[wire_id] = []
        wires[wire_id].append((slot, port_idx))

    # Reserve slot 0 as the null node. nullRef() == {node:0,port:0} and the
    # engine treats node 0 as "no connection", so no real node may live there.
    nodes.append(Node(slot=alloc(), tag='TAG_INVALID', val=0, valid=False))

    lines = ir_text.split('\n')

    for line in lines:
        result = parse_graft_line(line)
        if not result:
            continue
        name, args = result

        info = GRAFT_TO_EXTOP.get(name)
        if not info:
            continue
        extop_str, extop_int = info

        if len(args) < 3:
            continue

        arg_a_str = args[0]
        arg_b_str = args[1]
        arg_r_str = args[2]

        # Allocate core slots
        fn_slot  = alloc()  # fn node (caller)
        ext_slot = alloc()  # ext node
        res_slot = alloc()  # result wire slot

        # Operand a
        lit_a = parse_literal(arg_a_str)
        if lit_a is not None:
            a_slot = alloc()
            nodes.append(Node(slot=a_slot, tag='TAG_N32', val=lit_a, valid=True))
        elif is_wire(arg_a_str):
            a_slot = alloc()
            # This slot IS the wire — it will receive a value from another op
            nodes.append(Node(slot=a_slot, tag='TAG_INVALID', val=0, valid=False))
            # Register: this wire's second endpoint is a_slot (fn reads from here)
            reg_wire(arg_a_str, a_slot, pPRINCIPAL)
        else:
            a_slot = alloc()
            nodes.append(Node(slot=a_slot, tag='TAG_INVALID', val=0, valid=False))

        # Operand b
        lit_b = parse_literal(arg_b_str)
        if lit_b is not None:
            b_slot = alloc()
            nodes.append(Node(slot=b_slot, tag='TAG_N32', val=lit_b, valid=True))
        elif is_wire(arg_b_str):
            b_slot = alloc()
            nodes.append(Node(slot=b_slot, tag='TAG_INVALID', val=0, valid=False))
            reg_wire(arg_b_str, b_slot, pPRINCIPAL)
        else:
            b_slot = alloc()
            nodes.append(Node(slot=b_slot, tag='TAG_INVALID', val=0, valid=False))

        # Result slot — the wire variable result points to
        nodes.append(Node(slot=res_slot, tag='TAG_INVALID', val=0, valid=False))
        # Register: res_slot is the FIRST endpoint of this result wire
        if is_wire(arg_r_str):
            reg_wire(arg_r_str, res_slot, pPRINCIPAL)

        # fn node (ports filled later)
        nodes.append(Node(slot=fn_slot, tag='TAG_FN', val=0, valid=True))
        # ext node
        nodes.append(Node(slot=ext_slot, tag='TAG_EXT', val=extop_int, valid=True))

        pairs.append((fn_slot, ext_slot, res_slot, a_slot, b_slot))

        print(f"[gen] {extop_str}({arg_a_str}, {arg_b_str}) -> wire {arg_r_str} "
              f"fn={fn_slot} ext={ext_slot} res={res_slot} a={a_slot} b={b_slot}",
              file=sys.stderr)

    # Second pass: fan-out (vi:dup) equations.
    # A dup duplicates a literal onto two wires, each an operand of an op
    # parsed above. We register the dup's two outputs as the second
    # endpoints of those operand wires so resolve() links them.
    for line in lines:
        dup = parse_dup_line(line)
        if not dup:
            continue
        w0, w1, val = dup

        lit_slot = alloc()   # the literal being duplicated
        dup_slot = alloc()   # the dup node

        # literal <-> dup principal-to-principal (the active pair)
        nodes.append(Node(slot=lit_slot, tag='TAG_N32', val=val, valid=True,
                          port0=portref(dup_slot, pPRINCIPAL)))
        nodes.append(Node(slot=dup_slot, tag='TAG_DUP', val=0, valid=True,
                          port0=portref(lit_slot, pPRINCIPAL)))

        # dup's two outputs are the second endpoints of wires w0, w1
        reg_wire(w0, dup_slot, pAUX0)
        reg_wire(w1, dup_slot, pAUX1)

        dup_pairs.append((lit_slot, dup_slot))

        print(f"[gen] DUP n32#{val} -> wires {w0},{w1} "
              f"lit={lit_slot} dup={dup_slot}", file=sys.stderr)

    return nodes, wires, pairs, dup_pairs, slot_ctr[0]

# ---------------------------------------------------------------------------
# Wire resolution — set PortRefs on all nodes
# ---------------------------------------------------------------------------

def resolve(nodes, wires, pairs):
    """
    Set port0/port1/port2 on every node based on:
    1. Direct fn/ext connections (always the same structure)
    2. Wire table for cross-op connections
    """
    slot_to_node = {n.slot: n for n in nodes}

    # Step 1: resolve wire connections
    # Each wire should have exactly 2 endpoints
    for wire_id, endpoints in wires.items():
        if len(endpoints) == 2:
            (s0, p0), (s1, p1) = endpoints
            # s0's p0 port points to s1 at p0's back-index
            # s1's p1 port points to s0 at p1's back-index
            n0 = slot_to_node.get(s0)
            n1 = slot_to_node.get(s1)
            if n0:
                # Update s0's port p0 to point at s1
                pr = portref(s1, p0)
                if   p0 == pPRINCIPAL: n0.port0 = pr
                elif p0 == pAUX0:      n0.port1 = pr
                elif p0 == pAUX1:      n0.port2 = pr
            if n1:
                pr = portref(s0, p1)
                if   p1 == pPRINCIPAL: n1.port0 = pr
                elif p1 == pAUX0:      n1.port1 = pr
                elif p1 == pAUX1:      n1.port2 = pr
        elif len(endpoints) != 0:
            print(f"[gen] WARNING wire {wire_id} has {len(endpoints)} endpoints: {endpoints}",
                  file=sys.stderr)

    # Step 2: set direct fn/ext port connections
    for (fn_slot, ext_slot, res_slot, a_slot, b_slot) in pairs:
        fn  = slot_to_node[fn_slot]
        ext = slot_to_node[ext_slot]
        a   = slot_to_node[a_slot]
        b   = slot_to_node[b_slot]
        res = slot_to_node[res_slot]

        # fn.port0 -> res_slot (result consumer)
        # fn.port1 -> a_slot
        # fn.port2 -> b_slot
        fn.port0 = portref(res_slot, pPRINCIPAL)
        fn.port1 = portref(a_slot,   pPRINCIPAL)
        fn.port2 = portref(b_slot,   pPRINCIPAL)
        fn.port3 = portref(ext_slot, pPRINCIPAL)  # back-ref to ext partner

        # ext.port0 -> fn (active pair)
        # ext.port1 -> a_slot (operand a)
        # ext.port2 -> b_slot (operand b)
        ext.port0 = portref(fn_slot,  pPRINCIPAL)
        ext.port1 = portref(a_slot,   pAUX0)
        ext.port2 = portref(b_slot,   pAUX1)
        ext.port3 = nullref()

        # a_slot back-pointer: always points to owner fn via pAUX0
        # regardless of whether it's a literal or wire operand
        a.port0 = portref(fn_slot, pAUX0)
        a.port1 = nullref()
        a.port2 = nullref()
        a.port3 = nullref()

        # b_slot back-pointer: always points to owner fn via pAUX1
        b.port0 = portref(fn_slot, pAUX1)
        b.port1 = nullref()
        b.port2 = nullref()
        b.port3 = nullref()

        # res slot: back-pointer to fn (wire resolution may have already set this)
        if not res.port0:
            res.port0 = nullref()
        res.port1 = nullref()
        res.port2 = nullref()
        res.port3 = nullref()

    # Fill any remaining empty ports
    for n in nodes:
        if not n.port0: n.port0 = nullref()
        if not n.port1: n.port1 = nullref()
        if not n.port2: n.port2 = nullref()
        if not n.port3: n.port3 = nullref()

# ---------------------------------------------------------------------------
# BSV code generation
# ---------------------------------------------------------------------------

def node_to_bsv(n):
    """Generate dut.load() call for one node."""
    tag = n.tag
    valid = 'True' if n.valid else 'False'

    if tag == 'TAG_N32':
        return (f"dut.load({n.slot}, Node {{ tag: TAG_N32, val: {n.val},\n"
                f"                    port0: {n.port0},\n"
                f"                    port1: nullRef(), port2: nullRef(),\n"
                f"                    port3: nullRef(), valid: True }});")
    elif tag == 'TAG_FN':
        return (f"dut.load({n.slot}, Node {{ tag: TAG_FN, val: 0,\n"
                f"                    port0: {n.port0},\n"
                f"                    port1: {n.port1},\n"
                f"                    port2: {n.port2},\n"
                f"                    port3: {n.port3}, valid: True }});")
    elif tag == 'TAG_EXT':
        extop = EXTOP_STR[n.val] if n.val < len(EXTOP_STR) else 'EXT_ADD'
        return (f"dut.load({n.slot}, Node {{ tag: TAG_EXT,\n"
                f"                    val: zeroExtend(pack({extop})),\n"
                f"                    port0: {n.port0},\n"
                f"                    port1: {n.port1},\n"
                f"                    port2: {n.port2},\n"
                f"                    port3: nullRef(), valid: True }});")
    elif tag == 'TAG_DUP':
        return (f"dut.load({n.slot}, Node {{ tag: TAG_DUP, val: 0,\n"
                f"                    port0: {n.port0},\n"
                f"                    port1: {n.port1},\n"
                f"                    port2: {n.port2},\n"
                f"                    port3: nullRef(), valid: True }});")
    else:  # TAG_INVALID
        return (f"dut.load({n.slot}, Node {{ tag: TAG_INVALID, val: 0,\n"
                f"                    port0: {n.port0},\n"
                f"                    port1: nullRef(), port2: nullRef(),\n"
                f"                    port3: nullRef(), valid: False }});")

def generate_bsv(nodes, pairs, dup_pairs, total_slots):
    sorted_nodes = sorted(nodes, key=lambda n: n.slot)

    load_cases = '\n'.join(
        f"            {n.slot}: {node_to_bsv(n)}"
        for n in sorted_nodes
    )

    enq_start = total_slots
    slot_to_node = {n.slot: n for n in nodes}

    # Initial active pairs to enqueue:
    #   - arithmetic ops where BOTH operands are literals (fire immediately)
    #   - fan-out ops: (literal, dup) — the dup fires, then the engine
    #     enqueues the downstream op once both copies have landed.
    # Wire operands receive their value via propagation first.
    init_pairs = []
    for (fn, ext, res, a, b) in pairs:
        a_node = slot_to_node.get(a)
        b_node = slot_to_node.get(b)
        if (a_node and a_node.tag == 'TAG_N32' and
            b_node and b_node.tag == 'TAG_N32'):
            init_pairs.append((fn, ext))
    init_pairs.extend(dup_pairs)

    enq_cases = '\n'.join(
        f"            {enq_start + i}: begin\n"
        f"                dut.enqPair(ActivePair {{ left: {l}, right: {r} }});\n"
        f"                $display(\"enq pair {l} {r}\");\n"
        f"            end"
        for i, (l, r) in enumerate(init_pairs)
    )

    start_idx  = enq_start + len(init_pairs)
    total_load = start_idx + 1

    last_res = pairs[-1][2]

    return f"""// TestIntNets.bsv — generated by gen.py v3
// Wire resolution: bidirectional PortRef assignment

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
{enq_cases}
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
            $display("FAIL result not N32 tag %0d", pack(result.tag));
        $finish();
    endrule

endmodule

endpackage
"""

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

    nodes, wires, pairs, dup_pairs, total_slots = build_graph(ir_text)

    if not pairs:
        print("[gen] no arithmetic operations found", file=sys.stderr)
        sys.exit(1)

    resolve(nodes, wires, pairs)

    print(f"[gen] {len(pairs)} op(s), {len(dup_pairs)} dup(s), "
          f"{len(nodes)} nodes, {len(wires)} wires", file=sys.stderr)

    if show_only:
        print("\nWire table:")
        for w, eps in wires.items():
            print(f"  wire {w}: {eps}")
        print("\nNodes:")
        for n in sorted(nodes, key=lambda x: x.slot):
            print(f"  slot {n.slot}: {n.tag} val={n.val} "
                  f"p0={n.port0} p1={n.port1} p2={n.port2}")
        print("\nActive pairs:")
        for fn, ext, res, a, b in pairs:
            print(f"  fn={fn} ext={ext} res={res} a={a} b={b}")
        return

    bsv = generate_bsv(nodes, pairs, dup_pairs, total_slots)
    print(bsv)

if __name__ == '__main__':
    main()
