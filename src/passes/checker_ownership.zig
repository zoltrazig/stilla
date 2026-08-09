//! Pass: ownership analysis — conditional release and state merging
//! (phase2-checker.md, Ownership analysis; Core §10.10). In: a `Frame` at the entry of a
//! conditional construct (if/else, match, short-circuit `and`/`or`, or a
//! `for` loop) and the construct's evaluated branches. Out: the
//! `BindingState.released` and `BindingState.maybe` transitions that mark
//! enclosing unique bindings after the construct.
//!
//! Core §10.10: when a branch of a conditional construct releases an
//! unique binding (`move`, `drop`, or consuming destructure), every normal
//! path through the construct must release it by the construct's end,
//! unless it was already released before the construct was entered. After
//! the construct each enclosing unique binding is therefore definitely
//! owned, definitely released, or *maybe-unique* (released on some but not
//! all normal paths). A definitely-released binding is unusable
//! (use-after-move, Core §18) and is not auto-destroyed at scope end; a
//! maybe binding is also unusable, but the implementation tracks at
//! runtime whether it still needs destruction (`trydrop`) and destroys it
//! only on the paths that did not release it. Panic/trap (never) paths are
//! not normal control flow: they neither satisfy nor violate the release
//! requirement.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const checker = @import("checker.zig");

const CheckError = checker.CheckError;
const Frame = checker.Frame;
const Local = checker.Local;
const Scope = checker.Scope;
const BindingState = checker.BindingState;

/// One completed path through a conditional construct: which tracked
/// bindings were released along it, and whether the path completes
/// normally (a `never`/trap path is not normal control flow, Core §10.10).
pub const Path = struct {
    released: []bool,
    normal: bool,
};

/// Collect the unique locals visible at a conditional-construct entry:
/// every binding in the scope chain whose type is owned. Bindings created
/// inside the construct (branch locals, arm patterns, loop variables) are
/// not enclosing bindings and are not tracked.
pub fn begin(frame: *Frame) CheckError![]*Local {
    var tracked = std.ArrayList(*Local).empty;
    var s: ?*Scope = frame.scope;
    while (s) |sc| {
        var it = sc.locals.valueIterator();
        while (it.next()) |lptr| {
            const local: *Local = lptr.*;
            if (isUnique(frame, local.type_)) try tracked.append(frame.ck.alloc(), local);
        }
        s = sc.parent;
    }
    return tracked.items;
}

/// The tracked bindings' states at construct entry. Call after the
/// condition/scrutinee has been evaluated: an unconditional release there
/// (a single path) makes the binding dead at entry, so the construct
/// itself need not release it again.
pub fn entryStates(frame: *Frame, tracked: []*Local) CheckError![]BindingState {
    const states = try frame.ck.alloc().alloc(BindingState, tracked.len);
    for (tracked, 0..) |l, i| states[i] = l.state;
    return states;
}

/// Whether a binding is already dead (released, maybe, or consumed) and
/// therefore outside the merge.
fn isDead(state: BindingState) bool {
    return state == .consumed or state == .released or state == .maybe;
}

/// Which tracked bindings were released (became dead) since the entry
/// snapshot. Bindings already dead at entry are not counted as released by
/// this construct.
pub fn releasedMask(frame: *Frame, tracked: []*Local, entry: []BindingState) CheckError![]bool {
    const mask = try frame.ck.alloc().alloc(bool, tracked.len);
    for (tracked, 0..) |l, i| mask[i] = isDead(l.state) and !isDead(entry[i]);
    return mask;
}

/// Reset the tracked bindings to their entry states (a branch's releases
/// must not leak into the next branch).
pub fn restore(frame: *Frame, tracked: []*Local, entry: []BindingState) CheckError!void {
    for (tracked, 0..) |l, i| try checker.setState(frame, l, entry[i]);
}

/// One branch's released mask plus its normal-completion flag.
pub fn pathOf(frame: *Frame, tracked: []*Local, entry: []BindingState, normal: bool) CheckError!Path {
    return .{ .released = try releasedMask(frame, tracked, entry), .normal = normal };
}

/// A normal path that releases nothing (the implicit `else` of an
/// `if` without an `else`).
pub fn noopPath(frame: *Frame, tracked: []*Local) CheckError!Path {
    const mask = try frame.ck.alloc().alloc(bool, tracked.len);
    @memset(mask, false);
    return .{ .released = mask, .normal = true };
}

/// Merge a conditional construct's paths (Core §10.10). A tracked binding
/// released on every normal path becomes definitely released; released on
/// some but not all normal paths becomes *maybe-unique* (unusable
/// afterward, conditionally destroyed at runtime); otherwise it is
/// restored to its entry state.
pub fn merge(frame: *Frame, tracked: []*Local, entry: []BindingState, paths: []const Path, span: ast.Span) CheckError!void {
    _ = span;
    for (tracked, 0..) |l, i| {
        if (isDead(entry[i])) continue;
        var released_any = false;
        var released_all = true;
        var normal_any = false;
        for (paths) |p| {
            if (!p.normal) continue;
            normal_any = true;
            if (p.released[i]) released_any = true else released_all = false;
        }
        try checker.setState(frame, l, if (normal_any and released_any and !released_all) BindingState.maybe else if (released_all) BindingState.released else entry[i]);
    }
}

/// Whether evaluating `b` terminates normally: `false` when a statement
/// (or the trailing expression) has type `never`, i.e. the block traps
/// before completing. Types come from the annotation tables, so call after
/// the block has been inferred.
pub fn blockCompletesNormally(frame: *Frame, b: *const ast.Block) bool {
    for (b.stmts) |*stmt| switch (stmt.*) {
        .expr => |*e| if (exprIsNever(frame, &e.expr)) return false,
        else => {},
    };
    if (b.result) |*r| return !exprIsNever(frame, r);
    return true;
}

/// Whether evaluating `e` completes normally (`false` when its inferred
/// type is `never`).
pub fn exprCompletesNormally(frame: *Frame, e: *const ast.Expr) bool {
    return !exprIsNever(frame, e);
}

fn exprIsNever(frame: *Frame, e: *const ast.Expr) bool {
    const t = frame.ma.expr_of.get(e) orelse return false;
    return t == .primitive and t.primitive == .never;
}

/// Whether a value of type `t` is owned (not Copy); unique types are
/// subject to move/drop/conditional-release tracking (Core §18).
fn isUnique(frame: *Frame, t: cfg.Type) bool {
    return checker.isUnique(frame, t);
}
