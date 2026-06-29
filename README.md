# ivysaur

**Interaction-net reduction in hardware.** A study that takes [Ivy](https://github.com/VineLang/vine)
interaction-net programs and reduces them on a reduction core written in
[Bluespec](https://github.com/B-Lang-org/bsc) (BSV), driving the central thesis:

> **Bluespec's guarded atomic rules are interaction-net rewrite rules.**
> An active pair is a rule guard; a rewrite is a rule body; linearity is the
> invalidation of consumed slots. You write the *semantics* and the bsc
> scheduler hands you the *microarchitecture*, including parallelism, for free.

This repo is a personal study built to understand the Vine/Ivy/IVM stack from
the hardware side.

---

## What's here

```
vine/                 front end: Ivy programs, IR, and the lowering pass
  *.vi                Vine source programs
  *.ir                their Ivy `vi:` IR (vine --target none)
  gen.py              lowering pass: Ivy IR -> BSV loader (TestIntNets.bsv)
  notes/note.org      reasoning about the IR and the BSV mapping

bsv_src/              the hardware
  IvyTypes.bsv        node / port / tag data model (the PortRef pointer model)
  IntNets.bsv         sequential reduction engine (full rule set)
  IntNetsPar.bsv      parallel reduction core (concurrent rule firing)
  IvyQueue.bsv        active-pair FIFO
  IvyHeap.bsv         parameterised node heap
  TestIntNets.bsv     generated testbench (from gen.py)
  TestIntNetsPar.bsv  parallel-core testbench (two independent chains)
  sim/                Verilator harnesses
  Makefile            build + run
```

---

## The pipeline

```
Vine source            let c = (5 + 3) * 2 - 1;
    |  vine compiler
vi: IR                 vi:graft[:N32::add] = vi:fn(vi:n32#5 vi:n32#3 2)   (typed, human-readable)
    |  gen.py           (lowering pass; the eventual home for this is a --target bsv in the Ivy compiler)
BSV loader             dut.load(slot, Node {...});                        (heap image)
    |  bsc + Verilator
reduction core         FETCH -> EXEC -> DRAIN -> DETECT                   (rewrite until no active pairs)
    |
result                 RESULT 15
```

---

## Quick start

Requires `bsc` (Bluespec compiler) and `verilator` on `PATH`.

```sh
cd bsv_src
make            # sequential core: runs chain3 = (5+3)*2-1, prints RESULT 15
make par        # parallel core: two independent chains, prints PAR PASS
```

Regenerate the sequential testbench from any Ivy IR file:

```sh
make gen FILE=../vine/chain2.ir     # (5+3)*2 = 16
make gen FILE=../vine/dup_add.ir    # 5 + 5 = 10, via a vi:dup fan-out
make
```
