# AGENTS.md

Zig implementation of the Stilla v1.3 runtime and Stilla-to-CFG-AIR compiler. Use Zig 0.16.0, as required by `build.zig.zon`.

## Commands

- `zig build -fincremental` installs `zig-out/lib/libstilla.a` and `zig-out/bin/stilla`.
- `zig build -fincremental --release=safe` builds the same artifacts with ReleaseSafe optimizations.
- `zig build -fincremental test` runs the complete library and CLI test suite; prefer this before finishing.
- `zig fmt src/` formats sources. Run it before `zig fmt --check src/`; some files were historically not format-clean.
- `zig build -fincremental run -- examples/fib.st` compiles one Stilla source to CFG AIR on stdout.
- `zig build -fincremental examples` always regenerates AIR, LLIR assembly, and LLIR binary artifacts under `zig-out/examples/` and prints their sizes.
- CLI options must precede the input file. Important forms are `--output <file>`, `--emit-asm`, `--emit-bin <file>`, `--module <spec>`, `--entry-fn <name>`, `--no-entry-fn`, and `-I <dir>`. `--emit-bin` cannot be combined with `--emit-asm` or `--output`.

## Testing

- `zig test src/lex_tests.zig` works standalone, as do `module_tests.zig`, `context_tests.zig`, `host_tests.zig`, `builtin_tests.zig`, and `panic_tests.zig`.
- Other suites require `zig build test`: their `@import("stilla")` self-import and embedded `stilla_std_sources` module are wired only by `build.zig`.
- Put white-box tests in the owning module's `test {}` blocks. Put black-box or cross-module tests in the matching `*_tests.zig` file and import it from `root.zig`.
- Frontend coverage is intentionally split by pipeline area. Reuse `frontend_test_support.zig`; place LLIR tests in the existing core, ops, immediate, wide, branch, validation, normalization, assembly, or binary suite rather than growing `frontend_tests.zig`.

## Workflow

- Update the relevant documentation before implementing code.
- In prose, reference source and test files by filename, not repository path. Reference documents by filename rather than section number.
- Do not use `std.debug.print` for runtime or compiler output because stderr may be interpreted as an error. Use an explicit writer or output sink; the build-only examples summary is the existing exception.

## Architecture

- `root.zig` is the static-library root; `main.zig` is the compiler CLI. `build.zig` produces both artifacts and owns all test wiring.
- Drivers are thin: `moduleinfo.zig` builds the module graph, checker passes annotate and validate it, `lower.zig` produces CFG AIR, CFG passes optimize and lower drops, and LLIR passes lower, validate, assemble, and serialize it.
- Keep one pass per file under `parse/` or `passes/`. Subdirectory passes import top-level modules through `@import("stilla")`, whose self-import is configured in `build.zig`.
- CFG AIR data structures live in `cfg.zig`; its lexer, parser, printer, optimizer, validator, and lowerings live in pass files. The format and pipeline are documented in `air.md` and `frontend.md`; the canonical pass order is `passes.md`, the system map `architecture.md` (index: `docs/README.md`).
- Standard-library sources are compile-time embedded. Add each new `*.st` module to both `bundle.zig` and `stdbundle.zig`.
- The specifications under `spec/` are normative. Where Core and Runtime disagree about execution, Runtime governs.
