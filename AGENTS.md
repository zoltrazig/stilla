# AGENTS.md

Zig implementation of the Stilla v1.3 runtime and Stilla-to-CFG-AIR compiler. Use Zig 0.16.0, as required by `build.zig.zon`.

## Commands

- `zig build -fincremental` installs `zig-out/lib/libstilla.a` and `zig-out/bin/stilla`.
- `zig build -fincremental --release=safe` builds the same artifacts with ReleaseSafe optimizations.
- `zig build -fincremental test` runs the complete library and CLI test suite; prefer this before finishing. CI (`.github/workflows/ci.yml`) runs it with `-Doptimize=ReleaseSafe`, then builds the toolchain and runs `python3 tools/stsmith/sweep.py`.
- `zig fmt src/` formats sources. Run it before `zig fmt --check src/`; the tree is currently format-clean.
- `zig build -fincremental run -- examples/fib.st` compiles one Stilla source to CFG AIR on stdout; with no input it defaults to `examples/fib.st`.
- `zig build -fincremental examples` always regenerates AIR, LLIR assembly, and LLIR binary artifacts under `zig-out/examples/` and prints their sizes.
- CLI options must precede the input file. Important forms are `--output <file>`, `--emit-asm`, `--emit-bin <file>`, `--module <spec>`, `--entry-fn <name>`, `--no-entry-fn`, `-I <dir>`, `--seg` (enable the M2a SEG pass, off by default), and `--run`. `--emit-bin` cannot be combined with `--emit-asm` or `--output`.

## Conventions

- Use `std.ArrayList`, never `std.ArrayListUnmanaged`: in Zig 0.16 the latter is deprecated (`/// Deprecated; use ArrayList.` in `std/std.zig`) and `std.ArrayList` is the unmanaged-style container that takes the allocator per call. A few call sites (`effects.zig`, `hir.zig`, `passes/hir_effects.zig`) still use the old name; migrate new code to `std.ArrayList` and don't grow that surface.

## Testing

- `zig test src/lex_tests.zig` works standalone (it only pulls in `lex.zig` and `ast.zig`). Most other `*_tests.zig` files fail standalone: they transitively import `src/passes/*` and `src/parse/*` files whose `@import("stilla")` self-import and embedded `stilla_std_sources` module exist only under `build.zig`'s module wiring (`--dep` cannot attach to the main module from the CLI). Run those through `zig build test`.
- Add every new `*_tests.zig` to the `test {}` block in `root.zig` (alongside `std.testing.refAllDecls(@This())`) so it runs under `zig build test`.
- Put white-box tests in the owning module's `test {}` blocks. Put black-box or cross-module tests in the matching `*_tests.zig` file and import it from `root.zig`.
- Frontend coverage is intentionally split by pipeline area. Reuse `frontend_test_support.zig`; place LLIR tests in the existing core, ops, immediate, wide, branch, validation, normalization, assembly, or binary suite rather than growing `frontend_tests.zig`.

## Workflow

- Update the relevant documentation before implementing code.
- In prose, reference source and test files by filename, not repository path. Reference documents by filename rather than section number.
- Do not use `std.debug.print` for runtime or compiler output because stderr may be interpreted as an error. Use an explicit writer or output sink; the build-only examples summary in `build.zig` is the existing exception.

## Architecture

- `root.zig` is the static-library root; `main.zig` is the compiler CLI. `build.zig` produces both artifacts and owns all test wiring.
- Drivers are thin: `moduleinfo.zig` builds the module graph, checker passes annotate and validate it, `hir_build.zig` builds the HIR, `hir_effects.zig` annotates it, `hir_seg.zig` runs the optional M2a SEG pass, `lower.zig` produces CFG AIR, CFG passes optimize and lower drops, and LLIR passes lower, validate, assemble, and serialize it.
- Keep one pass per file under `parse/` or `passes/`. Subdirectory passes import top-level modules through `@import("stilla")`, whose self-import is configured in `build.zig`.
- CFG AIR data structures live in `cfg.zig`; its lexer, parser, printer, optimizer, validator, and lowerings live in pass files. The format and pipeline are documented in `air.md` and `frontend.md`; the canonical pass order is `passes.md`, the system map `architecture.md` (index: `docs/README.md`).
- Standard-library sources (`std/*.st`) are compile-time embedded via `std/bundle.zig` and surfaced through the table in `src/stdbundle.zig`. Add each new `*.st` module to both files.
- The specifications under `spec/` are normative. Where Core and Runtime disagree about execution, Runtime governs.
