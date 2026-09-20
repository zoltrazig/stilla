//! Pure hash / equality / const-eval / algebra rules for the SEG e-graph
//! driver (docs/hir.md §8, §11). Extracted from hir_egraph.zig: the M2b rule
//! engine is acyclic — these helpers depend only on std, meta, and hir, never
//! on the Island arena. The driver imports them through filescope aliases.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;

pub fn hashType(h: *std.hash.Wyhash, ty: meta.Type) void {
    switch (ty) {
        .primitive => |k| {
            h.update(&[_]u8{1});
            h.update(std.mem.asBytes(&@as(u32, @intFromEnum(k))));
        },
        .named => |n| {
            h.update(&[_]u8{2});
            h.update(std.mem.asBytes(&n.id));
            for (n.args) |a| hashType(h, a);
        },
        .param => |p| {
            h.update(&[_]u8{3});
            h.update(p);
        },
        .module => h.update(&[_]u8{4}),
        .list => |inner| {
            h.update(&[_]u8{5});
            hashType(h, inner.*);
        },
        .box => |inner| {
            h.update(&[_]u8{6});
            hashType(h, inner.*);
        },
        .tuple => |elems| {
            h.update(&[_]u8{7});
            for (elems) |e| hashType(h, e);
        },
        .function => |f| {
            h.update(&[_]u8{8});
            for (f.params) |p| {
                h.update(std.mem.asBytes(&@as(u32, @intFromEnum(p.mode))));
                hashType(h, p.type_);
            }
            hashType(h, f.ret.*);
        },
        .cleanup => h.update(&[_]u8{9}),
    }
}

pub fn hashConst(h: *std.hash.Wyhash, c: meta.ConstValue) void {
    switch (c) {
        .int => |v| {
            h.update(&[_]u8{1});
            h.update(std.mem.asBytes(&v));
        },
        .float => |v| {
            h.update(&[_]u8{2});
            h.update(std.mem.asBytes(&v));
        },
        .bool => |v| {
            h.update(&[_]u8{3});
            h.update(&[_]u8{@intFromBool(v)});
        },
        .string => |v| {
            h.update(&[_]u8{4});
            h.update(v);
        },
        .void => h.update(&[_]u8{5}),
    }
}

pub fn hashPayload(h: *std.hash.Wyhash, p: hir.Payload) void {
    switch (p) {
        .none => h.update(&[_]u8{0}),
        .const_value => |c| {
            h.update(&[_]u8{1});
            hashConst(h, c);
        },
        // The `binder` field holds a normalized Slot for an encoded `local`.
        .binder => |b| {
            h.update(&[_]u8{2});
            h.update(std.mem.asBytes(&b));
        },
        .func => |f| {
            h.update(&[_]u8{3});
            switch (f) {
                .func => |v| {
                    h.update(&[_]u8{0});
                    h.update(std.mem.asBytes(&v));
                },
                .host => |v| {
                    h.update(&[_]u8{1});
                    h.update(std.mem.asBytes(&v));
                },
            }
        },
        .module_const => |c| {
            h.update(&[_]u8{4});
            h.update(std.mem.asBytes(&c));
        },
        .field => |v| {
            h.update(&[_]u8{5});
            h.update(std.mem.asBytes(&v));
        },
        .tag => |v| {
            h.update(&[_]u8{6});
            h.update(std.mem.asBytes(&v));
        },
    }
}

pub fn hashHops(h: *std.hash.Wyhash, hops: []const hir.AccessHop) void {
    for (hops) |hop| {
        h.update(std.mem.asBytes(&hop.module));
        h.update(hop.name);
    }
}

pub fn payloadEql(a: hir.Payload, b: hir.Payload) bool {
    return switch (a) {
        .none => b == .none,
        .const_value => |ca| switch (b) {
            .const_value => |cb| constEql(ca, cb),
            else => false,
        },
        .binder => |ba| switch (b) {
            .binder => |bb| ba == bb,
            else => false,
        },
        .func => |fa| switch (b) {
            .func => |fb| std.meta.eql(fa, fb),
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

/// Conservative `ConstValue` equality: strings by contents; floats by `==`
/// (a NaN pair compares unequal — a missed merge, never a wrong one).
pub fn constEql(a: meta.ConstValue, b: meta.ConstValue) bool {
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

pub fn hopsEql(a: []const hir.AccessHop, b: []const hir.AccessHop) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.module != y.module) return false;
        if (!std.mem.eql(u8, x.name, y.name)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Rule predicates
// ---------------------------------------------------------------------------

pub fn baseName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

pub fn isCtorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "struct_make") or
        std.mem.eql(u8, name, "tuple_make") or
        std.mem.eql(u8, name, "list_make");
}

pub fn isTrivialAtomNode(op: hir.OpId) bool {
    const name = hir.registry.get(op).name;
    return std.mem.eql(u8, name, "const") or
        std.mem.eql(u8, name, "local") or
        std.mem.eql(u8, name, "fn_ref");
}

pub fn isIntegerRep(rep: hir.ScalarRep) bool {
    return switch (rep) {
        .i32, .i64, .u32, .u64 => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Constant folding (mirrors cfg_lower_emit's runtime semantics, extended to
// the 64-bit and float reps the HIR registers). A fold that could trap is
// refused: the runtime owns the trap.
// ---------------------------------------------------------------------------

pub fn foldUnary(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue) ?meta.ConstValue {
    if (std.mem.eql(u8, base, "neg")) {
        return switch (rep) {
            .i32 => intCV(i32, -%(asInt(i32, a) orelse return null)),
            .i64 => intCV(i64, -%(asInt(i64, a) orelse return null)),
            .u32 => intCV(u32, 0 -% (asInt(u32, a) orelse return null)),
            .u64 => intCV(u64, 0 -% (asInt(u64, a) orelse return null)),
            .f32 => floatCV(f32, -@as(f32, @floatCast(asF64(a) orelse return null))),
            .f64 => floatCV(f64, -(asF64(a) orelse return null)),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "abs")) {
        return switch (rep) {
            .i32 => blk: {
                const x = asInt(i32, a) orelse return null;
                break :blk intCV(i32, if (x < 0) -%x else x);
            },
            .i64 => blk: {
                const x = asInt(i64, a) orelse return null;
                break :blk intCV(i64, if (x < 0) -%x else x);
            },
            .f32 => floatCV(f32, @abs(@as(f32, @floatCast(asF64(a) orelse return null)))),
            .f64 => floatCV(f64, @abs(asF64(a) orelse return null)),
            else => null, // no unsigned abs (CFG leaves it unfolded too)
        };
    }
    if (std.mem.eql(u8, base, "not")) {
        return switch (a) {
            .bool => |v| .{ .bool = !v },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "clz")) {
        return switch (rep) {
            .i32 => .{ .int = @clz(@as(u32, @bitCast(asInt(i32, a) orelse return null))) },
            .u32 => .{ .int = @clz(asInt(u32, a) orelse return null) },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "popcount")) {
        return switch (rep) {
            .i32 => .{ .int = @popCount(@as(u32, @bitCast(asInt(i32, a) orelse return null))) },
            .u32 => .{ .int = @popCount(asInt(u32, a) orelse return null) },
            else => null,
        };
    }
    return null;
}

pub fn foldBinary(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    if (std.mem.eql(u8, base, "add") or std.mem.eql(u8, base, "sub") or
        std.mem.eql(u8, base, "mul") or std.mem.eql(u8, base, "div") or std.mem.eql(u8, base, "rem"))
    {
        return switch (rep) {
            .i32 => intArith(i32, base, a, b),
            .i64 => intArith(i64, base, a, b),
            .u32 => intArith(u32, base, a, b),
            .u64 => intArith(u64, base, a, b),
            .f32 => floatArith(f32, base, a, b),
            .f64 => floatArith(f64, base, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "min") or std.mem.eql(u8, base, "max")) {
        const is_min = std.mem.eql(u8, base, "min");
        return switch (rep) {
            .i32 => blk: {
                const x = asInt(i32, a) orelse return null;
                const y = asInt(i32, b) orelse return null;
                break :blk intCV(i32, if (is_min) @min(x, y) else @max(x, y));
            },
            .u32 => blk: {
                const x = asInt(u32, a) orelse return null;
                const y = asInt(u32, b) orelse return null;
                break :blk intCV(u32, if (is_min) @min(x, y) else @max(x, y));
            },
            .f32 => blk: {
                const x: f32 = @floatCast(asF64(a) orelse return null);
                const y: f32 = @floatCast(asF64(b) orelse return null);
                break :blk floatCV(f32, if (is_min) fminIeee(f32, x, y) else fmaxIeee(f32, x, y));
            },
            .f64 => blk: {
                const x = asF64(a) orelse return null;
                const y = asF64(b) orelse return null;
                break :blk floatCV(f64, if (is_min) fminIeee(f64, x, y) else fmaxIeee(f64, x, y));
            },
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "shl") or std.mem.eql(u8, base, "shr")) {
        const is_shl = std.mem.eql(u8, base, "shl");
        return switch (rep) {
            .i32 => intShift(i32, is_shl, a, b),
            .i64 => intShift(i64, is_shl, a, b),
            .u32 => intShift(u32, is_shl, a, b),
            .u64 => intShift(u64, is_shl, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "band") or std.mem.eql(u8, base, "bor") or std.mem.eql(u8, base, "bxor")) {
        return switch (rep) {
            .i32 => intBit(i32, base, a, b),
            .i64 => intBit(i64, base, a, b),
            .u32 => intBit(u32, base, a, b),
            .u64 => intBit(u64, base, a, b),
            else => null,
        };
    }
    if (std.mem.eql(u8, base, "eq") or std.mem.eql(u8, base, "ne") or
        std.mem.eql(u8, base, "lt") or std.mem.eql(u8, base, "le") or
        std.mem.eql(u8, base, "gt") or std.mem.eql(u8, base, "ge"))
    {
        return cmpResult(base, rep, a, b);
    }
    return null;
}

pub fn cmpResult(base: []const u8, rep: hir.ScalarRep, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const eq = std.mem.eql(u8, base, "eq");
    const ne = std.mem.eql(u8, base, "ne");
    const eq_style = eq or ne;
    const r: bool = switch (rep) {
        .i32 => cmpInt(i32, base, a, b) orelse return null,
        .i64 => cmpInt(i64, base, a, b) orelse return null,
        .u32 => cmpInt(u32, base, a, b) orelse return null,
        .u64 => cmpInt(u64, base, a, b) orelse return null,
        .f32, .f64 => cmpFloat(base, a, b) orelse return null,
        .bool => blk: {
            if (!eq_style) return null;
            const x = asBool(a) orelse return null;
            const y = asBool(b) orelse return null;
            break :blk if (eq) x == y else x != y;
        },
        .str => blk: {
            if (!eq_style) return null;
            const x = asStr(a) orelse return null;
            const y = asStr(b) orelse return null;
            break :blk if (eq) std.mem.eql(u8, x, y) else !std.mem.eql(u8, x, y);
        },
        // `byte` comparisons lower through the u32 family (hir.md §7.2
        // M1a note); the value occupies one host cell, compared unsigned.
        .byte => blk: {
            const x = asInt(u8, a) orelse return null;
            const y = asInt(u8, b) orelse return null;
            if (eq) break :blk x == y;
            if (ne) break :blk x != y;
            if (std.mem.eql(u8, base, "lt")) break :blk x < y;
            if (std.mem.eql(u8, base, "le")) break :blk x <= y;
            if (std.mem.eql(u8, base, "gt")) break :blk x > y;
            break :blk x >= y;
        },
    };
    return .{ .bool = r };
}

pub fn cmpInt(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?bool {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "eq")) return x == y;
    if (std.mem.eql(u8, base, "ne")) return x != y;
    if (std.mem.eql(u8, base, "lt")) return x < y;
    if (std.mem.eql(u8, base, "le")) return x <= y;
    if (std.mem.eql(u8, base, "gt")) return x > y;
    if (std.mem.eql(u8, base, "ge")) return x >= y;
    return null;
}

pub fn cmpFloat(base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?bool {
    const x = asF64(a) orelse return null;
    const y = asF64(b) orelse return null;
    if (std.mem.eql(u8, base, "eq")) return x == y;
    if (std.mem.eql(u8, base, "ne")) return x != y;
    if (std.mem.eql(u8, base, "lt")) return x < y;
    if (std.mem.eql(u8, base, "le")) return x <= y;
    if (std.mem.eql(u8, base, "gt")) return x > y;
    if (std.mem.eql(u8, base, "ge")) return x >= y;
    return null;
}

pub fn intArith(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "add")) return intCV(T, x +% y);
    if (std.mem.eql(u8, base, "sub")) return intCV(T, x -% y);
    if (std.mem.eql(u8, base, "mul")) return intCV(T, x *% y);
    if (y == 0) return null; // division/remainder by zero traps — leave it
    if (comptime @typeInfo(T).int.signedness == .signed) {
        if (x == std.math.minInt(T) and y == -1) {
            // `min / -1` traps for `div`; `min % -1` is exactly 0.
            if (std.mem.eql(u8, base, "div")) return null;
            return intCV(T, 0);
        }
    }
    if (std.mem.eql(u8, base, "div")) return intCV(T, @divTrunc(x, y));
    return intCV(T, @rem(x, y));
}

pub fn intShift(comptime T: type, is_shl: bool, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const bits = @typeInfo(T).int.bits;
    const U = std.meta.Int(.unsigned, bits);
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    const s: std.math.Log2Int(T) = @intCast(@as(U, @bitCast(y)) & (bits - 1));
    if (is_shl) return intCV(T, @bitCast(@as(U, @bitCast(x)) << s));
    return intCV(T, x >> s);
}

pub fn intBit(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asInt(T, a) orelse return null;
    const y = asInt(T, b) orelse return null;
    if (std.mem.eql(u8, base, "band")) return intCV(T, x & y);
    if (std.mem.eql(u8, base, "bor")) return intCV(T, x | y);
    return intCV(T, x ^ y);
}

pub fn floatArith(comptime T: type, base: []const u8, a: meta.ConstValue, b: meta.ConstValue) ?meta.ConstValue {
    const x = asF64(a) orelse return null;
    const y = asF64(b) orelse return null;
    if (std.mem.eql(u8, base, "add")) return floatCV(T, @as(T, @floatCast(x)) + @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "sub")) return floatCV(T, @as(T, @floatCast(x)) - @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "mul")) return floatCV(T, @as(T, @floatCast(x)) * @as(T, @floatCast(y)));
    if (std.mem.eql(u8, base, "div")) return floatCV(T, @as(T, @floatCast(x)) / @as(T, @floatCast(y)));
    // Zig `@rem` on floats is the truncated remainder (fmod).
    return floatCV(T, @rem(@as(T, @floatCast(x)), @as(T, @floatCast(y))));
}

// --- constant-value helpers (meta.ConstValue keeps integers as i64 bit
// patterns) ---------------------------------------------------------------

pub fn asInt(comptime T: type, c: meta.ConstValue) ?T {
    const U = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
    return switch (c) {
        .int => |i| @bitCast(@as(U, @truncate(@as(u64, @bitCast(i))))),
        else => null,
    };
}

pub fn asF64(c: meta.ConstValue) ?f64 {
    return switch (c) {
        .float => |f| f,
        else => null,
    };
}

pub fn asBool(c: meta.ConstValue) ?bool {
    return switch (c) {
        .bool => |b| b,
        else => null,
    };
}

pub fn asStr(c: meta.ConstValue) ?[]const u8 {
    return switch (c) {
        .string => |s| s,
        else => null,
    };
}

pub fn intCV(comptime T: type, v: T) meta.ConstValue {
    if (comptime @typeInfo(T).int.signedness == .signed) {
        return .{ .int = v };
    } else {
        return .{ .int = @bitCast(@as(u64, v)) };
    }
}

pub fn floatCV(comptime T: type, v: T) meta.ConstValue {
    return .{ .float = @floatCast(v) };
}

/// IEEE 754 `fmin`: NaN propagates, `fmin(-0, +0) = -0` (mirrors
/// cfg_lower_emit).
pub fn fminIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

pub fn fmaxIeee(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0.0 and b == 0.0) return if (std.math.signbit(b)) a else b;
    return if (a > b) a else b;
}

// ---------------------------------------------------------------------------
// Integer algebra identities
// ---------------------------------------------------------------------------

const AlgebraResult = union(enum) {
    /// Keep operand `keep` (0 or 1) as the result.
    keep: usize,
    /// The result is this constant (drops both operands).
    value: meta.ConstValue,
};

pub fn integerAlgebra(base: []const u8, rep: hir.ScalarRep, lc: ?meta.ConstValue, rc: ?meta.ConstValue) ?AlgebraResult {
    return switch (rep) {
        .i32 => intAlgebraT(i32, base, lc, rc),
        .i64 => intAlgebraT(i64, base, lc, rc),
        .u32 => intAlgebraT(u32, base, lc, rc),
        .u64 => intAlgebraT(u64, base, lc, rc),
        else => null,
    };
}

pub fn intAlgebraT(comptime T: type, base: []const u8, lc: ?meta.ConstValue, rc: ?meta.ConstValue) ?AlgebraResult {
    const lz = if (lc) |c| (asInt(T, c) orelse return null) == 0 else false;
    const rz = if (rc) |c| (asInt(T, c) orelse return null) == 0 else false;
    const lo = if (lc) |c| (asInt(T, c) orelse return null) == 1 else false;
    const ro = if (rc) |c| (asInt(T, c) orelse return null) == 1 else false;
    const lall = if (lc) |c| (asInt(T, c) orelse return null) == ~@as(T, 0) else false;
    const rall = if (rc) |c| (asInt(T, c) orelse return null) == ~@as(T, 0) else false;

    if (std.mem.eql(u8, base, "add")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "sub")) {
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "mul")) {
        if (lo) return .{ .keep = 1 };
        if (ro) return .{ .keep = 0 };
        if (lz or rz) return .{ .value = intCV(T, 0) };
    } else if (std.mem.eql(u8, base, "band")) {
        if (lall) return .{ .keep = 1 };
        if (rall) return .{ .keep = 0 };
        if (lz or rz) return .{ .value = intCV(T, 0) };
    } else if (std.mem.eql(u8, base, "bor")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
        if (lall) return .{ .value = intCV(T, ~@as(T, 0)) };
        if (rall) return .{ .value = intCV(T, ~@as(T, 0)) };
    } else if (std.mem.eql(u8, base, "bxor")) {
        if (lz) return .{ .keep = 1 };
        if (rz) return .{ .keep = 0 };
    } else if (std.mem.eql(u8, base, "shl") or std.mem.eql(u8, base, "shr")) {
        if (rz) return .{ .keep = 0 };
    }
    return null;
}
