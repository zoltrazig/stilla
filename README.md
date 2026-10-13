# Stilla Runtime (Zig)

[![CI](https://img.shields.io/github/actions/workflow/status/zoltrazig/stilla/ci.yml?style=flat-square&label=CI)](https://github.com/zoltrazig/stilla/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-blue?style=flat-square)](https://zoltrazig.github.io/)
[![Docs zh](https://img.shields.io/badge/docs-zh-blue?style=flat-square)](https://zoltrazig.github.io/zh/)

A Zig implementation of the **Stilla v1.3 runtime** and its toolchain: the
frontend compiler (module graph → type-checked CFG AIR → LLIR assembly and
binary), the interpreter VM that executes it, and the host-embedding surface
that connects both to a Zig or C host.

> Caveat: Almost all code in this program is Vibe Coded with DeepSeek V4 Flash.
> DON'T PANIC.

## Project status

`zig build -fincremental test` is green on HEAD. The checklist below is a
code-level survey of what actually exists in `src/`; items are grouped by
subsystem, and the trailing section lists what the code and docs still mark
open.

**Language frontend: source → CFG AIR**

- [x] **Lexer, AST, parser** — grammar sub-parsers (`parse/`), binding-power
  expression parsing, per-module diagnostic collection with recovery
- [x] **Module graph** — multi-file import resolution (embedded `std/` bundle
  and `-I` search dirs), cycle detection, topological ordering, host-binding
  classification (`moduleinfo` and the `module_*` passes)
- [x] **Type checker** — inference, ownership analysis with conditional
  release and state merging, generic monomorphization, `any`/union/tuple/list
- [x] **HIR seam** — checker output built into the canonical monomorphic HIR
  (`hir_build`, with full-expression cleanup registration split into
  `hir_build_cleanup`), structurally validated, annotated with effect
  summaries (`hir_effects` / `effects`), and lowered from there
  (`hir_lower`); canonical text printer/parser for round-trip checks
  ([hir.md](docs/hir.md), [effects.md](docs/effects.md))
- [x] **Effect model** — resource/control `EffectSummary` lattice
  (`effects_lattice`) over a pluggable provider engine (`effects_engine`),
  resource registry (`effects_registry`), host metadata and environment
  fingerprint (`effects_host`), conflict queries (`effects_conflict`), and
  canonical hashing (`effects_hash`); `effect_transfer`, function-summary
  SCC least fixpoint with incremental caching (`hir_effects_cache`),
  `OperandUse`, the cleanup-aware legality queries (`discardable` /
  `duplicable` / `isSegSafe` …), per-node annotation validation, precise
  `drop_effect(T)`, and the summary-driven module-const init/teardown check
  ([effects.md](docs/effects.md))
- [x] **SEG v1** — registry `seg` encoding facet and recursive island
  admission over `isSegSafe`, rewriting through a slotted e-graph arena
  (`hir_egraph`): an e-class table with union-find, island-wide slot
  numbering, and `encode` → stable-order saturation → extraction, carrying
  α-equivalence/CSE sharing, integer AC search, constant folding, constant
  `if`, and aggregate projection as union rules; the boundary rewrites
  (β→let, η, let simplification, known-variant `match`→let) are admitted
  by typed contracts (`rewrite_contract`) with post-rewrite effect
  re-validation (`hir_seg`; the `seg` gate is on by default in the
  executable and off in the library, so `--no-opt seg` opts out and
  library `OptimizeConfig.seg` opts in, [hir.md](docs/hir.md) §8, §11)
- [x] **CFG lowering** — control flow, `match`/patterns, field paths, calls,
  intrinsic (`builtin`) expansion, destruction placement, module init
  functions, syscalls
- [x] **CFG AIR** — lexer/parser/printer round-trip; a structural validator
  runs on every lowered program
- [x] **Mid-level optimizer** — the `cfg` gate with per-rewrite
  sub-toggles: tail-call, inline, CSE, copy-prop, PRE, if-convert,
  dead-block, drop-elide, dead-instr, jump-threading, phi-simplify;
  constant folding during emit; drop expansion
- [x] **Frontend cache** — per-module, dependency-tracked, keyed on a
  `SemanticKey` (specifier + content hash + effect-environment
  fingerprint) and recording the last compile's fingerprint

**LLIR backend: CFG → frozen image → bytes**

- [x] **Instruction set** — fixed-width 4-byte `Instr` in five formats, a
  ~271-opcode table with per-op schemas, `zero`/`ra`/`cond` registers, the
  frame/call contract, side-table records
- [x] **Eleven-stage lowering** — prepare, allocation, lifecycle plan, edge
  blocks, budget, intern, body/edge/control emit, fusion, linearize
- [x] **Validation, assembly, binary** — `llir_validate`, `llir_asm`, and
  `llir_emit_bin` + reader (`readBin`) round-trip; `--run` loads and
  structure-validates a binary before executing

**Runtime and embedding**

- [x] **Interpreter** — raw-`u64`-cell LLIR execution: i32/u32/i64/u64/f32/f64,
  bool, `any`; deterministic evaluation and destruction; panics as owned
  messages
- [x] **Lifecycle** — counted-value release placement, per-module destruction,
  cleanup tokens, user `drop` hooks
- [x] **Host layers** — signature-checked comptime registry, derived `.st`
  interfaces, syscalls, `builtin.print` output hook (no runtime default)
- [x] **Loader & artifacts** — dependency-order instantiation, host modules,
  `VmLoadedData`/`VmRuntimeState` split, `artifact_bundle` build-once/run-many
- [x] **Embedding** — `frontend.compile` + `runWithHostAndLoader`,
  `random_demo.zig`, `libstilla.a` static library
- [x] **CLI** — compile to canonical HIR / CFG AIR / LLIR assembly / LLIR
  binary; `--run` (source or self-contained binary);
  `--module`/`--entry-fn`/`--no-entry-fn`/`-I`; `--opt <name>` /
  `--no-opt <name>` config toggles (`seg` and `cfg` on, `hir` off by
  default) and `--opt-list` to print every toggle with its default

**Standard library (embedded `std/` source)**

- [x] **Modules** — `math`, `string`, `array`, `list`, `iter`, `hashmap`,
  `builtin`, compiled as ordinary Stilla alongside user code
- [x] **Host adapters** — `array`/`hashmap` backed by Zig host modules

**Tools and tests**

- [x] ~30 per-area suites (frontend, checker, optimizer, LLIR
  ops/wide/branch/normalize/validate/asm/bin, interpreter
  scalar/lifecycle/image/load/host, cache) plus ownership-fusion tests
- [x] Grammar→AST conformance suite over the normative ABNF and spec examples
- [x] **stsmith** — randomized, self-checking program generator with a
  seed-sweep harness
- [x] CLI end-to-end probes (exit-code contract, `--emit-bin` round-trip)

**Still open** — the remaining work is catalogued in [docs/roadmap.md](docs/roadmap.md).

## What is Stilla?

Stilla is a small, statically typed language for embedded scripting,
deterministic execution, host integration, and machine-generated code.
Its design is visible from the source: immutable bindings, explicit
ownership (`borrow` / `move`, no GC), deterministic left-to-right
evaluation and destruction, algebraic data types, and statically resolved
modules (Core §1.2).

This repository implements what a conforming implementation must *do* when
a program runs (the runtime), what an embedding host must provide (the host
contract), and the compiler that turns Stilla source into executable AIR —
in Zig.

## Specifications

The normative documents live in [`spec/`](spec/):

| Document | Covers |
| --- | --- |
| [Stilla Core Language Specification](spec/Stilla%20Core%20Language%20Specification.md) | v1.3 Draft — syntax and compile-time constraints (type system, ownership, generics, module rules, semantics, grammar) |
| [Stilla Runtime Specification](spec/Stilla%20Runtime%20Specification.md) | v1.3 Draft — the execution model: module instantiation, host environment, `builtin` interface, evaluation order, destruction, traps |
| [Stilla Standard Library](spec/Stilla%20Standard%20Library.md) | v1.3 Draft — standard-library modules (e.g. `math`, `text`) and their contracts |
| [Stilla Intrinsics Specification](spec/Stilla%20Intrinsics%20Specification.md) | v1.3 Draft — frontend recognition and mandatory AIR expansion before LLIR |
| [Stilla Core Grammar](spec/Stilla%20Core%20Grammar%20Draft.abnf) | Normative ABNF grammar (RFC 5234) for the core language |

Where Core and Runtime disagree about execution, the **Runtime
specification governs**.

## Documentation

The implementation documents live in [`docs/`](docs/) (indexed by
[docs/README.md](docs/README.md)):

| Document | Covers |
| --- | --- |
| [architecture.md](docs/architecture.md) | End-to-end map: artifacts, pipeline, boundaries, host embedding |
| [passes.md](docs/passes.md) | Ordered inventory of every pass, with links to the detail documents |
| [roadmap.md](docs/roadmap.md) | Open work: planned, spec-blocked, and intentionally-deferred items |
| [frontend.md](docs/frontend.md) | The compiler pipeline end to end: module graph → checker → CFG lowering → optimizer → LLIR backend |
| [module-graph.md](docs/module-graph.md) | Module identity, resolution, loading, cycle detection, topo sort |
| [checker.md](docs/checker.md) | Inference, generic expansion, ownership analysis, checks |
| [cfg-lowering.md](docs/cfg-lowering.md) | HIR → CFG AIR; destruction placement, module init functions |
| [optimizer.md](docs/optimizer.md) | Tail-call elimination, inlining, CSE, copy propagation, and the mid-level rewrites |
| [llir-typed.md](docs/llir-typed.md) | The typed LLIR lowering layer |
| [host-bindings.md](docs/host-bindings.md) | The typed host-binding layer: comptime registry, signature checks, embedding |
| [interpreter-vm.md](docs/interpreter-vm.md) | The LLIR interpreter VM: instruction image, execution loop, host adapters, destruction |

## Build and test

Requires **Zig 0.16.0** (see `build.zig.zon`).

```sh
zig build -fincremental           # build + install both artifacts:
                                   #   zig-out/bin/stilla      — the compiler/interpreter CLI
                                   #   zig-out/lib/libstilla.a — the embeddable static library
zig build -fincremental examples   # compile every examples/*.st to AIR, LLIR asm, and LLIR bin under zig-out/examples/
zig build -fincremental embed      # run the host-embedding example (examples/embed/random_demo.zig)
zig build -fincremental test       # run unit tests
zig build -fincremental test -Dtest-filter=<name>   # rerun only matching unit tests (repeatable)
```

For consumers that link the static library (C, C++, …):

```sh
zig build -fincremental --release=safe -p <prefix>   # install libstilla.a under <prefix>
```

## The `stilla` executable

A single executable (`main.zig`) that is both the **frontend
compiler** and the **interpreter**: it parses a Stilla source file (plus
its imports, resolved against the embedded `std/` bundle), expands the
embedded-bundle intrinsics into ordinary AIR, and prints the program's
**CFG AIR** text form:

```sh
zig build -fincremental run -- app.st              # compile app.st, print CFG AIR to stdout
zig-out/bin/stilla --output app.ir app.st
```

```text
module "app" {
    func @app.main() -> int32 {
    entry:
        %0: int32 = const 42
        ret %0
    }
}
```

With `--emit-hir` the compiler instead prints the canonical HIR it built
before CFG lowering ([hir.md](docs/hir.md) §4): one
`// @<module>.<name>`-labeled, canonical-text root expression per
function. The dump is a concatenation of roots, not a single parseable
HIR expression, and it is an inspection surface whose printer still
rejects the few node forms with no member-carrying text (below).

```sh
zig-out/bin/stilla --emit-hir app.st
```

```text
// @app.init
fn () {
  void
}

// @app.main
fn () {
  42i32
}
```

Options: `--output <file>`, `--module <spec>`, `--entry-fn <name>` /
`--no-entry-fn`, `-I <dir>`, `--opt <name>` / `--no-opt <name>`
(per-field toggles for `OptimizeConfig`; the executable defaults to
`seg` and `cfg` on, `hir` off, all sub-toggles on,
[hir.md](docs/hir.md) §11), `--opt-list` (print every toggle and its
default, with each gate's sub-toggles nested beneath it), and the
emission modes
`--emit-hir` (the canonical HIR text form, [hir.md](docs/hir.md) §4),
`--emit-asm`, `--emit-bin <file>`, and `--run` (compile and execute).
Diagnostics are
`<file>:<line>:<col>: error: <message>`. The pipeline and the LLIR
backend it lowers to are documented in [frontend.md](docs/frontend.md)
and [interpreter-vm.md](docs/interpreter-vm.md). `--emit-hir` fails loudly
rather than degrade: the printer's serialization boundary rejects only
value-position module access chains (the node forms with no
member-carrying text), so a program using one reports the offending
function and exits 1 with no output written. `struct_make`, `field_get`,
and `variant_make` serialize through their result type and member bracket
([hir.md](docs/hir.md) §4.4).

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

Then wire it in `build.zig`:

```zig
const stilla = b.dependency("stilla", .{ .target = target, .optimize = optimize });
// module.addImport("stilla", stilla.module("stilla"));
```

And in Zig source, the compile-and-run path (what the CLI takes):

```zig
const stilla = @import("stilla");

// Compile: entry module → CFG AIR. Diagnostics arrive as
// `compilation.diag(s)` (file:line:col).
var compilation = try stilla.frontend.compile(allocator, .{ .entry = "app.st" });
defer compilation.deinit();
const program = &(compilation.program orelse return error.CompileFailed);

// Lower to per-module LLIR artifacts and run from the entry export.
// `term` is a `Termination`: `.normal` (the root's return cell) or
// `.panic` (an owned message to report).
var bundle = try stilla.artifact_bundle.ArtifactBundle.build(allocator, program);
var term = try stilla.interpreter.runWithHostAndLoader(allocator, &bundle.root, .{}, bundle.loaderHandle());
defer term.deinit(allocator);
```

### Defining host functions

The runnable example is `random_demo.zig` — `zig build -fincremental
embed` builds it, runs it, and reports the round trip. The blocks below
are quoted from that file (it is the example; this README only annotates
it). The embedder gives Stilla a `random` host module: one `pub fn` per
member, module state injected as the leading `*Rng` parameter (never a
Stilla parameter):

```zig
/// The module's state: injected as the leading `*Rng` parameter of
/// every member.
const Rng = struct { prng: std.Random.DefaultPrng, io: std.Io, ... };

/// The host module: `pub const symbol` names the module; every `pub fn`
/// is a member binding.
const random = struct {
    pub const symbol = "random";

    pub fn next(rng: *Rng) i32 {
        const v = rng.prng.random().int(i32);
        rng.record(v);
        return v;
    }

    /// Uniform draw in [0, max).
    pub fn int(rng: *Rng, max: i32) i32 {
        const v = rng.prng.random().intRangeLessThan(i32, 0, max);
        rng.record(v);
        return v;
    }

    /// Reseed the module's PRNG — state mutated from Stilla.
    pub fn seed(rng: *Rng, s: i32) void {
        rng.prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(@as(i64, s))));
    }

    /// Host time (seconds since the Unix epoch) — host information
    /// flowing into the program, read through the embedding's Io.
    pub fn time(rng: *Rng) i32 { ... }
};
const random_desc: host_bind.ModuleDesc = host_bind.register(random);
const random_iface = host_bind.interfaceOf(random, "");
```

`register` derives the sorted, signature-checked member table; the
**interface** — the `.st` text the frontend checks the program's call
sites against — is derived from the same Zig signatures by
`interfaceOf`, so the two can't drift. Stilla accesses it as an ordinary
imported module:

```stilla
const random = import("random");
const builtin = import("builtin");
fn main() -> int32 {
    random.seed(random.time());
    let a = random.next();
    let b = random.int(6);
    builtin.print("draw a");
    builtin.print(builtin.str(a));
    a + b
}
```

Then compile, lower, and run through the two-stage embed path
(`buildProgram` builds the source/interface maps, compiles, lowers, and
merges the module into the default host registry; `runProgram` executes
the built program, so one build runs many times):

```zig
var failed: stilla.frontend.Compilation = undefined;
var built = try stilla.interpreter.buildProgram(arena, .{
    .entry = "app",
    .sources = &.{.{ .specifier = "app", .text = APP }},
    .ifaces  = &.{.{ .specifier = "random", .text = random_iface }},
    .modules = &.{.{ .desc = &random_desc, .userdata = &rng }},
    .entry_fn = "main",
    .print = .{ .userdata = &print_sink, .invoke = appPrint },
}, &failed);
const term = try stilla.interpreter.runProgram(arena, &built);
```

`builtin.print` has no runtime default — the embedder supplies the
output hook (`appPrint` above writes message + newline to stdout). The
program's `main` returns `a + b`, which the example then verifies
against the draws the host observed. See [host-bindings.md](docs/host-bindings.md) for the full walkthrough;
`random_demo.zig` is the verbatim source.

### As a C embedder

Stilla is designed for host integration. The static library artifact
(`libstilla.a`) is the linking surface for hosts written in other
languages; the public Zig API is the source of truth for now.

## License

MIT — see [LICENSE](LICENSE).
