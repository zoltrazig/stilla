//! Canonical HIR text printer — hir.md §4.
//!
//! Serializes the in-memory structures of `hir.zig` (one root expression
//! of a `Program`) to the canonical text form. `src/hir.zig` re-exports
//! `print`; the parser in `hir_parse.zig` accepts exactly what this
//! printer emits (parse(print(x)) re-parses to an α-equal program).
//!
//! Canonical conventions (hir.md §4.1, §4.8):
//!
//! - **Deterministic binder numbering.** Text binder numbers are
//!   printer-local symbols, assigned by a single pre-order traversal in
//!   first-introduction order (region params before their bodies, so the
//!   overall numbering is text-occurrence order). Output is single-line;
//!   the parser ignores whitespace, so layout carries no meaning.
//! - **Refs dictionary.** `fnref`/`module` targets print through a
//!   `#refs:` dictionary line: print numbers are assigned per kind in
//!   stable-key order (hir.md §4.8), so the text is independent of the
//!   internal FuncId/ConstId numbering. The `hir.SerCtx` supplies the
//!   stable keys; refs-bearing text without a key is an error, never a
//!   silent number guess. Nominal types print through the same context.
//! - **No derived annotations.** Ownership views and full-expression
//!   membership are deliberately absent from canonical text (hir.md §4.6).
//!
//! S2 serialization boundaries (user-approved, PROGRESS.md):
//! struct_make / field_get / variant_make have no §4.4 text form that
//! carries member/tag identity — printing them errors, never silently
//! degrades. Non-finite floats are likewise not serializable in the v1
//! text form (numeric literals are `{d}` + type suffix).

const std = @import("std");
const hir = @import("stilla").hir;
const cfg = @import("stilla").cfg;
const ast = @import("stilla").ast;

const PrintError = error{ OutOfMemory, NotSerializable };

const fake_span = ast.Span{ .source = 0, .start = 0, .end = 0 };

const Printer = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    ctx: hir.SerCtx,
    // Binder text numbers, assigned on declaration in print order.
    binder_no: std.AutoHashMap(hir.BinderId, u32),
    next_no: u32 = 0,

    fn init(allocator: std.mem.Allocator, ctx: hir.SerCtx) Printer {
        return .{
            .alloc = allocator,
            .ctx = ctx,
            .binder_no = std.AutoHashMap(hir.BinderId, u32).init(allocator),
        };
    }

    fn printFmt(self: *Printer, comptime fmt: []const u8, args: anytype) PrintError!void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.put(s);
    }

    fn num(self: *Printer, bid: hir.BinderId) !u32 {
        const gop = try self.binder_no.getOrPut(bid);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.next_no;
            self.next_no += 1;
        }
        return gop.value_ptr.*;
    }

    fn put(self: *Printer, text: []const u8) PrintError!void {
        try self.out.appendSlice(self.alloc, text);
    }

    fn putByte(self: *Printer, b: u8) PrintError!void {
        try self.out.append(self.alloc, b);
    }

    // -- types (hir.md §4.5, short spellings) ------------------------------

    fn printType(self: *Printer, ty: cfg.Type) PrintError!void {
        switch (ty) {
            .primitive => |k| try self.put(switch (k) {
                .int32 => "i32",
                .int64 => "i64",
                .uint32 => "u32",
                .uint64 => "u64",
                .float32 => "f32",
                .float64 => "f64",
                .bool => "bool",
                .byte => "byte",
                .str => "str",
                .any => "any",
                .void => "void",
                .never => "never",
                .hostdata => "hostdata",
            }),
            .named => |n| {
                if (n.id >= self.ctx.types.len) return PrintError.NotSerializable;
                try self.put(self.ctx.types[n.id].name());
                if (n.args.len > 0) {
                    try self.put("[");
                    for (n.args, 0..) |a, i| {
                        if (i > 0) try self.put(", ");
                        try self.printType(a);
                    }
                    try self.put("]");
                }
            },
            .list => |inner| {
                try self.put("[");
                try self.printType(inner.*);
                try self.put("]");
            },
            .box => |inner| {
                try self.put("box(");
                try self.printType(inner.*);
                try self.put(")");
            },
            .tuple => |elems| {
                try self.put("(");
                for (elems, 0..) |e, i| {
                    if (i > 0) try self.put(", ");
                    try self.printType(e);
                }
                try self.put(")");
            },
            .function => |ft| {
                try self.put("fn (");
                for (ft.params, 0..) |p, i| {
                    if (i > 0) try self.put(", ");
                    try self.printType(p.type_);
                }
                try self.put(") -> ");
                try self.printType(ft.ret.*);
            },
            .module, .param, .cleanup => return PrintError.NotSerializable,
        }
    }

    // -- literals -----------------------------------------------------------

    fn printConstValue(self: *Printer, c: cfg.ConstValue, ty: cfg.Type) PrintError!void {
        switch (c) {
            .int => |v| {
                // The literal's suffix comes from the const node type.
                if (ty != .primitive) return PrintError.NotSerializable;
                try self.printFmt("{d}", .{v});
                try self.put(primSuffix(ty.primitive) orelse return PrintError.NotSerializable);
            },
            .float => |f| {
                if (ty != .primitive) return PrintError.NotSerializable;
                if (!std.math.isFinite(f)) return PrintError.NotSerializable;
                try self.printFmt("{d}", .{f});
                // Keep a '.' so the lexer sees a float, then the suffix.
                const items = self.out.items;
                var has_dot = false;
                for (items) |ch| {
                    if (ch == '.') has_dot = true;
                }
                if (!has_dot) try self.put(".0");
                try self.put(primSuffix(ty.primitive) orelse return PrintError.NotSerializable);
            },
            .bool => |b| try self.put(if (b) "true" else "false"),
            .string => |s| try self.printString(s),
            .void => try self.put("void"),
        }
    }

    /// Pattern literals carry no type in the arena, so they print bare
    /// and parse back as the default rep (documented; the pattern stores
    /// only the value).
    fn printPatternConst(self: *Printer, c: cfg.ConstValue) PrintError!void {
        switch (c) {
            .int => |v| try self.printFmt("{d}", .{v}),
            .float => |f| {
                if (!std.math.isFinite(f)) return PrintError.NotSerializable;
                try self.printFmt("{d}", .{f});
                for (self.out.items) |ch| {
                    if (ch == '.') return;
                }
                try self.put(".0");
            },
            .bool => |b| try self.put(if (b) "true" else "false"),
            .string => |s| try self.printString(s),
            .void => try self.put("void"),
        }
    }

    fn printString(self: *Printer, s: []const u8) PrintError!void {
        try self.put("\"");
        for (s) |ch| switch (ch) {
            '\n' => try self.put("\\n"),
            '\t' => try self.put("\\t"),
            '\r' => try self.put("\\r"),
            '"' => try self.put("\\\""),
            '\\' => try self.put("\\\\"),
            else => try self.putByte(ch),
        };
        try self.put("\"");
    }
};

fn primSuffix(kind: ast.PrimitiveKind) ?[]const u8 {
    return switch (kind) {
        .int32 => "i32",
        .int64 => "i64",
        .uint32 => "u32",
        .uint64 => "u64",
        .float32 => "f32",
        .float64 => "f64",
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Reference collection and numbering (hir.md §4.8)
// ---------------------------------------------------------------------------

const RefSets = struct {
    funcs: std.ArrayListUnmanaged(hir.FuncId) = .empty,
    hosts: std.ArrayListUnmanaged(hir.HostBindingId) = .empty,
    consts: std.ArrayListUnmanaged(hir.ConstId) = .empty,
};

fn collectRefs(allocator: std.mem.Allocator, program: *const hir.Program, root: hir.ExprId, refs: *RefSets) !void {
    const n = program.node(root);
    switch (n.payload) {
        .func => |f| switch (f) {
            .func => |id| try refs.funcs.append(allocator, id),
            .host => |id| try refs.hosts.append(allocator, id),
        },
        .module_const => |id| try refs.consts.append(allocator, id),
        else => {},
    }
    for (program.operands(root)) |op| try collectRefs(allocator, program, op, refs);
    for (program.regionsOf(root)) |rid| {
        const r = program.region(rid);
        try collectRefs(allocator, program, r.root, refs);
    }
}

/// Dedup + sort each ref kind by its stable key; returns print numbers as
/// the index into the sorted id list (per kind).
const RefNumbers = struct {
    funcs: []const hir.FuncId = &.{},
    hosts: []const hir.HostBindingId = &.{},
    consts: []const hir.ConstId = &.{},
};

fn assignRefNumbers(allocator: std.mem.Allocator, ctx: hir.SerCtx, refs: *RefSets) !RefNumbers {
    var out = RefNumbers{};
    if (refs.funcs.items.len > 0) {
        const ids = try allocator.dupe(hir.FuncId, refs.funcs.items);
        std.mem.sort(hir.FuncId, ids, ctx, struct {
            fn lessThan(c: hir.SerCtx, a: hir.FuncId, b: hir.FuncId) bool {
                return std.mem.lessThan(u8, c.funcs[a].key, c.funcs[b].key);
            }
        }.lessThan);
        out.funcs = ids;
    }
    if (refs.hosts.items.len > 0) {
        const ids = try allocator.dupe(hir.HostBindingId, refs.hosts.items);
        std.mem.sort(hir.HostBindingId, ids, ctx, struct {
            fn lessThan(c: hir.SerCtx, a: hir.HostBindingId, b: hir.HostBindingId) bool {
                return std.mem.lessThan(u8, c.hosts[a].key, c.hosts[b].key);
            }
        }.lessThan);
        out.hosts = ids;
    }
    if (refs.consts.items.len > 0) {
        const ids = try allocator.dupe(hir.ConstId, refs.consts.items);
        std.mem.sort(hir.ConstId, ids, ctx, struct {
            fn lessThan(c: hir.SerCtx, a: hir.ConstId, b: hir.ConstId) bool {
                return std.mem.lessThan(u8, c.consts[a].key, c.consts[b].key);
            }
        }.lessThan);
        out.consts = ids;
    }
    return out;
}

/// Canonical text of one root expression.
pub fn print(program: *const hir.Program, root: hir.ExprId, allocator: std.mem.Allocator, ctx: hir.SerCtx) ![]u8 {
    var refs = RefSets{};
    try collectRefs(allocator, program, root, &refs);
    const numbers = try assignRefNumbers(allocator, ctx, &refs);
    var p = Printer.init(allocator, ctx);
    // #refs dictionary first (only when refs are present).
    if (numbers.funcs.len > 0 or numbers.hosts.len > 0 or numbers.consts.len > 0) {
        try p.put("#refs: ");
        var first = true;
        for (numbers.funcs, 0..) |id, i| {
            if (!first) try p.put(", ");
            first = false;
            try p.printFmt("F{d} = {s}", .{ i, ctx.funcs[id].key });
        }
        for (numbers.hosts, 0..) |id, i| {
            if (!first) try p.put(", ");
            first = false;
            try p.printFmt("H{d} = {s}", .{ i, ctx.hosts[id].key });
        }
        for (numbers.consts, 0..) |id, i| {
            if (!first) try p.put(", ");
            first = false;
            try p.printFmt("C{d} = {s}", .{ i, ctx.consts[id].key });
        }
        try p.put("\n");
    }
    try printExpr(&p, program, root, &numbers, false);
    return p.out.toOwnedSlice(allocator);
}

/// Ref print number for an id (index of the id in its sorted kind list),
/// or an error when the ref is missing from the collected numbers.
fn refNo(numbers: *const RefNumbers, id: hir.FuncId) !u32 {
    for (numbers.funcs, 0..) |f, i| {
        if (f == id) return @intCast(i);
    }
    return PrintError.NotSerializable;
}
fn hostNo(numbers: *const RefNumbers, id: hir.HostBindingId) !u32 {
    for (numbers.hosts, 0..) |h, i| {
        if (h == id) return @intCast(i);
    }
    return PrintError.NotSerializable;
}
fn constNo(numbers: *const RefNumbers, id: hir.ConstId) !u32 {
    for (numbers.consts, 0..) |c, i| {
        if (c == id) return @intCast(i);
    }
    return PrintError.NotSerializable;
}

// ---------------------------------------------------------------------------
// Expression printing
// ---------------------------------------------------------------------------

/// `in_condition` marks a region root that is an if's then/else branch:
/// an if there must be parenthesized so the `else` binds correctly.
fn printExpr(p: *Printer, program: *const hir.Program, id: hir.ExprId, numbers: *const RefNumbers, _: bool) PrintError!void {
    const n = program.node(id);
    const op_name = hir.registry.get(n.op).name;
    if (std.mem.eql(u8, op_name, "local")) {
        const bid = n.payload.binder;
        const no = try p.num(bid);
        try p.printFmt("%B{d}", .{no});
        return;
    }
    if (std.mem.eql(u8, op_name, "const")) {
        try p.printConstValue(n.payload.const_value, n.ty);
        return;
    }
    if (std.mem.eql(u8, op_name, "fn_ref")) {
        switch (n.payload.func) {
            .func => |f| try p.printFmt("fnref F{d}", .{try refNo(numbers, f)}),
            .host => |h| try p.printFmt("fnref H{d}", .{try hostNo(numbers, h)}),
        }
        return;
    }
    if (std.mem.eql(u8, op_name, "module_const")) {
        try p.printFmt("module C{d}", .{try constNo(numbers, n.payload.module_const)});
        return;
    }
    if (std.mem.eql(u8, op_name, "panic")) {
        try p.put("panic");
        return;
    }
    if (std.mem.eql(u8, op_name, "let")) {
        const regs = program.regionsOf(id);
        const r = program.region(regs[0]);
        const binders = program.params(regs[0]);
        const bid = binders[0];
        const b = program.binder(bid);
        const no = try p.num(bid);
        try p.printFmt("let B{d}: ", .{no});
        try p.printType(b.ty);
        try printMode(p, b.mode);
        try p.put(" = ");
        const ops = program.operands(id);
        try printExpr(p, program, ops[0], numbers, false);
        try p.put(" in ");
        try printExpr(p, program, r.root, numbers, false);
        return;
    }
    if (std.mem.eql(u8, op_name, "lambda")) {
        const regs = program.regionsOf(id);
        const r = program.region(regs[0]);
        const binders = program.params(regs[0]);
        try p.put("fn (");
        for (binders, 0..) |bid, i| {
            if (i > 0) try p.put(", ");
            const b = program.binder(bid);
            const no = try p.num(bid);
            try p.printFmt("B{d}: ", .{no});
            try p.printType(b.ty);
            try printMode(p, b.mode);
        }
        try p.put(") => ");
        try printExpr(p, program, r.root, numbers, false);
        return;
    }
    if (std.mem.eql(u8, op_name, "if")) {
        const ops = program.operands(id);
        try p.put("if ");
        try printExpr(p, program, ops[0], numbers, false);
        try p.put(" then ");
        const regs = program.regionsOf(id);
        try printBranch(p, program, regs[0], numbers);
        const else_r = program.region(regs[1]);
        if (elseIsVoid(program, else_r.root)) {
            // Missing else is the default void branch.
        } else {
            try p.put(" else ");
            try printBranch(p, program, regs[1], numbers);
        }
        return;
    }
    if (std.mem.eql(u8, op_name, "match")) {
        const ops = program.operands(id);
        const scrutinee_ty = program.node(ops[0]).ty;
        try p.put("match ");
        try printExpr(p, program, ops[0], numbers, false);
        try p.put(" { ");
        const regs = program.regionsOf(id);
        for (regs, 0..) |rid, i| {
            if (i > 0) try p.put(", ");
            try printArm(p, program, rid, scrutinee_ty, numbers);
        }
        try p.put(" }");
        return;
    }
    if (std.mem.eql(u8, op_name, "call")) {
        try p.put("call(");
        const ops = program.operands(id);
        for (ops, 0..) |o, i| {
            if (i > 0) try p.put(", ");
            try printExpr(p, program, o, numbers, false);
        }
        try p.put(")");
        return;
    }
    // Generic eager op form.
    const desc = hir.registry.get(n.op);
    if (desc.regions != .none) return PrintError.NotSerializable;
    if (std.mem.eql(u8, op_name, "struct_make") or
        std.mem.eql(u8, op_name, "field_get") or
        std.mem.eql(u8, op_name, "variant_make"))
    {
        return PrintError.NotSerializable; // member identity: no S2 text form
    }
    try p.put(op_name);
    try p.put("(");
    const ops = program.operands(id);
    for (ops, 0..) |o, i| {
        if (i > 0) try p.put(", ");
        try printExpr(p, program, o, numbers, false);
    }
    try p.put(")");
    // Result-type annotation for ops whose type is not self-determined.
    if (needsAnnotation(op_name, ops.len)) {
        try p.put(": ");
        try p.printType(n.ty);
    }
}

/// True when the else branch is the implicit void branch.
fn elseIsVoid(program: *const hir.Program, root: hir.ExprId) bool {
    const n = program.node(root);
    if (!std.mem.eql(u8, hir.registry.get(n.op).name, "const")) return false;
    return n.payload.const_value == .void;
}

fn printMode(p: *Printer, mode: hir.BinderMode) PrintError!void {
    if (mode == .move) {
        try p.put(" @move");
    } else if (mode == .borrow) {
        try p.put(" @borrow");
    }
}

/// An if branch: parenthesize when the branch root is itself an if.
fn printBranch(p: *Printer, program: *const hir.Program, rid: hir.RegionId, numbers: *const RefNumbers) PrintError!void {
    const r = program.region(rid);
    if (std.mem.eql(u8, hir.registry.get(program.node(r.root).op).name, "if")) {
        try p.put("(");
        try printExpr(p, program, r.root, numbers, false);
        try p.put(")");
    } else {
        try printExpr(p, program, r.root, numbers, false);
    }
}

fn needsAnnotation(name: []const u8, operand_count: usize) bool {
    if (std.mem.eql(u8, name, "num_cast") or std.mem.eql(u8, name, "any_cast")) return true;
    if (std.mem.eql(u8, name, "list_make") and operand_count == 0) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Arm patterns (hir.md §4.3, §5.4)
// ---------------------------------------------------------------------------

fn printArm(p: *Printer, program: *const hir.Program, rid: hir.RegionId, scrutinee_ty: cfg.Type, numbers: *const RefNumbers) PrintError!void {
    const r = program.region(rid);
    if (r.pattern) |pid| {
        var cursor: usize = 0;
        const binders = program.params(rid);
        try printPattern(p, program, pid, scrutinee_ty, binders, &cursor, numbers);
        try p.put(" => ");
    }
    try printExpr(p, program, r.root, numbers, false);
}

/// Binder leaves consume the arm's region params in order (leaf order ==
/// params order, hir.md §5.4); the printer numbers each consumed param.
fn printPattern(p: *Printer, program: *const hir.Program, pid: hir.PatternId, sub_ty: cfg.Type, binders: []const hir.BinderId, cursor: *usize, numbers: *const RefNumbers) PrintError!void {
    const pat = program.pattern(pid);
    switch (pat) {
        .wildcard => try p.put("_"),
        .bind => |bid| {
            if (cursor.* >= binders.len) return PrintError.NotSerializable;
            const no = try p.num(bid);
            try p.printFmt("B{d}", .{no});
            cursor.* += 1;
        },
        .literal => |c| try p.printPatternConst(c),
        .tuple => |children| {
            try p.put("(");
            for (children, 0..) |c, i| {
                if (i > 0) try p.put(", ");
                try printPattern(p, program, c, sub_ty.tuple[i], binders, cursor, numbers);
            }
            try p.put(")");
        },
        .list => |lp| {
            try p.put("[");
            const elem_ty = sub_ty.list.*;
            var first = true;
            for (lp.elems) |c| {
                if (!first) try p.put(", ");
                first = false;
                try printPattern(p, program, c, elem_ty, binders, cursor, numbers);
            }
            if (lp.rest) |c| {
                if (!first) try p.put(", ");
                try p.put("..");
                try printPattern(p, program, c, elem_ty, binders, cursor, numbers);
            }
            try p.put("]");
        },
        .struct_ => |sp| {
            if (sub_ty != .named or sub_ty.named.id >= p.ctx.types.len) return PrintError.NotSerializable;
            const decl = p.ctx.types[sub_ty.named.id].struct_;
            try p.put(" { ");
            var first = true;
            for (sp.fields) |f| {
                if (!first) try p.put(", ");
                first = false;
                try p.put(decl.fields[f.field].name);
                try p.put(": ");
                try printPattern(p, program, f.pat, decl.fields[f.field].type_, binders, cursor, numbers);
            }
            try p.put(" }");
        },
        .variant => |vp| {
            if (sub_ty != .named or sub_ty.named.id >= p.ctx.types.len) return PrintError.NotSerializable;
            const decl = p.ctx.types[sub_ty.named.id].union_;
            if (vp.tag >= decl.variants.len) return PrintError.NotSerializable;
            try p.put(decl.name);
            try p.put("::");
            try p.put(decl.variants[vp.tag].name);
            if (vp.payload) |child| {
                try p.put("(");
                const payload_ty = try variantPayloadType(p, decl, sub_ty.named, vp.tag);
                try printPattern(p, program, child, payload_ty, binders, cursor, numbers);
                try p.put(")");
            }
        },
        .type_test => |tt| {
            try p.printType(tt.ty);
            try p.put(" ");
            const no = try p.num(tt.bind);
            try p.printFmt("B{d}", .{no});
            cursor.* += 1;
        },
    }
}

fn variantPayloadType(p: *Printer, decl: cfg.UnionDecl, named: cfg.Type.Named, tag: u32) PrintError!cfg.Type {
    const payloads = decl.variants[tag].payloads;
    if (payloads.len == 0) return PrintError.NotSerializable;
    const allocator = p.alloc;
    if (payloads.len == 1) {
        return cfg.substParams(allocator, decl.type_params, named.args, payloads[0]);
    }
    const tys = try allocator.alloc(cfg.Type, payloads.len);
    for (payloads, 0..) |pt, i| tys[i] = cfg.substParams(allocator, decl.type_params, named.args, pt);
    return .{ .tuple = tys };
}

// ---------------------------------------------------------------------------
// White-box tests: round trip and printer determinism (hir.md §4.7–§4.9)
// ---------------------------------------------------------------------------

const hir_parse = @import("hir_parse.zig");

const t = std.testing;

fn constEql(a: cfg.ConstValue, b: cfg.ConstValue) bool {
    return switch (a) {
        .int => |ia| switch (b) {
            .int => |ib| ia == ib,
            else => false,
        },
        .float => |fa| switch (b) {
            .float => |fb| fa == fb,
            else => false,
        },
        .bool => |ba| switch (b) {
            .bool => |bb| ba == bb,
            else => false,
        },
        .string => |sa| switch (b) {
            .string => |sb| std.mem.eql(u8, sa, sb),
            else => false,
        },
        .void => b == .void,
    };
}

/// α-equivalence: node-by-node structural comparison over two programs,
/// remapping binders of `a` onto `b` positionally at each region.
fn alphaEq(allocator: std.mem.Allocator, a: *const hir.Program, aroot: hir.ExprId, b: *const hir.Program, broot: hir.ExprId) bool {
    var map = std.AutoHashMap(hir.BinderId, hir.BinderId).init(allocator);
    defer map.deinit();
    return exprEq(a, aroot, b, broot, &map);
}

fn mapGet(map: *std.AutoHashMap(hir.BinderId, hir.BinderId), id: hir.BinderId) ?hir.BinderId {
    return map.get(id);
}

fn mapPut(map: *std.AutoHashMap(hir.BinderId, hir.BinderId), a: hir.BinderId, b: hir.BinderId) bool {
    if (map.get(a)) |already| return already == b;
    map.put(a, b) catch return false;
    return true;
}

fn payloadEq(a: hir.Payload, b: hir.Payload, map: *std.AutoHashMap(hir.BinderId, hir.BinderId)) bool {
    return switch (a) {
        .none => b == .none,
        .const_value => |ca| switch (b) {
            .const_value => |cb| constEql(ca, cb),
            else => false,
        },
        .binder => |ba| switch (b) {
            .binder => |bb| (mapGet(map, ba) orelse return false) == bb,
            else => false,
        },
        .func => |fa| switch (b) {
            .func => |fb| switch (fa) {
                .func => |xf| fb == .func and fb.func == xf,
                .host => |xh| fb == .host and fb.host == xh,
            },
            else => false,
        },
        .module_const => |ca| switch (b) {
            .module_const => |cb| ca == cb,
            else => false,
        },
        .field => |fa| switch (b) {
            .field => |fb| fa == fb,
            else => false,
        },
        .tag => |ta| switch (b) {
            .tag => |tb| ta == tb,
            else => false,
        },
    };
}

fn patternEq(pa: hir.PatternId, pb: hir.PatternId, a: *const hir.Program, b: *const hir.Program, map: *std.AutoHashMap(hir.BinderId, hir.BinderId)) bool {
    const x = a.pattern(pa);
    const y = b.pattern(pb);
    return switch (x) {
        .wildcard => y == .wildcard,
        .bind => |ba| switch (y) {
            .bind => |bb| (mapGet(map, ba) orelse return false) == bb,
            else => false,
        },
        .literal => |ca| switch (y) {
            .literal => |cb| constEql(ca, cb),
            else => false,
        },
        .tuple => |xa| switch (y) {
            .tuple => |xb| {
                if (xa.len != xb.len) return false;
                for (xa, xb) |c1, c2| {
                    if (!patternEq(c1, c2, a, b, map)) return false;
                }
                return true;
            },
            else => false,
        },
        .list => |la| switch (y) {
            .list => |lb| {
                if (la.elems.len != lb.elems.len) return false;
                for (la.elems, lb.elems) |c1, c2| {
                    if (!patternEq(c1, c2, a, b, map)) return false;
                }
                if ((la.rest == null) != (lb.rest == null)) return false;
                if (la.rest) |r1| if (!patternEq(r1, lb.rest.?, a, b, map)) return false;
                return true;
            },
            else => false,
        },
        .struct_ => |sa| switch (y) {
            .struct_ => |sb| {
                if (sa.fields.len != sb.fields.len) return false;
                for (sa.fields, sb.fields) |f1, f2| {
                    if (f1.field != f2.field) return false;
                    if (!patternEq(f1.pat, f2.pat, a, b, map)) return false;
                }
                return true;
            },
            else => false,
        },
        .variant => |va| switch (y) {
            .variant => |vb| {
                if (va.tag != vb.tag) return false;
                if ((va.payload == null) != (vb.payload == null)) return false;
                if (va.payload) |p1| if (!patternEq(p1, vb.payload.?, a, b, map)) return false;
                return true;
            },
            else => false,
        },
        .type_test => |ta| switch (y) {
            .type_test => |tb| {
                if (!cfg.Type.eql(ta.ty, tb.ty)) return false;
                return (mapGet(map, ta.bind) orelse return false) == tb.bind;
            },
            else => false,
        },
    };
}

fn exprEq(a: *const hir.Program, aid: hir.ExprId, b: *const hir.Program, bid: hir.ExprId, map: *std.AutoHashMap(hir.BinderId, hir.BinderId)) bool {
    const na = a.node(aid);
    const nb = b.node(bid);
    if (na.op != nb.op) return false;
    if (!cfg.Type.eql(na.ty, nb.ty)) return false;
    if (!payloadEq(na.payload, nb.payload, map)) return false;
    const a_ops = a.operands(aid);
    const b_ops = b.operands(bid);
    if (a_ops.len != b_ops.len) return false;
    for (a_ops, b_ops) |o1, o2| {
        if (!exprEq(a, o1, b, o2, map)) return false;
    }
    const a_regs = a.regionsOf(aid);
    const b_regs = b.regionsOf(bid);
    if (a_regs.len != b_regs.len) return false;
    for (a_regs, b_regs) |r1, r2| {
        const ra = a.region(r1);
        const rb = b.region(r2);
        const a_params = a.params(r1);
        const b_params = b.params(r2);
        if (a_params.len != b_params.len) return false;
        for (a_params, b_params) |p1, p2| {
            if (!mapPut(map, p1, p2)) return false;
        }
        if (!exprEq(a, ra.root, b, rb.root, map)) return false;
        if ((ra.pattern == null) != (rb.pattern == null)) return false;
        if (ra.pattern) |p1| {
            if (!patternEq(p1, rb.pattern.?, a, b, map)) return false;
        }
    }
    return true;
}

/// Parse, canonical-print, re-parse: the round-trip contract of §4.9.
const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    program: hir.Program,
    root: hir.ExprId,
    fn text(self: *Parsed) []u8 {
        return print(&self.program, self.root, self.arena.allocator(), .{}) catch "";
    }
};

fn roundTripOk(text: []const u8, ctx: hir.SerCtx) !bool {
    var p1 = try hir_parse.parseText(text, ctx);
    defer p1.arena.deinit();
    const printed = try print(&p1.program, p1.root, p1.arena.allocator(), ctx);
    var p2 = try hir_parse.parseText(printed, ctx);
    defer p2.arena.deinit();
    return alphaEq(p2.arena.allocator(), &p1.program, p1.root, &p2.program, p2.root);
}

/// §4.7 golden examples (ctx fixtures below).
const golden_double = "fn (B0: i32) => mul.i32(%B0, 2i32)";
const golden_match = "fn (B0: Option[i32]) => match(%B0) { Option::Some(B1) => add.i32(%B1, 1i32), Option::None => 0i32 }";
const golden_let_call = "fn (B0: i32) => let B1: i32 = call(fn (B2: i32) => add.i32(%B2, 0i32), %B0) in mul.i32(%B1, 1i32)";

test "round trip: §4.7 goldens parse, print canonically, and re-parse α-equal" {
    try t.expect(try roundTripOk(golden_double, .{}));
    try t.expect(try roundTripOk(golden_let_call, .{}));
    // ex2 needs the nominal Option fixture in the serialization context.
    var fix = try optionFixture(t.allocator);
    defer fix.arena.deinit();
    try t.expect(try roundTripOk(golden_match, fix.ctx));
}

test "round trip: §8.7 example fragment" {
    // §8.7's HIR example (FE comments removed — derived annotations are
    // not part of canonical text).
    const text = "fn (B0: i32) => let B1: i32 = call(fn (B2: i32) => add.i32(%B2, 0i32), %B0) in mul.i32(%B1, 1i32)";
    try t.expect(try roundTripOk(text, .{}));
}

test "print(parse(x)) is canonical and stable" {
    var p1 = try hir_parse.parseText(golden_let_call, .{});
    defer p1.arena.deinit();
    const a = try print(&p1.program, p1.root, p1.arena.allocator(), .{});
    const b = try print(&p1.program, p1.root, p1.arena.allocator(), .{});
    try t.expectEqualStrings(a, b);
    // The canonical form of the example is single-line prefix text.
    try t.expectEqualStrings("fn (B0: i32) => let B1: i32 = call(fn (B2: i32) => add.i32(%B2, 0i32), %B0) in mul.i32(%B1, 1i32)", a);
}

test "α-equivalent texts print identically (binder renumbering)" {
    const t1 = "fn (B0: i32) => mul.i32(%B0, 2i32)";
    const t2 = "fn (B7: i32) => mul.i32(%B7, 2i32)";
    var p1 = try hir_parse.parseText(t1, .{});
    defer p1.arena.deinit();
    var p2 = try hir_parse.parseText(t2, .{});
    defer p2.arena.deinit();
    const s1 = try print(&p1.program, p1.root, p1.arena.allocator(), .{});
    const s2 = try print(&p2.program, p2.root, p2.arena.allocator(), .{});
    try t.expectEqualStrings(s1, s2);
}

test "let init exclusion: init cannot reference its own binder" {
    try t.expectError(error.Syntax, hir_parse.parseText("let B0: i32 = %B0 in %B0", .{}));
}

test "let binder visible only in its body" {
    // After the let's body the binder is gone: the reference is unknown.
    try t.expectError(error.Syntax, hir_parse.parseText("seq(let B0: i32 = 1i32 in %B0, %B0)", .{}));
}

test "reference to undeclared binder is rejected" {
    try t.expectError(error.Syntax, hir_parse.parseText("fn (B0: i32) => %B1", .{}));
}

test "unknown opcode and malformed literals are rejected" {
    try t.expectError(error.Syntax, hir_parse.parseText("nosuch(%B0)", .{}));
    try t.expectError(error.Syntax, hir_parse.parseText("1i33", .{}));
    try t.expectError(error.Syntax, hir_parse.parseText("1", .{}));
    try t.expectError(error.Syntax, hir_parse.parseText("fn (B0: i32) => mul.i32(%B0)", .{}));
}

test "text forms without S2 member identity are rejected, not degraded" {
    try t.expectError(error.Syntax, hir_parse.parseText("struct_make(%B0) : P", .{}));
    try t.expectError(error.Syntax, hir_parse.parseText("field_get(%B0) : i32", .{}));
    try t.expectError(error.Syntax, hir_parse.parseText("variant_make(%B0) : U", .{}));
    // Printing a program containing them fails the same way.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var prog = try hir.Program.init(arena.allocator());
    const lit = try prog.addExpr(.{ .op = hir.opId("const").?, .ty = cfg.Type{ .primitive = .int32 }, .payload = .{ .const_value = .{ .int = 1 } } });
    const ops = try prog.addOperands(&.{lit});
    const fg = try prog.addExpr(.{ .op = hir.opId("field_get").?, .ty = cfg.Type{ .primitive = .int32 }, .operands = ops, .payload = .{ .field = 0 } });
    try t.expectError(error.NotSerializable, print(&prog, fg, arena.allocator(), .{}));
}

test "nominal types require the serialization context" {
    try t.expectError(error.Syntax, hir_parse.parseText(golden_match, .{}));
    try t.expectError(error.Syntax, hir_parse.parseText("fn (B0: Missing) => %B0", .{}));
}

test "refs round-trip through stable keys, not numeric ids" {
    var fix = try refFixture(t.allocator);
    defer fix.arena.deinit();
    // func id 0 prints as F0 by key order; ids resolve back through ctx.
    // Canonical text carries the #refs dictionary (§4.8).
    const text = "#refs: F0 = string.concat\nfn (B0: i32) => call(fnref F0, %B0)";
    try t.expect(try roundTripOk(text, fix.ctx));
    // A fnref with no dictionary entry is rejected (no number guessing).
    try t.expectError(error.Syntax, hir_parse.parseText("fn (B0: i32) => call(fnref F5, %B0)", fix.ctx));
    try t.expectError(error.Syntax, hir_parse.parseText("fn (B0: i32) => call(fnref F0, %B0)", .{}));
}

// -- fixtures ---------------------------------------------------------------

const Fixture = struct { arena: std.heap.ArenaAllocator, ctx: hir.SerCtx };

fn optionFixture(allocator: std.mem.Allocator) !Fixture {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const t_param = "T";
    const param_ty = cfg.Type{ .param = t_param };
    const some_payload = try a.dupe(cfg.Type, &.{param_ty});
    var variants = try a.alloc(cfg.VariantDecl, 2);
    variants[0] = .{ .name = "Some", .payloads = some_payload };
    variants[1] = .{ .name = "None", .payloads = &.{} };
    const type_params = try a.dupe([]const u8, &.{t_param});
    const decls = try a.alloc(cfg.TypeDecl, 1);
    decls[0] = .{ .union_ = .{
        .name = "Option",
        .module = "test",
        .type_params = type_params,
        .ownership = .copy,
        .variants = variants,
    } };
    return .{ .arena = arena, .ctx = .{ .types = decls } };
}

fn refFixture(allocator: std.mem.Allocator) !Fixture {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    // fn (i32) -> i32
    const ret_ptr = try a.create(cfg.Type);
    ret_ptr.* = cfg.Type{ .primitive = .int32 };
    const params = try a.dupe(cfg.Param, &.{cfg.syntheticParam(fake_span, .plain, cfg.Type{ .primitive = .int32 })});
    const fn_ty = cfg.Type{ .function = .{ .params = params, .ret = ret_ptr } };
    const funcs = try a.alloc(hir.SerCtx.FuncDecl, 1);
    funcs[0] = .{ .key = "string.concat", .type_ = fn_ty };
    return .{ .arena = arena, .ctx = .{ .funcs = funcs } };
}

test "printer determinism over constructed programs (S1 structures)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = try hir.Program.init(arena.allocator());
    const b_x = try p.addBinder(cfg.Type{ .primitive = .int32 }, .value);
    const init = try p.addExpr(.{ .op = hir.opId("const").?, .ty = cfg.Type{ .primitive = .int32 }, .payload = .{ .const_value = .{ .int = 42 } } });
    const body = try p.addExpr(.{ .op = hir.opId("local").?, .ty = cfg.Type{ .primitive = .int32 }, .payload = .{ .binder = b_x } });
    const region = try p.addRegion(&.{b_x}, body, null);
    const regions = try p.addRegions(&.{region});
    const operands = try p.addOperands(&.{init});
    const let_id = try p.addExpr(.{ .op = hir.opId("let").?, .ty = cfg.Type{ .primitive = .int32 }, .operands = operands, .regions = regions });
    const out = try print(&p, let_id, arena.allocator(), .{});
    try t.expectEqualStrings("let B0: i32 = 42i32 in %B0", out);
    // And it round-trips.
    var p2 = try hir_parse.parseText(out, .{});
    defer p2.arena.deinit();
    try t.expect(alphaEq(p2.arena.allocator(), &p, let_id, &p2.program, p2.root));
}
