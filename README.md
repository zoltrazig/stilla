# Stilla Runtime (Zig)

A Zig implementation of the **Stilla v1.3 runtime** and its toolchain: the
frontend compiler (module graph → type-checked CFG AIR → LLIR assembly and
binary), the interpreter VM that executes it, and the host-embedding surface
that connects both to a Zig or C host.

> Caveat: Almost all code in this program is Vibe Coded with DeepSeek V4 Flash.
> DON'T PANIC.

## Project status

`zig build test` is green on HEAD. The checklist below is a code-level
survey of what actually exists in `src/`; items are grouped by subsystem,
and the trailing section lists what the code and docs still mark open.

**Language frontend: source → CFG AIR**

- [x] **Lexer, AST, parser** — grammar sub-parsers (`parse/`), binding-power
  expression parsing, per-module diagnostic collection with recovery
- [x] **Module graph** — multi-file import resolution (embedded `std/` bundle
  and `-I` search dirs), cycle detection, topological ordering, host-binding
  classification (`moduleinfo` + `passes/module_*`)
- [x] **Type checker** — inference, ownership analysis with conditional
  release and state merging, generic monomorphization, `any`/union/tuple/list
- [x] **CFG lowering** — control flow, `match`/patterns, field paths, calls,
  intrinsic (`builtin`) expansion, destruction placement, module init
  functions, syscalls
- [x] **CFG AIR** — lexer/parser/printer round-trip; a structural validator
  runs on every lowered program
- [x] **Mid-level optimizer** — tail-call, inline, CSE, copy-prop, PRE,
  if-convert, dead-block, drop-elide, dead-instr, jump-threading,
  phi-simplify; constant folding during emit; drop expansion
- [x] **Frontend cache** — per-module, dependency-tracked

**LLIR backend: CFG → frozen image → bytes**

- [x] **Instruction set** — fixed-width 4-byte `Instr` in six formats, a
  ~270-opcode table with per-op schemas, `zero`/`ra`/`cond` registers, the
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
  `examples/embed/random_demo.zig`, `libstilla.a` static library
- [x] **CLI** — compile to AIR / LLIR assembly / LLIR binary; `--run` (source
  or self-contained binary); `--module`/`--entry-fn`/`--no-entry-fn`/`-I`

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

**Still open** (from code and docs)

- [ ] Hot-reload is designed for but the reload entry point is not wired
  (interpreter_loader.zig)
- [ ] The `movwz*`/`movwn*`/`movwk*` I-format rows exist but the frontend
  lowering does not emit them yet (longer forms are compiled instead)
- [ ] `select` does not yet participate in CSE (optimizer.md §8.4 follow-up)
- [ ] Inferred tuple/list elements can still carry a module value; §2.3 not
  closed for container positions (phase2-checker.md)
- [ ] Only the Zig API is public for embedding — no C header yet

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
| [stilla-intro.md](docs/stilla-intro.md) | The language and its design, for new readers |
| [architecture.md](docs/architecture.md) | End-to-end map: artifacts, pipeline, boundaries, host embedding |
| [passes.md](docs/passes.md) | Canonical ordered pass inventory, with links to the detail documents |
| [frontend.md](docs/frontend.md) | The compiler pipeline end to end: phase-1 module graph → phase-2 checker → phase-3 CFG AIR → LLIR backend |
| [phase1-module-graph.md](docs/phase1-module-graph.md) | Phase 1: module identity, resolution, cycle detection, topo sort |
| [phase2-checker.md](docs/phase2-checker.md) | Phase 2: inference, generic expansion, ownership analysis, checks |
| [phase3-cfg-lowering.md](docs/phase3-cfg-lowering.md) | Phase 3: annotated AST → CFG AIR, destruction placement, module init functions |
| [optimizer.md](docs/optimizer.md) | Passes 7–8: tail-call elimination, inlining, CSE, copy propagation, and the mid-level rewrites |
| [llir-typed.md](docs/llir-typed.md) | The typed LLIR lowering layer |
| [host-bindings.md](docs/host-bindings.md) | The typed host-binding layer: comptime registry, signature checks, embedding |
| [interpreter-vm.md](docs/interpreter-vm.md) | The LLIR interpreter VM: instruction image, execution loop, host adapters, destruction |

## Build and test

Requires **Zig 0.16.0** (see `build.zig.zon`).

```sh
zig build            # build + install both artifacts:
                     #   zig-out/bin/stilla      — the compiler/interpreter CLI
                     #   zig-out/lib/libstilla.a — the embeddable static library
zig build examples   # compile every examples/*.st to AIR, LLIR asm, and LLIR bin under zig-out/examples/
zig build embed      # run the host-embedding example (examples/embed/random_demo.zig)
zig build test       # run unit tests
```

For consumers that link the static library (C, C++, …):

```sh
zig build -Doptimize=ReleaseSafe -p <prefix>   # install libstilla.a under <prefix>
```

## The `stilla` executable

A single executable (`src/main.zig`) that is both the **frontend
compiler** and the **interpreter**: it parses a Stilla source file (plus
its imports, resolved against the embedded `std/` bundle), expands the
embedded-bundle intrinsics into ordinary AIR, and prints the program's
**CFG AIR** text form:

```sh
zig build run -- app.st              # compile app.st, print CFG AIR to stdout
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

Options: `--output <file>`, `--module <spec>`, `--entry-fn <name>` /
`--no-entry-fn`, `-I <dir>`, and the emission modes `--emit-asm`,
`--emit-bin <file>`, and `--run` (compile and execute). Diagnostics are
`<file>:<line>:<col>: error: <message>`. The pipeline is documented in
[frontend.md](docs/frontend.md); the LLIR backend it lowers to is in
[frontend.md](docs/frontend.md) and [interpreter-vm.md](docs/interpreter-vm.md).

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

The runnable example is `examples/embed/random_demo.zig` — `zig build
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
against the draws the host observed. See
[host-bindings.md](docs/host-bindings.md) §3.4 for the full walkthrough;
`examples/embed/random_demo.zig` is the verbatim source.

### As a C embedder

Stilla is designed for host integration. The static library artifact
(`libstilla.a`) is the linking surface for hosts written in other
languages; the public Zig API is the source of truth for now.

## License

MIT — see [LICENSE](LICENSE).
