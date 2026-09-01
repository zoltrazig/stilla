//! Pass: intrinsic expansion — the per-member expansion table for the
//! embedded standard-library bundle's bodyless declarations (Intrinsics
//! Specification §2–§4). A bundle member is an intrinsic iff it is a
//! bodyless function or an initializer-less constant of a module loaded
//! from the embedded bundle (`moduleinfo.isIntrinsic` — origin-based, so
//! a same-spelled declaration outside the bundle never matches). Every
//! intrinsic use must have an explicit entry here:
//!
//! - host-backed functions expand to a call to the existing `(module,
//!   member)` host binding — the same `syscall` form as before the
//!   migration (phase3-cfg-lowering.md, System calls for host bindings),
//!   emitted by `cfg_lower_call.lowerHostCall` verbatim, so direct-call
//!   output stays byte-identical;
//! - the `math` constants materialize their specified f32 bit patterns
//!   as ordinary typed constants at each use site (air.md §5.6) — no
//!   member row read, no storage slot, no `@init` write.
//!
//! There is no wildcard "every bundle function is a syscall" default
//! (Intrinsics §3): an intrinsic with no entry fails compilation before
//! canonical AIR is produced. The full diagnostic set lands with the
//! failure-diagnostics phase; this table is the single dispatch point it
//! will extend.
//!
//! The syscall-target derivation (`syscallTarget`) is shared with the
//! host-binding path and the pattern-length query so exactly one spelling
//! of each target exists (air.md §8.2/§9.3: the target names the host
//! registry binding, independent of the AIR member table).

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_call = @import("cfg_lower_call.zig");
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_func = @import("cfg_lower_func.zig");
const cfg_lower_validate = @import("cfg_lower_validate.zig");
const checker = @import("checker.zig");

const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;

/// One host-backed expansion entry: the expansion of the bundle member
/// is a call to the existing `(module, member)` host binding.
const HostEntry = struct {
    module: []const u8,
    member: []const u8,
};

/// The explicit expansion table for bundle functions (Intrinsics §3 —
/// no wildcard default): every bodyless function of the embedded bundle,
/// one entry each (the phase-0 checklist).
const host_entries = [_]HostEntry{
    // builtin (Runtime §4)
    .{ .module = "builtin", .member = "print" },
    .{ .module = "builtin", .member = "str" },
    .{ .module = "builtin", .member = "box" },
    .{ .module = "builtin", .member = "unbox" },
    .{ .module = "builtin", .member = "panic" },
    .{ .module = "builtin", .member = "assert" },
    .{ .module = "builtin", .member = "hash" },
    // math (StdLib §4) — IEEE-754 functions beyond the AIR arithmetic set
    .{ .module = "math", .member = "sqrt" },
    .{ .module = "math", .member = "pow" },
    .{ .module = "math", .member = "exp" },
    .{ .module = "math", .member = "ln" },
    .{ .module = "math", .member = "log2" },
    .{ .module = "math", .member = "log10" },
    .{ .module = "math", .member = "sin" },
    .{ .module = "math", .member = "cos" },
    .{ .module = "math", .member = "tan" },
    .{ .module = "math", .member = "asin" },
    .{ .module = "math", .member = "acos" },
    .{ .module = "math", .member = "atan" },
    .{ .module = "math", .member = "atan2" },
    .{ .module = "math", .member = "floor" },
    .{ .module = "math", .member = "ceil" },
    .{ .module = "math", .member = "round" },
    .{ .module = "math", .member = "trunc" },
    .{ .module = "math", .member = "abs" },
    .{ .module = "math", .member = "min" },
    .{ .module = "math", .member = "max" },
    // list (Runtime §4.3–§4.4)
    .{ .module = "list", .member = "len" },
    .{ .module = "list", .member = "range" },
    // string (StdLib §5) — code-point semantics
    .{ .module = "string", .member = "len" },
    .{ .module = "string", .member = "is_empty" },
    .{ .module = "string", .member = "concat" },
    .{ .module = "string", .member = "contains" },
    .{ .module = "string", .member = "starts_with" },
    .{ .module = "string", .member = "ends_with" },
    .{ .module = "string", .member = "index_of" },
    .{ .module = "string", .member = "substring" },
    .{ .module = "string", .member = "split" },
    .{ .module = "string", .member = "join" },
    .{ .module = "string", .member = "trim" },
    .{ .module = "string", .member = "lower" },
    .{ .module = "string", .member = "upper" },
    .{ .module = "string", .member = "replace" },
    .{ .module = "string", .member = "repeat" },
    .{ .module = "string", .member = "to_utf8" },
    .{ .module = "string", .member = "from_utf8" },
    .{ .module = "string", .member = "to_codepoints" },
    .{ .module = "string", .member = "from_codepoints" },
    // array (StdLib §1–§2) — host storage
    .{ .module = "array", .member = "make" },
    .{ .module = "array", .member = "len" },
    .{ .module = "array", .member = "get" },
    .{ .module = "array", .member = "set" },
    .{ .module = "array", .member = "clone" },
    // hashmap (StdLib §1, §3) — host storage
    .{ .module = "hashmap", .member = "empty" },
    .{ .module = "hashmap", .member = "insert" },
    .{ .module = "hashmap", .member = "get" },
    .{ .module = "hashmap", .member = "contains" },
    .{ .module = "hashmap", .member = "remove" },
    .{ .module = "hashmap", .member = "len" },
    .{ .module = "hashmap", .member = "clone" },
};

/// One materialized-constant entry: the specified f32 bit pattern (IEEE
/// 754; quiet NaN = 0x7FC00000), verified against Zig `std.math` in the
/// phase-0 contract.
const ConstEntry = struct {
    module: []const u8,
    member: []const u8,
    bits: u32,
};

/// The materialization table for bundle constants (air.md §5.6).
const const_entries = [_]ConstEntry{
    .{ .module = "math", .member = "pi", .bits = 0x40490FDB },
    .{ .module = "math", .member = "e", .bits = 0x402DF854 },
    .{ .module = "math", .member = "tau", .bits = 0x40C90FDB },
    .{ .module = "math", .member = "inf", .bits = 0x7F800000 },
    .{ .module = "math", .member = "nan", .bits = 0x7FC00000 },
};

/// True when `(module, member)` has a host-backed expansion entry.
pub fn isHostExpansion(module_spec: []const u8, member: []const u8) bool {
    for (host_entries) |e| {
        if (std.mem.eql(u8, e.module, module_spec) and std.mem.eql(u8, e.member, member)) return true;
    }
    return false;
}

/// The specified f32 bit pattern of a materializable intrinsic constant,
/// or null when `(module, member)` has no entry.
pub fn constBits(module_spec: []const u8, member: []const u8) ?u32 {
    for (const_entries) |e| {
        if (std.mem.eql(u8, e.module, module_spec) and std.mem.eql(u8, e.member, member)) return e.bits;
    }
    return null;
}

/// Expand an intrinsic call (dispatched from `cfg_lower_call` when the
/// callee is a bodyless bundle declaration). Host-backed entries reuse
/// the host-binding lowering verbatim — evaluation order, parameter
/// modes, ownership transfers, and the specialized signature riding on
/// the syscall are unchanged (air.md §8.2/§9.3). `builtin.str` and
/// `builtin.hash` additionally enforce the Runtime §4.2/§4.9
/// supported-type constraint on the specialized signature before the
/// syscall is emitted. No entry → compile error before canonical AIR
/// (Intrinsics §3).
pub fn expandIntrinsicCall(
    self: *Lowerer,
    fs: *FuncState,
    e: *const ast.Call,
    target: moduleinfo.PathTarget,
) LowerError!?*cfg.Value {
    const vm = target.vm;
    if (!isHostExpansion(target.module.specifier, vm.name.text)) {
        return self.fail(e.span, "intrinsic '{s}.{s}' has no expansion", .{ target.module.specifier, vm.name.text });
    }
    // The str/hash constraint needs the specialized signature, which the
    // arguments determine — so this path lowers the arguments itself and
    // shares the emission tail with `lowerHostCall` rather than
    // double-lowering them.
    if (isConstrainedMember(target.module.specifier, vm.name.text)) {
        const ha = (try cfg_lower_call.lowerHostArgs(self, fs, e, vm.type_.function)) orelse return null;
        const sig_fn = try cfg_lower_call.specializedSig(self, fs, e, vm.type_, ha.arg_types);
        try checkStrHashSignature(self, e.span, vm.name.text, sig_fn);
        return try cfg_lower_call.emitHostCall(self, fs, e.span, target.module.specifier, vm.name.text, ha.args, sig_fn);
    }
    return try cfg_lower_call.lowerHostCall(self, fs, e, target);
}

/// True when `(module, member)` is one of the members whose generic type
/// argument is constrained to the Runtime §4.2/§4.9 supported set
/// (`builtin.str` / `builtin.hash`).
fn isConstrainedMember(module_spec: []const u8, member: []const u8) bool {
    return std.mem.eql(u8, module_spec, "builtin") and
        (std.mem.eql(u8, member, "str") or std.mem.eql(u8, member, "hash"));
}

/// The Runtime §4.2/§4.9 supported `T` of `builtin.str` / `builtin.hash`.
/// The required set is exactly the nine listed primitives; every other
/// type — including the remaining primitives (`any`, `hostdata`, `void`,
/// `never`) and every container — is a compile-time error.
fn isSupportedStrHashType(t: cfg.Type) bool {
    return switch (t) {
        .primitive => |k| switch (k) {
            .byte, .int32, .uint32, .int64, .uint64, .float32, .float64, .bool, .str => true,
            else => false,
        },
        else => false,
    };
}

/// Enforce the Runtime §4.2/§4.9 supported-type constraint on the
/// specialized signature of a `builtin.str` / `builtin.hash` use: `T`
/// must be one of {byte, int32, uint32, i64, u64, float32, f64, bool,
/// str}. Runs at
/// both expansion entry points (direct call and first-class wrapper
/// synthesis), so an unsupported specialization fails before canonical
/// AIR (Intrinsics §3 — the host cannot serve the expansion).
fn checkStrHashSignature(self: *Lowerer, span: ast.Span, member: []const u8, ft: cfg.FunctionType) LowerError!void {
    if (ft.params.len != 1) {
        return self.fail(span, "intrinsic 'builtin.{s}' takes exactly one argument", .{member});
    }
    const t = ft.params[0].type_;
    if (!isSupportedStrHashType(t)) {
        return self.fail(span, "intrinsic 'builtin.{s}' does not support type '{s}' (supported: byte, int32, uint32, int64, uint64, float32, float64, bool, str)", .{ member, try typeName(self, t) });
    }
}

/// A diagnostic name for a `cfg.Type`: the same names as the AIR text
/// form (`cfg_print.printType`), rendered without the program's type
/// table — named types resolve through the module graph's interner.
fn typeName(self: *Lowerer, t: cfg.Type) LowerError![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try appendTypeName(self, &buf, t);
    return buf.toOwnedSlice(self.arena);
}

fn appendTypeName(self: *Lowerer, buf: *std.ArrayList(u8), t: cfg.Type) LowerError!void {
    switch (t) {
        .primitive => |k| try buf.appendSlice(self.arena, @tagName(k)),
        .named => |n| {
            if (self.resolve.typeNameOf(n.id)) |name| {
                try buf.appendSlice(self.arena, name);
            } else {
                try buf.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "type#{d}", .{n.id}));
            }
            if (n.args.len > 0) {
                try buf.appendSlice(self.arena, "[");
                for (n.args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(self.arena, ", ");
                    try appendTypeName(self, buf, a);
                }
                try buf.appendSlice(self.arena, "]");
            }
        },
        .param => |s| try buf.appendSlice(self.arena, s),
        .module => try buf.appendSlice(self.arena, "module"),
        .cleanup => try buf.appendSlice(self.arena, "cleanup"),
        .list => |inner| {
            try buf.appendSlice(self.arena, "list[");
            try appendTypeName(self, buf, inner.*);
            try buf.appendSlice(self.arena, "]");
        },
        .box => |inner| {
            try buf.appendSlice(self.arena, "box[");
            try appendTypeName(self, buf, inner.*);
            try buf.appendSlice(self.arena, "]");
        },
        .tuple => |elems| {
            try buf.appendSlice(self.arena, "tuple[");
            for (elems, 0..) |e, i| {
                if (i > 0) try buf.appendSlice(self.arena, ", ");
                try appendTypeName(self, buf, e);
            }
            try buf.appendSlice(self.arena, "]");
        },
        .function => try buf.appendSlice(self.arena, "fn"),
    }
}

/// The syscall target of a bundle intrinsic's host-backed expansion:
/// validated against the expansion table first (no wildcard default —
/// a member without an entry fails here, Intrinsics §3), then derived
/// once by `syscallTarget`. Direct emitters that bypass the call path
/// (the list-pattern length query) route through this so every
/// intrinsic syscall comes from the table.
pub fn intrinsicSyscallTarget(self: *Lowerer, span: ast.Span, module_spec: []const u8, member: []const u8) LowerError!cfg.SysCallTarget {
    if (!isHostExpansion(module_spec, member)) {
        return self.fail(span, "intrinsic '{s}.{s}' has no expansion", .{ module_spec, member });
    }
    return syscallTarget(self, span, module_spec, member);
}

/// The single derivation of a syscall target from `(module, member)`
/// (air.md §8.2/§9.3): the `builtin` module dispatches on its interface
/// enum (`BuiltinId` — the builtin module's host interface name); every
/// other module names its host-registry binding directly. Shared by the
/// host-binding path, the intrinsic table, and the pattern-length query.
pub fn syscallTarget(self: *Lowerer, span: ast.Span, module_spec: []const u8, member: []const u8) LowerError!cfg.SysCallTarget {
    if (std.mem.eql(u8, module_spec, "builtin")) {
        return .{ .builtin = std.meta.stringToEnum(cfg.BuiltinId, member) orelse
            return self.fail(span, "unknown builtin member '{s}'", .{member}) };
    }
    return .{ .host_module = .{ .module = module_spec, .member = member } };
}

// -------------------------------------------------------------------------
// First-class function values (intrinsic plan, phase 3)
// -------------------------------------------------------------------------

/// First-class use of an intrinsic function member (intrinsic plan,
/// phase 3): synthesize — or reuse from the program-wide cache — a
/// wrapper `IrFunc` whose body is exactly the direct expansion (entry →
/// parameters forwarded by mode → the same syscall → ret; `never` →
/// trap) and emit a `fn_ref` to it. The concrete signature comes from
/// the checker's `FuncInstance` for a generic intrinsic (`spec !=
/// null`); a non-generic member's declared signature is already
/// concrete. The wrapper occupies no member row; it joins the using
/// module's `funcs` list like a lambda (`lower.IntrinsicKey` dedups per
/// (declaring module, member, specialization), so two modules using the
/// same intrinsic value share one synthesized function).
pub fn intrinsicFnRef(
    self: *Lowerer,
    fs: *FuncState,
    span: ast.Span,
    owner: *moduleinfo.ModuleInfo,
    vm: *const moduleinfo.ValueMember,
    spec: ?*checker.FuncInstance,
) LowerError!?*cfg.Value {
    // The str/hash supported-type constraint applies to first-class uses
    // too: the synthesized wrapper would carry a signature the host
    // cannot serve (Runtime §4.2/§4.9).
    if (isConstrainedMember(owner.specifier, vm.name.text)) {
        const sig = if (spec) |s| s.signature else vm.type_;
        const ft = switch (sig) {
            .function => |f| f,
            else => return self.fail(span, "intrinsic 'builtin.{s}' is not a function", .{vm.name.text}),
        };
        try checkStrHashSignature(self, span, vm.name.text, ft);
    }
    const key: lower.IntrinsicKey = .{
        .owner = @intFromPtr(owner),
        .slot = vm.slot,
        .spec = if (spec) |s| s.id else std.math.maxInt(u32),
    };
    const name = blk: {
        if (self.intrinsic_wrappers.get(key)) |ir| break :blk ir.name.text;
        const sig = if (spec) |s| s.signature else vm.type_;
        const ir = try synthIntrinsicFunc(self, fs.module, span, owner.specifier, vm.name.text, sig);
        try self.intrinsic_wrappers.put(self.arena, key, ir);
        try self.intrinsic_funcs.append(self.arena, ir);
        break :blk ir.name.text;
    };
    return cfg_lower_emit.emit(self, fs, span, .{ .fn_ref = name }, if (spec) |s| s.signature else vm.type_);
}

/// Synthesize one first-class intrinsic wrapper into the using module:
/// entry → parameters forwarded by mode → the same syscall as the direct
/// expansion → ret (a `never` intrinsic traps after its call — Runtime
/// §7.1). Named `{using-module}.{fn}.intrinsic.{N}` in a namespace of
/// its own, distinct from air.md §11's specialization names
/// `{module}.{fn}.{id}`.
fn synthIntrinsicFunc(
    self: *Lowerer,
    into: *moduleinfo.ModuleInfo,
    span: ast.Span,
    owner_spec: []const u8,
    member: []const u8,
    sig: cfg.Type,
) LowerError!*cfg.IrFunc {
    const ft = switch (sig) {
        .function => |f| f,
        else => return self.fail(span, "intrinsic '{s}.{s}' is not a function", .{ owner_spec, member }),
    };
    const name = try std.fmt.allocPrint(self.arena, "{s}.{s}.intrinsic.{d}", .{ into.specifier, member, self.next_intrinsic_id });
    self.next_intrinsic_id += 1;
    var params = std.ArrayList(cfg.Param).empty;
    for (ft.params, 0..) |*p, i| {
        try params.append(self.arena, .{
            .span = span,
            .name = .{ .span = span, .text = try std.fmt.allocPrint(self.arena, "p{d}", .{i}) },
            .mode = p.mode,
            .type_ = p.type_,
        });
    }
    var wfs = try cfg_lower_func.newFuncState(self, into, .{ .span = span, .text = name }, params.items, ft.ret.*);
    wfs.cur = try cfg_lower_emit.newBlock(self, &wfs, "entry");
    // Forward the parameters by mode directly into the syscall: borrow
    // parameters arrive borrowed, owned ones transfer with the call's
    // signature contract (air.md §8.2/§9.3). Table-validated target —
    // same guard as every other expansion path (Intrinsics §3).
    const target = try intrinsicSyscallTarget(self, span, owner_spec, member);
    // A void-typed parameter carries no observable value; like the
    // direct-call lowering it emits no operand.
    var args = std.ArrayList(*cfg.Value).empty;
    for (wfs.values.items, 0..) |v, i| {
        if (i < ft.params.len and cfg_lower_emit.isVoid(ft.params[i].type_)) continue;
        try args.append(self.arena, v);
    }
    const result = try cfg_lower_call.emitSyscall(self, &wfs, span, target, args.items, ft);
    if (result) |r| {
        if (cfg_lower_emit.isVoid(r.type_)) {
            try cfg_lower_emit.setTerminator(self, &wfs, .{ .ret = null });
        } else {
            // Same return shape as a lambda body returning the call's
            // value (cfg_lower_expr.lowerLambda).
            cfg_lower_emit.markConsumed(self, &wfs, r);
            try cfg_lower_emit.cleanupDisable(self, &wfs, r.span, r);
            try cfg_lower_emit.setTerminator(self, &wfs, .{ .ret = r });
        }
    } else if (wfs.cur != null) {
        try cfg_lower_emit.setTerminator(self, &wfs, .{ .ret = null });
    }
    return cfg_lower_validate.finishFunc(self, &wfs);
}
