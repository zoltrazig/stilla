const std = @import("std");

/// Deterministic splitmix64 PRNG, independent of std.rand internals so the
/// stream cannot change between Zig/stdlib versions. One PRNG drives the
/// whole generator, so output order is the draw order.
pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Uniform u64 in [0, n), n must be > 0. Bias (< 2^-32) is negligible
    /// for a test generator.
    pub fn below(self: *Rng, n: u64) u64 {
        std.debug.assert(n != 0);
        return self.next() % n;
    }

    /// Uniform usize in [0, n).
    pub fn index(self: *Rng, n: usize) usize {
        return @intCast(self.below(@intCast(n)));
    }

    /// Uniform integer in [lo, hi] inclusive for signed isize bounds.
    pub fn range(self: *Rng, lo: i64, hi: i64) i64 {
        std.debug.assert(lo <= hi);
        const span: u64 = @intCast(@as(i128, hi) - lo + 1);
        return lo + @as(i64, @intCast(self.below(span)));
    }

    /// True with probability pct/100.
    pub fn chance(self: *Rng, pct: u64) bool {
        return self.below(100) < pct;
    }
};

test "rng: deterministic and stable" {
    var a = Rng.init(123);
    var b = Rng.init(123);
    var c = Rng.init(456);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(a.next(), b.next());
        _ = c.next();
    }
}
