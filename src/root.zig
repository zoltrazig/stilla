//! Stilla runtime — a Zig implementation of the Stilla v1.3 execution
//! model, as defined by the *Stilla Runtime Specification - v1.3 Draft*
//! in `spec/`.
//!
//! Status: early skeleton. The module layout mirrors the Runtime
//! specification's sections so that the long-term work has a home:
//!
//! - `context` — execution context (Runtime §1.3, §2, §8)
//! - `module`  — module instantiation and storage (Runtime §2)
//! - `host`    — host environment contract (Runtime §3)
//! - `builtin` — required `builtin` interface (Runtime §4)
//! - `panic`   — termination and traps (Runtime §7)
//! - `stdbundle` — the `std/` standard-library bundle: declaration-only
//!               host-binding modules embedded at compile time (frontend
//!               §3.2, §5.6)
//! - `ast`     — source spans and AST nodes for diagnostics (compile-time)
//! - `lex`     — lexer: source text → tokens (compile-time)
//! - `parser`  — LL(k) parser: token stream → AST (compile-time)
//! - `cfg`     — the CFG IR (ir.md): data structures plus the text-form
//!               parser and canonical printer (compile-time)
//! - `checker` — type checker and AST annotator (compile-time). Current
//!               status: name/type inference, ownership analysis including
//!               conditional release (frontend.md §4.5, Core §10.10),
//!               generic specialization with monomorphized instances
//!               (frontend.md §4.4), and the §4.6 consumer checks; the
//!               remaining §4.6 checks are future work (frontend.md §4)
//! - `moduleinfo` — module graph construction (frontend Phase 1): member
//!                tables, import resolution, cycle detection, topological
//!                sort, type resolution
//! - `lower`   — CFG lowering (frontend Phase 3): annotated AST + module
//!               graph → `cfg.IrProgram`
//! - `frontend` — the pipeline driver: entry module → IR
//! - `passes`  — the pass algorithms split out of the pipeline files, one
//!               file per pass (frontend.md §6), imported directly by the
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
//!               inside `cfg_lower_emit`), and
//!               the IR text form's lexer,
//!               parser, and printer (`cfg_lex`, `cfg_parse`, `cfg_print` —
//!               re-exported by `cfg`)
//!
//! See README.md for the roadmap.

const std = @import("std");

pub const ast = @import("ast.zig");
pub const builtin = @import("builtin.zig");
pub const cfg = @import("cfg.zig");
pub const checker = @import("passes/checker.zig");
pub const context = @import("context.zig");
pub const frontend = @import("frontend.zig");
pub const host = @import("host.zig");
pub const lex = @import("lex.zig");
pub const lower = @import("lower.zig");
pub const module = @import("module.zig");
pub const moduleinfo = @import("moduleinfo.zig");
pub const panic = @import("panic.zig");
pub const parser = @import("parser.zig");
pub const stdbundle = @import("stdbundle.zig");

/// Version of this library.
pub const version = std.SemanticVersion{ .major = 0, .minor = 0, .patch = 1 };

test {
    // Reference every public declaration so tests are wired into the
    // library's test step.
    std.testing.refAllDecls(@This());

    // Test files, one per module or pipeline area (mirroring the Zig
    // compiler's pre_module_ast / post_module_ast / pre_optimize_cfg
    // slices): `ast`, `lex`, and `parser` before the module AST; the
    // type-checker, module registry, host-contract, and stdbundle modules
    // on the annotated AST; and the CFG IR, module graph, and frontend
    // pipeline before optimization. Each file references the module files
    // whose test blocks it aggregates and holds that area's black-box
    // tests.
    _ = @import("ast_tests.zig");
    _ = @import("lex_tests.zig");
    _ = @import("parser_tests.zig");
    _ = @import("checker_tests.zig");
    _ = @import("module_tests.zig");
    _ = @import("context_tests.zig");
    _ = @import("host_tests.zig");
    _ = @import("builtin_tests.zig");
    _ = @import("panic_tests.zig");
    _ = @import("stdbundle_tests.zig");
    _ = @import("moduleinfo_tests.zig");
    _ = @import("frontend_tests.zig");
}
