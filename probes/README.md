# Compiler probes

Small Stilla programs that isolate CFG AIR and LLIR shapes. Each `.st` file
must compile independently with the current compiler; probes are inputs for IR
regression tests and manual inspection, not user-facing examples.

The detailed probes cover the source-reachable operation/type matrix:

- `numeric.st`: register arithmetic and unary negation for all six numeric types
- `integer_bits.st`: shifts and bitwise operations for all four integer types
- `immediates.st`: integer immediate arithmetic, shifts, masks, and comparisons
- `comparisons.st`: value and branch comparisons for numeric, byte, bool, and str
- `casts.st`: all 20 non-identity casts among byte, int32, uint32, float32, and float64
- `fusion.st`: multiply-add fusion for every numeric representation and integer
  immediate forms that are reachable from source
- `aggregates.st`, `union_match.st`, and `list_match.st`: construction and projection
- `patterns.st`: literal, exact-list, rest-list, shorthand struct, and multi-payload
  union patterns
- `any.st`: copy/move packing, type tests, and copy/move recovery
- `calls.st`, `tail_recursion.st`, and `ownership.st`: calls, argument modes, returns,
  tail calls, retain/release, move, borrow, and drop
- `lifecycle.st`: automatic aggregate and temporary destruction plus conditional moves
- `generic.st` and `generic_aggregates.st`: inferred and explicit function specialization,
  first-class specialization, and generic structs, unions, and aliases
- `box.st`: Copy and Unique box construction and extraction through `builtin` intrinsics
- `branch.st`, `short_circuit.st`, and `control_flow.st`: joins, short-circuit branches,
  void conditionals, and `never` branches
- `strings.st`: string concatenation and comparison
- `constants.st`: scalar constants, including 64-bit values that exercise move-wide
  materialization

Some LLIR instructions have no one-to-one source construct. `spill_take`,
`spill_put`, `result_take`, argument-window instructions, `jal`/`jalr`/`jr`,
`auipc`, `lui`, long-branch inversions, and replacement/release variants are
selected by register allocation, calling convention, relaxation, or ownership
normalization. `msub` is currently present in the LLIR ISA but is not selected
by the source-to-LLIR fusion pass. The control-flow and call probes exercise
some backend selectors, but exact opcode coverage belongs in the synthetic LLIR
tests because allocator and optimizer choices may change without changing
source semantics.

Compile one probe to CFG AIR:

```sh
zig build run -- probes/branch.st
```

Use `--emit-asm` or `--emit-bin <path>` to exercise the later IR stages. The
CLI enables optimization by default, including immediate and fusion selection.
