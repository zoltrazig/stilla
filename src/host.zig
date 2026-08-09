//! Host environment — Runtime §3.
//!
//! The embedding host:
//!
//! - creates the execution context (§3);
//! - registers host-provided modules (§3.1);
//! - provides the `builtin` interface (§3.2, §4);
//! - invokes entry points (§3.3);
//! - receives control back on normal termination or panic (§3.4) and
//!   disposes of the terminated context and any host-owned resources.
//!
//! Host cleanup is outside Stilla source semantics and must not be
//! described as execution of Stilla `drop` hooks (Runtime §3.4).

const std = @import("std");
const builtin = @import("builtin.zig");

/// The embedding-host contract (Runtime §3).
pub const Host = struct {
    /// Allocator the runtime uses for context-owned storage.
    allocator: std.mem.Allocator,

    /// Required `builtin` interface implementation (Runtime §3.2, §4).
    builtin: builtin.VTable = .{},

    /// Opaque host state passed to every builtin call.
    userdata: *const anyopaque = undefined,

    // TODO(runtime): host-provided module registry (§3.1) and the
    // load-time resolution process (Runtime §2.6, Core §2.4): a specifier
    // resolves to exactly one of a Stilla source module, a standard-library
    // module, or a host-provided module.
    //
    // TODO(runtime): entry-point convention (Runtime §3.3) — a standalone
    // runtime conventionally loads an entry module and invokes
    // `entry.main()`; an embedding host may directly invoke any exposed
    // module function.
};
