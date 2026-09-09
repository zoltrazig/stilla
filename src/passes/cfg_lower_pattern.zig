//! Pass: pattern shape queries shared with the HIR seam. The direct AST
//! pattern lowering (bindPattern / destructureStruct/Tuple/List/Variant
//! and their helpers) was removed in PROGRESS S6b — the HIR seam lowers
//! patterns from `hir.Pattern` (see hir_lower_pattern.zig) with the
//! same atomic `unpack_*`/`split_list`/`read_*` semantics. Only the
//! AST-shape query the builder still needs survives here.

const std = @import("std");
const ast = @import("stilla").ast;

/// True when a pattern contains a type-test pattern anywhere (Core
/// §14.7). Type-test patterns are refutable, so `let` and `for` — which
/// require irrefutable patterns — reject them (Core §14). The HIR
/// builder mirrors cfg_lower_control's match rules with this query
/// (whole-arm type tests only, wildcard required).
pub fn patternHasTypeTest(p: *const ast.Pattern) bool {
    return switch (p.*) {
        .type_test => true,
        .tuple => |tp| blk: {
            for (tp.elems) |*el| {
                if (patternHasTypeTest(el)) break :blk true;
            }
            break :blk false;
        },
        .list => |lp| blk: {
            for (lp.items) |*el| {
                if (patternHasTypeTest(el)) break :blk true;
            }
            break :blk false;
        },
        .path => |pp| switch (pp.tail) {
            .struct_ => |sp| blk: {
                for (sp.fields) |*f| {
                    if (f.pattern) |*fp| {
                        if (patternHasTypeTest(fp)) break :blk true;
                    }
                }
                break :blk false;
            },
            .variant => |vp| blk: {
                if (vp.args) |args| for (args) |*a| {
                    if (patternHasTypeTest(a)) break :blk true;
                };
                break :blk false;
            },
            .none => false,
        },
        .wildcard, .literal => false,
    };
}
