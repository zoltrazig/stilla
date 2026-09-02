const std = @import("std");

/// Numeric model mirroring Stilla's defined behavior for the subset the
/// generator emits. All results are computed exactly as the Stilla runtime
/// is expected to: wrapping add/sub/mul, C-style truncating div/rem, shifts
/// with the count masked mod the type width, and the documented `as`
/// casts. Functions that can trap in Stilla (div/rem by zero) return null
/// so the generator can discard the offending expression.
pub const IntW = enum { i32, u32, i64, u64 };

pub fn typeName(w: IntW) []const u8 {
    return switch (w) {
        .i32 => "int32",
        .u32 => "uint32",
        .i64 => "int64",
        .u64 => "uint64",
    };
}

pub const IntVal = struct {
    w: IntW,
    bits: u64, // low 32 bits meaningful for 32-bit widths; two's complement for signed

    fn mask(w: IntW) u64 {
        return if (w == .i32 or w == .u32) 0xFFFFFFFF else std.math.maxInt(u64);
    }

    fn normalize(v: IntVal) IntVal {
        return .{ .w = v.w, .bits = v.bits & mask(v.w) };
    }

    /// Construct from a mathematical value; two's complement truncation.
    pub fn mk(w: IntW, value: i128) IntVal {
        var v: IntVal = .{ .w = w, .bits = @truncate(@as(u128, @bitCast(value))) };
        v = normalize(v);
        return v;
    }

    pub fn fromBits(w: IntW, bits: u64) IntVal {
        return normalize(.{ .w = w, .bits = bits });
    }

    /// Mathematical value, sign-extended for signed widths.
    pub fn toI128(v: IntVal) i128 {
        return switch (v.w) {
            .i32 => @as(i32, @bitCast(@as(u32, @truncate(v.bits)))),
            .i64 => @as(i64, @bitCast(v.bits)),
            .u32 => @as(u32, @truncate(v.bits)),
            .u64 => v.bits,
        };
    }

    pub fn isZero(v: IntVal) bool {
        return v.bits & mask(v.w) == 0;
    }

    fn asI64(v: IntVal) i64 {
        return @intCast(toI128(v));
    }

    pub fn add(a: IntVal, b: IntVal) IntVal {
        const w = a.w;
        if (w == .i32 or w == .u32) {
            const r = @as(u32, @truncate(a.bits)) +% @as(u32, @truncate(b.bits));
            return fromBits(w, r);
        }
        return fromBits(w, a.bits +% b.bits);
    }

    pub fn sub(a: IntVal, b: IntVal) IntVal {
        const w = a.w;
        if (w == .i32 or w == .u32) {
            const r = @as(u32, @truncate(a.bits)) -% @as(u32, @truncate(b.bits));
            return fromBits(w, r);
        }
        return fromBits(w, a.bits -% b.bits);
    }

    pub fn mul(a: IntVal, b: IntVal) IntVal {
        const w = a.w;
        if (w == .i32 or w == .u32) {
            const r = @as(u32, @truncate(a.bits)) *% @as(u32, @truncate(b.bits));
            return fromBits(w, r);
        }
        return fromBits(w, a.bits *% b.bits);
    }

    /// C-style div (trunc toward zero). Null on divide-by-zero.
    pub fn div(a: IntVal, b: IntVal) ?IntVal {
        if (b.isZero()) return null;
        if (minOverMinusOne(a, b)) return null;
        const w = a.w;
        const r: u64 = switch (w) {
            .i32 => @as(u64, @as(u32, @bitCast(@divTrunc(@as(i32, @bitCast(@as(u32, @truncate(a.bits)))), @as(i32, @bitCast(@as(u32, @truncate(b.bits)))))))),
            .i64 => @bitCast(@divTrunc(@as(i64, @bitCast(a.bits)), @as(i64, @bitCast(b.bits)))),
            .u32 => @as(u32, @truncate(a.bits)) / @as(u32, @truncate(b.bits)),
            .u64 => a.bits / b.bits,
        };
        return fromBits(w, r);
    }

    /// C-style rem (sign of dividend). Null on divide-by-zero.
    pub fn rem(a: IntVal, b: IntVal) ?IntVal {
        if (b.isZero()) return null;
        if (minOverMinusOne(a, b)) return null;
        const w = a.w;
        const r: u64 = switch (w) {
            .i32 => @as(u64, @as(u32, @bitCast(@rem(@as(i32, @bitCast(@as(u32, @truncate(a.bits)))), @as(i32, @bitCast(@as(u32, @truncate(b.bits)))))))),
            .i64 => @bitCast(@rem(@as(i64, @bitCast(a.bits)), @as(i64, @bitCast(b.bits)))),
            .u32 => @as(u32, @truncate(a.bits)) % @as(u32, @truncate(b.bits)),
            .u64 => a.bits % b.bits,
        };
        return fromBits(w, r);
    }

    fn isMinI(v: IntVal) bool {
        return switch (v.w) {
            .i32 => @as(u32, @truncate(v.bits)) == 0x80000000,
            .i64 => v.bits == @as(u64, @bitCast(@as(i64, std.math.minInt(i64)))),
            else => false,
        };
    }

    /// min / -1 wraps for int32 and traps for int64; generator avoids emitting
    /// it, so model it as "unsafe" too.
    fn minOverMinusOne(a: IntVal, b: IntVal) bool {
        if (a.w == .u32 or a.w == .u64) return false;
        if (!isMinI(a)) return false;
        return toI128(b) == -1;
    }

    fn shiftCount(v: IntVal) u6 {
        const is32 = v.w == .i32 or v.w == .u32;
        const m: u64 = if (is32) 31 else 63;
        return @intCast(v.bits & m);
    }

    /// Shift left; count masked mod width, result wraps.
    pub fn shl(a: IntVal, b: IntVal) IntVal {
        const w = a.w;
        const n = shiftCount(b);
        const r: u64 = if (w == .i32 or w == .u32)
            @as(u32, @truncate(a.bits)) << @intCast(n)
        else
            a.bits << @intCast(n);
        return fromBits(w, r);
    }

    /// Shift right; arithmetic on signed widths, logical on unsigned.
    pub fn shr(a: IntVal, b: IntVal) IntVal {
        const w = a.w;
        const n = shiftCount(b);
        const r: u64 = switch (w) {
            .i32 => @as(u64, @as(u32, @bitCast(@as(i32, @bitCast(@as(u32, @truncate(a.bits)))) >> @intCast(n)))),
            .i64 => @bitCast(@as(i64, @bitCast(a.bits)) >> @intCast(n)),
            .u32 => @as(u32, @truncate(a.bits)) >> @intCast(n),
            .u64 => a.bits >> @intCast(n),
        };
        return fromBits(w, r);
    }

    pub fn bitAnd(a: IntVal, b: IntVal) IntVal {
        return fromBits(a.w, a.bits & b.bits);
    }
    pub fn bitOr(a: IntVal, b: IntVal) IntVal {
        return fromBits(a.w, a.bits | b.bits);
    }
    pub fn bitXor(a: IntVal, b: IntVal) IntVal {
        return fromBits(a.w, a.bits ^ b.bits);
    }
    pub fn notBits(a: IntVal) IntVal {
        return fromBits(a.w, ~a.bits);
    }

    pub fn neg(a: IntVal) IntVal {
        // wraps on min; generator avoids min so this never differs from Stilla.
        return mul(a, IntVal.mk(a.w, -1));
    }

    pub fn cmp(a: IntVal, b: IntVal, op: Cmp) bool {
        return switch (op) {
            .eq => toI128(a) == toI128(b),
            .ne => toI128(a) != toI128(b),
            .lt => toI128(a) < toI128(b),
            .le => toI128(a) <= toI128(b),
            .gt => toI128(a) > toI128(b),
            .ge => toI128(a) >= toI128(b),
        };
    }

    /// `as` between integer types: widen/reinterpret, or truncate to target width.
    pub fn castInt(a: IntVal, to: IntW) IntVal {
        const v = toI128(a);
        if (to == .u64) {
            // int64 -> u64 reinterprets the cell rather than sign-extending.
            if (a.w == .i64) return fromBits(.u64, a.bits);
        }
        if (to == .i64) {
            if (a.w == .u64) return fromBits(.i64, a.bits); // reinterpret cell
        }
        return IntVal.mk(to, v);
    }
};

pub const Cmp = enum { eq, ne, lt, le, gt, ge };

pub fn cmpName(op: Cmp) []const u8 {
    return switch (op) {
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
    };
}

/// Print the literal for `v` as it would be typed at `v.w`: signed widths
/// print negative with a leading `-`, unsigned widths print full range.
pub fn printInt(buf: []u8, v: IntVal) []const u8 {
    return switch (v.w) {
        .i32 => std.fmt.bufPrint(buf, "{d}", .{@as(i32, @bitCast(@as(u32, @truncate(v.bits))))}) catch unreachable,
        .i64 => std.fmt.bufPrint(buf, "{d}", .{@as(i64, @bitCast(v.bits))}) catch unreachable,
        .u32 => std.fmt.bufPrint(buf, "{d}", .{@as(u32, @truncate(v.bits))}) catch unreachable,
        .u64 => std.fmt.bufPrint(buf, "{d}", .{v.bits}) catch unreachable,
    };
}

/// Exact integer -> float32. Caller ensures magnitude is exactly representable.
pub fn toF32(v: IntVal) f32 {
    return @floatFromInt(v.toI128());
}

/// Exact integer -> float64.
pub fn toF64(v: IntVal) f64 {
    return @floatFromInt(v.toI128());
}

/// Float -> integer cast with Stilla semantics: truncate toward zero,
/// clamp to the target range, NaN -> 0. For generator values this is exact.
pub fn fromFloat(f: f64, to: IntW) IntVal {
    if (std.math.isNan(f)) return IntVal.mk(to, 0);
    const clamped: f64 = switch (to) {
        .i32 => std.math.clamp(f, @as(f64, @floatFromInt(std.math.minInt(i32))), @as(f64, @floatFromInt(std.math.maxInt(i32)))),
        .i64 => std.math.clamp(f, @as(f64, @floatFromInt(std.math.minInt(i64))), @as(f64, @floatFromInt(std.math.maxInt(i64)))),
        .u32 => std.math.clamp(f, 0, @as(f64, @floatFromInt(std.math.maxInt(u32)))),
        .u64 => std.math.clamp(f, 0, @as(f64, @floatFromInt(std.math.maxInt(u64)))),
    };
    return IntVal.mk(to, @intFromFloat(@trunc(clamped)));
}

/// A value the generator can carry in locals: scalar ints, bools, strings.
pub const Value = union(enum) {
    int: IntVal,
    boolean: bool,
    str: []const u8,

    pub fn typeOf(v: Value) ScalarType {
        return switch (v) {
            .int => |i| .{ .int = i.w },
            .boolean => .boolean,
            .str => .str,
        };
    }
};

pub const ScalarType = union(enum) {
    int: IntW,
    boolean,
    str,

    pub fn name(t: ScalarType) []const u8 {
        return switch (t) {
            .int => |w| typeName(w),
            .boolean => "bool",
            .str => "str",
        };
    }
};
