# Stilla Runtime (Zig)

A Zig implementation of the **Stilla v1.2 runtime**: the embedding-host side
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
| [Stilla Core Language Specification - v1.2 Draft](spec/Stilla%20Core%20Language%20Specification%20-%20v1.2%20Draft.md) | Syntax and compile-time constraints: type system, ownership checking, generic specialization, static module rules, formal static semantics, grammar |
| [Stilla Runtime Specification - v1.2 Draft](spec/Stilla%20Runtime%20Specification%20-%20v1.2%20Draft.md) | The execution model this library implements: module instantiation, host environment, `builtin` interface, evaluation order, runtime destruction, termination and traps |
| [Stilla Standard Library - v1.2 Draft](spec/Stilla%20Standard%20Library%20-%20v1.2%20Draft.md) | Standard-library modules (e.g. `math`, `text`) and their contracts |

Where a behavior is described in both the Core and Runtime documents, the
**Runtime specification governs execution**.

## Library layout

`src/` mirrors the Runtime specification section-by-section so the long-term
work has a home:

| File | Runtime spec | Role |
| --- | --- | --- |
| [`src/root.zig`](src/root.zig) | — | Library root: public API surface and version |
| [`src/context.zig`](src/context.zig) | §1.3, §2, §8 | Execution context: owns module storage, provides `builtin`, unit of panic termination |
| [`src/module.zig`](src/module.zig) | §2 | Module instantiation and immutable module storage, keyed by specifier |
| [`src/host.zig`](src/host.zig) | §3 | Embedding-host contract: allocator, `builtin` implementation, host state |
| [`src/builtin.zig`](src/builtin.zig) | §4 | Required `builtin` interface (`print`, `len`, `panic`, …) as a host-supplied vtable |
| [`src/panic.zig`](src/panic.zig) | §7 | Termination and traps: `Panic` + `Termination` without unwinding |

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
