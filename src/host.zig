//! Host environment — Runtime §3.
//!
//! The embedding host:
//!
//! - creates the execution context (§3);
//! - registers host-provided modules (§3.1);
//! - provides the required `builtin` interface (§3.2, §4) that programs
//!   reach by importing the standard-library `builtin` module (Core §3);
//! - invokes entry points (§3.3);
//! - receives control back on normal termination or panic (§3.4) and
//!   disposes of the terminated context and any host-owned resources.
//!
//! Host cleanup is outside Stilla source semantics and must not be
//! described as execution of Stilla `drop` hooks (Runtime §3.4).
//!
//! M2: the per-module handler structs (`DefaultHostCall`,
//! `MathHostCall`, `StringHostCall`, `ListHostCall`) implement the
//! stdlib host interfaces the default adapter dispatches by
//! `(specifier, member)` (docs/interpreter-vm.md §9). Handlers receive
//! only verified plain data and never touch the VM; the adapter does
//! the heap mechanics. M3 adds the `array`/`hashmap` opaque host
//! objects: their storage (`ArrayObject`, `HashMapObject`) lives here
//! as plain data and the interpreter adapters own the retain/release
//! and exactly-once disposal contract (docs/interpreter-vm.md §9).

const std = @import("std");
const vm_types = @import("vm_types.zig");
const unicode_case = @import("unicode_case.zig");

/// Default implementations of the required `builtin` host module (Runtime
/// §4) as standalone function pointers, one per member. The interpreter
/// has already verified each call — signature, argument count, and str
/// arguments — and performed the VM heap mechanics (box allocation, unbox
/// extraction, str-object allocation, panic-message duplication), so a
/// handler receives only plain, verified data and never touches the VM.
/// The only type dependencies are `vm_types` (`Value`, `ScalarView`).
pub const DefaultHostCall = struct {
    print: *const fn (userdata: ?*const anyopaque, message: []const u8) void = hostPrint,
    str: *const fn (userdata: ?*const anyopaque, value: vm_types.ScalarView, buf: []u8) anyerror![]const u8 = hostStr,
    box: *const fn (userdata: ?*const anyopaque, value: vm_types.Value) vm_types.Value = hostBox,
    unbox: *const fn (userdata: ?*const anyopaque, payload: vm_types.Value) vm_types.Value = hostUnbox,
    panic: *const fn (userdata: ?*const anyopaque, message: []const u8) []const u8 = hostPanic,
    assert: *const fn (userdata: ?*const anyopaque, message: []const u8) []const u8 = hostAssert,
    hash: *const fn (userdata: ?*const anyopaque, bytes: []const u8) vm_types.Value = hostHash,
};

/// The default `builtin` implementation (Runtime §4): the interpreter
/// dispatches verified builtin invocations through this table.
pub const defaultHostCall = DefaultHostCall{};

/// `builtin.print` — Runtime §4.1: write one line to the host's output.
fn hostPrint(userdata: ?*const anyopaque, message: []const u8) void {
    _ = userdata;
    std.Io.File.writeStreamingAll(std.Io.File.stdout(), std.Options.debug_io, message) catch return;
    std.Io.File.writeStreamingAll(std.Io.File.stdout(), std.Options.debug_io, "\n") catch {};
}

/// `builtin.str` — Runtime §4.2: canonical decimal form of the decoded
/// scalar; a str view is returned unchanged.
fn hostStr(userdata: ?*const anyopaque, value: vm_types.ScalarView, buf: []u8) anyerror![]const u8 {
    _ = userdata;
    return vm_types.formatView(value, buf);
}

/// `builtin.box` — Runtime §4.5: the payload to wrap. The interpreter
/// allocates the box shell around the returned value.
fn hostBox(userdata: ?*const anyopaque, value: vm_types.Value) vm_types.Value {
    _ = userdata;
    return value;
}

/// `builtin.unbox` — Runtime §4.6: the extracted payload. The interpreter
/// frees the box shell after the handler returns.
fn hostUnbox(userdata: ?*const anyopaque, payload: vm_types.Value) vm_types.Value {
    _ = userdata;
    return payload;
}

/// `builtin.panic` — Runtime §4.7: the termination message.
fn hostPanic(userdata: ?*const anyopaque, message: []const u8) []const u8 {
    _ = userdata;
    return message;
}

/// `builtin.assert` — Runtime §4.8: the panic message; the interpreter
/// calls this only on the false path.
fn hostAssert(userdata: ?*const anyopaque, message: []const u8) []const u8 {
    _ = userdata;
    return message;
}

/// `builtin.hash` — Runtime §4.9: hash the verified bytes (str contents
/// or raw scalar cell).
fn hostHash(userdata: ?*const anyopaque, bytes: []const u8) vm_types.Value {
    _ = userdata;
    return std.hash.Wyhash.hash(0, bytes);
}

// ---------------------------------------------------------------------------
// The `math` module (StdLib §4) — IEEE 754 `float32` functions. Handlers
// receive decoded `f32` arguments and return `f32` results; the adapter
// decodes the canonical cells and encodes the result (M2).
// ---------------------------------------------------------------------------

/// One unary `f32 -> f32` handler.
const MathFn1 = *const fn (userdata: ?*const anyopaque, x: f32) f32;
/// One binary `f32 × f32 -> f32` handler.
const MathFn2 = *const fn (userdata: ?*const anyopaque, x: f32, y: f32) f32;

/// The `math` member names, in the StdLib §4 order (the adapter resolves
/// the syscall's member name through this enum).
pub const MathMember = enum {
    sqrt,
    pow,
    exp,
    ln,
    log2,
    log10,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    atan2,
    floor,
    ceil,
    round,
    trunc,
    abs,
    min,
    max,
};

/// Default implementations of the `math` module members (StdLib §4) as
/// standalone function pointers, one per member, beside `DefaultHostCall`.
/// Results follow IEEE 754, including NaN and infinity, and are
/// deterministic within a single execution context. `atan2(y, x)` takes
/// y first; `round` rounds ties away from zero; `min`/`max` follow IEEE
/// `fmin`/`fmax` (NaN propagates, `min(-0, +0) = -0`).
pub const MathHostCall = struct {
    sqrt: MathFn1 = mathSqrt,
    pow: MathFn2 = mathPow,
    exp: MathFn1 = mathExp,
    ln: MathFn1 = mathLn,
    log2: MathFn1 = mathLog2,
    log10: MathFn1 = mathLog10,
    sin: MathFn1 = mathSin,
    cos: MathFn1 = mathCos,
    tan: MathFn1 = mathTan,
    asin: MathFn1 = mathAsin,
    acos: MathFn1 = mathAcos,
    atan: MathFn1 = mathAtan,
    atan2: MathFn2 = mathAtan2,
    floor: MathFn1 = mathFloor,
    ceil: MathFn1 = mathCeil,
    round: MathFn1 = mathRound,
    trunc: MathFn1 = mathTrunc,
    abs: MathFn1 = mathAbs,
    min: MathFn2 = mathMin,
    max: MathFn2 = mathMax,
};

/// The default `math` implementation (StdLib §4).
pub const mathHostCall = MathHostCall{};

fn mathSqrt(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return std.math.sqrt(x);
}
fn mathPow(userdata: ?*const anyopaque, x: f32, y: f32) f32 {
    _ = userdata;
    return std.math.pow(f32, x, y);
}
fn mathExp(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @exp(x);
}
fn mathLn(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @log(x);
}
fn mathLog2(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @log2(x);
}
fn mathLog10(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @log10(x);
}
fn mathSin(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @sin(x);
}
fn mathCos(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @cos(x);
}
fn mathTan(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @tan(x);
}
fn mathAsin(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return std.math.asin(x);
}
fn mathAcos(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return std.math.acos(x);
}
fn mathAtan(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return std.math.atan(x);
}
fn mathAtan2(userdata: ?*const anyopaque, y: f32, x: f32) f32 {
    _ = userdata;
    return std.math.atan2(y, x); // y first, matching IEEE 754
}
fn mathFloor(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @floor(x);
}
fn mathCeil(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @ceil(x);
}
fn mathRound(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return std.math.round(x); // ties away from zero
}
fn mathTrunc(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @trunc(x);
}
fn mathAbs(userdata: ?*const anyopaque, x: f32) f32 {
    _ = userdata;
    return @abs(x);
}
fn mathMin(userdata: ?*const anyopaque, a: f32, b: f32) f32 {
    _ = userdata;
    return vm_types.fminIeee(f32, a, b); // IEEE fmin
}
fn mathMax(userdata: ?*const anyopaque, a: f32, b: f32) f32 {
    _ = userdata;
    return vm_types.fmaxIeee(f32, a, b); // IEEE fmax
}

// ---------------------------------------------------------------------------
// The `string` module (StdLib §5) — Unicode text operations. Handlers
// receive verified plain data (`[]const u8` UTF-8 byte slices, decoded
// scalars, or scratch buffers) and never touch the VM; the adapter
// performs the heap mechanics (str/list object allocation, list walks)
// and maps handler errors to owned trap messages. All text processing
// operates on code points, never byte offsets (StdLib §5).
// ---------------------------------------------------------------------------

/// Errors a string handler reports; the interpreter adapter maps each to
/// an owned deterministic trap message (StdLib §5, Runtime §7.2).
pub const StringErr = error{
    /// Invalid UTF-8 in a str or byte sequence.
    InvalidUtf8,
    /// substring offsets out of range, or repeat with a negative count.
    Range,
    /// A code point that is not a Unicode scalar value.
    BadCodepoint,
    /// Scratch-buffer allocation failed.
    OutOfMemory,
};

/// The `string` member names (StdLib §5, std/string.st).
pub const StringMember = enum {
    len,
    is_empty,
    concat,
    contains,
    starts_with,
    ends_with,
    index_of,
    substring,
    split,
    join,
    trim,
    lower,
    upper,
    replace,
    repeat,
    to_utf8,
    from_utf8,
    to_codepoints,
    from_codepoints,
};

/// Default implementations of the `string` module members (StdLib §5) as
/// standalone function pointers, one per member, beside `DefaultHostCall`.
/// String-producing handlers append into a caller-provided scratch
/// buffer (the adapter copies into VM str objects); `split` appends
/// pieces as slices into the input (the adapter copies immediately);
/// `join` receives the parts already materialized by the adapter.
pub const StringHostCall = struct {
    len: *const fn (userdata: ?*const anyopaque, s: []const u8) StringErr!i32 = stringLen,
    is_empty: *const fn (userdata: ?*const anyopaque, s: []const u8) bool = stringIsEmpty,
    concat: *const fn (userdata: ?*const anyopaque, a: []const u8, b: []const u8, out: *std.array_list.Managed(u8)) StringErr!void = stringConcat,
    contains: *const fn (userdata: ?*const anyopaque, haystack: []const u8, needle: []const u8) bool = stringContains,
    starts_with: *const fn (userdata: ?*const anyopaque, s: []const u8, prefix: []const u8) bool = stringStartsWith,
    ends_with: *const fn (userdata: ?*const anyopaque, s: []const u8, suffix: []const u8) bool = stringEndsWith,
    index_of: *const fn (userdata: ?*const anyopaque, haystack: []const u8, needle: []const u8) StringErr!?i32 = stringIndexOf,
    substring: *const fn (userdata: ?*const anyopaque, s: []const u8, start: i32, end: i32, out: *std.array_list.Managed(u8)) StringErr!void = stringSubstring,
    split: *const fn (userdata: ?*const anyopaque, s: []const u8, sep: []const u8, out: *std.array_list.Managed([]const u8)) StringErr!void = stringSplit,
    join: *const fn (userdata: ?*const anyopaque, parts: []const []const u8, sep: []const u8, out: *std.array_list.Managed(u8)) StringErr!void = stringJoin,
    trim: *const fn (userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void = stringTrim,
    lower: *const fn (userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void = stringLower,
    upper: *const fn (userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void = stringUpper,
    replace: *const fn (userdata: ?*const anyopaque, s: []const u8, from: []const u8, to: []const u8, out: *std.array_list.Managed(u8)) StringErr!void = stringReplace,
    repeat: *const fn (userdata: ?*const anyopaque, s: []const u8, count: i32, out: *std.array_list.Managed(u8)) StringErr!void = stringRepeat,
    to_utf8: *const fn (userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void = stringToUtf8,
    from_utf8: *const fn (userdata: ?*const anyopaque, bytes: []const u8, out: *std.array_list.Managed(u8)) StringErr!void = stringFromUtf8,
    to_codepoints: *const fn (userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u32)) StringErr!void = stringToCodepoints,
    from_codepoints: *const fn (userdata: ?*const anyopaque, cps: []const u32, out: *std.array_list.Managed(u8)) StringErr!void = stringFromCodepoints,
};

/// The default `string` implementation (StdLib §5).
pub const stringHostCall = StringHostCall{};

/// §5: lengths are in code points, never bytes.
fn stringLen(userdata: ?*const anyopaque, s: []const u8) StringErr!i32 {
    _ = userdata;
    const n = std.unicode.utf8CountCodepoints(s) catch return error.InvalidUtf8;
    return @intCast(n);
}
fn stringIsEmpty(userdata: ?*const anyopaque, s: []const u8) bool {
    _ = userdata;
    return s.len == 0;
}
fn stringConcat(userdata: ?*const anyopaque, a: []const u8, b: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    try out.appendSlice(a);
    try out.appendSlice(b);
}
fn stringContains(userdata: ?*const anyopaque, haystack: []const u8, needle: []const u8) bool {
    _ = userdata;
    // Both are valid UTF-8, so byte search preserves code-point
    // boundaries; an empty needle matches at index 0.
    return std.mem.indexOf(u8, haystack, needle) != null;
}
fn stringStartsWith(userdata: ?*const anyopaque, s: []const u8, prefix: []const u8) bool {
    _ = userdata;
    return std.mem.startsWith(u8, s, prefix);
}
fn stringEndsWith(userdata: ?*const anyopaque, s: []const u8, suffix: []const u8) bool {
    _ = userdata;
    return std.mem.endsWith(u8, s, suffix);
}
fn stringIndexOf(userdata: ?*const anyopaque, haystack: []const u8, needle: []const u8) StringErr!?i32 {
    _ = userdata;
    if (needle.len == 0) return 0; // an empty needle matches at index 0
    const occ = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const n = std.unicode.utf8CountCodepoints(haystack[0..occ]) catch return error.InvalidUtf8;
    return @intCast(n); // code-point index of the first occurrence
}
fn stringSubstring(userdata: ?*const anyopaque, s: []const u8, start: i32, end: i32, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    const n: i32 = @intCast(std.unicode.utf8CountCodepoints(s) catch return error.InvalidUtf8);
    // StdLib §5: negative offset, start > end, or offset beyond len traps.
    if (start < 0 or end < start or start > n or end > n) return error.Range;
    // Walk to the byte offset of code-point `start`, then on to `end`.
    var pos: usize = 0;
    var i: i32 = 0;
    while (i < start) : (i += 1) {
        pos += std.unicode.utf8ByteSequenceLength(s[pos]) catch return error.InvalidUtf8;
    }
    const bstart = pos;
    while (i < end) : (i += 1) {
        pos += std.unicode.utf8ByteSequenceLength(s[pos]) catch return error.InvalidUtf8;
    }
    try out.appendSlice(s[bstart..pos]);
}
fn stringSplit(userdata: ?*const anyopaque, s: []const u8, sep: []const u8, out: *std.array_list.Managed([]const u8)) StringErr!void {
    _ = userdata;
    if (s.len == 0) return out.append(""); // an empty s splits to [""]
    if (sep.len == 0) {
        // An empty sep yields single-code-point strings.
        var pos: usize = 0;
        while (pos < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[pos]) catch return error.InvalidUtf8;
            try out.append(s[pos .. pos + n]);
            pos += n;
        }
        return;
    }
    var pos: usize = 0;
    while (true) {
        const occ = std.mem.indexOfPos(u8, s, pos, sep) orelse {
            try out.append(s[pos..]);
            return;
        };
        try out.append(s[pos..occ]);
        pos = occ + sep.len;
    }
}
fn stringJoin(userdata: ?*const anyopaque, parts: []const []const u8, sep: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    for (parts, 0..) |p, i| {
        if (i > 0) try out.appendSlice(sep);
        try out.appendSlice(p);
    }
}

/// The Unicode White_Space property (Unicode DerivedCoreProperties) as
/// inclusive [lo, hi] code-point ranges, sorted. The canonical set is
/// small and stable; a linear scan is fine.
const white_space = [_][2]u21{
    .{ 0x09, 0x0D },     .{ 0x20, 0x20 },     .{ 0x85, 0x85 },     .{ 0xA0, 0xA0 },
    .{ 0x1680, 0x1680 }, .{ 0x2000, 0x200A }, .{ 0x2028, 0x2029 }, .{ 0x202F, 0x202F },
    .{ 0x205F, 0x205F }, .{ 0x3000, 0x3000 },
};
fn isWhiteSpace(cp: u21) bool {
    for (white_space) |r| {
        if (cp >= r[0] and cp <= r[1]) return true;
    }
    return false;
}

/// §5: removes leading and trailing Unicode whitespace.
fn stringTrim(userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    var first: ?usize = null;
    var last_end: usize = 0;
    var pos: usize = 0;
    while (pos < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[pos]) catch return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(s[pos .. pos + n]) catch return error.InvalidUtf8;
        if (!isWhiteSpace(cp)) {
            if (first == null) first = pos;
            last_end = pos + n;
        }
        pos += n;
    }
    if (first) |f| try out.appendSlice(s[f..last_end]);
}

/// Encode one code point into `out`.
fn appendCp(out: *std.array_list.Managed(u8), cp: u21) StringErr!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadCodepoint;
    try out.appendSlice(buf[0..n]);
}

/// Append `cp`'s full lowercase mapping (SpecialCasing expansion, else
/// the simple mapping, else itself).
fn appendLower(out: *std.array_list.Managed(u8), cp: u21) StringErr!void {
    if (unicode_case.lookupSpecialLower(cp)) |sp| {
        try out.appendSlice(sp.expansion);
    } else if (unicode_case.lookupSimple(cp)) |m| {
        try appendCp(out, @intCast(m.lower));
    } else {
        try appendCp(out, cp);
    }
}

/// Append `cp`'s full uppercase mapping (SpecialCasing expansion, else
/// the simple mapping, else itself).
fn appendUpper(out: *std.array_list.Managed(u8), cp: u21) StringErr!void {
    if (unicode_case.lookupSpecialUpper(cp)) |sp| {
        try out.appendSlice(sp.expansion);
    } else if (unicode_case.lookupSimple(cp)) |m| {
        try appendCp(out, @intCast(m.upper));
    } else {
        try appendCp(out, cp);
    }
}

/// §5: full Unicode default case conversion; may change the length.
/// `lower` applies the Final_Sigma context (Unicode Standard §3.13,
/// SpecialCasing.txt): capital sigma maps to final sigma when preceded
/// by a cased character (skipping Case_Ignorable characters going
/// backward) and not followed by a cased character (skipping
/// Case_Ignorable characters going forward), evaluated on the input.
fn stringLower(userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    // Cased-ness of the nearest preceding code point that is not
    // Case_Ignorable; ignorables leave it unchanged.
    var prev_cased = false;
    while (it.nextCodepoint()) |cp| {
        // `it.i` now points past `cp` — the forward-scan start.
        if (cp == 0x03A3 and prev_cased and !followedByCased(s, it.i)) {
            try appendCp(out, 0x03C2); // GREEK SMALL LETTER FINAL SIGMA
        } else {
            try appendLower(out, cp);
        }
        if (!unicode_case.isCaseIgnorable(cp)) prev_cased = unicode_case.isCased(cp);
    }
}

/// Final_Sigma forward condition: is the nearest code point after byte
/// offset `i` that is not Case_Ignorable cased? End of string counts as
/// "not followed by cased".
fn followedByCased(s: []const u8, i: usize) bool {
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = i };
    while (it.nextCodepoint()) |cp| {
        if (unicode_case.isCaseIgnorable(cp)) continue;
        return unicode_case.isCased(cp);
    }
    return false;
}
fn stringUpper(userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| try appendUpper(out, cp);
}

/// §5: replaces every non-overlapping occurrence of `from` with `to`;
/// an empty `from` inserts `to` between every code point and at both
/// ends. Left-to-right so replacements never overlap.
fn stringReplace(userdata: ?*const anyopaque, s: []const u8, from: []const u8, to: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    if (from.len == 0) {
        try out.appendSlice(to);
        var pos: usize = 0;
        while (pos < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[pos]) catch return error.InvalidUtf8;
            try out.appendSlice(s[pos .. pos + n]);
            try out.appendSlice(to);
            pos += n;
        }
        return;
    }
    var pos: usize = 0;
    while (true) {
        const occ = std.mem.indexOfPos(u8, s, pos, from) orelse {
            try out.appendSlice(s[pos..]);
            return;
        };
        try out.appendSlice(s[pos..occ]);
        try out.appendSlice(to);
        pos = occ + from.len;
    }
}
fn stringRepeat(userdata: ?*const anyopaque, s: []const u8, count: i32, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    // StdLib §5: a negative count is a deterministic runtime trap.
    if (count < 0) return error.Range;
    var i: i32 = 0;
    while (i < count) : (i += 1) try out.appendSlice(s);
}
fn stringToUtf8(userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    // VM strings are stored as UTF-8, so the encoding is the bytes.
    try out.appendSlice(s);
}
fn stringFromUtf8(userdata: ?*const anyopaque, bytes: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    // StdLib §5: invalid UTF-8 is a deterministic runtime trap.
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    try out.appendSlice(bytes);
}
fn stringToCodepoints(userdata: ?*const anyopaque, s: []const u8, out: *std.array_list.Managed(u32)) StringErr!void {
    _ = userdata;
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| try out.append(@intCast(cp));
}
fn stringFromCodepoints(userdata: ?*const anyopaque, cps: []const u32, out: *std.array_list.Managed(u8)) StringErr!void {
    _ = userdata;
    // StdLib §5: surrogates and values above 0x10FFFF trap.
    var buf: [4]u8 = undefined;
    for (cps) |cp| {
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return error.BadCodepoint;
        try out.appendSlice(buf[0..n]);
    }
}

// ---------------------------------------------------------------------------
// The `list` module (Runtime §4.3–§4.4) — the two host-backed members.
// `len` is an O(1) read: the adapter hands the head cons node's stored
// suffix length to the handler. `range` generates the inclusive integer
// range as plain values; the adapter materializes the `list[int32]`
// cons chain (M2).
// ---------------------------------------------------------------------------

pub const ListHostCall = struct {
    /// §4.3: the element count of a borrowed list (the adapter reads the
    /// head node's stored suffix length).
    len: *const fn (userdata: ?*const anyopaque, count: i32) i32 = listLen,
    /// §4.4: the inclusive [start, end] integer range, appended as plain
    /// values; empty when start > end.
    range: *const fn (userdata: ?*const anyopaque, start: i32, end: i32, out: *std.array_list.Managed(i32)) anyerror!void = listRange,
};

/// The default `list` implementation (Runtime §4.3–§4.4).
pub const listHostCall = ListHostCall{};

fn listLen(userdata: ?*const anyopaque, count: i32) i32 {
    _ = userdata;
    return count;
}
fn listRange(userdata: ?*const anyopaque, start: i32, end: i32, out: *std.array_list.Managed(i32)) anyerror!void {
    _ = userdata;
    var v = start;
    while (v <= end) : (v += 1) try out.append(v);
}

// M3 opaque host-object storage, one module per file; the flattened
// re-exports below keep the interpreter adapter's single `host_module`
// import working.
pub const array_storage = @import("host_array.zig");
pub const hashmap_storage = @import("host_hashmap.zig");
pub const ArrayMember = array_storage.ArrayMember;
pub const ArrayErr = array_storage.ArrayErr;
pub const ArrayObject = array_storage.ArrayObject;
pub const HashMapMember = hashmap_storage.HashMapMember;
pub const HashMapEntry = hashmap_storage.HashMapEntry;
pub const HashMapHashFn = hashmap_storage.HashMapHashFn;
pub const HashMapEqFn = hashmap_storage.HashMapEqFn;
pub const HashMapObject = hashmap_storage.HashMapObject;
