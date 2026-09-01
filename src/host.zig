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
//! The stdlib host implementations live here as plain functions
//! (`hostStr`..`hostHash`, `stringLen`..`stringFromCodepoints`,
//! `listLen`/`listRange`) — the module structs in interpreter_host.zig
//! bind them (docs/host-bindings.md §7). Handlers receive only verified
//! plain data and never touch the VM; the binding layer does the heap
//! mechanics. M3 adds the `array`/`hashmap` opaque host objects: their
//! storage (`ArrayObject`, `HashMapObject`) lives here as plain data and
//! the interpreter bindings own the retain/release and exactly-once
//! disposal contract (docs/interpreter-vm.md §9).

const std = @import("std");
const vm_types = @import("vm_types.zig");
const unicode_case = @import("unicode_case.zig");

/// `builtin.print` — Runtime §4.1 — has no runtime implementation: it
/// dispatches to the embedding's `HostCall.print` hook (host-bindings.md
/// §7). The other `builtin` members:
///
/// `builtin.str` — Runtime §4.2: canonical decimal form of the decoded
/// scalar; a str view is returned unchanged.
pub fn hostStr(value: vm_types.ScalarView, buf: []u8) anyerror![]const u8 {
    return vm_types.formatView(value, buf);
}

/// `builtin.box` — Runtime §4.5: the payload to wrap. The interpreter
/// allocates the box shell around the returned value.
pub fn hostBox(value: vm_types.Value) vm_types.Value {
    return value;
}

/// `builtin.unbox` — Runtime §4.6: the extracted payload. The interpreter
/// frees the box shell after the handler returns.
pub fn hostUnbox(payload: vm_types.Value) vm_types.Value {
    return payload;
}

/// `builtin.panic` — Runtime §4.7: the termination message.
pub fn hostPanic(message: []const u8) []const u8 {
    return message;
}

/// `builtin.assert` — Runtime §4.8: the panic message; the interpreter
/// calls this only on the false path.
pub fn hostAssert(message: []const u8) []const u8 {
    return message;
}

/// `builtin.hash` — Runtime §4.9: hash the verified bytes (str contents
/// or raw scalar cell).
pub fn hostHash(bytes: []const u8) vm_types.Value {
    return std.hash.Wyhash.hash(0, bytes);
}

// ---------------------------------------------------------------------------
// The `string` module (StdLib §5) — Unicode text operations. Handlers
// receive verified plain data (`[]const u8` UTF-8 byte slices, decoded
// scalars, or scratch buffers) and never touch the VM; the binding layer
// performs the heap mechanics (str/list object allocation, list walks)
// and maps handler errors to owned trap messages. All text processing
// operates on code points, never byte offsets (StdLib §5).
// ---------------------------------------------------------------------------

/// Errors a string handler reports; the interpreter binding maps each to
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

/// §5: lengths are in code points, never bytes.
pub fn stringLen(s: []const u8) StringErr!i32 {
    const n = std.unicode.utf8CountCodepoints(s) catch return error.InvalidUtf8;
    return @intCast(n);
}
pub fn stringIsEmpty(s: []const u8) bool {
    return s.len == 0;
}
pub fn stringConcat(a: []const u8, b: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    try out.appendSlice(a);
    try out.appendSlice(b);
}
pub fn stringContains(haystack: []const u8, needle: []const u8) bool {
    // Both are valid UTF-8, so byte search preserves code-point
    // boundaries; an empty needle matches at index 0.
    return std.mem.indexOf(u8, haystack, needle) != null;
}
pub fn stringStartsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}
pub fn stringEndsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}
pub fn stringIndexOf(haystack: []const u8, needle: []const u8) StringErr!?i32 {
    if (needle.len == 0) return 0; // an empty needle matches at index 0
    const occ = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const n = std.unicode.utf8CountCodepoints(haystack[0..occ]) catch return error.InvalidUtf8;
    return @intCast(n); // code-point index of the first occurrence
}
pub fn stringSubstring(s: []const u8, start: i32, end: i32, out: *std.array_list.Managed(u8)) StringErr!void {
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
pub fn stringSplit(s: []const u8, sep: []const u8, out: *std.array_list.Managed([]const u8)) StringErr!void {
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
pub fn stringJoin(parts: []const []const u8, sep: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
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
pub fn stringTrim(s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
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
pub fn stringLower(s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
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
pub fn stringUpper(s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| try appendUpper(out, cp);
}

/// §5: replaces every non-overlapping occurrence of `from` with `to`;
/// an empty `from` inserts `to` between every code point and at both
/// ends. Left-to-right so replacements never overlap.
pub fn stringReplace(s: []const u8, from: []const u8, to: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
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
pub fn stringRepeat(s: []const u8, count: i32, out: *std.array_list.Managed(u8)) StringErr!void {
    // StdLib §5: a negative count is a deterministic runtime trap.
    if (count < 0) return error.Range;
    var i: i32 = 0;
    while (i < count) : (i += 1) try out.appendSlice(s);
}
pub fn stringToUtf8(s: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    // VM strings are stored as UTF-8, so the encoding is the bytes.
    try out.appendSlice(s);
}
pub fn stringFromUtf8(bytes: []const u8, out: *std.array_list.Managed(u8)) StringErr!void {
    // StdLib §5: invalid UTF-8 is a deterministic runtime trap.
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    try out.appendSlice(bytes);
}
pub fn stringToCodepoints(s: []const u8, out: *std.array_list.Managed(u32)) StringErr!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| try out.append(@intCast(cp));
}
pub fn stringFromCodepoints(cps: []const u32, out: *std.array_list.Managed(u8)) StringErr!void {
    // StdLib §5: surrogates and values above 0x10FFFF trap.
    var buf: [4]u8 = undefined;
    for (cps) |cp| {
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return error.BadCodepoint;
        try out.appendSlice(buf[0..n]);
    }
}

// ---------------------------------------------------------------------------
// The `list` module (Runtime §4.3–§4.4) — the two host-backed members.
// `len` is an O(1) read: the binding hands the head cons node's stored
// suffix length to the handler. `range` generates the inclusive integer
// range as plain values; the binding materializes the `list[int32]`
// cons chain (M2).
// ---------------------------------------------------------------------------

/// §4.3: the element count of a borrowed list (the binding reads the
/// head node's stored suffix length).
pub fn listLen(count: i32) i32 {
    return count;
}

/// §4.4: the inclusive [start, end] integer range, appended as plain
/// values; empty when start > end.
pub fn listRange(start: i32, end: i32, out: *std.array_list.Managed(i32)) anyerror!void {
    var v = start;
    while (v <= end) : (v += 1) try out.append(v);
}

// M3 opaque host-object storage, one module per file; the flattened
// re-exports below keep the interpreter binding's single `host_module`
// import working.
pub const array_storage = @import("host_array.zig");
pub const hashmap_storage = @import("host_hashmap.zig");
pub const ArrayErr = array_storage.ArrayErr;
pub const ArrayObject = array_storage.ArrayObject;
pub const HashMapEntry = hashmap_storage.HashMapEntry;
pub const HashMapHashFn = hashmap_storage.HashMapHashFn;
pub const HashMapEqFn = hashmap_storage.HashMapEqFn;
pub const HashMapObject = hashmap_storage.HashMapObject;
