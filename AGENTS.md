# AGENTS.md

Zig implementation of the Stilla v1.3 runtime and Stilla-to-CFG-AIR compiler. Use Zig 0.16.0, as required by `build.zig.zon`.

## Commands

- `zig build -fincremental` installs `zig-out/lib/libstilla.a` and `zig-out/bin/stilla`.
- `zig build -fincremental --release=safe` builds the same artifacts with ReleaseSafe optimizations.
- `zig build -fincremental test` runs the complete library and CLI test suite; prefer this before finishing. Adding `-Dtest-filter=<name>` (repeatable) reruns only matching unit tests. CI (`.github/workflows/ci.yml`) runs it with `-Doptimize=ReleaseSafe`, then builds the toolchain and runs `python3 tools/stsmith/sweep.py`.
- `zig fmt src/` formats sources. Run it before `zig fmt --check src/`; the tree is currently format-clean.
- `zig build -fincremental run -- examples/fib.st` compiles one Stilla source to CFG AIR on stdout; with no input it defaults to `examples/fib.st`.
- `zig build -fincremental examples` always regenerates AIR, LLIR assembly, and LLIR binary artifacts under `zig-out/examples/` and prints their sizes.
- CLI options must precede the input file. Important forms are `--output <file>`, `--emit-hir`, `--emit-asm`, `--emit-bin <file>`, `--module <spec>`, `--entry-fn <name>`, `--no-entry-fn`, `-I <dir>`, `--opt <name>` / `--no-opt <name>` (toggle a field of `OptimizeConfig`, last occurrence wins; the executable defaults to `seg` and `cfg` on, `hir` off, and every sub-toggle on), `--opt-list` (list every toggle and its default), and `--run`. The emission modes (`--emit-hir`, `--emit-asm`, `--emit-bin`) are mutually exclusive; `--emit-bin` and `--run` cannot be combined with `--output`, and `--run` cannot be combined with `--no-entry-fn`.

## Conventions

- Use `std.ArrayList`, never `std.ArrayListUnmanaged`: in Zig 0.16 the latter is deprecated (`/// Deprecated; use ArrayList.` in `std/std.zig`) and `std.ArrayList` is the unmanaged-style container that takes the allocator per call. `effects.zig` is fully migrated; the HIR side (`hir.zig`, `passes/hir_build.zig`, `passes/hir_effects.zig`, `passes/hir_parse.zig`, `passes/hir_print.zig`, `passes/hir_seg.zig`, `passes/hir_simplify.zig`, `passes/hir_validate.zig`, `hir_seg_tests.zig`) still uses the old name; migrate new code to `std.ArrayList` and don't grow that surface.

## Testing

- Work narrow, then wide: run the affected suite with `-Dtest-filter=<name>` (repeatable) first, and only run the full `zig build -fincremental test` once it passes.
- Always redirect the full run so its output survives for inspection: `zig build -fincremental test > /tmp/stilla-test.log 2>&1`, then grep the log for failures instead of re-running (Zig prints `error:`/`FAIL` lines and a summary count).
- `zig test src/lex_tests.zig` works standalone (it only pulls in `lex.zig` and `ast.zig`). Most other `*_tests.zig` files fail standalone: they transitively import `src/passes/*` and `src/parse/*` files whose `@import("stilla")` self-import and embedded `stilla_std_sources` module exist only under `build.zig`'s module wiring (`--dep` cannot attach to the main module from the CLI). Run those through `zig build test`.
- Add every new `*_tests.zig` to the `test {}` block in `root.zig` (alongside `std.testing.refAllDecls(@This())`) so it runs under `zig build test`.
- Put white-box tests in the owning module's `test {}` blocks. Put black-box or cross-module tests in the matching `*_tests.zig` file and import it from `root.zig`.
- Frontend coverage is intentionally split by pipeline area. Reuse `frontend_test_support.zig`; place LLIR tests in the existing core, ops, immediate, wide, branch, validation, normalization, assembly, or binary suite rather than growing `frontend_tests.zig`.
- `probes/*.st` is the dynamic smoke corpus (`probe_corpus.zig` enumerates it at test time); every probe must compile, run, and agree under the consumers/SEG differentials. `frontend_pass_smoke_tests.zig` pushes each probe through every transform/optimization pass. Put whole-program black-box fixtures that are not runnable corpus members (host bindings, traps, intentional diagnostics) under `probes/cases/` and read them with `frontend_test_support.probeSource` or `probe_corpus.read` instead of constructing Stilla source inline.
- A new pass, consumer, or rewrite needs a `probes/*.st` that actually triggers it, not merely one it runs over — compare the AIR with the pass on and off. Add a bullet for the probe in `probes/README.md`. A probe whose `main` intentionally traps must also be listed in `probe_corpus.panics`, and one that prints must do so deterministically, because the consumers/SEG on/off differentials compare output verbatim.
- `zig build test` reports per-test wall-clock timings through the custom simple-mode runner in `test_runner.zig`, wired for the library (`root.zig`), CLI (`main.zig`), and stsmith (`gen.zig`) test roots. As each test finishes the runner prints `[i/N] <name> ... OK (<ms> ms)` (status `OK`/`SKIP`/`FAIL`) to stderr, then the counts and a top-20 slowest-tests table. Simple mode bypasses the test server protocol, so the build-level `N/M tests passed` summary and progress tree are intentionally absent and the runner prints its own counts instead. `-Dtest-filter=<name>` is unaffected. The runner's `std.debug.print` is a deliberate exception to the runtime-output rule above: under simple mode the test step inherits stdio, so the runner's stdout and stderr are the terminal (the old server-mode runner instead used stdout as its `--listen` IPC pipe).

## Workflow

- Update the relevant documentation before implementing code.
- In prose, reference source and test files by filename, not repository path. Reference documents by filename rather than section number.
- Do not reference ephemeral planning artifacts — `plan.md`, `docs/todo.md`, `PROGRESS.md`, `TODO.md`, or milestone/stage/phase labels such as `M2b`, `S5`, or `Phase 7` — from code, tests, or design docs. Comments and docs describe the system, not the work history: cite a design document by filename and section (`hir.md` §11, `effects.md` §14), or name the concrete module, pass, or test. Keep that vocabulary out of identifiers, comments, doc-comments, test names, and diagnostic strings.
- Do not use `std.debug.print` for runtime or compiler output because stderr may be interpreted as an error. Use an explicit writer or output sink; the build-only examples summary in `build.zig` is the existing exception.

## Architecture

- `root.zig` is the static-library root; `main.zig` is the compiler CLI. `build.zig` produces both artifacts and owns all test wiring.
- Drivers are thin: `moduleinfo.zig` builds the module graph, checker passes annotate and validate it, `hir_build.zig` builds the HIR, `hir_effects.zig` annotates it, `hir_seg.zig` runs the optional SEG pass, `lower.zig` produces CFG AIR, CFG passes optimize and lower drops, and LLIR passes lower, validate, assemble, and serialize it.
- Keep one pass per file under `parse/` or `passes/`. Subdirectory passes import top-level modules through `@import("stilla")`, whose self-import is configured in `build.zig`.
- CFG AIR data structures live in `cfg.zig`; its lexer, parser, printer, optimizer, validator, and lowerings live in pass files. The format and pipeline are documented in `air.md` and `frontend.md`; the canonical pass order is `passes.md`, the system map `architecture.md` (index: `docs/README.md`).
- Standard-library sources (`std/*.st`) are compile-time embedded via `std/bundle.zig` and surfaced through the table in `src/stdbundle.zig`. Add each new `*.st` module to both files.
- The specifications under `spec/` are normative. Where Core and Runtime disagree about execution, Runtime governs.
