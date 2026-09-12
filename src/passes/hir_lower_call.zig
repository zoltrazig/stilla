//! Pass: HIR call lowering (docs/hir.md §9, §5.5; PROGRESS S5). In:
//! Ctx + FuncState + a `call` node. Out: direct calls (member/instance
//! record callees), value calls (λ refs, locals, arbitrary callees),
//! and host syscalls (bodyless bindings / bundle intrinsics) — the
//! three `cfg_lower_call` forms, dispatched on the callee *record*
//! instead of re-walking the AST.
//!
//! A member/instance `fn_ref` as the call's first operand lowers to a
//! direct call (the record's own signature carries the arg modes); in
//! every other position that same node is a `module_ref`+`load_member`
//! pair (hir_lower_expr.fnRef). Forwarding wrappers bypass the arg
//! machinery entirely (see hir_lower.zig's `.intrinsic` arm).

const std = @import("std");
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const lower = @import("stilla").lower;
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_call = @import("cfg_lower_call.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");
const hir_lower = @import("hir_lower.zig");
const hir_lower_expr = @import("hir_lower_expr.zig");
const type_resolve = @import("type_resolve.zig");

const Ctx = hir_lower.Ctx;
const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;
const no_span = hir_lower.no_span;

/// Lower a `call` node.
pub fn call(c: *Ctx, fs: *FuncState, id: hir.ExprId) LowerError!?*cfg.Value {
    const self = c.self;
    const n = c.node(id);
    const ops = c.operands(id);
    const callee_id = ops[0];
    const callee_node = c.node(callee_id);
    const is_callee_ref = std.mem.eql(u8, c.opName(callee_id), "fn_ref");

    if (is_callee_ref) {
        const fid = switch (callee_node.payload.func) {
            .func => |f| f,
            .host => |hid| return hostCall(c, fs, id, callee_node, hid, false),
        };
        const rec = &c.built.funcs.items[fid];
        switch (rec.kind) {
            // A member/instance function in callee position: a direct
            // call at the record's own (specialized) signature.
            .member, .instance => {
                var args = std.ArrayList(*cfg.Value).empty;
                for (rec.params, ops[1..]) |p, arg_id| {
                    const v = (try hir_lower_expr.expr(c, fs, arg_id)) orelse return null;
                    const arg = try cfg_lower_call.lowerCallArg(self, fs, v, p.mode, p.type_);
                    // A void-typed argument carries no observable value:
                    // it emits no operand (the phantom must never reach
                    // the text form, cfg-lowering.md Pass 4.1).
                    if (arg.type_ == .primitive and arg.type_.primitive == .void) continue;
                    try args.append(self.arena, arg);
                }
                return cfg_lower_call.emitCall(self, fs, no_span, .{ .direct = .{ .name = rec.name } }, args.items, n.ty);
            },
            // A first-class intrinsic wrapper in callee position: a
            // value call over the wrapper's `fn_ref` (its body forwards
            // to the syscall; the signature is already concrete).
            .intrinsic => {
                const fv = (try hir_lower_expr.fnRef(c, fs, callee_id, true)) orelse return null;
                return valueCall(c, fs, id, fv);
            },
            // A hoisted λ: a value call over its `fn_ref`.
            .lambda => {
                const fv = (try hir_lower_expr.fnRef(c, fs, callee_id, true)) orelse return null;
                return valueCall(c, fs, id, fv);
            },
            .init, .drop_hook => return self.fail(no_span, "internal: '{s}' is not callable", .{rec.name}),
        }
    }

    // Any other callee: a value call over the lowered callee value.
    const fv = (try hir_lower_expr.expr(c, fs, callee_id)) orelse return null;
    return valueCall(c, fs, id, fv);
}

/// A value call: the callee's function type carries the arg modes; the
/// result type comes from `specializeSignature` (the direct value
/// call's rule; a concrete signature comes back unchanged).
fn valueCall(c: *Ctx, fs: *FuncState, id: hir.ExprId, fv: *cfg.Value) LowerError!?*cfg.Value {
    const self = c.self;
    const ops = c.operands(id);
    if (fv.type_ != .function) {
        return self.fail(no_span, "calling a non-function value", .{});
    }
    const ft = fv.type_.function;
    var args = std.ArrayList(*cfg.Value).empty;
    var arg_types = std.ArrayList(meta.Type).empty;
    for (ft.params, 0..) |p, i| {
        const arg_id = ops[1 + i];
        const v = (try hir_lower_expr.expr(c, fs, arg_id)) orelse return null;
        const arg = try cfg_lower_call.lowerCallArg(self, fs, v, p.mode, p.type_);
        try arg_types.append(self.arena, arg.type_);
        if (arg.type_ == .primitive and arg.type_.primitive == .void) continue; // void args emit no operand
        try args.append(self.arena, arg);
    }
    // The signature specializes from the argument types (Core §12.2) —
    // the same AST-free rule the direct value call applies; a concrete
    // signature comes back unchanged.
    const specialized = moduleinfo.specializeSignature(self.resolve, fs.module, fv.type_.function, arg_types.items);
    const ret = switch (specialized) {
        .function => |sft| sft.ret.*,
        else => return self.fail(no_span, "callee is not a function", .{}),
    };
    return cfg_lower_call.emitCall(self, fs, no_span, .{ .value = fv }, args.items, ret);
}

/// A host-binding callee: the syscall form. `sig` comes from the
/// `fn_ref` node (the builder stored the call's specialized signature
/// there — `call_of` instantiations included), so no re-specialization
/// happens; bundle-intrinsic expansion and the str-hash signature
/// check apply exactly as in the direct lowering.
fn hostCall(c: *Ctx, fs: *FuncState, id: hir.ExprId, callee_node: hir.ExprNode, hid: hir.HostBindingId, wrapper_fwd: bool) LowerError!?*cfg.Value {
    _ = wrapper_fwd; // forwarding wrappers are lowered in hir_lower.zig
    const self = c.self;
    const ops = c.operands(id);
    const host = c.built.hosts.items[hid];
    const owner = self.graph.modules[host.module];

    // The signature: the `fn_ref` node's stored function type (already
    // the call's specialization when the source used `::[...]`).
    const sig_fn = callee_node.ty.function;
    // Effective modes: move when the argument is a `move` node (the
    // checker's rule, recorded structurally by the builder).
    var eff_params = std.ArrayList(meta.Param).empty;
    var args = std.ArrayList(*cfg.Value).empty;
    for (sig_fn.params, 0..) |p, i| {
        const arg_id = ops[1 + i];
        const moving = std.mem.eql(u8, c.opName(arg_id), "move");
        const v = (try hir_lower_expr.expr(c, fs, arg_id)) orelse return null;
        const mode: meta.ParamMode = effectiveMode(p.mode, moving, v.type_);
        try eff_params.append(self.arena, .{ .span = p.span, .name = p.name, .mode = mode, .type_ = p.type_ });
        const arg = try cfg_lower_call.lowerCallArg(self, fs, v, mode, p.type_);
        if (arg.type_ == .primitive and arg.type_.primitive == .void) continue; // void args emit no operand
        try args.append(self.arena, arg);
    }
    // The syscall carries the EFFECTIVE modes (a `move` declared
    // parameter relaxed to `plain` for a Copy argument passed without
    // an explicit `move`) — mirror the direct effectiveSig rule, so the
    // runtime and validator see the call-site transfer (the box/unbox
    // contract depends on it).
    const eff_sig = meta.FunctionType{ .params = eff_params.items, .ret = sig_fn.ret };
    // Origin-based dispatch (mirror the direct call dispatch, Intrinsics
    // §2): a bodyless bundle-origin member is an intrinsic and must have
    // an explicit expansion entry — a member with no table entry (a
    // future bundle member) fails before canonical AIR. Any other
    // bodyless declaration is a host binding (a system call).
    const vm = owner.valueMember(host.name) orelse
        return self.fail(no_span, "host binding '{s}.{s}' vanished", .{ owner.specifier, host.name });
    if (owner.isIntrinsic(vm) and !cfg_lower_intrinsic.isHostExpansion(owner.specifier, host.name)) {
        return self.fail(no_span, "intrinsic '{s}.{s}' has no expansion", .{ owner.specifier, host.name });
    }
    // Bundle-intrinsic expansions apply their constraint checks; every
    // host call lowers to the same `syscall` emission either way.
    if (cfg_lower_intrinsic.isHostExpansion(owner.specifier, host.name)) {
        if (cfg_lower_intrinsic.isConstrainedMember(owner.specifier, host.name)) {
            try cfg_lower_intrinsic.checkStrHashSignature(self, no_span, host.name, sig_fn);
        }
    }
    return cfg_lower_call.emitHostCall(self, fs, no_span, owner.specifier, host.name, args.items, eff_sig);
}

/// The effective argument mode (the direct effectiveMode rule over HIR
/// shapes): only a *move-mode* parameter can change — a unique one is
/// always moved; a Copy one moves iff the argument was written `move`.
fn effectiveMode(declared: meta.ParamMode, moving: bool, t: meta.Type) meta.ParamMode {
    if (declared != .move) return declared;
    if (t.ownership() != .copy) return declared;
    return if (moving) .move else .plain;
}
