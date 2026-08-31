//! Stilla runtime — a Zig implementation of the Stilla v1.3 execution
//! model, as defined by the *Stilla Runtime Specification - v1.3 Draft*
//! in `spec/`.
//!
//! Status: early skeleton. The module layout mirrors the Runtime
//! specification's sections so that the long-term work has a home:
//!
//! - `host`    — host environment contract (Runtime §3)
//! - `stdbundle` — the `std/` standard-library bundle: declaration-only
//!               host-binding modules embedded at compile time (frontend
//!               §3.2, §5.6)
//! - `ast`     — source spans and AST nodes for diagnostics (compile-time)
//! - `lex`     — lexer: source text → tokens (compile-time)
//! - `parser`  — LL(k) parser: token stream → AST (compile-time)
//! - `cfg`     — the AIR (air.md): data structures plus the text-form
//!               parser and canonical printer (compile-time)
//! - `checker` — type checker and AST annotator (compile-time). Current
//!               status: name/type inference, ownership analysis including
//!               conditional release (phase2-checker.md, Ownership analysis; Core §10.10),
//!               generic specialization with monomorphized instances
//!               (phase2-checker.md, Generic expansion), and the phase-2 consumer checks; the
//!               remaining phase-2 checks are future work (phase2-checker.md)
//! - `moduleinfo` — module graph construction (frontend Phase 1): member
//!                tables, import resolution, cycle detection, topological
//!                sort, type resolution
//! - `lower`   — CFG lowering (frontend Phase 3): annotated AST + module
//!               graph → `cfg.IrProgram`
//! - `frontend` — the pipeline driver: entry module → AIR
//! - `interpreter` — the raw-`u64`-cell LLIR interpreter VM
//!               (docs/interpreter-vm.md): the structurally validated
//!               image, interpreted in place → `Termination`. Split
//!               into `interpreter_types` (shared records and the
//!               runtime state `VmRuntimeState`),
//!               `interpreter_loader` (runtime module loading and the
//!               loaded data — `VmLoadedData` and the loader functions),
//!               `interpreter_dispatch`
//!               (per-opcode handlers), and `interpreter_host` (run API
//!               + host adapters).
//! - `vm_types`    — raw VM cells and scalar/non-scalar value encoding
//! - `llir`    — the phase-1 frozen LLIR model
//!               (spec/Stilla LLIR Instruction Set.md, spec/Stilla
//!               LLIR Specification.md): the
//!               4-byte v9 `Instr` (`[4]u8`, six formats), the 234-strong logical `Opcode` table with
//!               per-opcode schemas, reps, and the shared
//!               `encode`/`decode`, the
//!               special registers (`zero`/`ra`/`cond`), the frame/call contract, descriptors and
//!               side-table records; no interpreter (lowering, validation,
//!               and assembly live in `passes`)
//! - `passes`  — the pass algorithms split out of the pipeline files, one
//!               file per pass (frontend.md §4), imported directly by the
//!               pipeline files and re-exported where they replace former
//!               in-file logic: the module-graph passes (`module_load`,
//!               `module_scan`, `topo_sort`, `module_materialize`,
//!               `module_check`), the type-resolution passes
//!               (`type_resolve`, `type_shape`, `type_infer`), the
//!               annotator (`checker`, with `checker_annotate`,
//!               `checker_validate`, `checker_ownership` — the
//!               conditional-release and state-merging analysis — and the
//!               generic-expansion pass `monomorphize`), the CFG-lowering
//!               passes
//!               (`cfg_lower_program`, `cfg_lower_module`, `cfg_lower_func`,
//!               `cfg_lower_expr`, `cfg_lower_control`, `cfg_lower_call`,
//!               `cfg_lower_pattern`, `cfg_lower_path`, `cfg_lower_emit`,
//!               `cfg_lower_validate`), the CFG-optimization passes
//!               (`cfg_optimize`, `cfg_pre`; constant folding, arithmetic
//!               simplification, CSE, and copy propagation run on-the-fly
//!               inside `cfg_lower_emit`), the post-optimization drop-lowering
//!               pass (`cfg_lower_drop`), the LLIR-lowering driver
//!               (`cfg_lower_llir` — the CFG → fixed-width LLIR
//!               conversion of the Stilla LLIR specifications,
//!               orchestrated by `Builder.lowerLlir` as eleven named
//!               stages in fixed order: prepare (`cfg_lower_llir_prepare`
//!               — dense-ID allocation), allocate (`llir_alloc` — type-
//!               constrained linear-scan value→slot mapping with the
//!               frame layout numbers), lifecycle plan
//!               (`cfg_lower_lifecycle` — counted-value release
//!               placement), edge blocks (`cfg_lower_llir_edges.planBlocks`
//!               — an LLIR-only edge block per effect-bearing outgoing
//!               edge), budget (per-block record sizing with
//!               deferred PCs), intern (`cfg_lower_llir_intern` —
//!               side-table serialization),
//!               body emit (`cfg_lower_llir_emit`), edge emit
//!               (`cfg_lower_llir_edges`), control emit
//!               (`cfg_lower_llir_control`) (every record into its
//!               block's list at block-local indices; phi elimination
//!               as ordinary `copy`/`move`/`borrow` edge records with
//!               scratch-serialized swap cycles; calls, returns, and
//!               self-tailcalls as `jal ra`/`jalr`/`take`/
//!               `ret`/`tailcall_self`; syscalls with statically-
//!               carried `SyscallDesc`s; n-ary aggregate construct /
//!               multi-result destructure / `switch` as one fixed
//!               record plus descriptor; `copy`/`borrow`/`move_` as
//!               explicit fast slot ops; cleanup tokens as fp-relative
//!               cells), the block-local LLIR rewrites (`llir_fusion`
//!               — const+op immediate fusion plus `read_indexi` and
//!               the fused multiply-accumulate peepholes), and finally
//!               linearize (`llir_linearize` — the one stage that computes PCs, lays out
//!               the linear form, expands long branches, and writes the
//!               final relative offsets for branches, jumps, direct
//!               calls, and switch arms (`switch_arms` rows hold their
//!               targets' symbolic `BlockId`s until then); nothing
//!               before linearization ever sees an absolute PC, and the
//!               input CFG is never rewritten), and the LLIR validation
//!               and assembly passes (`llir_validate`, `llir_asm`)), and
//!               the AIR text form's lexer,
//!               parser, and printer (`cfg_lex`, `cfg_parse`, `cfg_print` —
//!               re-exported by `cfg`)
//!
//! See README.md for the roadmap.

const std = @import("std");

pub const artifact_bundle = @import("artifact_bundle.zig");
pub const ast = @import("ast.zig");
pub const llir = @import("llir.zig");
pub const vm_instr = @import("vm_instr.zig");
pub const cfg = @import("cfg.zig");
pub const checker = @import("passes/checker.zig");
pub const frontend = @import("frontend.zig");
pub const frontend_cache = @import("frontend_cache.zig");
pub const host = @import("host.zig");
pub const interpreter = @import("interpreter.zig");
pub const vm_types = @import("vm_types.zig");
pub const lex = @import("lex.zig");
pub const lower = @import("lower.zig");
pub const moduleinfo = @import("moduleinfo.zig");
pub const parser = @import("parser.zig");
pub const stdbundle = @import("stdbundle.zig");

/// Version of this library.
pub const version = std.SemanticVersion{ .major = 0, .minor = 0, .patch = 1 };

test {
    // Reference every public declaration so tests are wired into the
    // library's test step.
    std.testing.refAllDecls(@This());

    // Test files, one per module or cohesive pipeline slice (mirroring the
    // Zig compiler's pre_module_ast / post_module_ast / pre_optimize_cfg
    // slices): `ast`, `lex`, and `parser` before the module AST; the
    // type-checker, module registry, host-contract, and stdbundle modules
    // on the annotated AST; and the AIR, module graph, and frontend
    // pipeline before optimization. The `frontend` area is split into
    // several files (lowering + conformance, optimizer, cfg passes,
    // LLIR lowering/validation/normalization, assembly printer) that
    // share helpers through `frontend_test_support.zig`. Each file
    // references the module files whose test blocks it aggregates and
    // holds that area's black-box tests.
    _ = @import("ast_tests.zig");
    _ = @import("lex_tests.zig");
    _ = @import("parser_tests.zig");
    _ = @import("checker_tests.zig");
    _ = @import("host_tests.zig");
    _ = @import("stdbundle_tests.zig");
    _ = @import("vm_instr.zig");
    _ = @import("interpreter_scalar_tests.zig");
    _ = @import("interpreter_lifecycle_tests.zig");
    _ = @import("interpreter_host_tests.zig");
    _ = @import("interpreter_image_tests.zig");
    _ = @import("interpreter_load_tests.zig");
    _ = @import("interpreter_vm_tests.zig");
    _ = @import("moduleinfo_tests.zig");
    _ = @import("frontend_tests.zig");
    _ = @import("frontend_lowering_tests.zig");
    _ = @import("frontend_spec_tests.zig");
    _ = @import("frontend_regression_tests.zig");
    _ = @import("frontend_optimizer_tests.zig");
    _ = @import("frontend_cfg_passes_tests.zig");
    _ = @import("frontend_intrinsic_tests.zig");
    _ = @import("frontend_llir_core_tests.zig");
    _ = @import("frontend_llir_ops_tests.zig");
    _ = @import("frontend_llir_ops_imm_tests.zig");
    _ = @import("frontend_llir_ops_wide_tests.zig");
    _ = @import("frontend_llir_ops_branch_tests.zig");
    _ = @import("frontend_llir_validate_tests.zig");
    _ = @import("frontend_llir_normalize_tests.zig");
    _ = @import("frontend_llir_asm_tests.zig");
    _ = @import("frontend_llir_bin_tests.zig");
    _ = @import("frontend_llir_typed_tests.zig");
    _ = @import("ownership_fused_tests.zig");
    _ = @import("frontend_cache_tests.zig");
}
