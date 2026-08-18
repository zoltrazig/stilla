# Stilla Runtime (Zig)

A Zig implementation of the **Stilla v1.3 runtime**: the embedding-host side
of the Stilla execution model — execution contexts, module instantiation,
the `builtin` interface, deterministic evaluation, runtime destruction,
and panic/trap semantics.

> **Status:** early skeleton. The library builds, tests, and exposes the
> architecture; the runtime itself is a long-term project.

## What is Stilla?

Stilla is a small, statically typed language designed for embedded
scripting, deterministic execution, host integration, and machine-generated
code. Its design is visible from the source code: immutable bindings,
explicit ownership (`borrow` / `move`, no GC), deterministic
left-to-right evaluation, deterministic destruction, algebraic data types,
and statically resolved modules. See the language's design principles in
Core §1.2.

This repository implements the **runtime** half of the language — what a
conforming implementation must *do* when a program runs, and what an
embedding host must provide — in Zig.

## Specifications

The normative documents live in [`spec/`](spec/):

| Document | Covers |
| --- | --- |
| [Stilla Core Language Specification](spec/Stilla%20Core%20Language%20Specification.md) | v1.3 Draft — syntax and compile-time constraints: type system, ownership checking, generic specialization, static module rules, formal static semantics, grammar (version recorded inside) |
| [Stilla Runtime Specification](spec/Stilla%20Runtime%20Specification.md) | v1.3 Draft — the execution model this library implements: module instantiation, host environment, `builtin` interface, evaluation order, runtime destruction, termination and traps (version recorded inside) |
| [Stilla Standard Library](spec/Stilla%20Standard%20Library.md) | v1.3 Draft — standard-library modules (e.g. `math`, `text`) and their contracts (version recorded inside) |
| [Stilla Core Grammar](spec/Stilla%20Core%20Grammar%20Draft.abnf) | Normative ABNF grammar (RFC 5234) for the core language — the lexical and syntactic productions and their descriptive notes (version recorded inside: v1.3 Draft) |

Where a behavior is described in both the Core and Runtime documents, the
**Runtime specification governs execution**.

## Library layout

`src/` mirrors the Runtime specification section-by-section so the long-term
work has a home:

| File | Runtime spec | Role |
| --- | --- | --- |
| [`src/root.zig`](src/root.zig) | — | Library root: public API surface and version |
| [`src/context.zig`](src/context.zig) | §1.3, §2, §8 | Execution context: owns module storage, instantiates standard-library modules (`builtin` included), unit of panic termination |
| [`src/module.zig`](src/module.zig) | §2 | Module instantiation and immutable module storage, keyed by specifier |
| [`src/host.zig`](src/host.zig) | §3 | Embedding-host contract: allocator, `builtin` implementation, host state |
| [`src/builtin.zig`](src/builtin.zig) | §4 | Required `builtin` interface (`print`, `panic`, …) as a host-supplied vtable |
| [`src/panic.zig`](src/panic.zig) | §7 | Termination and traps: `Panic` + `Termination` without unwinding |
| [`src/ast.zig`](src/ast.zig) | — (compile-time) | Source spans, line index, AST node types, and diagnostics |
| [`src/lex.zig`](src/lex.zig) | — (compile-time) | Lexer for the core language grammar: source text → tokens |
| [`src/parser.zig`](src/parser.zig) | — (compile-time) | LL(k) parser: token stream → AST |
| [`src/passes/checker.zig`](src/passes/checker.zig) | — (compile-time) | Phase-2 type checker (phase2-checker.md): per-module annotation (name/type/ownership/expression side tables), generic expansion via `monomorphize.zig`, and the phase-2 checks — type mismatch, match exhaustiveness, refutable patterns, non-capture, borrow lifetimes, module-const init order, recursive types without indirection, and drop-hook destruction-view restrictions |
| [`src/passes/`](src/passes/) | — (compile-time) | The pass implementations, one file per pass: phase-1 module graph (`module_load`…`module_check`, `topo_sort`), type resolution (`type_resolve`, `type_shape`, `type_infer`), phase-2 annotation and checks (`checker`, `checker_annotate`, `checker_validate`, `checker_ownership`, `monomorphize`), CFG lowering (`cfg_lower_*`; `cfg_lower_emit` also runs the on-the-fly constant folding / arithmetic simplification / CSE / copy propagation of braun13cc.pdf §3.1), the mid-level optimizer (`cfg_optimize`, `cfg_pre`, `cfg_dead_block`, `cfg_tail_call`), and the IR text form's lexer, parser, and printer (`cfg_lex`, `cfg_parse`, `cfg_print`, re-exported by `cfg`) |
| [`src/moduleinfo.zig`](src/moduleinfo.zig) | — (compile-time) | Module graph construction (frontend phase 1): `Builder`, `ModuleInfo`, `ModuleGraph`, specifier resolution, member-table materialization (type-resolution helpers re-exported from `src/passes/type_resolve.zig`) |
| [`src/frontend.zig`](src/frontend.zig) | — (compile-time) | Frontend pipeline driver: entry module → phase-1 graph → phase-3 `cfg.IrProgram` (`Compilation`) |
| [`src/cfg.zig`](src/cfg.zig) | — (compile-time) | The CFG IR data structures of ir.md §11 (text lexer/parser/printer re-exported from `src/passes/`) |
| [`src/lower.zig`](src/lower.zig) | — (compile-time) | CFG lowering (frontend phase 3): annotated AST + module graph → `cfg.IrProgram`, destruction placement, module init functions |
| [`src/stdbundle.zig`](src/stdbundle.zig) + [`std/bundle.zig`](std/bundle.zig) | — (compile-time) | The embedded standard library: every `std/*.st` source registered as a specifier→source row |

## Build and test

Requires **Zig 0.16.0** (see `build.zig.zon`).

```sh
zig build            # build + install the static library (zig-out/lib/libstilla.a)
zig build test       # run unit tests
zig build test --summary all   # same, with the full step tree
```

For consumers (C, C++, or any host that can link a static library):

```sh
zig build -Doptimize=ReleaseSafe -p <prefix>   # install libstilla.a under <prefix>
```

## The frontend compiler

Alongside the library, the build produces a **frontend compiler**
(`src/main.zig`): it parses a Stilla source file (plus its imports, resolved
against the embedded `std/` bundle) and prints the program's **CFG IR** in
the ir.md §9 text form — the contract the runtime side consumes.

```sh
zig build run -- app.st              # compile app.st, print CFG IR to stdout
zig-out/bin/stilla app.st --output app.ir
```

```text
module "app" {
    func @app.main() -> int32 {
    entry:
        %0: int32 = const 0
        %1: int32 = const 10
        %2: list[int32] = syscall list#range, %0, %1
        %3: int32 = syscall list#len, %2
        ret %3
    }
}
```

Options: `--output <file>` writes to a file, `--module <spec>` overrides the
module specifier (default: the input file's stem), and `--entry-fn <name>` /
`--no-entry-fn` selects or suppresses the host entry function (default
`main`). Diagnostics are `<file>:<line>:<col>: error: <message>`.

The pipeline is documented in [`frontend.md`](frontend.md): phase 1 builds
the module graph (`src/moduleinfo.zig`, with the import-ordering algorithm
in `src/passes/topo_sort.zig`), phase 2 annotates and checks every module
(`src/passes/checker.zig` + `checker_annotate.zig` + `checker_validate.zig`
+ `checker_ownership.zig` + `monomorphize.zig`), and phase 3 lowers the
annotated AST to the CFG structures of ir.md §11 (`src/lower.zig`,
`src/cfg.zig`; the IR text form's lexer, parser, and printer live in
`src/passes/cfg_lex.zig` / `src/passes/cfg_parse.zig` /
`src/passes/cfg_print.zig`, re-exported by `cfg`). A mid-level optimizer is
planned: Pass 7 rewrites calls in tail position into frame-reusing jumps so
self-recursion becomes iteration (`src/passes/cfg_tail_call.zig`), and Pass
8 (`src/passes/cfg_optimize.zig`) runs semantics-preserving rewrites —
constant folding, common subexpression elimination, partial redundancy
elimination, copy propagation, dead-block elimination, drop elision, and
phi simplification — one file per rewrite under `src/passes/`.

## Using the library

### As a Zig dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .stilla = .{
        .url = "https://github.com/<you>/stilla/archive/<commit>.tar.gz",
        .hash = "<hash from `zig build --fetch`>",
    },
},
```

Then import and use it in `build.zig`:

```zig
const stilla = b.dependency("stilla", .{
    .target = target,
    .optimize = optimize,
});
// module.addImport("stilla", stilla.module("stilla"));
```

And in Zig source:

```zig
const stilla = @import("stilla");
const runtime = stilla.context; // execution context, module storage, builtin vtable, ...
```

### As a C embedder

Stilla is designed for host integration. The static library artifact
(`libstilla.a`) is the linking surface for hosts written in other
languages; the public Zig API is the source of truth for now.

## License

MIT — see [LICENSE](LICENSE).
