//! Black-box interpreter host-boundary tests: the required `builtin` interface,
//! `(specifier, member)` dispatch to `math`/`string`/`list`, the `any` dynamic
//! type pack/test/recover, and the M3 `array`/`hashmap` opaque host objects.

const std = @import("std");
const llir = @import("llir.zig");
const vm_types = @import("vm_types.zig");
const interpreter = @import("interpreter.zig");
const vm_dispatch = @import("interpreter_dispatch.zig");
const frontend = @import("frontend.zig");
const moduleinfo = @import("moduleinfo.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const lower = @import("lower.zig");
const checker = @import("passes/checker.zig");
const stdbundle = @import("stdbundle.zig");
const host_module = @import("host.zig");
const artifact_bundle = @import("artifact_bundle.zig");
const llir_emit_bin = @import("passes/llir_emit_bin.zig");
const stilla_asm_printer = lower.llirAsm;
const testing = std.testing;

const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;

const support = @import("interpreter_test_support.zig");
const load = support.load;
const Loaded = support.Loaded;
const CaptureAdapter = support.CaptureAdapter;
const runHand = support.runHand;
const runHandBlocks = support.runHandBlocks;
const runHandImage = support.runHandImage;
const primType = support.primType;

// ---------------------------------------------------------------------------
// Phase 6 — host adapter, `any` dynamic types (TODO.md 阶段 6)
// ---------------------------------------------------------------------------

test "host: builtin.print and str format every supported scalar" {
    // Capture through a host adapter instead of writing to real stdout: fd 1
    // is the build runner's `--listen` pipe in `zig build test`, so stdout
    // sinks are probed as subprocesses, never in-process (build.zig). The
    // `str` members still delegate to the default host call.
    const Capture = struct {
        buffer: [128]u8 = undefined,
        len: usize = 0,
    };
    var state = Capture{};

    const Adapter = struct {
        fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: interpreter.HostSignature, args: []const vm_types.Value) interpreter.HostResult {
            if (std.mem.eql(u8, member, "print") and args.len > 0) {
                const c: *Capture = @ptrCast(@alignCast(@constCast(userdata.?)));
                const bytes = vm.runtime.heap.strSliceOf(args[0]) orelse return .{ .panic = "print: not a str" };
                @memcpy(c.buffer[c.len..][0..bytes.len], bytes);
                c.len += bytes.len;
                c.buffer[c.len] = '\n';
                c.len += 1;
                return .{ .value = 0 };
            }
            return interpreter.defaultHostCall(vm, userdata, module_symbol, member, sig, args);
        }
    };

    var l = try load(
        \\const builtin = import("builtin");
        \\fn big() -> i64 { 2971215073 }
        \\fn huge() -> u64 { 18446744073709551615 }
        \\fn precise() -> f64 { 2.5 }
        \\fn main() -> void {
        \\    builtin.print(builtin.str(42));
        \\    builtin.print(builtin.str(-7));
        \\    builtin.print(builtin.str(3.5));
        \\    builtin.print(builtin.str(true));
        \\    builtin.print(builtin.str("hi"));
        \\    builtin.print(builtin.str(big()));
        \\    builtin.print(builtin.str(huge()));
        \\    builtin.print(builtin.str(precise()));
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = Adapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings("42\n-7\n3.5\ntrue\nhi\n2971215073\n18446744073709551615\n2.5\n", state.buffer[0..state.len]);
}

test "host: custom adapter captures print and delegates the rest" {
    // The embedding replaces the adapter; builtin members it does not
    // implement keep the default behavior. The captured str cell is
    // decoded through the public str helper.
    const Capture = struct {
        buffer: [64]u8 = undefined,
        len: usize = 0,
    };
    var state = Capture{};

    const Adapter = struct {
        fn invoke(vm: *interpreter.VmCtx, userdata: ?*const anyopaque, module_symbol: []const u8, member: []const u8, sig: interpreter.HostSignature, args: []const vm_types.Value) interpreter.HostResult {
            if (std.mem.eql(u8, member, "print") and args.len > 0) {
                const c: *Capture = @ptrCast(@alignCast(@constCast(userdata.?)));
                const bytes = vm.runtime.heap.strSliceOf(args[0]) orelse return .{ .panic = "print: not a str" };
                @memcpy(c.buffer[0..bytes.len], bytes);
                c.len = bytes.len;
                return .{ .value = 0 };
            }
            return interpreter.defaultHostCall(vm, userdata, module_symbol, member, sig, args);
        }
    };

    var l = try load(
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print("hello host");
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = Adapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings("hello host", state.buffer[0..state.len]);
}

test "host: builtin.print dispatches through the HostCall.print hook" {
    // The registry path: with no `invoke` overrider, `builtin.print`
    // resolves through the default registry and calls the embedding's
    // `HostCall.print` hook — the message bytes plus the hook's own
    // userdata. The hook is responsible for the line ending (the old
    // default wrote message + "\n" to stdout; there is no default now).
    const Capture = struct {
        buffer: [64]u8 = undefined,
        len: usize = 0,
    };
    var state = Capture{};
    const Hook = struct {
        fn invoke(userdata: ?*anyopaque, bytes: []const u8) void {
            const c: *Capture = @ptrCast(@alignCast(userdata.?));
            @memcpy(c.buffer[c.len..][0..bytes.len], bytes);
            c.len += bytes.len;
            c.buffer[c.len] = '\n';
            c.len += 1;
        }
    };
    var l = try load(
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print("one");
        \\    builtin.print("two");
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .print = .{ .userdata = &state, .invoke = Hook.invoke } },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings("one\ntwo\n", state.buffer[0..state.len]);
}

test "host: builtin.print without a hook traps as not implemented" {
    // There is no default print implementation: a program that calls
    // `builtin.print` under the default `HostCall` traps deterministically
    // with the standard not-implemented message.
    var l = try load(
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print("hi");
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| {
            try testing.expect(std.mem.indexOf(u8, m, "not implemented") != null);
            try testing.expect(std.mem.indexOf(u8, m, "builtin#print") != null);
        },
    }
}

test "host: box/unbox round-trips ownership through the default adapter" {
    var l = try load(
        \\const builtin = import("builtin");
        \\fn main() -> int32 {
        \\    let b = builtin.box(7);
        \\    let u = builtin.unbox(b);
        \\    u
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 7), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "host: a Copy box survives a non-consuming unbox (Runtime §4.6)" {
    // `builtin.unbox(b)` of a Copy-payload box returns a copy and does
    // not invalidate the source box: the shell must survive, so a
    // second `unbox(b)` still reads the payload, and the move-unbox
    // afterwards consumes the box. The syscall's signature carries the
    // EFFECTIVE mode (plain here, move for `unbox(move b)`) — the
    // declared `move box[T]` parameter alone would free the shell on
    // the first read and the second would deref freed memory.
    var l = try load(
        \\const builtin = import("builtin");
        \\fn main() -> int32 {
        \\    let b = builtin.box(7);
        \\    builtin.unbox(b) + builtin.unbox(b) + builtin.unbox(move b)
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 21), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "host: builtin.panic terminates with the message; assert(false) panics" {
    var l = try load(
        \\const builtin = import("builtin");
        \\fn main() -> int32 {
        \\    builtin.panic("boom");
        \\}
    , false);
    defer l.deinit();
    {
        var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
        defer term.deinit(testing.allocator);
        switch (term) {
            .normal => return error.TestUnexpectedResult,
            .panic => |m| try testing.expect(std.mem.indexOf(u8, m, "boom") != null),
        }
    }

    var l2 = try load(
        \\const builtin = import("builtin");
        \\fn main() -> int32 {
        \\    builtin.assert(1 == 2, "not equal");
        \\    0
        \\}
    , false);
    defer l2.deinit();
    {
        var term = try interpreter.runWithEntry(testing.allocator, l2.image, try l2.fid("main"), .{});
        defer term.deinit(testing.allocator);
        switch (term) {
            .normal => return error.TestUnexpectedResult,
            .panic => |m| try testing.expect(std.mem.indexOf(u8, m, "not equal") != null),
        }
    }
}

test "host: unknown member traps as not implemented" {
    // D2 dispatch: the default host resolves (specifier, member) and
    // reports `not_implemented` for a member with no handler, which the
    // syscall dispatch turns into a deterministic trap. The frontend
    // cannot produce an unknown member (its intrinsic expansion table
    // rejects them at compile time), so patch a compiled binding's
    // member range to a genuinely unknown string in the image — the
    // "app" module specifier — while its module specifier stays
    // "builtin".
    var l = try load(
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print("x");
        \\}
    , false);
    defer l.deinit();
    // The artifact is symbolic: patch the import's member symbol bytes
    // in the strings blob to a genuinely unknown member ("app"), while
    // the declaring module symbol stays "builtin" — the syscall then
    // dispatches into the builtin handler with an unknown member.
    try testing.expect(l.image.self_symbol < l.image.symbols.len);
    try testing.expect(l.image.imports.len > 0);
    const strings = @constCast(l.image.strings);
    var patched = false;
    for (l.image.imports) |imp| {
        const mr = l.image.symbols[imp.member_sym];
        const bytes = strings[mr.start..][0..mr.len];
        if (std.mem.eql(u8, bytes, "print")) {
            @memcpy(bytes, "app\x00\x00");
            patched = true;
        }
    }
    try testing.expect(patched);
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| {
            try testing.expect(std.mem.indexOf(u8, m, "not implemented") != null);
            // The trap names the genuinely unknown member.
            try testing.expect(std.mem.indexOf(u8, m, "app") != null);
        },
    }
}

// ---------------------------------------------------------------------------
// M2 — host dispatch by (specifier, member): `math`, `string`, `list`
// (docs/interpreter-vm.md §9). One compile→run fixture per module, plus
// the unknown-member trap and the dispatch-identity assertions.
test "host: math module computes the 20 StdLib functions with IEEE edges" {
    // Every `math` member (StdLib §4) prints through the capturing
    // adapter; golden values are exact f32 results. `atan2(y, x)` takes
    // y first, `round` ties away from zero, `min`/`max` are IEEE
    // `fmin`/`fmax`.
    var state = CaptureAdapter{};
    var l = try load(
        \\const math = import("math");
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print(builtin.str(math.sqrt(9.0)));
        \\    builtin.print(builtin.str(math.pow(2.0, 10.0)));
        \\    builtin.print(builtin.str(math.exp(0.0)));
        \\    builtin.print(builtin.str(math.ln(1.0)));
        \\    builtin.print(builtin.str(math.log2(8.0)));
        \\    builtin.print(builtin.str(math.log10(100.0)));
        \\    builtin.print(builtin.str(math.sin(0.0)));
        \\    builtin.print(builtin.str(math.cos(0.0)));
        \\    builtin.print(builtin.str(math.tan(0.0)));
        \\    builtin.print(builtin.str(math.asin(1.0)));
        \\    builtin.print(builtin.str(math.acos(1.0)));
        \\    builtin.print(builtin.str(math.atan(1.0)));
        \\    builtin.print(builtin.str(math.atan2(1.0, 1.0)));
        \\    builtin.print(builtin.str(math.floor(2.7)));
        \\    builtin.print(builtin.str(math.ceil(2.2)));
        \\    builtin.print(builtin.str(math.round(2.5)));
        \\    builtin.print(builtin.str(math.round(-2.5)));
        \\    builtin.print(builtin.str(math.trunc(-2.7)));
        \\    builtin.print(builtin.str(math.abs(-3.5)));
        \\    builtin.print(builtin.str(math.min(1.5, 2.5)));
        \\    builtin.print(builtin.str(math.max(1.5, 2.5)));
        \\    builtin.print(builtin.str(math.pi));
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings(
        "3\n1024\n1\n0\n3\n2\n0\n1\n0\n1.5707964\n0\n0.7853982\n0.7853982\n2\n3\n3\n-3\n-2\n3.5\n1.5\n2.5\n3.1415927\n",
        state.buffer[0..state.len],
    );

    // IEEE edges: NaN propagates through min/max; min(-0, +0) = -0 and
    // max(-0, +0) = +0 (fmin/fmax); sqrt(-1) is NaN; ln(0) is -inf;
    // `inf` is positive infinity.
    var state2 = CaptureAdapter{};
    var l2 = try load(
        \\const math = import("math");
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print(builtin.str(math.min(math.nan, 1.0)));
        \\    builtin.print(builtin.str(math.max(math.nan, 1.0)));
        \\    builtin.print(builtin.str(math.min(-0.0, 0.0)));
        \\    builtin.print(builtin.str(math.max(-0.0, 0.0)));
        \\    builtin.print(builtin.str(math.sqrt(-1.0)));
        \\    builtin.print(builtin.str(math.ln(0.0)));
        \\    builtin.print(builtin.str(math.inf));
        \\}
    , false);
    defer l2.deinit();
    var term2 = try interpreter.runWithEntry(
        testing.allocator,
        l2.image,
        try l2.fid("main"),
        .{ .userdata = &state2, .invoke = CaptureAdapter.invoke },
    );
    defer term2.deinit(testing.allocator);
    switch (term2) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings(
        "nan\nnan\n-0\n0\nnan\n-inf\ninf\n",
        state2.buffer[0..state2.len],
    );
}

test "host: string module computes the 19 StdLib functions with code-point semantics" {
    // Every `string` member (StdLib §5): code-point len/index (never
    // byte offsets), full Unicode default case conversion (İ.lower =
    // "i̇", ß.upper = "SS", and the Final_Sigma context), and the
    // byte/code-point conversions.
    var state = CaptureAdapter{};
    var l = try load(
        \\const string = import("string");
        \\const lists = import("list");
        \\const builtin = import("builtin");
        \\using builtin.Option;
        \\fn main() -> void {
        \\    let s = string.concat("hel", "lo");
        \\    builtin.print(builtin.str(string.len("héllo")));
        \\    builtin.print(builtin.str(string.is_empty("")));
        \\    builtin.print(builtin.str(string.contains(s, "ell")));
        \\    builtin.print(builtin.str(string.starts_with(s, "he")));
        \\    builtin.print(builtin.str(string.ends_with(s, "lo")));
        \\    builtin.print(builtin.str(string.len(s)));
        \\    match (string.index_of(s, "ll")) {
        \\        Option::Some(i) => builtin.print(builtin.str(i)),
        \\        Option::None => builtin.print("none")
        \\    };
        \\    match (string.index_of(s, "zz")) {
        \\        Option::Some(i) => builtin.print(builtin.str(i)),
        \\        Option::None => builtin.print("none")
        \\    };
        \\    builtin.print(string.substring(s, 1, 3));
        \\    let parts = string.split(s, "l");
        \\    builtin.print(builtin.str(lists.len(parts)));
        \\    builtin.print(string.join(parts, "-"));
        \\    builtin.print(string.trim("  hi  "));
        \\    builtin.print(string.lower("AbC"));
        \\    builtin.print(string.upper("AbC"));
        \\    builtin.print(string.lower("İ"));
        \\    builtin.print(string.upper("ß"));
        \\    builtin.print(string.lower("ΟΣ"));
        \\    // Case_Ignorable combining marks are skipped when
        \\    // resolving the Final_Sigma context on both sides.
        \\    builtin.print(string.lower("ΌΣ"));
        \\    builtin.print(string.lower("ΟΣ́Α"));
        \\    builtin.print(string.replace("banana", "na", "NA"));
        \\    builtin.print(string.repeat("ab", 3));
        \\    builtin.print(string.from_utf8(string.to_utf8("A€")));
        \\    builtin.print(string.from_codepoints(string.to_codepoints("A€")));
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings(
        "5\ntrue\ntrue\ntrue\ntrue\n5\n2\nnone\nel\n3\nhe--o\nhi\nabc\nABC\ni̇\nSS\nος\nός\nοσ́α\nbaNANA\nababab\nA€\nA€\n",
        state.buffer[0..state.len],
    );
}

test "host: string module traps on out-of-range and invalid input" {
    // StdLib §5 / Runtime §7.2 deterministic traps: out-of-range
    // substring offsets, a negative repeat count, invalid UTF-8, and
    // non-scalar code points (a surrogate).
    const cases = [_]struct { src: []const u8, expect: []const u8 }{
        .{ .src =
        \\const string = import("string");
        \\fn main() -> void { string.substring("hi", 3, 4); }
        , .expect = "index out of range" },
        .{ .src =
        \\const string = import("string");
        \\fn main() -> void { string.substring("hi", -1, 2); }
        , .expect = "index out of range" },
        .{ .src =
        \\const string = import("string");
        \\fn main() -> void { string.repeat("x", -1); }
        , .expect = "index out of range" },
        .{ .src =
        \\const string = import("string");
        \\fn main() -> void { string.from_utf8([255 as byte]); }
        , .expect = "invalid UTF-8" },
        .{ .src =
        \\const string = import("string");
        \\fn main() -> void { string.from_codepoints([55296 as uint32]); }
        , .expect = "not a Unicode scalar value" },
    };
    for (cases) |c| {
        var l = try load(c.src, false);
        defer l.deinit();
        var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
        defer term.deinit(testing.allocator);
        switch (term) {
            .normal => return error.TestUnexpectedResult,
            .panic => |m| try testing.expect(std.mem.indexOf(u8, m, c.expect) != null),
        }
    }
}

test "host: read_payload reads the union payload cell, not the tag" {
    // Regression: `read_payload` (the non-consuming union payload read,
    // whose MemberDesc ref the LLIR spec pins at 0) used to read cell 0
    // — the tag — instead of the active variant's payload at cell 1 + ref.
    // The scrutinee `o` is live across both matches (borrowed), so both
    // arms lower to `read_payload`; with the bug they printed the tag 0.
    var l = try load(
        \\const builtin = import("builtin");
        \\using builtin.Option;
        \\fn main() -> void {
        \\    let o = Option::Some(42);
        \\    match (o) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("none")
        \\    };
        \\    match (o) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("none")
        \\    };
        \\}
    , false);
    defer l.deinit();
    var out = CaptureAdapter{};
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &out, .invoke = CaptureAdapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings("42\n42\n", out.buffer[0..out.len]);
}

test "host: list module len/range with inclusive and empty ranges" {
    // Runtime §4.3–§4.4: `range` is inclusive [start, end]; empty when
    // start > end; `len` is the element count (an O(1) read of the head
    // cons node's stored suffix length). List matching reads the head.
    var state = CaptureAdapter{};
    var l = try load(
        \\const lists = import("list");
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print(builtin.str(lists.len(lists.range(1, 5))));
        \\    builtin.print(builtin.str(lists.len(lists.range(5, 5))));
        \\    builtin.print(builtin.str(lists.len(lists.range(3, 1))));
        \\    builtin.print(builtin.str(lists.len(lists.range(-2, 2))));
        \\    match (lists.range(1, 3)) {
        \\        [] => builtin.print("empty"),
        \\        [h, ..t] => builtin.print(builtin.str(h))
        \\    }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings("5\n1\n0\n5\n1\n", state.buffer[0..state.len]);
}

test "host: same member name dispatches by module specifier (string.len vs list.len)" {
    // D2 dispatch identity: `len` is a member of both `string` and
    // `list`; the default host tells them apart by the (specifier,
    // member) pair — `string.len` counts code points, `list.len` counts
    // elements. Both syscalls carry the member name "len".
    var l = try load(
        \\const string = import("string");
        \\const lists = import("list");
        \\fn main() -> int32 {
        \\    string.len("héllo") * 10 + lists.len(lists.range(1, 3))
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 53), v), // 5 * 10 + 3
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "any: 32/64-bit dynamic types pack, test, and recover by dynamic TypeId" {
    var l = try load(
        \\fn main() -> int32 {
        \\    let vi: i64 = 9007199254740993;
        \\    let a: any = vi;
        \\    let w = a as i64;
        \\    let vu: u64 = 18446744073709551615;
        \\    let a2: any = vu;
        \\    let w2 = a2 as u64;
        \\    if (w == vi and w2 == vu) { 1 } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 1), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "any: a full binary64 cell (NaN payload) survives pack and recovery" {
    var l = try load(
        \\fn main() -> int32 {
        \\    let n: f64 = 0.0 / 0.0;
        \\    let a: any = n;
        \\    let w = a as f64;
        \\    if (w != w) { 1 } else { 0 }
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => |v| try testing.expectEqual(@as(Value, 1), v),
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "any: wrong-type recovery traps (dynamic TypeId mismatch)" {
    var l = try load(
        \\fn main() -> int32 {
        \\    let v: int32 = 5;
        \\    let a: any = v;
        \\    let w = a as uint32;
        \\    w as int32
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| try testing.expect(std.mem.indexOf(u8, m, "mismatch") != null),
    }
}

// ---------------------------------------------------------------------------
// M3 — opaque host objects: `array` / `hashmap` (StdLib §2, §3)
// ---------------------------------------------------------------------------

test "host: array module make/len/get/set/clone with copy element semantics" {
    // StdLib §2 usage: construct, borrow reads, in-place consuming
    // `set` (same shell moves on), and a deep `clone`.
    var state = CaptureAdapter{};
    var l = try load(
        \\const array = import("array");
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    let a = array.make(3, 7);
        \\    builtin.print(builtin.str(array.len::[int32](a)));
        \\    builtin.print(builtin.str(array.get::[int32](a, 1)));
        \\    let a = array.set(move a, 2, 42);
        \\    builtin.print(builtin.str(array.get::[int32](a, 2)));
        \\    let b = array.clone::[int32](a);
        \\    let a = array.set(move a, 1, 5);
        \\    builtin.print(builtin.str(array.get::[int32](a, 1)));
        \\    builtin.print(builtin.str(array.get::[int32](b, 1)));
        \\    builtin.print(builtin.str(array.len::[int32](b)));
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings("3\n7\n42\n5\n7\n3\n", state.buffer[0..state.len]);
}

test "host: array module traps on negative length and invalid indices" {
    // Runtime §7.2: negative `make` length; `get`/`set` with a negative
    // or >= len index trap deterministically.
    const cases = [_]struct { src: []const u8, expect: []const u8 }{
        .{ .src =
        \\const array = import("array");
        \\fn main() -> void { array.make(-1, 0); }
        , .expect = "array.make: negative length" },
        .{ .src =
        \\const array = import("array");
        \\fn main() -> void {
        \\    let a = array.make(2, 0);
        \\    array.get::[int32](a, 2);
        \\}
        , .expect = "array.get: index 2 out of range (len 2)" },
        .{ .src =
        \\const array = import("array");
        \\fn main() -> void {
        \\    let a = array.make(2, 0);
        \\    array.get::[int32](a, -1);
        \\}
        , .expect = "array.get: index -1 out of range (len 2)" },
        .{ .src =
        \\const array = import("array");
        \\fn main() -> void {
        \\    let a = array.make(2, 0);
        \\    let a = array.set(move a, 5, 1);
        \\}
        , .expect = "array.set: index 5 out of range (len 2)" },
    };
    for (cases) |c| {
        var l = try load(c.src, false);
        defer l.deinit();
        var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
        defer term.deinit(testing.allocator);
        switch (term) {
            .normal => return error.TestUnexpectedResult,
            .panic => |m| try testing.expect(std.mem.indexOf(u8, m, c.expect) != null),
        }
    }
}

test "host: array with str elements survives clone and overwrite with zero leaks" {
    // Counted str elements: `make` holds one reference per slot, `get`
    // copies (the copy outlives an overwrite of the same slot), `clone`
    // retains each element, and overwrite releases the displaced cell.
    var l = try load(
        \\const array = import("array");
        \\const builtin = import("builtin");
        \\fn main() -> int32 {
        \\    let a = array.make(2, "hi");
        \\    let first = array.get::[str](a, 0);
        \\    let b = array.clone::[str](a);
        \\    let a = array.set(move a, 0, "bye");
        \\    if (first == "hi") {
        \\        if (array.get::[str](b, 0) == "hi") {
        \\            if (array.get::[str](a, 0) == "bye") { 0 } else { 3 }
        \\        } else { 2 }
        \\    } else { 1 }
        \\}
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    var result: Value = 0;
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |t| {
            switch (t) {
                .normal => |v| result = v,
                .panic => |m| {
                    std.log.err("unexpected panic: {s}", .{m});
                    testing.allocator.free(m);
                    return error.TestUnexpectedResult;
                },
            }
            break;
        }
        try vm.drainDestroyWork();
    }
    vm.finishCleanup();
    try testing.expectEqual(@as(Value, 0), result);
    try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count());
    try testing.expectEqual(@as(usize, 0), vm.runtime.host_resources.count());
}

test "host: hashmap module empty/insert/get/contains/remove/len/clone with str keys" {
    // StdLib §3 usage: str keys match by content (mirroring
    // `builtin.hash` and `==`), `get` yields `Option[V]`, `remove`
    // returns tuple[map, Option[V]] with the value transferred.
    var state = CaptureAdapter{};
    var l = try load(
        \\const hashmap = import("hashmap");
        \\const builtin = import("builtin");
        \\using builtin.Option;
        \\fn main() -> void {
        \\    let m = hashmap.empty::[str, int32]();
        \\    let m = hashmap.insert(move m, "a", 1);
        \\    let m = hashmap.insert(move m, "b", 2);
        \\    builtin.print(builtin.str(hashmap.len::[str, int32](m)));
        \\    builtin.print(builtin.str(hashmap.contains::[str, int32](m, "b")));
        \\    builtin.print(builtin.str(hashmap.contains::[str, int32](m, "zz")));
        \\    match (hashmap.get::[str, int32](m, "a")) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    match (hashmap.get::[str, int32](m, "zz")) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    let m = hashmap.insert(move m, "b", 9);
        \\    match (hashmap.get::[str, int32](m, "b")) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    let c = hashmap.clone::[str, int32](m);
        \\    builtin.print(builtin.str(hashmap.len::[str, int32](c)));
        \\    let (m, removed) = hashmap.remove::[str, int32](move m, "b");
        \\    match (removed) {
        \\        Option::Some(v) => builtin.print(builtin.str(v)),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    builtin.print(builtin.str(hashmap.len::[str, int32](m)));
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings(
        "2\ntrue\nfalse\n1\nmissing\n9\n2\n9\n1\n",
        state.buffer[0..state.len],
    );
}

test "host: hashmap with scalar keys, overwrite, and str-key content identity" {
    // int32 keys exercise the raw-cell hash path; an existing key
    // replaces the value; equal-content str keys hit one entry while
    // distinct contents miss.
    var state = CaptureAdapter{};
    var l = try load(
        \\const hashmap = import("hashmap");
        \\const builtin = import("builtin");
        \\using builtin.Option;
        \\fn main() -> void {
        \\    let m = hashmap.empty::[int32, str]();
        \\    let m = hashmap.insert(move m, 10, "x");
        \\    let m = hashmap.insert(move m, 20, "y");
        \\    let m = hashmap.insert(move m, 10, "z");
        \\    builtin.print(builtin.str(hashmap.len::[int32, str](m)));
        \\    match (hashmap.get::[int32, str](m, 10)) {
        \\        Option::Some(v) => builtin.print(v),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    let (m, removed) = hashmap.remove::[int32, str](move m, 10);
        \\    match (removed) {
        \\        Option::Some(v) => builtin.print(v),
        \\        Option::None => builtin.print("missing")
        \\    };
        \\    builtin.print(builtin.str(hashmap.contains::[int32, str](m, 10)));
        \\    let s = hashmap.empty::[str, int32]();
        \\    let a = "he";
        \\    let b = "llo";
        \\    let s = hashmap.insert(move s, a, 1);
        \\    let s = hashmap.insert(move s, b, 2);
        \\    builtin.print(builtin.str(hashmap.len::[str, int32](s)));
        \\    builtin.print(builtin.str(hashmap.contains::[str, int32](s, "llo")));
        \\}
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(
        testing.allocator,
        l.image,
        try l.fid("main"),
        .{ .userdata = &state, .invoke = CaptureAdapter.invoke },
    );
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => {},
        .panic => |m| {
            std.log.err("unexpected panic: {s}", .{m});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqualStrings("2\nz\nz\nfalse\n2\ntrue\n", state.buffer[0..state.len]);
}

test "host: hashmap traps on an unhashable key type before any mutation" {
    // StdLib §3: `builtin.hash` covers only primitive scalars and str;
    // the frontend does not reject a list key today, so the runtime
    // traps deterministically instead of mis-hashing.
    var l = try load(
        \\const hashmap = import("hashmap");
        \\fn main() -> void { hashmap.empty::[list[int32], int32](); }
    , false);
    defer l.deinit();
    var term = try interpreter.runWithEntry(testing.allocator, l.image, try l.fid("main"), .{});
    defer term.deinit(testing.allocator);
    switch (term) {
        .normal => return error.TestUnexpectedResult,
        .panic => |m| try testing.expect(std.mem.indexOf(u8, m, "unsupported key type") != null),
    }
}

test "host: opaque array/map disposal runs exactly once on drop" {
    // The arrays and map die at scope/return end; the disposer releases
    // every stored cell and the registry ends empty — exactly once each.
    var l = try load(
        \\const array = import("array");
        \\const hashmap = import("hashmap");
        \\fn work() -> int32 {
        \\    let a = array.make(3, "elem");
        \\    let b = array.clone::[str](a);
        \\    let m = hashmap.empty::[str, int32]();
        \\    let m = hashmap.insert(move m, "k", 1);
        \\    array.len::[str](b)
        \\}
        \\fn main() -> int32 { work() }
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    var result: Value = 0;
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |t| {
            switch (t) {
                .normal => |v| result = v,
                .panic => |m| {
                    std.log.err("unexpected panic: {s}", .{m});
                    testing.allocator.free(m);
                    return error.TestUnexpectedResult;
                },
            }
            break;
        }
        try vm.drainDestroyWork();
    }
    vm.finishCleanup();
    try testing.expectEqual(@as(Value, 3), result);
    try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count());
    try testing.expectEqual(@as(usize, 0), vm.runtime.host_resources.count());
}

test "host: opaque array/map disposal runs exactly once on panic teardown" {
    // Panic mid-frame with live opaque objects: `finishCleanup` disposes
    // every registered resource exactly once.
    var l = try load(
        \\const array = import("array");
        \\const hashmap = import("hashmap");
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    let a = array.make(2, 5);
        \\    let m = hashmap.empty::[int32, int32]();
        \\    let m = hashmap.insert(move m, 1, 2);
        \\    builtin.panic("boom");
        \\}
    , false);
    defer l.deinit();
    var vm = interpreter.VmCtx.init(testing.allocator);
    defer vm.deinit();
    try vm.setupRootArtifact(l.image, try l.fid("main"));
    var panicked = false;
    while (!vm.runtime.terminated) {
        if (try vm_dispatch.step(&vm)) |t| {
            switch (t) {
                .normal => {},
                .panic => |m| {
                    panicked = true;
                    testing.allocator.free(m);
                },
            }
            break;
        }
        try vm.drainDestroyWork();
    }
    vm.finishCleanup();
    try testing.expect(panicked);
    try testing.expectEqual(@as(usize, 0), vm.runtime.heap.registry.count());
    try testing.expectEqual(@as(usize, 0), vm.runtime.host_resources.count());
}
