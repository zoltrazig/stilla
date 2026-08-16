//! Pass: block-level annotation — frontend.md §4.1 (cross-module name
//! resolution), §4.3 (expression inference and annotation tables), §4.4
//! (generic expansion: specializes generic calls and `::[...]` value
//! expressions into `FuncInstance`s via `monomorphize`), §4.5 (ownership
//! analysis / binding-state tracking, with conditional release and state
//! merging delegated to `checker_ownership`, Core §10.10), and §4.6's
//! non-capture, borrow-lifetime, and drop-hook destruction-view
//! restrictions.
//! In: phase-1 `ModuleInfo` + the phase-2 driver `Checker`.
//! Out: the module's `ModuleAnnotation` side tables — `expr_of`,
//! `binding_of`, `bindings`, `call_sig`, `call_of`, `spec_of`, `names` —
//! and, as a side effect, the static ownership transitions (`move`/`drop`,
//! `released` and the conditional-construct merges) that §4.5 tracks.
//!
//! Type shapes (`structDecl`, `unionDecl`, `fieldIndex`, `variantIndex`,
//! `ownershipOf`) and module-scope resolution (`resolvePathMember`,
//! `bindTypeArgs`, `substSignature`, `specializeSignature`) come from the
//! existing module-scope passes; this pass adds the local scope: paths
//! resolve against enclosing bindings first, then against the module's
//! members.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const type_resolve = @import("type_resolve.zig");
const type_shape = @import("type_shape.zig");
const type_infer = @import("type_infer.zig");
const checker = @import("checker.zig");
const validate = @import("checker_validate.zig");
const monomorphize = @import("monomorphize.zig");
const ownership = @import("checker_ownership.zig");

const CheckError = checker.CheckError;
const Frame = checker.Frame;
const Local = checker.Local;
const Scope = checker.Scope;
const BindingState = checker.BindingState;
const ModuleInfo = moduleinfo.ModuleInfo;
const ModuleAnnotation = checker.ModuleAnnotation;

/// Annotate one module's items: const types and initializers, function
/// bodies, struct drop hooks, and the member-name table. Structs, unions,
/// type defs, and module-level `using` declarations are otherwise phase-1
/// territory and skipped here.
pub fn annotateModule(ck: *checker.Checker, info: *ModuleInfo) CheckError!void {
    const program = info.program orelse return;
    const ma = try ck.moduleAnnotation(info);

    const root = try ck.alloc().create(Scope);
    root.* = .{};
    const frame = try ck.alloc().create(Frame);
    frame.* = .{
        .ck = ck,
        .info = info,
        .ma = ma,
        .resolve = .{ .arena = ck.alloc(), .by_specifier = &ck.graph.?.by_specifier, .type_ids = &ck.graph.?.type_interner },
        .scope = root,
    };

    for (program.items) |*item| switch (item.*) {
        .const_def => |*c| {
            if (c.type_ != null) {
                _ = try ck.resolveTypeOf(ma, info, &c.type_.?);
                try ma.names.put(ck.alloc(), c.name.text, &c.name);
            }
            if (c.init) |init| {
                _ = try inferExpr(frame, init);
                try ma.names.put(ck.alloc(), c.name.text, &c.name);
            }
        },
        .func_def => |*f| {
            try ma.names.put(ck.alloc(), f.name.text, &f.name);
            // Generic templates are never checked unspecialized (Core
            // §12.4); each used specialization is expanded and checked
            // under the concrete substitution (§4.4).
            if (f.body) |body| {
                if (f.type_params.len == 0) try checkFuncBody(frame, f, body);
            }
        },
        .struct_def => |*s| {
            // The user `drop` hook's destruction-view restrictions (Core
            // §9.2, §18 *User drop hook*). Generic templates are never
            // checked unspecialized (Core §12.4); their hooks are lowered
            // per specialization, matching `cfg_lower_module`.
            if (s.type_params.len == 0) {
                if (s.drop) |d| try checkDropHook(frame, s, d);
            }
        },
        else => {},
    };
}

/// The destruction-view restrictions inside a `drop` hook body (Core
/// §9.2, §18 *User drop hook*): the hook argument is bound as a borrowed
/// unique local, so the existing borrowed-value rules reject moving,
/// dropping, returning, or escaping it — `move`/`drop` of the view fail
/// in `markConsumed`, a view (or an unique projection of it) as the block
/// result fails here, and moving an unique field out (a `move` parameter,
/// an owning binding/container/field) fails the borrowed-store rules.
fn checkDropHook(frame: *Frame, s: *const ast.StructDef, d: *const ast.DropDecl) CheckError!void {
    _ = try pushScope(frame, true);
    defer popScope(frame);
    _ = try bindLocal(frame, d.param.text, cfg.Type{ .named = (moduleinfo.resolveTypeId(frame.resolve, frame.info, s.name.text) orelse return) }, true);
    _ = try checkBlock(frame, d.body);
    if (d.body.result) |*r| {
        if (try isBorrowedExpr(frame, r)) {
            return frame.ck.fail(r.span(), "cannot return the destruction view from a drop hook (Core §9.2)", .{});
        }
    }
}

// ---------------------------------------------------------------------------
// Functions and blocks
// ---------------------------------------------------------------------------

fn checkFuncBody(frame: *Frame, f: *const ast.FuncDef, body: *const ast.Block) CheckError!void {
    _ = try pushScope(frame, true);
    defer popScope(frame);

    for (f.params) |*p| {
        const t = try frame.ck.resolveTypeOf(frame.ma, frame.info, &p.type_);
        _ = try bindLocal(frame, p.name.text, t, p.mode == .borrow);
    }
    // Resolve the declared return type so the validate pass can check the
    // body's result against it; unreachable when the body has no result.
    if (f.ret != null) _ = try frame.ck.resolveTypeOf(frame.ma, frame.info, &f.ret.?);

    _ = try checkBlock(frame, body);

    // A borrowed unique value cannot be returned as owned: there is no
    // user-visible borrow lifetime for it to outlive (Core §10.7, §18).
    if (body.result) |*r| {
        if (try isBorrowedExpr(frame, r)) {
            return frame.ck.fail(r.span(), "cannot return a borrowed value as owned; copy or move it first (Core §10.7)", .{});
        }
    }
}

fn checkBlock(frame: *Frame, b: *const ast.Block) CheckError!cfg.Type {
    _ = try pushScope(frame, false);
    defer popScope(frame);

    for (b.stmts) |*stmt| switch (stmt.*) {
        .let => |*l| try checkLet(frame, l),
        .drop => |*d| {
            // `drop name;` marks the binding destroyed (Core §9.4). The
            // lowerer owns the unknown-binding diagnostic; borrowed and
            // already-dead bindings are rejected here.
            _ = try markConsumed(frame, d.name.text, d.span, "drop", "dropped");
        },
        .using => |*u| try bindUsing(frame, u),
        .expr => |*e| {
            _ = try inferExpr(frame, &e.expr);
        },
        .empty => {},
    };

    if (b.result) |*r| return (try inferExpr(frame, r)) orelse cfg.Type{ .primitive = .void };
    return cfg.Type{ .primitive = .void };
}

fn checkLet(frame: *Frame, l: *const ast.LetStmt) CheckError!void {
    // Resolve the declared type eagerly so the validate pass can compare
    // it against the initializer (frontend §4.6, Core §5).
    if (l.type_ != null) _ = try frame.ck.resolveTypeOf(frame.ma, frame.info, &l.type_.?);
    const t: ?cfg.Type = blk: {
        // A declared `any` type makes the binding `any` (Core §11.6): the
        // top-type coercion is materialized at the let, so type-test
        // patterns and `as` recovery see a genuine `any` value. The
        // initializer is still inferred and annotated (its type feeds
        // `validateLet`'s compatibility check).
        const it = try inferExpr(frame, l.init);
        if (l.type_ != null) {
            const dt = try frame.ck.resolveTypeOf(frame.ma, frame.info, &l.type_.?);
            if (dt == .primitive and dt.primitive == .any) break :blk dt;
            if (it == null) break :blk dt;
        }
        break :blk it;
    };
    // A `let` binding owns its initializer, so the initializer may not be
    // a borrowed unique value (Core §10.7, §18). An irrefutable
    // identifier pattern bound to an existing unique local owner requires
    // an explicit `move` (Core §10.4); a fresh unique expression binds
    // directly (Core §10.5).
    if (try isBorrowedExpr(frame, l.init)) {
        return frame.ck.fail(l.init.span(), "cannot store a borrowed value into an owning binding (Core §10.7)", .{});
    }
    switch (l.pattern) {
        .path => |*pp| if (pp.tail == .none and pp.path.len == 1) {
            try requireMoveIfOwned(frame, l.init, "binding");
        },
        else => {},
    }
    if (t) |tt| try inferPattern(frame, &l.pattern, tt, false);
}

/// A block-level `using` alias is a scoped compile-time binding (Core
/// §13.1); unresolvable aliases are silently skipped, matching phase 1.
fn bindUsing(frame: *Frame, u: *const ast.UsingDecl) CheckError!void {
    const alias = u.alias orelse return;
    const target = type_resolve.resolveAliasTarget(frame.resolve, frame.info, u) orelse return;
    switch (target) {
        .module => {
            const local = try bindLocal(frame, alias.text, cfg.Type{ .module = {} }, false);
            local.is_using = true;
        },
        .value => |mr| {
            const m = frame.resolve.module(mr.module) orelse return;
            const vm = m.valueMember(mr.name) orelse return;
            const local = try bindLocal(frame, alias.text, vm.type_, false);
            local.is_using = true;
        },
        .type => {},
    }
}

// ---------------------------------------------------------------------------
// Scopes and bindings
// ---------------------------------------------------------------------------

fn pushScope(frame: *Frame, is_func: bool) CheckError!*Scope {
    const scope = try frame.ck.alloc().create(Scope);
    scope.* = .{ .parent = frame.scope, .is_func = is_func };
    frame.scope = scope;
    return scope;
}

fn popScope(frame: *Frame) void {
    frame.scope = frame.scope.parent.?;
}

fn bindLocal(frame: *Frame, name: []const u8, t: cfg.Type, is_borrow: bool) CheckError!*Local {
    const ma = frame.ma;
    const id = ma.next_binding_id;
    ma.next_binding_id += 1;
    const local = try frame.ck.alloc().create(Local);
    local.* = .{
        .name = name,
        .type_ = t,
        .id = id,
        .state = if (is_borrow) BindingState.borrowed else BindingState.owned,
        .is_borrow = is_borrow,
    };
    try frame.scope.locals.put(frame.ck.alloc(), name, local);
    try ma.binding_of.put(frame.ck.alloc(), id, t);
    try ma.bindings.put(frame.ck.alloc(), id, local.state);
    return local;
}

fn lookupLocal(frame: *Frame, name: []const u8) ?*Local {
    var s: ?*Scope = frame.scope;
    while (s) |sc| {
        if (sc.locals.get(name)) |l| return l;
        s = sc.parent;
    }
    return null;
}

/// A local plus the scope that binds it, used by the non-capture check
/// (Core §6.2) to tell an enclosing function's binding from this function's
/// own.
const LocalBinding = struct { local: *Local, scope: *Scope };

fn lookupLocalScope(frame: *Frame, name: []const u8) ?LocalBinding {
    var s: ?*Scope = frame.scope;
    while (s) |sc| {
        if (sc.locals.get(name)) |l| return .{ .local = l, .scope = sc };
        s = sc.parent;
    }
    return null;
}

/// Mark a named binding consumed when it holds an unique value (Core
/// §10.4, §10.6); a move/drop of a Copy value is a no-op. Returns
/// the binding's type, or null when the name is not in scope (the lowerer
/// reports unknown bindings). A borrowed, already-moved, definitely-
/// released, or maybe-unique binding cannot be moved or dropped (Core
/// §18 *Ownership*).
fn markConsumed(frame: *Frame, name: []const u8, span: ast.Span, action: []const u8, actioned: []const u8) CheckError!?cfg.Type {
    const local = lookupLocal(frame, name) orelse return null;
    if (!isUnique(frame, local.type_)) return local.type_;
    switch (local.state) {
        .owned => {},
        .borrowed => return frame.ck.fail(span, "cannot {s} borrowed binding '{s}'", .{ action, name }),
        .consumed => return frame.ck.fail(span, "use of already-{s} value '{s}'", .{ actioned, name }),
        .released => return frame.ck.fail(span, "use of released value '{s}'", .{name}),
        .maybe => return frame.ck.fail(span, "use of maybe-released value '{s}'", .{name}),
    }
    try checker.setState(frame, local, .consumed);
    return local.type_;
}

fn isUnique(frame: *Frame, t: cfg.Type) bool {
    return checker.isUnique(frame, t);
}

// ---------------------------------------------------------------------------
// Borrowed-expression detection and consuming scrutinees (Core §13.4,
// §13.5, §10.7, §18)
// ---------------------------------------------------------------------------

fn isUniqueType(frame: *Frame, t: ?cfg.Type) bool {
    return if (t) |tt| isUnique(frame, tt) else false;
}

/// True when an expression evaluates to a borrowed unique value: a `borrow`
/// parameter (or a binding derived from one), a borrowed member/index, or a
/// conditional/block/move whose results are borrowed. Module members are
/// never borrowed (execution-context lifetime, Core §2.7). Borrowed unique
/// values cannot be moved, dropped, returned as owned, or stored into an
/// owning location (Core §10.7, §18).
fn isBorrowedExpr(frame: *Frame, e: *const ast.Expr) CheckError!bool {
    switch (e.*) {
        .paren => |*p| return try isBorrowedExpr(frame, p.inner),
        .path => |*p| {
            if (p.tail != .none) return false;
            if (lookupLocal(frame, p.path[0].text)) |local| {
                const head_borrowed = isUnique(frame, local.type_) and local.is_borrow;
                if (p.path.len == 1) return head_borrowed;
                // A dotted path through a local (`file.inner`) is borrowed
                // when the head is a borrowed unique binding and the
                // projection is unique (Core §10.7, §18 *User drop hook*).
                if (head_borrowed) return isUniqueType(frame, frame.ma.expr_of.get(e));
                return false;
            }
            // Module-qualified paths have execution-context lifetime.
            return false;
        },
        .member => |*mm| {
            if (try moduleValueOf(frame, mm.object)) |_| return false;
            return isUniqueType(frame, frame.ma.expr_of.get(e));
        },
        .index => |*ix| {
            _ = ix;
            return isUniqueType(frame, frame.ma.expr_of.get(e));
        },
        .if_ => |*i| {
            if (try isBorrowedExpr(frame, i.cond)) return true;
            if (try blockResultBorrowed(frame, i.then)) return true;
            if (i.else_) |else_e| return try isBorrowedExpr(frame, else_e);
            return false;
        },
        .match => |*m| {
            for (m.arms) |*arm| {
                if (try isBorrowedExpr(frame, arm.body)) return true;
            }
            return false;
        },
        .block => |*b| return try blockResultBorrowed(frame, b.block),
        else => return false,
    }
}

fn blockResultBorrowed(frame: *Frame, b: *const ast.Block) CheckError!bool {
    if (b.result) |*r| return try isBorrowedExpr(frame, r);
    return false;
}

/// True when a `match`/`for` scrutinee is an explicit `move` expression
/// (Core §13.4, §13.5), peeling surrounding parentheses.
fn scrutineeIsMove(frame: *Frame, e: *const ast.Expr) bool {
    switch (e.*) {
        .paren => |*p| return scrutineeIsMove(frame, p.inner),
        .move => return true,
        else => return false,
    }
}

/// Whether matching/iterating over `e` consumes the whole owner, making the
/// pattern's unique bindings owners rather than borrows (Core §13.4,
/// §13.5). True for an explicit `move`, for a Copy scrutinee, and for
/// a fresh unique value (any non-path expression); false for an unique
/// binding or module member, which is borrowed by the construct.
fn consumesScrutinee(frame: *Frame, e: *const ast.Expr, t: cfg.Type) bool {
    if (scrutineeIsMove(frame, e)) return true;
    if (!isUnique(frame, t)) return true;
    switch (e.*) {
        .path => |*p| return p.tail != .none,
        else => return true,
    }
}

/// Core §14.6 *Whole-owner*: consumingly destructuring a struct that
/// defines its own `drop` hook is a compile-time error; borrowing
/// destructuring is fine. Only reached for consuming scrutinees.
fn checkDropHookMatch(frame: *Frame, m: *const ast.MatchExpr, scrut_t: cfg.Type) CheckError!void {
    if (scrut_t != .named) return;
    const sd = moduleinfo.structDecl(frame.resolve, frame.info, frame.resolve.typeNameOf(scrut_t.named) orelse return) orelse return;
    if (sd.drop == null) return;
    for (m.arms) |*arm| {
        if (arm.pattern == .path and arm.pattern.path.tail == .struct_) {
            return frame.ck.fail(arm.pattern.span(), "cannot consumingly destructure a struct that defines a drop hook (Core §14.6)", .{});
        }
    }
}

// ---------------------------------------------------------------------------
// Call-argument ownership (Core §18 *Parameters*, §10.6, §10.7)
// ---------------------------------------------------------------------------

/// An existing unique local owner must be transferred with an explicit
/// `move` (Core §10.4, §10.6): storing it into an owning field, payload,
/// tuple/list element, or binding without `move` would leave two owners
/// of one value. A fresh unique expression transfers implicitly (Core
/// §10.5) and a Copy value needs no transfer; a `move` operand or a
/// parenthesized `(move x)` is already explicit and passes through.
fn requireMoveIfOwned(frame: *Frame, a: *const ast.Expr, what: []const u8) CheckError!void {
    switch (a.*) {
        .path => |*p| {
            if (p.tail == .none and p.path.len == 1) {
                if (lookupLocal(frame, p.path[0].text)) |local| {
                    if (isUnique(frame, local.type_) and local.state == .owned) {
                        return frame.ck.fail(a.span(), "unique value must be moved with 'move' before being stored into an owning {s} (Core §10.4)", .{what});
                    }
                }
            }
        },
        else => {},
    }
}

/// Check every argument of a call against its parameter's mode. A plain
/// parameter accepts only Copy arguments; a `borrow` parameter
/// rejects `move`; a `move` parameter requires an explicit `move` of an
/// existing unique owner, rejects borrowed values, and accepts a fresh
/// unique value as an implicit transfer.
fn checkArgsOwnership(frame: *Frame, c: *const ast.Call, arg_types: []const cfg.Type, sig: cfg.Type) CheckError!void {
    if (sig != .function) return;
    const params = sig.function.params;
    for (c.args, 0..) |*a, i| {
        if (i >= params.len) break;
        if (!isUnique(frame, arg_types[i])) continue;
        switch (params[i].mode) {
            .plain => {
                // The top type `any` is the sole exception (Core §10.6):
                // a unique argument may be moved into the `any` — an
                // explicit `move` or a fresh unique value transfers; an
                // existing local owner must be moved. `hostdata` never
                // coerces to `any` (Core §11.6) and is rejected.
                const pt = params[i].type_;
                if (pt == .primitive and pt.primitive == .any) {
                    if (arg_types[i] == .primitive and arg_types[i].primitive == .hostdata) {
                        return frame.ck.fail(a.span(), "'hostdata' does not coerce to 'any' (Core §11.6, §11.7)", .{});
                    }
                    if (scrutineeIsMove(frame, a)) continue;
                    if (a.* != .path) continue; // fresh unique expression
                    if (lookupLocal(frame, a.path.path[0].text)) |local| {
                        if (isUnique(frame, local.type_) and local.state == .owned) {
                            return frame.ck.fail(a.span(), "unique value must be moved with 'move' before being passed to an 'any' parameter (Core §10.6)", .{});
                        }
                    }
                    if (try isBorrowedExpr(frame, a)) {
                        return frame.ck.fail(a.span(), "cannot move a borrowed value (Core §10.7)", .{});
                    }
                    continue;
                }
                return frame.ck.fail(a.span(), "plain parameter accepts only Copy arguments (Core §10.6)", .{});
            },
            .borrow => {
                if (scrutineeIsMove(frame, a)) {
                    return frame.ck.fail(a.span(), "cannot move a value into a borrow parameter (Core §18)", .{});
                }
            },
            .move => {
                if (scrutineeIsMove(frame, a)) continue;
                switch (a.*) {
                    .path => |*p| {
                        if (p.tail == .none and p.path.len == 1) {
                            if (lookupLocal(frame, p.path[0].text)) |local| {
                                if (isUnique(frame, local.type_) and local.state == .owned) {
                                    return frame.ck.fail(a.span(), "unique value must be moved with 'move' before being passed to a move parameter (Core §18)", .{});
                                }
                            }
                        }
                    },
                    else => {},
                }
                if (try isBorrowedExpr(frame, a)) {
                    return frame.ck.fail(a.span(), "cannot move a borrowed value (Core §10.7)", .{});
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Expression inference (frontend §4.3)
// ---------------------------------------------------------------------------

/// Infer the type an expression produces, recording it in `expr_of`
/// (frontend §4.3). Returns null when the type is not inferable; the node
/// is still visited so every child's type is recorded.
fn inferExpr(frame: *Frame, e: *const ast.Expr) CheckError!?cfg.Type {
    const t = try inferExprInner(frame, e);
    if (t) |tt| try frame.ma.expr_of.put(frame.ck.alloc(), e, tt);
    return t;
}

fn inferExprInner(frame: *Frame, e: *const ast.Expr) CheckError!?cfg.Type {
    const alloc = frame.ck.alloc();
    switch (e.*) {
        .int => return cfg.Type{ .primitive = .int32 },
        .float => return cfg.Type{ .primitive = .float32 },
        .string => return cfg.Type{ .primitive = .str },
        .bool => return cfg.Type{ .primitive = .bool },
        .void => return cfg.Type{ .primitive = .void },
        .import => return cfg.Type{ .module = {} },
        .path => |*p| return inferPath(frame, p),
        .paren => |*p| return inferExpr(frame, p.inner),
        .tuple => |*t| {
            var elems = try alloc.alloc(cfg.Type, t.elems.len);
            for (t.elems, 0..) |*el, i| {
                const et = try inferExpr(frame, el);
                if (try isBorrowedExpr(frame, el)) {
                    return frame.ck.fail(el.span(), "cannot store a borrowed value into an owning container (Core §10.7)", .{});
                }
                try requireMoveIfOwned(frame, el, "element");
                elems[i] = et orelse cfg.Type{ .primitive = .any };
            }
            return cfg.Type{ .tuple = elems };
        },
        .list => |*l| {
            var elem: cfg.Type = cfg.Type{ .primitive = .int32 };
            for (l.elems, 0..) |*el, i| {
                const et = try inferExpr(frame, el);
                if (try isBorrowedExpr(frame, el)) {
                    return frame.ck.fail(el.span(), "cannot store a borrowed value into an owning container (Core §10.7)", .{});
                }
                try requireMoveIfOwned(frame, el, "element");
                if (et) |t| {
                    if (i == 0) elem = t;
                }
            }
            const ptr = try alloc.create(cfg.Type);
            ptr.* = elem;
            return cfg.Type{ .list = ptr };
        },
        .lambda => |*lam| {
            _ = try pushScope(frame, true);
            defer popScope(frame);
            var params = try alloc.alloc(cfg.Param, lam.params.len);
            for (lam.params, 0..) |*p, i| {
                const t = try frame.ck.resolveTypeOf(frame.ma, frame.info, &p.type_);
                params[i] = .{ .span = p.span, .name = p.name, .mode = p.mode, .type_ = t };
                _ = try bindLocal(frame, p.name.text, t, p.mode == .borrow);
            }
            const ret = try checkBlock(frame, lam.body);
            const ret_ptr = try alloc.create(cfg.Type);
            ret_ptr.* = ret;
            return cfg.Type{ .function = .{ .params = params, .ret = ret_ptr } };
        },
        .if_ => |*i| {
            const tracked = try ownership.begin(frame);
            _ = try inferExpr(frame, i.cond);
            const entry = try ownership.entryStates(frame, tracked);
            const then_t = try checkBlock(frame, i.then);
            const then_path = try ownership.pathOf(frame, tracked, entry, ownership.blockCompletesNormally(frame, i.then));
            if (i.else_) |else_e| {
                try ownership.restore(frame, tracked, entry);
                const else_t = (try inferExpr(frame, else_e)) orelse cfg.Type{ .primitive = .void };
                const else_path = try ownership.pathOf(frame, tracked, entry, ownership.exprCompletesNormally(frame, else_e));
                try ownership.merge(frame, tracked, entry, &.{ then_path, else_path }, i.span);
                return try joinBranches(frame, i.span, then_t, else_t);
            }
            // An `if` without an `else` has an implicit else path that
            // releases nothing (Core §10.10).
            const noop = try ownership.noopPath(frame, tracked);
            try ownership.merge(frame, tracked, entry, &.{ then_path, noop }, i.span);
            return cfg.Type{ .primitive = .void };
        },
        .match => |*m| {
            const tracked = try ownership.begin(frame);
            const scrut_t = (try inferExpr(frame, m.scrutinee)) orelse cfg.Type{ .primitive = .any };
            // `match (move value)` consumes the complete owner; matching an
            // unique value through an ordinary expression borrows it, and
            // the arm's unique payload bindings are borrows for the arm
            // lifetime (Core §13.4). Only a statically known target
            // (`move`, or an unique path with no fresh owner) is checked
            // for the drop-hook restriction.
            const consuming = consumesScrutinee(frame, m.scrutinee, scrut_t);
            if (consuming) try checkDropHookMatch(frame, m, scrut_t);
            const entry = try ownership.entryStates(frame, tracked);
            var result: ?cfg.Type = null;
            const paths = try alloc.alloc(ownership.Path, m.arms.len);
            for (m.arms, 0..) |*arm, ai| {
                _ = try inferPattern(frame, &arm.pattern, scrut_t, !consuming);
                const at = (try inferExpr(frame, arm.body)) orelse cfg.Type{ .primitive = .void };
                result = if (result) |r| try joinBranches(frame, m.span, r, at) else at;
                paths[ai] = try ownership.pathOf(frame, tracked, entry, ownership.exprCompletesNormally(frame, arm.body));
                try ownership.restore(frame, tracked, entry);
            }
            try ownership.merge(frame, tracked, entry, paths, m.span);
            return result orelse cfg.Type{ .primitive = .void };
        },
        .block => |*b| return try checkBlock(frame, b.block),
        .unary => |*u| {
            const ot = try inferExpr(frame, u.operand);
            if (u.op == .not) return cfg.Type{ .primitive = .bool };
            return ot;
        },
        .binary => |*b| switch (b.op) {
            .and_, .or_ => {
                // Short-circuit operands are conditional constructs (Core
                // §16.2): the right operand runs on one path only, so a
                // release there is a release on some but not all paths.
                const tracked = try ownership.begin(frame);
                _ = try inferExpr(frame, b.lhs);
                const entry = try ownership.entryStates(frame, tracked);
                const lhs_path = try ownership.pathOf(frame, tracked, entry, true);
                _ = try inferExpr(frame, b.rhs);
                const rhs_path = try ownership.pathOf(frame, tracked, entry, ownership.exprCompletesNormally(frame, b.rhs));
                try ownership.merge(frame, tracked, entry, &.{ lhs_path, rhs_path }, b.span);
                return cfg.Type{ .primitive = .bool };
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                _ = try inferExpr(frame, b.lhs);
                _ = try inferExpr(frame, b.rhs);
                return cfg.Type{ .primitive = .bool };
            },
            .add, .sub, .mul, .div, .rem => {
                const lt = try inferExpr(frame, b.lhs);
                _ = try inferExpr(frame, b.rhs);
                return lt;
            },
        },
        .cast => |*c| {
            _ = try inferExpr(frame, c.operand);
            return try frame.ck.resolveTypeOf(frame.ma, frame.info, &c.target);
        },
        .member => |*mm| return try resolveMember(frame, mm.object, mm.name.text),
        .index => |*ix| {
            const ot = try inferExpr(frame, ix.object);
            _ = try inferExpr(frame, ix.index);
            if (ot) |t| {
                if (t == .list) return t.list.*;
            }
            return null;
        },
        .call => |*c| return inferCall(frame, c),
        .specialize => |*s| return inferSpecialize(frame, s),
        .move => |m| return try markConsumed(frame, m.name.text, m.span, "move", "moved"),
    }
}

fn inferPath(frame: *Frame, p: *const ast.PathExpr) CheckError!?cfg.Type {
    switch (p.tail) {
        .construct => |*sc| {
            // Struct construction: the path is a type name (Core §8.1).
            // Each field slot is an owning location, so a field value may
            // not be a borrowed unique value (Core §10.7), and an existing
            // unique local owner must be moved explicitly (Core §10.4).
            for (sc.fields) |*f| {
                _ = try inferExpr(frame, f.value);
                if (try isBorrowedExpr(frame, f.value)) {
                    return frame.ck.fail(f.value.span(), "cannot store a borrowed value into an owning field (Core §10.7)", .{});
                }
                try requireMoveIfOwned(frame, f.value, "field");
            }
            return namedPath(frame, p.path);
        },
        .variant => |*v| {
            // Union-variant construction: the path is a type name. Payload
            // slots are owning locations (Core §10.7), and an existing
            // unique local owner must be moved explicitly (Core §10.4).
            if (v.args) |args| {
                for (args) |*a| {
                    _ = try inferExpr(frame, a);
                    if (try isBorrowedExpr(frame, a)) {
                        return frame.ck.fail(a.span(), "cannot store a borrowed value into an owning payload (Core §10.7)", .{});
                    }
                    try requireMoveIfOwned(frame, a, "payload");
                }
            }
            return namedPath(frame, p.path);
        },
        .none => {},
    }

    return resolvePath(frame, p.path);
}

/// Resolve a dotted path's value type. The first segment resolves against
/// enclosing bindings (a local struct/tuple field chain, Core §15.1) and
/// then against module members (Core §2.5, §2.7); a local that has been
/// moved or definitely released is a use-after-move error (Core §18
/// *Ownership*).
fn resolvePath(frame: *Frame, path: []const ast.Ident) CheckError!?cfg.Type {
    const head = path[0];
    if (lookupLocalScope(frame, head.text)) |found| {
        // A lambda or function body may not capture a local binding from an
        // enclosing function scope (Core §6.2); module members and `using`
        // aliases have execution-context lifetime and are exempt.
        if (!found.local.is_using and isCapture(frame, found.scope)) {
            return frame.ck.fail(head.span, "lambda may not capture enclosing local binding '{s}' (Core §6.2)", .{found.local.name});
        }
        const local = found.local;
        if (isUnique(frame, local.type_)) {
            const kind: []const u8 = switch (local.state) {
                .consumed => "moved",
                .released => "released",
                .maybe => "maybe-released",
                else => "",
            };
            if (kind.len != 0) {
                return frame.ck.fail(head.span, "use of {s} value '{s}'", .{ kind, local.name });
            }
        }
        if (path.len == 1) return local.type_;
        var cur = local.type_;
        for (path[1..]) |seg| {
            cur = try memberTypeOf(frame, cur, seg) orelse return null;
        }
        return cur;
    }
    // Module-qualified paths (module value members, Core §2.5, §2.7).
    if (type_infer.resolvePathMember(frame.resolve, frame.info, path)) |vm| {
        // An unspecialized generic function is not a value (Core §12.4);
        // `identity::[int32]` is the first-class monomorphic form.
        if (vm.decl == .func and vm.decl.func.type_params.len > 0) {
            return frame.ck.fail(head.span, "unspecialized generic function '{s}' cannot be used as a value (Core §12.4)", .{vm.name.text});
        }
        return vm.type_;
    }
    return null;
}

/// Core §6.2 *Non-capture*: a function or lambda may reference its own
/// parameters and locals, module members, types, and builtins — but not a
/// local binding from an enclosing function scope. `scope_of_local` is the
/// scope that binds the referenced name; returns true when it lives in a
/// function scope strictly enclosing the innermost enclosing function
/// scope of the current position (module-root bindings are allowed).
fn isCapture(frame: *Frame, scope_of_local: *const Scope) bool {
    var own: ?*Scope = null;
    var s: ?*Scope = frame.scope;
    while (s) |sc| {
        if (sc.is_func) {
            own = sc;
            break;
        }
        s = sc.parent;
    }
    const own_s = own orelse return false;
    if (scope_of_local == own_s) return false;
    var up: ?*Scope = own_s.parent;
    while (up) |sc| {
        if (sc.parent == null) return false;
        if (sc == scope_of_local) return true;
        up = sc.parent;
    }
    return false;
}

/// The type of a member selected on `cur` by name (`cur.name`), for struct
/// fields and tuple elements (Core §15.1).
fn memberTypeOf(frame: *Frame, cur: cfg.Type, seg: ast.Ident) CheckError!?cfg.Type {
    switch (cur) {
        .named => |n| {
            const qname = frame.resolve.typeNameOf(n) orelse return null;
            const sd = moduleinfo.structDecl(frame.resolve, frame.info, qname) orelse return null;
            const idx = moduleinfo.fieldIndex(sd, seg.text) orelse return null;
            return try frame.ck.resolveTypeOf(frame.ma, frame.info, &sd.fields[idx].type_);
        },
        .tuple => |elems| {
            const idx = std.fmt.parseInt(usize, seg.text, 10) catch return null;
            if (idx >= elems.len) return null;
            return elems[idx];
        },
        else => return null,
    }
}

fn namedPath(frame: *Frame, path: []const ast.Ident) CheckError!?cfg.Type {
    const name = type_resolve.joinPath(frame.ck.alloc(), path) orelse return null;
    return cfg.Type{ .named = (moduleinfo.resolveTypeId(frame.resolve, frame.info, name) orelse return null) };
}

// ---------------------------------------------------------------------------
// Calls (frontend §4.3, §4.4)
// ---------------------------------------------------------------------------

fn inferCall(frame: *Frame, c: *const ast.Call) CheckError!?cfg.Type {
    var callee = c.callee;
    var explicit: ?[]cfg.Type = null;
    if (callee.* == .specialize) {
        explicit = try resolveSpecializeArgs(frame, &callee.specialize);
        callee = callee.specialize.operand;
    }

    // A call to a generic function specializes it from the argument types
    // and/or the explicit `::[...]` arguments (Core §12.2, §12.3); the
    // callee is a template, not a value, so its operand is not visited.
    if (try inferCalleeDecl(frame, callee)) |target| {
        const decl = target.vm.decl.func;
        if (decl.type_params.len > 0) {
            var arg_types = try frame.ck.alloc().alloc(cfg.Type, c.args.len);
            for (c.args, 0..) |*a, i| {
                arg_types[i] = (try inferExpr(frame, a)) orelse cfg.Type{ .primitive = .any };
            }
            const inst = try specializeInstance(frame, target, explicit, arg_types);
            try frame.ma.call_of.put(frame.ck.alloc(), c, inst);
            try checkArgsOwnership(frame, c, arg_types, inst.signature);
            const ft = switch (inst.signature) {
                .function => |f| f,
                else => return null,
            };
            return ft.ret.*;
        }
        if (explicit != null) {
            return frame.ck.fail(c.span, "only generic functions take type arguments", .{});
        }
    }

    // Non-generic callee: visit it as a value and record its signature.
    _ = try inferExpr(frame, c.callee);

    const fn_t = try inferCallee(frame, callee) orelse return null;
    if (fn_t != .function) return null;
    const sig = fn_t.function;

    var arg_types = try frame.ck.alloc().alloc(cfg.Type, c.args.len);
    for (c.args, 0..) |*a, i| {
        arg_types[i] = (try inferExpr(frame, a)) orelse cfg.Type{ .primitive = .any };
    }

    try checkArgsOwnership(frame, c, arg_types, fn_t);

    // Record the concrete signature for the validate pass only when the
    // callee has no type parameters (generic calls specialize per site).
    if (!hasTypeVars(frame, fn_t)) {
        try frame.ma.call_sig.put(frame.ck.alloc(), c, fn_t);
    }

    const specialized = moduleinfo.specializeSignature(frame.resolve, frame.info, sig, arg_types);
    const ft = switch (specialized) {
        .function => |f| f,
        else => return null,
    };
    return ft.ret.*;
}

// ---------------------------------------------------------------------------
// Generic expansion (frontend §4.4, Core §12)
// ---------------------------------------------------------------------------

/// A `::[...]` specialization in value position (Core §12.3, §12.4):
/// `identity::[int32]` is a first-class monomorphic function value. On a
/// non-function operand the type arguments are simply ignored (peeled),
/// matching the old inference behavior.
fn inferSpecialize(frame: *Frame, s: *const ast.Specialize) CheckError!?cfg.Type {
    if (try inferCalleeDecl(frame, s.operand)) |target| {
        const decl = target.vm.decl.func;
        if (decl.type_params.len > 0) {
            const args = try resolveSpecializeArgs(frame, s);
            const inst = try specializeInstance(frame, target, args, &[_]cfg.Type{});
            try frame.ma.spec_of.put(frame.ck.alloc(), s, inst);
            return inst.signature;
        }
        return frame.ck.fail(s.span, "only generic functions take type arguments", .{});
    }
    return inferExpr(frame, s.operand);
}

/// Resolve a callee expression to the function declaration it names, when
/// it is a statically-known function (a module member path, Core §2.5,
/// §2.7). Returns null for any other expression (a local lambda, a value
/// through a struct field, …).
fn inferCalleeDecl(frame: *Frame, callee: *const ast.Expr) CheckError!?moduleinfo.PathTarget {
    switch (callee.*) {
        .path => |*p| {
            if (p.tail == .none) {
                if (type_infer.resolvePathTarget(frame.resolve, frame.info, p.path)) |target| {
                    if (target.vm.decl == .func) return target;
                }
            }
            return null;
        },
        .member => |*mm| {
            if (try moduleValueOf(frame, mm.object)) |mi| {
                if (mi.valueMember(mm.name.text)) |vm| {
                    if (vm.decl == .func) return .{ .vm = vm, .module = mi };
                }
            }
            return null;
        },
        else => return null,
    }
}

/// Resolve the type arguments of an explicit `::[...]` specialization
/// (Core §12.3).
fn resolveSpecializeArgs(frame: *Frame, s: *const ast.Specialize) CheckError![]cfg.Type {
    const args = try frame.ck.alloc().alloc(cfg.Type, s.type_args.len);
    for (s.type_args, 0..) |*t, i| {
        args[i] = try frame.ck.resolveTypeOf(frame.ma, frame.info, t);
    }
    return args;
}

/// Create (or reuse) the `FuncInstance` for one specialization of a
/// generic function: type arguments from the explicit list or inferred
/// from the argument types, a monomorphic signature, and — for Stilla
/// bodies — a monomorphized clone checked under the concrete substitution
/// (frontend §4.4). Host bindings get `mono = null` (frontend §5.6).
fn specializeInstance(
    frame: *Frame,
    target: moduleinfo.PathTarget,
    explicit: ?[]const cfg.Type,
    arg_types: []const cfg.Type,
) CheckError!*checker.FuncInstance {
    const ck = frame.ck;
    const decl = target.vm.decl.func;
    const def_module = target.module;
    const def_ma = try ck.moduleAnnotation(def_module);
    const def_resolve = moduleinfo.Resolve{ .arena = ck.alloc(), .by_specifier = &ck.graph.?.by_specifier, .type_ids = &ck.graph.?.type_interner };
    const sig = switch (target.vm.type_) {
        .function => |f| f,
        else => return ck.fail(target.vm.name.span, "generic declaration has no function signature", .{}),
    };

    // Build the type-parameter substitution (Core §12.2, §12.3).
    var env = std.StringHashMapUnmanaged(cfg.Type).empty;
    if (explicit) |args| {
        if (args.len != decl.type_params.len) {
            return ck.fail(target.vm.name.span, "expected {d} type argument(s), found {d}", .{ decl.type_params.len, args.len });
        }
        for (decl.type_params, args) |tp, a| {
            try env.put(ck.alloc(), tp.text, a);
        }
    } else {
        _ = type_infer.bindTypeArgs(def_resolve, def_module, sig, arg_types, &env);
        for (decl.type_params) |tp| {
            if (!env.contains(tp.text)) {
                return ck.fail(target.vm.name.span, "cannot infer type argument '{s}'", .{tp.text});
            }
        }
    }

    // The instance's type arguments, ordered by the declaration's
    // parameter list.
    const type_args = try ck.alloc().alloc(cfg.Type, decl.type_params.len);
    for (decl.type_params, 0..) |tp, i| {
        type_args[i] = env.get(tp.text).?;
    }

    // Deduplicate per (declaration, type arguments): each specialization is
    // expanded and checked exactly once (frontend §4.4).
    for (ck.annotation.instances.items) |inst| {
        if (inst.decl != decl) continue;
        if (!typeArgsEqual(inst.type_args, type_args)) continue;
        return inst;
    }

    const inst = try ck.alloc().create(checker.FuncInstance);
    inst.* = .{
        .decl = decl,
        .type_args = type_args,
        .signature = type_infer.substSignature(def_resolve, def_module, sig, &env),
        .mono = null,
    };
    // Append before the body is checked so a self-recursive generic call
    // deduplicates to the in-flight instance.
    try ck.annotation.instances.append(ck.alloc(), inst);
    if (decl.body != null) {
        inst.mono = try monomorphize.monomorphizeFunc(ck.alloc(), def_resolve, decl, type_args);
        try checkInstanceBody(ck, def_module, def_ma, inst.mono.?);
    }
    return inst;
}

fn typeArgsEqual(a: []const cfg.Type, b: []const cfg.Type) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!cfg.Type.eql(x, y)) return false;
    }
    return true;
}

/// Check one monomorphized instance body under its concrete substitution:
/// annotate it (against the defining module, so cross-module types resolve
/// correctly) and run the §4.6 checks on it. Unspecialized generic bodies
/// are never checked (Core §12.4).
fn checkInstanceBody(ck: *checker.Checker, info: *ModuleInfo, ma: *ModuleAnnotation, f: *const ast.FuncDef) CheckError!void {
    const root = try ck.alloc().create(Scope);
    root.* = .{};
    const frame = try ck.alloc().create(Frame);
    frame.* = .{
        .ck = ck,
        .info = info,
        .ma = ma,
        .resolve = .{ .arena = ck.alloc(), .by_specifier = &ck.graph.?.by_specifier, .type_ids = &ck.graph.?.type_interner },
        .scope = root,
    };
    try checkFuncBody(frame, f, f.body.?);
    try validate.validateMonomorphized(ck, info, ma, f);
}

/// True when a type mentions an unresolved named type — the signature of a
/// generic binding (recursive: `list[T]`, `fn(move A) -> B`).
fn hasTypeVars(frame: *Frame, t: cfg.Type) bool {
    return switch (t) {
        .primitive, .module, .cleanup => false,
        // Every `.named` is a concrete interned decl; only `.param` marks
        // an unresolved generic type variable.
        .named => false,
        .param => true,
        .list => |inner| hasTypeVars(frame, inner.*),
        .box => |inner| hasTypeVars(frame, inner.*),
        .tuple => |elems| blk: {
            for (elems) |e| if (hasTypeVars(frame, e)) break :blk true;
            break :blk false;
        },
        .function => |f| blk: {
            for (f.params) |p| if (hasTypeVars(frame, p.type_)) break :blk true;
            break :blk hasTypeVars(frame, f.ret.*);
        },
    };
}

fn inferCallee(frame: *Frame, callee: *const ast.Expr) CheckError!?cfg.Type {
    switch (callee.*) {
        .path => |*p| {
            if (p.tail == .none) {
                if (type_infer.resolvePathMember(frame.resolve, frame.info, p.path)) |vm| return vm.type_;
                // A local fn-typed binding (a parameter or let-bound
                // function value): calling through it is a first-class
                // function-value call (Core §12.4). Non-capture (Core §18)
                // is enforced here exactly as for any other reference to
                // an enclosing-scope local.
                if (p.path.len == 1) {
                    if (lookupLocalScope(frame, p.path[0].text)) |found| {
                        if (!found.local.is_using and isCapture(frame, found.scope)) {
                            return frame.ck.fail(p.path[0].span, "lambda may not capture enclosing local binding '{s}' (Core §6.2)", .{found.local.name});
                        }
                        const lt = found.local.type_;
                        if (lt == .function) return lt;
                    }
                }
            }
            return null;
        },
        .member => |*mm| return try resolveMember(frame, mm.object, mm.name.text),
        else => return null,
    }
}

/// Resolve `object.name`: a module member of a module value, a field of a
/// struct value (Core §15.1), or an element of a tuple (named by index).
fn resolveMember(frame: *Frame, object: *const ast.Expr, name: []const u8) CheckError!?cfg.Type {
    if (try moduleValueOf(frame, object)) |mi| {
        if (mi.valueMember(name)) |vm| {
            // Module generic names follow the same rule as module paths:
            // an unspecialized generic is not a value (Core §12.4).
            if (vm.decl == .func and vm.decl.func.type_params.len > 0) {
                return frame.ck.fail(object.span(), "unspecialized generic function '{s}' cannot be used as a value (Core §12.4)", .{vm.name.text});
            }
            return vm.type_;
        }
        return null;
    }
    const obj_t = (try inferExpr(frame, object)) orelse return null;
    switch (obj_t) {
        .named => |n| {
            const qname = frame.resolve.typeNameOf(n) orelse return null;
            const sd = moduleinfo.structDecl(frame.resolve, frame.info, qname) orelse return null;
            const idx = moduleinfo.fieldIndex(sd, name) orelse return null;
            return try frame.ck.resolveTypeOf(frame.ma, frame.info, &sd.fields[idx].type_);
        },
        .tuple => |elems| {
            const idx = std.fmt.parseInt(usize, name, 10) catch return null;
            if (idx >= elems.len) return null;
            return elems[idx];
        },
        else => return null,
    }
}

/// The module a path/member-chain expression denotes, when it is a module
/// value (Core §2.3, §2.7).
fn moduleValueOf(frame: *Frame, object: *const ast.Expr) CheckError!?*ModuleInfo {
    switch (object.*) {
        .path => |*p| {
            if (p.tail == .none and p.path.len == 1) {
                if (frame.info.valueMember(p.path[0].text)) |vm| {
                    if (vm.module_spec) |spec| return frame.resolve.module(spec);
                }
            }
            return null;
        },
        .member => |*mm| {
            if (try moduleValueOf(frame, mm.object)) |mi| {
                if (mi.valueMember(mm.name.text)) |vm| {
                    if (vm.module_spec) |spec| return frame.resolve.module(spec);
                }
            }
            return null;
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Patterns (frontend §4.3)
// ---------------------------------------------------------------------------

/// Bind the names a pattern introduces, given the value type it matches.
/// Type-test patterns bind the tested type (Core §14.7); union-variant
/// patterns bind the variant's payload types; the list-with-rest pattern
/// binds the head elements and the rest list.
///
/// When `borrow` is set (a non-consuming `match`/`for` over an unique
/// owner, Core §13.4, §13.5), the unique bindings become borrows: they may
/// be read and passed along, but not moved or dropped.
fn inferPattern(frame: *Frame, p: *const ast.Pattern, value_t: cfg.Type, borrow: bool) CheckError!void {
    switch (p.*) {
        .wildcard => {},
        .literal => |*lit| {
            _ = lit;
        },
        .type_test => |*tt| {
            if (tt.binding) |b| {
                const t = try frame.ck.resolveTypeOf(frame.ma, frame.info, &tt.type_);
                _ = try bindLocal(frame, b.text, t, borrow and isUnique(frame, t));
            }
        },
        .tuple => |*tp| {
            if (value_t == .tuple) {
                for (tp.elems, 0..) |*el, i| {
                    const elem_t = if (i < value_t.tuple.len) value_t.tuple[i] else cfg.Type{ .primitive = .any };
                    try inferPattern(frame, el, elem_t, borrow);
                }
            }
        },
        .path => |*pp| switch (pp.tail) {
            .none => {
                // A bare identifier pattern binds the whole value.
                if (pp.path.len == 1) _ = try bindLocal(frame, pp.path[0].text, value_t, borrow and isUnique(frame, value_t));
            },
            .struct_ => |*sp| {
                if (value_t == .named) {
                    const sd = moduleinfo.structDecl(frame.resolve, frame.info, frame.resolve.typeNameOf(value_t.named) orelse return) orelse return;
                    for (sp.fields) |*f| {
                        const idx = moduleinfo.fieldIndex(sd, f.name.text) orelse continue;
                        const field_t = try frame.ck.resolveTypeOf(frame.ma, frame.info, &sd.fields[@intCast(idx)].type_);
                        if (f.pattern) |*fp| {
                            try inferPattern(frame, fp, field_t, borrow);
                        } else {
                            _ = try bindLocal(frame, f.name.text, field_t, borrow and isUnique(frame, field_t));
                        }
                    }
                }
            },
            .variant => |*vp| {
                if (value_t == .named) {
                    const name = type_resolve.joinPath(frame.ck.alloc(), pp.path) orelse return;
                    const ud = moduleinfo.unionDecl(frame.resolve, frame.info, name) orelse return;
                    const idx = moduleinfo.variantIndex(ud, vp.name.text) orelse return;
                    if (vp.args) |args| {
                        if (ud.variants[@intCast(idx)].types) |types| {
                            for (args, 0..) |*a, i| {
                                const payload_t = if (i < types.len)
                                    try frame.ck.resolveTypeOf(frame.ma, frame.info, &types[i])
                                else
                                    cfg.Type{ .primitive = .any };
                                try inferPattern(frame, a, payload_t, borrow);
                            }
                        }
                    }
                }
            },
        },
        .list => |*lp| {
            const elem_t: cfg.Type = if (value_t == .list) value_t.list.* else cfg.Type{ .primitive = .any };
            for (lp.items) |*it| try inferPattern(frame, it, elem_t, borrow);
            if (lp.rest) |r| _ = try bindLocal(frame, r.text, value_t, borrow and isUnique(frame, value_t));
        },
    }
}

/// Unify the types of two branch/arm results: `never` coerces to the other,
/// equal types keep their shape, anything else widens to `any`.
/// Join the branch types of an `if`/`match` (Core §13.2). Equal types
/// join to themselves, `never` contributes nothing, and a mixed join
/// widens to `any` — except that `hostdata` does not coerce to `any`
/// (Core §11.6, §11.7), so a mixed join involving `hostdata` is a
/// compile-time error.
fn joinBranches(frame: *Frame, span: ast.Span, a: cfg.Type, b: cfg.Type) CheckError!cfg.Type {
    if (a == .primitive and a.primitive == .never) return b;
    if (b == .primitive and b.primitive == .never) return a;
    if (cfg.Type.eql(a, b)) return a;
    if (isHostdata(a) or isHostdata(b)) {
        return frame.ck.fail(span, "'hostdata' does not coerce to 'any' (Core §11.6, §11.7); a branch of type 'hostdata' cannot join a branch of another type", .{});
    }
    return cfg.Type{ .primitive = .any };
}

fn isHostdata(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .hostdata;
}
