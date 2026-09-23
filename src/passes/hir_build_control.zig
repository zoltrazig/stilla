//! Part of the AST→HIR builder (hir.md §5.5; driver:
//! `hir_build.zig`): the two-region control nodes (`if`, `and`/`or`
//! short-circuit rows), `if`, and `match` with its arm regions.

const std = @import("std");
const ast = @import("stilla").ast;
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const moduleinfo = @import("stilla").moduleinfo;
const cfg_lower_pattern = @import("cfg_lower_pattern.zig");
const hir_build = @import("hir_build.zig");
const hir_build_block = @import("hir_build_block.zig");
const hir_build_expr = @import("hir_build_expr.zig");
const hir_build_pattern = @import("hir_build_pattern.zig");

/// `ifNode(cond, then, else)`: two regions rooted at the branch values.
fn ifNode(b: *hir_build.Builder, span: meta.Span, cond: hir.ExprId, then: hir.ExprId, else_: hir.ExprId) hir_build.BuildError!hir.ExprId {
    return controlNode(b, span, "if", cond, then, else_);
}

/// One control node with two regions (`if`, or the `and`/`or` short-circuit
/// rows — the §5.5/§7.1 amendment: and/or keep their own rows so the
/// HIR→CFG lowering can reproduce the reference short-circuit diamond).
pub fn controlNode(b: *hir_build.Builder, span: meta.Span, op_name: []const u8, cond: hir.ExprId, then: hir.ExprId, else_: hir.ExprId) hir_build.BuildError!hir.ExprId {
    const ops = try b.built.program.addOperands(&.{cond});
    const rt = try b.built.program.addRegion(&.{}, then, null);
    const re = try b.built.program.addRegion(&.{}, else_, null);
    const regs = try b.built.program.addRegions(&.{ rt, re });
    const tty = b.built.program.typeOf(b.built.program.node(then).ty);
    const ety = b.built.program.typeOf(b.built.program.node(else_).ty);
    return b.built.program.addExpr(.{ .op = try b.op(span, op_name), .ty = try b.internTy(unifyJoin(tty, ety)), .operands = ops, .regions = regs, .origin = try b.origin(span) });
}

/// The join type of two branch values: never contributes nothing; equal
/// types join to themselves; a mixed pair joins as `any`.
fn unifyJoin(a: meta.Type, b_: meta.Type) meta.Type {
    if (a == .primitive and a.primitive == .never) return b_;
    if (b_ == .primitive and b_.primitive == .never) return a;
    if (meta.Type.eql(a, b_)) return a;
    return meta.Type{ .primitive = .any };
}

pub fn buildIf(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, i: *const ast.IfExpr) hir_build.BuildError!hir.ExprId {
    const cond = try hir_build_expr.buildExpr(b, info, i.cond);
    const then = try hir_build_block.buildBlock(b, info, i.then);
    const else_ = if (i.else_) |el| try hir_build_expr.buildExpr(b, info, el) else try hir_build_expr.voidLiteral(b, i.span);
    return ifNode(b, i.span, cond, then, else_);
}

// ---------------------------------------------------------------------------
// match and patterns
// ---------------------------------------------------------------------------

pub fn buildMatch(b: *hir_build.Builder, info: *moduleinfo.ModuleInfo, e: *const ast.Expr, m: *const ast.MatchExpr) hir_build.BuildError!hir.ExprId {
    const scrut = try hir_build_expr.buildExpr(b, info, m.scrutinee);
    const scrut_ty = b.built.program.typeOf(b.built.program.node(scrut).ty);
    const moving = hir_build_block.isMoveExpr(m.scrutinee);
    const ops = try b.built.program.addOperands(&.{scrut});
    // Type-test arms over an 'any' scrutinee — mirror cfg_lower_control's
    // lowerPatternMatch rules: at least one type test anywhere demands a
    // wildcard arm, and a type test nested under a tuple/list/struct arm
    // would recover a payload without a preceding `type_is` test, so only
    // whole-arm type tests are allowed (Core §14.7).
    var has_type_test = false;
    for (m.arms) |*arm| {
        if (cfg_lower_pattern.patternHasTypeTest(&arm.pattern)) {
            has_type_test = true;
            break;
        }
    }
    if (has_type_test) {
        var has_wildcard = false;
        for (m.arms) |*arm| if (arm.pattern == .wildcard) {
            has_wildcard = true;
            break;
        };
        if (!has_wildcard) {
            return b.fail(m.span, "a match over an 'any' value with type-test patterns must include a wildcard '_' arm", .{});
        }
        for (m.arms) |*arm| {
            if (arm.pattern != .type_test and cfg_lower_pattern.patternHasTypeTest(&arm.pattern)) {
                return b.fail(arm.span, "a type-test pattern must be the whole arm of a match", .{});
            }
        }
    }
    var reg_ids = std.ArrayList(hir.RegionId).empty;
    var arm_tys = std.ArrayList(meta.Type).empty;
    for (m.arms) |*arm| {
        var binder_ids = std.ArrayList(hir.BinderId).empty;
        const pat_id = try hir_build_pattern.buildPattern(b, info, &arm.pattern, scrut_ty, moving, &binder_ids);
        try b.pushScope();
        try hir_build_pattern.bindPatternLeaves(b, &arm.pattern, binder_ids.items);
        const body = try hir_build_expr.buildExpr(b, info, arm.body);
        b.popScope();
        try arm_tys.append(b.arena, b.built.program.typeOf(b.built.program.node(body).ty));
        const rid = try b.built.program.addRegion(binder_ids.items, body, pat_id);
        try reg_ids.append(b.arena, rid);
    }
    const regs = try b.built.program.addRegions(reg_ids.items);
    var jt: meta.Type = .{ .primitive = .void };
    for (arm_tys.items) |t2| jt = unifyJoin(jt, t2);
    return b.built.program.addExpr(.{ .op = try b.op(m.span, "match"), .ty = try b.internTy(b.annotatedType(info, e) orelse jt), .operands = ops, .regions = regs, .origin = try b.origin(m.span) });
}
