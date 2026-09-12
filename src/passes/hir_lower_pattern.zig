//! Pass: HIR pattern lowering (docs/hir.md §9, §5.4; PROGRESS S5). In:
//! Ctx + FuncState + a `hir.Pattern` (or an arm region) + the base
//! value. Out: bindings for the pattern's leaves, with the direct
//! `cfg_lower_pattern` semantics — atomic `unpack_*`/`split_list` for a
//! consuming (whole-owner) destructure, `read_*` projections otherwise,
//! wildcard drops, and the match-arm test chain (`eq`/`type_is`/length).
//! The HIR patterns carry resolved field indexes and variant tags, and
//! binding leaves name region params directly, so no name resolution
//! happens here.

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const lower = @import("stilla").lower;
const cfg_lower_emit = @import("cfg_lower_emit.zig");
const cfg_lower_expr = @import("cfg_lower_expr.zig");
const cfg_lower_intrinsic = @import("cfg_lower_intrinsic.zig");
const hir_lower = @import("hir_lower.zig");
const hir_lower_expr = @import("hir_lower_expr.zig");

const Ctx = hir_lower.Ctx;
const Lowerer = lower.Lowerer;
const FuncState = lower.FuncState;
const LowerError = lower.LowerError;
const no_span = hir_lower.no_span;

/// Bind a pattern against `base`. `base_owned` is the whole-owner rule
/// (Core §14.6): a consuming destructure takes the base as a whole.
pub fn bindPattern(c: *Ctx, fs: *FuncState, pid: hir.PatternId, base: *cfg.Value, base_owned: bool) LowerError!void {
    const self = c.self;
    switch (c.built.program.pattern(pid)) {
        .wildcard => {
            // `let _ = expr`: the value is discarded.
            if (base.ownership == .unique and base.state == .owned and !cfg_lower_emit.isConsumed(fs, base)) {
                try cfg_lower_emit.emitDrop(self, fs, no_span, base);
            }
        },
        .literal => {}, // tested by the match's eq chain
        .bind => |bid| {
            try hir_lower.bindBinder(c, fs, bid, base, base.ownership == .unique and base.state == .owned);
        },
        .type_test => |tp| {
            // The arm's `type_is` test verified the tag, so the unpack
            // extracts the payload without trapping (Core §11.6.1–2).
            if (base.type_ != .primitive or base.type_.primitive != .any) {
                return self.fail(no_span, "a type-test pattern requires an 'any' scrutinee", .{});
            }
            if (cfg_lower_emit.isUnique(self, fs, tp.ty) and !base_owned) {
                return self.fail(no_span, "cannot recover an unique payload from a borrowed 'any'", .{});
            }
            const op: cfg.Op = if (base_owned) .{ .any_unpack_move = base } else .{ .any_unpack_copy = base };
            const payload = (try cfg_lower_emit.emit(self, fs, no_span, op, tp.ty)) orelse return;
            try hir_lower.bindBinder(c, fs, tp.bind, payload, payload.state == .owned and payload.ownership == .unique);
        },
        .tuple => |elems| {
            const elem_types = switch (base.type_) {
                .tuple => |t| t,
                else => return self.fail(no_span, "tuple pattern requires a tuple value", .{}),
            };
            if (elems.len > elem_types.len) return self.fail(no_span, "tuple pattern has too many elements", .{});
            if (base_owned) {
                const results = try cfg_lower_emit.emitUnpack(self, fs, no_span, .{ .unpack_tuple = base }, elem_types[0..elems.len]);
                cfg_lower_emit.markConsumed(self, fs, base);
                try cfg_lower_emit.cleanupDisable(self, fs, no_span, base);
                for (elems, results) |el, proj| try bindPattern(c, fs, el, proj, proj.state == .owned);
            } else {
                for (elems, 0..) |el, i| {
                    const proj = (try cfg_lower_emit.emit(self, fs, no_span, .{ .read_tuple = .{ .base = base, .index = @intCast(i) } }, elem_types[i])) orelse continue;
                    try bindPattern(c, fs, el, proj, proj.state == .owned);
                }
            }
        },
        .list => |lp| try destructureList(c, fs, lp, base, base_owned),
        .struct_ => |sp| {
            if (base_owned) {
                // Atomic destructure: one `unpack_struct` consumes the
                // base and defines every field value at once. The
                // builder wrote the pattern fields in declaration
                // order, so the projections line up with the unpack.
                const field_types = try self.arena.alloc(meta.Type, sp.fields.len);
                for (sp.fields, 0..) |fp, i| {
                    field_types[i] = fieldType(c, base, fp.field);
                }
                const results = try cfg_lower_emit.emitUnpack(self, fs, no_span, .{ .unpack_struct = base }, field_types);
                cfg_lower_emit.markConsumed(self, fs, base);
                try cfg_lower_emit.cleanupDisable(self, fs, no_span, base);
                for (sp.fields, results) |fp, proj| {
                    try bindPattern(c, fs, fp.pat, proj, proj.state == .owned);
                }
            } else {
                for (sp.fields) |fp| {
                    const proj = (try cfg_lower_emit.emit(self, fs, no_span, .{ .read_field = .{ .base = base, .index = fp.field } }, fieldType(c, base, fp.field))) orelse continue;
                    try bindPattern(c, fs, fp.pat, proj, proj.state == .owned);
                }
            }
        },
        .variant => {
            // Variant patterns appear only inside a union match, where
            // `bindUnionArm` handles the payload; reaching one here
            // means the builder let a variant pattern through a `let`.
            return self.fail(no_span, "variant patterns require a union match in this frontend", .{});
        },
    }
}

/// The (substituted) type of field `idx` of a named struct base: the
/// serialized layout's declared type, substituted with the base's type
/// arguments (the direct lowering's `substParams` rule — `p.first` of
/// a `Pair[int32, str]` is `int32`, Core §12.1).
fn fieldType(c: *Ctx, base: *cfg.Value, idx: u32) meta.Type {
    const sd = c.built.types[base.type_.named.id].struct_;
    return meta.substParams(c.self.arena, sd.type_params, base.type_.named.args, sd.fields[idx].type_);
}

fn destructureList(c: *Ctx, fs: *FuncState, lp: hir.Pattern.ListPattern, base: *cfg.Value, base_owned: bool) LowerError!void {
    const self = c.self;
    const elem_type = switch (base.type_) {
        .list => |inner| inner.*,
        else => return self.fail(no_span, "list pattern requires a list value", .{}),
    };
    if (base_owned) {
        if (lp.elems.len == 0) {
            // `[]` and `[..rest]` split nothing: the base is the whole
            // owner (Core §14.6) — the direct lowering's early return.
            if (lp.rest) |rest| {
                try hir_lower.bindBinder(c, fs, restBinder(c, rest), base, base.ownership == .unique and base.state == .owned);
            } else {
                cfg_lower_emit.markConsumed(self, fs, base);
                try cfg_lower_emit.cleanupDisable(self, fs, no_span, base);
            }
            return;
        }
        var types = std.ArrayList(meta.Type).empty;
        try types.appendNTimes(self.arena, elem_type, lp.elems.len);
        const tail_type = try self.arena.create(meta.Type);
        const tail_inner = try self.arena.create(meta.Type);
        tail_inner.* = elem_type;
        tail_type.* = .{ .list = tail_inner };
        try types.append(self.arena, tail_type.*);
        const results = try cfg_lower_emit.emitUnpack(self, fs, no_span, .{ .split_list = base }, types.items);
        cfg_lower_emit.markConsumed(self, fs, base);
        try cfg_lower_emit.cleanupDisable(self, fs, no_span, base);
        for (lp.elems, results[0..lp.elems.len]) |item, proj| try bindPattern(c, fs, item, proj, proj.state == .owned);
        if (lp.rest) |rest| {
            const rest_v = results[results.len - 1];
            try hir_lower.bindBinder(c, fs, restBinder(c, rest), rest_v, rest_v.state == .owned and rest_v.ownership == .unique);
        } else if (results.len > 0) {
            // Exact pattern: the remainder is dead; destroy it now.
            const rest_v = results[results.len - 1];
            if (cfg_lower_emit.mayBeUnique(self, fs, rest_v.type_) and rest_v.state == .owned and !cfg_lower_emit.isConsumed(fs, rest_v)) {
                _ = try cfg_lower_emit.emit(self, fs, no_span, .{ .drop_ = rest_v }, null);
                cfg_lower_emit.markConsumed(self, fs, rest_v);
            }
        }
    } else {
        for (lp.elems, 0..) |item, i| {
            const idx = (try cfg_lower_expr.emitConst(self, fs, no_span, .{ .int = @intCast(i) }, .{ .primitive = .int32 })).?;
            const proj = (try cfg_lower_emit.emit(self, fs, no_span, .{ .read_index = .{ .base = base, .index = idx } }, elem_type)) orelse continue;
            try bindPattern(c, fs, item, proj, proj.state == .owned);
        }
        if (lp.rest) |rest| {
            // `..rest` binds a borrowed sublist view (Core §14.5).
            const inner = try self.arena.create(meta.Type);
            inner.* = elem_type;
            const tail = (try cfg_lower_emit.emit(self, fs, no_span, .{ .tail = base }, .{ .list = inner })) orelse return;
            try hir_lower.bindBinder(c, fs, restBinder(c, rest), tail, tail.state == .owned and tail.ownership == .unique);
        }
    }
}

/// A rest/leaf pattern id's binder (a `bind` leaf).
fn restBinder(c: *Ctx, pid: hir.PatternId) hir.BinderId {
    return switch (c.built.program.pattern(pid)) {
        .bind => |bid| bid,
        else => 0, // unreachable: the builder binds rests to leaves
    };
}

/// Bind a union-match arm: a variant pattern unpacks its payload
/// (`unpack_variant` consuming / `read_payload`+`borrow_variant`
/// otherwise); a catch-all identifier binds the whole scrutinee (Core
/// §13.4). `rid` is the arm region (its `pattern` is the arm pattern).
pub fn bindUnionArm(c: *Ctx, fs: *FuncState, rid: hir.RegionId, scrut: *cfg.Value, moving: bool) LowerError!void {
    const self = c.self;
    const pat_id = c.built.program.region(rid).pattern orelse
        return self.fail(no_span, "union-match arm has no pattern", .{});
    switch (c.built.program.pattern(pat_id)) {
        .wildcard => {},
        .bind => |bid| {
            // Identifier catch-all binds the whole scrutinee.
            try hir_lower.bindBinder(c, fs, bid, scrut, moving and scrut.ownership == .unique and scrut.state == .owned);
        },
        .variant => |vp| {
            const td = c.built.types[scrut.type_.named.id];
            const ud = td.union_;
            const variant = ud.variants[vp.tag];
            const payload_pid = vp.payload orelse return; // no payload to bind
            // The payload types substitute the union's type parameters
            // with the scrutinee's arguments (Core §12.1).
            const payload_types = try self.arena.alloc(meta.Type, variant.payloads.len);
            for (variant.payloads, 0..) |pt, i| {
                payload_types[i] = meta.substParams(self.arena, ud.type_params, scrut.type_.named.args, pt);
            }
            if (payload_types.len == 1) {
                if (moving) {
                    const payload = (try cfg_lower_emit.emitUnpack(self, fs, no_span, .{ .unpack_variant = .{ .base = scrut, .tag = vp.tag } }, &.{payload_types[0]}))[0];
                    try bindPattern(c, fs, payload_pid, payload, payload.state == .owned);
                } else {
                    const payload = (try cfg_lower_emit.emit(self, fs, no_span, .{ .read_payload = scrut }, payload_types[0])) orelse return;
                    try bindPattern(c, fs, payload_pid, payload, payload.state == .owned);
                }
            } else {
                // A tuple payload destructures element-wise: the builder
                // wrapped the multi-payload patterns in a tuple
                // sub-pattern; its elements bind against the unpack's
                // per-element projections.
                const elems: []hir.PatternId = switch (c.built.program.pattern(payload_pid)) {
                    .tuple => |elems| elems,
                    else => return self.fail(no_span, "multi-payload variant pattern is not a tuple", .{}),
                };
                if (moving) {
                    const payloads = try cfg_lower_emit.emitUnpack(self, fs, no_span, .{ .unpack_variant = .{ .base = scrut, .tag = vp.tag } }, payload_types);
                    for (elems, payloads) |el, proj| try bindPattern(c, fs, el, proj, proj.state == .owned);
                } else {
                    const payloads = try cfg_lower_emit.emitBorrowVariant(self, fs, no_span, scrut, vp.tag, payload_types);
                    for (elems, payloads) |el, proj| try bindPattern(c, fs, el, proj, proj.state == .owned);
                }
            }
        },
        else => return self.fail(no_span, "unsupported pattern shape in a union match", .{}),
    }
}

/// True when a union-match arm pattern is a catch-all: `_` or a plain
/// identifier binding.
pub fn isCatchAll(c: *const Ctx, pid: hir.PatternId) bool {
    return switch (c.built.program.pattern(pid)) {
        .wildcard, .bind => true,
        else => false,
    };
}

/// The variant tag a union-match arm pattern selects.
pub fn variantTag(c: *const Ctx, pid: hir.PatternId) LowerError!u32 {
    return switch (c.built.program.pattern(pid)) {
        .variant => |vp| vp.tag,
        else => c.self.fail(no_span, "unsupported pattern in a union match (expected a variant pattern or a catch-all)", .{}),
    };
}

/// Whether a pattern is refutable (needs a test in a non-union match):
/// literals, type tests, and constraining list patterns. Only
/// `[..rest]` (no items) and the irrefutable shapes fall through.
pub fn refutable(c: *const Ctx, pid: hir.PatternId) bool {
    return switch (c.built.program.pattern(pid)) {
        .literal, .type_test => true,
        .list => |lp| !(lp.elems.len == 0 and lp.rest != null),
        else => false,
    };
}

/// The number of test conditions an arm's pattern needs.
pub fn armTestCount(c: *const Ctx, rid: hir.RegionId) usize {
    const pat_id = c.built.program.region(rid).pattern orelse return 0;
    return switch (c.built.program.pattern(pat_id)) {
        .literal, .type_test => 1,
        .list => |lp| blk: {
            var n: usize = 1; // the length test
            for (lp.elems) |el| {
                if (c.built.program.pattern(el) == .literal) n += 1;
            }
            break :blk n;
        },
        else => 0,
    };
}

/// Whether the arm's pattern has a test condition at index `k`.
pub fn hasArmTest(c: *const Ctx, rid: hir.RegionId, k: usize) LowerError!bool {
    return k < armTestCount(c, rid);
}

/// Emit the k-th test condition for a match arm; null when the pattern
/// has no test at that index. List patterns test length first (k == 0,
/// the `list#len` syscall — the same expansion a source `list.len`
/// call lowers to), then each literal item's equality.
pub fn armTest(c: *Ctx, fs: *FuncState, scrut: *cfg.Value, rid: hir.RegionId, k: usize) LowerError!?*cfg.Value {
    const self = c.self;
    const pat_id = c.built.program.region(rid).pattern orelse return null;
    switch (c.built.program.pattern(pat_id)) {
        .literal => |lit| {
            if (k != 0) return null;
            const lit_v = try literalConst(c, fs, lit);
            return try cfg_lower_emit.emit(self, fs, no_span, .{ .eq = .{ .a = scrut, .b = lit_v } }, .{ .primitive = .bool });
        },
        .type_test => |tp| {
            if (k != 0) return null;
            return try cfg_lower_emit.emit(self, fs, no_span, .{ .type_is = .{ .value = scrut, .type_ = tp.ty } }, .{ .primitive = .bool });
        },
        .list => |lp| {
            if (k == 0) {
                const target: i64 = @intCast(lp.elems.len);
                const n_const = (try cfg_lower_expr.emitConst(self, fs, no_span, .{ .int = target }, .{ .primitive = .int32 })).?;
                const args = try self.arena.alloc(*cfg.Value, 1);
                args[0] = scrut;
                const elem_type = switch (scrut.type_) {
                    .list => |inner| inner.*,
                    else => return self.fail(no_span, "list pattern requires a list value", .{}),
                };
                const elem_ptr = try self.arena.create(meta.Type);
                elem_ptr.* = elem_type;
                const len_params = try self.arena.alloc(meta.Param, 1);
                len_params[0] = meta.syntheticParam(no_span, .borrow, .{ .list = elem_ptr });
                const len_ret = try self.arena.create(meta.Type);
                len_ret.* = .{ .primitive = .int32 };
                const len = (try cfg_lower_emit.emit(self, fs, no_span, .{ .syscall = .{
                    .span = no_span,
                    .target = try cfg_lower_intrinsic.intrinsicSyscallTarget(self, no_span, "list", "len"),
                    .args = args,
                    .sig = .{ .params = len_params, .ret = len_ret },
                } }, .{ .primitive = .int32 })).?;
                if (lp.rest != null) {
                    return try cfg_lower_emit.emit(self, fs, no_span, .{ .ge = .{ .a = len, .b = n_const } }, .{ .primitive = .bool });
                }
                return try cfg_lower_emit.emit(self, fs, no_span, .{ .eq = .{ .a = len, .b = n_const } }, .{ .primitive = .bool });
            }
            // Item test: the (k-1)-th literal item's equality.
            const elem_type = switch (scrut.type_) {
                .list => |inner| inner.*,
                else => return self.fail(no_span, "list pattern requires a list value", .{}),
            };
            var item_idx: usize = 0;
            var lit_idx: usize = 1;
            for (lp.elems) |el| {
                const el_pat = c.built.program.pattern(el);
                if (el_pat != .literal) {
                    item_idx += 1;
                    continue;
                }
                if (lit_idx == k) {
                    const lit = try literalConst(c, fs, el_pat.literal);
                    const idx = (try cfg_lower_expr.emitConst(self, fs, no_span, .{ .int = @intCast(item_idx) }, .{ .primitive = .int32 })).?;
                    const elem = (try cfg_lower_emit.emit(self, fs, no_span, .{ .read_index = .{ .base = scrut, .index = idx } }, elem_type)).?;
                    return try cfg_lower_emit.emit(self, fs, no_span, .{ .eq = .{ .a = elem, .b = lit } }, .{ .primitive = .bool });
                }
                item_idx += 1;
                lit_idx += 1;
            }
            return null;
        },
        else => return null,
    }
}

/// A literal pattern's constant value.
fn literalConst(c: *Ctx, fs: *FuncState, lit: meta.ConstValue) LowerError!*cfg.Value {
    return (try cfg_lower_expr.emitConst(c.self, fs, no_span, lit, litType(lit))).?;
}

/// The type of a literal pattern's constant (the direct
/// `lowerLiteralConst` mapping; negative literals arrive pre-negated
/// in `meta.ConstValue.int`).
fn litType(lit: meta.ConstValue) meta.Type {
    return switch (lit) {
        .int => .{ .primitive = .int32 },
        .float => .{ .primitive = .float32 },
        .string => .{ .primitive = .str },
        .bool => .{ .primitive = .bool },
        else => .{ .primitive = .int32 },
    };
}
