//! Pass: LLIR binary — flat serialization of a frozen `llir.LlirProgram`
//! image (TODO 6.1) plus the minimal reader that reconstructs an
//! in-memory image from the bytes (TODO 6.2). In: the read-only
//! `LlirProgram` (or its bytes). Out: a deterministic little-endian byte
//! stream, or the field-equal in-memory image.
//!
//! The binary is the image **directly** serialized — no assembly text
//! round-trip (TODO 6, "明确不采用": binary 由 image 直接序列化). It is a
//! versioned logical format, not a stable persistence ABI (spec §8); the
//! layout is documented here and is mirrored by `read`.
//!
//! Format (all little-endian, fixed-width, no padding, no pointers):
//! ```text
//! u32 magic   = 0x52494c4c ("LLIR" as little-endian bytes)
//! u32 version = 17
//! module symbol {start, len}: u32, u32  (self_symbol's byte range)
//! entry member {start, len}: u32, u32   (entry_member's byte range)
//! {tables.len} × u32 count, one per table, in the LlirProgram field order below
//! the tables, in the same order: each table is count_i × row bytes
//!   instructions:    Instr         (4 canonical bytes, v10 encoding)
//!   functions:       FunctionDesc  (code_start, code_end, entry_pc,
//!                    signature_id: u32, f_count: u16, x_count: u32,
//!                    window_count: u16 — 28 bytes/row)
//!   blocks:          BlockDesc     (2 × u32)
//!   constants:       ConstRecord   (kind u32, a, b: u32)
//!   types:           TypeDesc      (4 × u32)
//!   type_decls:      TypeDeclDesc  (5 × u32)
//!   type_decl_fields: TypeId       (u32)
//!   union_variants:  UnionVariant  (2 × u32)
//!   union_payloads:  TypeId        (u32)
//!   host_types:      HostTypeDesc  (3 × u32)
//!   modules:         ModuleDesc    (7 × u32)
//!   module_members:  ModuleMember  (kind u32, type_, ref: u32)
//!   module_slots:    ModuleSlot    (2 × u32)
//!   signatures:      SignatureDesc (3 × u32)
//!   params:          ParamDesc     (mode u32, type_: u32)
//!   host_bindings:   HostBinding   (module_id, member_start, member_len: u32)
//!   call_args:       ValueReg      (u8)
//!   syscall_descs:   SyscallDesc   (4 × u32)
//!   construct_descs: ConstructDesc (4 × u32)
//!   destructure_dsts: ValueReg     (u8)
//!   destructure_dst_types: TypeId  (u32)
//!   destructure_descs: DestructureDesc (4 × u32)
//!   switch_arms:     SwitchArm     (2 × u32)
//!   switch_descs:    SwitchDesc    (2 × u32)
//!   member_descs:    MemberDesc    (3 × u32)
//!   drop_descs:      DropDesc      (2 × u32)
//!   strings:         u8 × count
//! ```
//! The `call_descs` table is removed (neither call form references
//! a descriptor). Enum fields (ConstKind, TypeKind, TypeDeclKind,
//! DestructureKind, ParamMode, ModuleMemberKind) serialize as their
//! `u32` value; `Instr` records are copied as their four canonical bytes
//! and `ValueReg` stays raw `u8` — little-endian word assembly happens
//! only inside `encode`/`decode` (Instruction Set §2). No address or
//! pointer ever enters the stream — the image carries none (spec §2),
//! and the reader
//! allocates the reconstructed slices with the caller's allocator
//! (strings are copied, so the returned image never aliases the input
//! bytes). The counts/widths are comptime-checked against `LlirProgram`
//! and every record field must be a fixed-width integer, enum, or the
//! 4-byte `Instr` array (the spec §2 "no pointer/slice escape"
//! guarantee, enforced at compile
//! time). `read` bounds-checks the header and every table against the
//! input length before touching it.
//!
//! The image and its bytes are read-only: nothing is modified.

const std = @import("std");
const llir = @import("stilla").llir;

/// The little-endian `u32` spelling of the ASCII bytes `LLIR`.
pub const magic: u32 = 0x52494c4c;
/// The format version. Bump on any layout change; `read` rejects other
/// versions (the format is not a stable persistence ABI, spec §8).
/// Version 9: the v9 contiguous renumber (Instruction Set §4–§9).
/// Version 10: the overlapping output window (Instruction Set §4–§6,
/// §8) — `result_take` is deleted and the generic `take` closes the
/// E-type run: the opcode assignment is 212 logical opcodes (R 71 /
/// B 20 / C 42 / E 44 / I 31 / U 4), the I-type keeps its former
/// `result_take` selector 10 reserved so the `slot_*` encodings never
/// move, and `take dst, F(L+3+O-A)` replaces the post-call
/// `result_take dst, W-A`. The instruction encoding itself stays v10
/// from here on.
/// Version 11: `ModuleDesc` gains the module specifier
/// (`spec_start`/`spec_len` into the `strings` blob — the identity a
/// host dispatches `HostBinding`s by), two further `u32`s per module
/// row; no other row changes. Readers built for a different version
/// reject this image on its version alone, before a single table count
/// is decoded (spec §8.3).
/// Version 12: the header gains the entry `FunctionId` (one `u32`
/// between `version` and the counts), so a binary is self-contained —
/// `stilla --run <file>` needs no side information (interpreter-vm.md
/// §13 M5, D3). `write` without an entry records 0.
/// Version 13: the operand-register re-encoding (Instruction Set §3) —
/// the zero/cond/T fast bank at `0x00–0x11` (indexed directly) and the
/// frame registers at `0x13–0x7f`. Every instruction word and every
/// register-carrying side-table row changes, so all earlier images are
/// rejected on the version alone.
/// Version 14: `ra` moves to `0x02` — the specials are now the lowest
/// three encodings (`zero` 0x00, `cond` 0x01, `ra` 0x02, the latter a
/// reserved call-convention hole inside the fast bank), the T bank
/// shifts to `0x03–0x12`, and the fast bank becomes everything below
/// `frame_base` (`0x13`). All earlier images rejected on the version
/// alone.
/// Version 15: each artifact is module-local — the whole-program
/// `modules`/`module_members`/`host_bindings` tables are replaced by
/// the module header (`self_symbol`, `init`, `entry_member`), the
/// `SymbolId` table, and the sorted `imports`/`exports` tables; the
/// header's entry `FunctionId` becomes the symbolic entry member;
/// `FunctionDesc` drops `module_id`; `TypeDeclDesc` gains the
/// imported-hook field; `HostTypeDesc.host_module` becomes a symbol
/// string.
/// Version 16: the call header grows to three cells (`saved_fn`) so
/// `window_count` semantics become `3 + A`.
/// Version 17: the C-type block grows the 64-bit integer cast matrix —
/// the 22 `cvt.*` opcodes for `i64`/`u64` sources and targets (C
/// selectors 42–63, previously reserved) — so every C-type selector is
/// assigned and the logical opcode set is 234 (227 defined). No table or
/// header row changes; only the instruction encoding space grows.
pub const version: u32 = 17;

/// The scalar header fields serialized inside the table block (count 1
/// + one value word each) — listed by name because `TypeId == u32`.
const header_scalars = [_][]const u8{ "self_symbol", "init", "entry_member" };

fn isHeaderScalar(comptime name: []const u8) bool {
    inline for (header_scalars) |h| {
        if (std.mem.eql(u8, name, h)) return true;
    }
    return false;
}

/// The tables in serialization order: `{ LlirProgram field, row type }`.
/// Kept in lockstep with the struct by the comptime check below, so the
/// counts block and the table bodies can never drift apart.
const tables = .{
    .{ "instructions", llir.Instr },
    .{ "functions", llir.FunctionDesc },
    .{ "blocks", llir.BlockDesc },
    .{ "self_symbol", u32 },
    .{ "init", u32 },
    .{ "entry_member", u32 },
    .{ "symbols", llir.SymRange },
    .{ "imports", llir.ImportDesc },
    .{ "exports", llir.ExportDesc },
    .{ "module_slots", llir.ModuleSlot },
    .{ "constants", llir.ConstRecord },
    .{ "types", llir.TypeDesc },
    .{ "type_decls", llir.TypeDeclDesc },
    .{ "type_decl_fields", llir.TypeId },
    .{ "union_variants", llir.UnionVariant },
    .{ "union_payloads", llir.TypeId },
    .{ "host_types", llir.HostTypeDesc },
    .{ "signatures", llir.SignatureDesc },
    .{ "params", llir.ParamDesc },
    .{ "call_args", llir.ValueReg },
    .{ "syscall_descs", llir.SyscallDesc },
    .{ "construct_descs", llir.ConstructDesc },
    .{ "destructure_dsts", llir.ValueReg },
    .{ "destructure_dst_types", llir.TypeId },
    .{ "destructure_descs", llir.DestructureDesc },
    .{ "switch_arms", llir.SwitchArm },
    .{ "switch_descs", llir.SwitchDesc },
    .{ "member_descs", llir.MemberDesc },
    .{ "drop_descs", llir.DropDesc },
    .{ "strings", u8 },
};

/// The header: magic + version + the module symbol's `{start,len}` +
/// the symbolic entry member's `{start,len}` (four `u32`s replacing the
/// former entry `FunctionId`) + one count per table. Public so tests can
/// locate a table's byte offset inside a serialized stream.
pub const header_size = (6 + tables.len + header_scalars.len) * @sizeOf(u32);

comptime {
    // The table list must name exactly the LlirProgram fields, in order.
    const fields = std.meta.fields(llir.LlirProgram);
    if (fields.len != tables.len) {
        @compileError("llir_emit_bin: table list out of sync with LlirProgram");
    }
    for (fields, tables) |f, t| {
        if (!std.mem.eql(u8, f.name, t[0])) {
            @compileError("llir_emit_bin: table list out of sync at " ++ f.name);
        }
    }
    // Every record field must be a fixed-width integer, enum, or the
    // 4-byte `Instr` array — no pointer, slice, or string escapes into
    // the stream (spec §2).
    for (tables) |t| {
        if (t[1] == u8) continue;
        switch (@typeInfo(t[1])) {
            .int, .@"enum" => {}, // scalar fixed-width row
            .array => { // llir.Instr = [4]u8
                if (@typeInfo(@typeInfo(t[1]).array.child) != .int or @typeInfo(t[1]).array.len != 4) {
                    @compileError("llir_emit_bin: expected the 4-byte Instr array");
                }
            },
            .@"struct" => {
                for (std.meta.fields(t[1])) |f| {
                    switch (@typeInfo(f.type)) {
                        .int, .@"enum" => {},
                        else => @compileError("llir_emit_bin: non-fixed-width field " ++ f.name ++ " in " ++ @typeName(t[1])),
                    }
                }
            },
            else => @compileError("llir_emit_bin: unsupported row type " ++ @typeName(t[1])),
        }
    }
}

/// The serialized size of an image: the header plus every table's rows.
/// `write` emits exactly this many bytes (`bytes.len == size(image)`,
/// TODO 6.1 acceptance).
pub fn size(image: llir.LlirProgram) usize {
    var total = header_size;
    inline for (tables) |t| {
        if (comptime !isHeaderScalar(t[0])) {
            total += @field(image, t[0]).len * @sizeOf(t[1]);
        }
    }
    return total;
}

/// Serialize an image to a flat little-endian byte stream. Deterministic:
/// the same image always produces the same bytes. The image is never
/// modified.
pub fn write(image: llir.LlirProgram, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendInt(&out, allocator, u32, magic);
    try appendInt(&out, allocator, u32, version);
    // The header's symbolic identity words: the module symbol's and the
    // entry member's `{start,len}` byte ranges (zeros when absent).
    const sym_zero = llir.SymRange{ .start = 0, .len = 0 };
    const mod_range = if (image.self_symbol < image.symbols.len) image.symbols[image.self_symbol] else sym_zero;
    const entry_range = if (image.entry_member < image.symbols.len) image.symbols[image.entry_member] else sym_zero;
    try appendInt(&out, allocator, u32, mod_range.start);
    try appendInt(&out, allocator, u32, mod_range.len);
    try appendInt(&out, allocator, u32, entry_range.start);
    try appendInt(&out, allocator, u32, entry_range.len);
    inline for (tables) |t| {
        // A scalar header field writes count 1; a table writes its row
        // count. The reader mirrors this distinction.
        const count: u32 = if (comptime isHeaderScalar(t[0])) 1 else @intCast(@field(image, t[0]).len);
        try appendInt(&out, allocator, u32, count);
    }
    inline for (tables) |t| {
        const rows = @field(image, t[0]);
        if (comptime isHeaderScalar(t[0])) {
            try appendInt(&out, allocator, u32, rows);
        } else if (t[1] == u8) {
            try out.appendSlice(allocator, rows);
        } else {
            for (rows) |row| try writeRow(&out, allocator, row);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `write`, spelled for the symbolic header: the module symbol and the
/// entry member are `LlirProgram` fields (`self_symbol`/`entry_member`
/// symbol ids, serialized as their `{start,len}` byte ranges), so the
/// written binary is self-contained by construction.
pub fn writeWithEntry(image: llir.LlirProgram, entry: u32, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    _ = entry;
    return write(image, allocator);
}

/// The error set of `read`: allocation failure or a malformed stream
/// (bad magic/version, a count whose rows overrun the input, or a
/// truncated stream).
pub const Error = error{ OutOfMemory, InvalidFormat };

/// Reconstruct an in-memory image from a `write`-produced byte stream.
/// All returned slices are allocated with `allocator` (strings are
/// copied), so the image never aliases the input bytes; free with the
/// allocator or drop an arena. The stream is bounds-checked before any
/// table is parsed (TODO 6.2: the reader is the round-trip companion of
/// `write`; load-time `validateLLIR` is a VM concern, stage 7 A3).
pub fn read(allocator: std.mem.Allocator, bytes: []const u8) Error!llir.LlirProgram {
    var r = Reader{ .bytes = bytes };
    if (try r.int(u32) != magic) return error.InvalidFormat;
    if (try r.int(u32) != version) return error.InvalidFormat;
    // The header's symbolic module symbol and entry member `{start,len}`
    // pairs — validated against the strings blob at load time; the read
    // here only consumes the four words.
    _ = try r.int(u32);
    _ = try r.int(u32);
    _ = try r.int(u32);
    _ = try r.int(u32);
    var counts: [tables.len]u32 = undefined;
    inline for (&counts) |*c| c.* = try r.int(u32);
    var image: llir.LlirProgram = undefined;
    inline for (tables, 0..) |t, i| {
        if (comptime isHeaderScalar(t[0])) {
            if (counts[i] != 1) return error.InvalidFormat;
            @field(image, t[0]) = try r.int(u32);
        } else if (t[1] == u8) {
            const s = try r.take(counts[i]);
            @field(image, t[0]) = try allocator.dupe(u8, s);
        } else {
            @field(image, t[0]) = try readTable(allocator, &r, t[1], counts[i]);
        }
    }
    return image;
}

/// Free every table allocation of an image produced by `read` (each
/// table was `allocator.alloc`/`dupe`d into `allocator`). Scalar header
/// fields carry no storage. Only call on a `read`-produced image whose
/// tables the caller owns.
pub fn freeImage(allocator: std.mem.Allocator, image: *llir.LlirProgram) void {
    inline for (tables) |t| {
        if (comptime isHeaderScalar(t[0])) continue;
        if (t[1] == u8) {
            const f = &@field(image, t[0]);
            if (f.len > 0) allocator.free(@constCast(f.*));
        } else {
            const f = &@field(image, t[0]);
            if (f.len > 0) allocator.free(@constCast(f.*));
        }
    }
}

/// The symbolic entry member's `{start, len}` byte range recorded in a
/// produced stream, bounds- and version-checked. The caller resolves it
/// through the loaded artifact's `symbols`/`exports` tables.
pub fn readEntry(bytes: []const u8) Error![2]u32 {
    if (bytes.len < header_size) return error.InvalidFormat;
    var r = Reader{ .bytes = bytes };
    if (try r.int(u32) != magic) return error.InvalidFormat;
    if (try r.int(u32) != version) return error.InvalidFormat;
    _ = try r.int(u32); // module symbol start
    _ = try r.int(u32); // module symbol len
    const start = try r.int(u32);
    const len = try r.int(u32);
    return .{ start, len };
}

// ---------------------------------------------------------------------------
// Writer helpers
// ---------------------------------------------------------------------------

fn appendInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: anytype) error{OutOfMemory}!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, @intCast(value), .little);
    try out.appendSlice(allocator, &buf);
}

/// Write one row: a scalar integer/enum directly, a fixed-width record
/// field by field, or an `Instr` array copied byte-for-byte. Rejected at
/// comptime for any other type.
fn writeRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) error{OutOfMemory}!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => try appendInt(out, allocator, T, value),
        .@"enum" => try appendInt(out, allocator, u32, @intFromEnum(value)),
        .array => try out.appendSlice(allocator, &value),
        .@"struct" => try appendRecord(out, allocator, value),
        else => @compileError("llir_emit_bin: unsupported row type " ++ @typeName(T)),
    }
}

/// Write one fixed-width record, field by field: integers as-is, enums as
/// their `u32` value. Rejected at comptime for any other field type.
fn appendRecord(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) error{OutOfMemory}!void {
    const T = @TypeOf(value);
    inline for (std.meta.fields(T)) |f| {
        switch (@typeInfo(f.type)) {
            .int => try appendInt(out, allocator, f.type, @field(value, f.name)),
            .@"enum" => try appendInt(out, allocator, u32, @intFromEnum(@field(value, f.name))),
            else => @compileError("llir_emit_bin: non-fixed-width field " ++ f.name ++ " in " ++ @typeName(T)),
        }
    }
}

// ---------------------------------------------------------------------------
// Reader helpers
// ---------------------------------------------------------------------------

/// A bounds-checked cursor over the input bytes.
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    /// The next `n` bytes, or `InvalidFormat` when they overrun the input.
    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.bytes.len - r.pos) return error.InvalidFormat;
        const s = r.bytes[r.pos..][0..n];
        r.pos += n;
        return s;
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        const b = try r.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }
};

/// Parse one row, mirroring `writeRow`: a scalar integer/enum directly, a
/// fixed-width record field by field, or an `Instr` array read byte by
/// byte. Enum fields go through `readEnum` — a raw tag that names no
/// declared value is `InvalidFormat`, never an unchecked `@enumFromInt`.
fn readRow(r: *Reader, comptime T: type) Error!T {
    switch (@typeInfo(T)) {
        .int => return r.int(T),
        .@"enum" => return try readEnum(r, T),
        .array => {
            const b = try r.take(@sizeOf(T));
            var out: T = undefined;
            @memcpy(out[0..], b);
            return out;
        },
        .@"struct" => return readRecord(r, T),
        else => @compileError("llir_emit_bin: unsupported row type " ++ @typeName(T)),
    }
}

/// One enum field, tag-checked: the raw `u32` must name a declared tag
/// of `T` (the enum fields are untrusted image bytes, and an
/// out-of-range `@enumFromInt` on an exhaustive enum is undefined). The
/// scan is a small comptime-unrolled loop over the declared tags.
fn readEnum(r: *Reader, comptime T: type) Error!T {
    const raw = try r.int(u32);
    inline for (std.meta.tags(T)) |tag| {
        if (@intFromEnum(tag) == raw) return tag;
    }
    return error.InvalidFormat;
}

/// Parse one fixed-width record, mirroring `appendRecord`.
fn readRecord(r: *Reader, comptime T: type) Error!T {
    var out: T = undefined;
    inline for (std.meta.fields(T)) |f| {
        switch (@typeInfo(f.type)) {
            .int => @field(out, f.name) = try r.int(f.type),
            .@"enum" => @field(out, f.name) = try readEnum(r, f.type),
            else => @compileError("llir_emit_bin: non-fixed-width field " ++ f.name ++ " in " ++ @typeName(T)),
        }
    }
    return out;
}

/// Parse a whole table of `n` rows (n from the header count; the row
/// width is comptime-known, so `n` alone cannot overrun — the `take`
/// bounds check catches truncation row by row).
fn readTable(allocator: std.mem.Allocator, r: *Reader, comptime T: type, n: u32) Error![]T {
    const out = try allocator.alloc(T, n);
    for (out) |*row| row.* = try readRow(r, T);
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "emit/read round-trips a minimal empty image" {
    // Every table empty: the stream is exactly the header.
    const image = llir.LlirProgram{
        .self_symbol = 0,
        .init = llir.no_index,
        .entry_member = llir.no_index,
        .symbols = &.{},
        .imports = &.{},
        .exports = &.{},
        .instructions = &.{},
        .functions = &.{},
        .blocks = &.{},
        .constants = &.{},
        .types = &.{},
        .type_decls = &.{},
        .type_decl_fields = &.{},
        .union_variants = &.{},
        .union_payloads = &.{},
        .host_types = &.{},
        .module_slots = &.{},
        .signatures = &.{},
        .params = &.{},

        .call_args = &.{},
        .syscall_descs = &.{},
        .construct_descs = &.{},
        .destructure_dsts = &.{},
        .destructure_dst_types = &.{},
        .member_descs = &.{},
        .drop_descs = &.{},
        .destructure_descs = &.{},
        .switch_arms = &.{},
        .switch_descs = &.{},

        .strings = &.{},
    };
    try testing.expectEqual(header_size, size(image));

    const bytes = try write(image, testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(header_size, bytes.len);
    // magic + version + the four symbolic identity words + one count per
    // table (plus a count+value pair per header scalar), little-endian u32.
    try testing.expectEqual(magic, std.mem.readInt(u32, bytes[0..4], .little));
    try testing.expectEqual(version, std.mem.readInt(u32, bytes[4..8], .little));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try read(arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 0), back.instructions.len);
    try testing.expectEqual(@as(usize, 0), back.strings.len);
}

test "read rejects a bad magic, a bad version, and a truncated stream" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "XXXX");
    try testing.expectError(error.InvalidFormat, read(testing.allocator, bytes.items));

    bytes.clearRetainingCapacity();
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, magic, .little);
    try bytes.appendSlice(testing.allocator, &buf);
    // A foreign version — `read` rejects it before touching any table.
    std.mem.writeInt(u32, &buf, 5, .little);
    try bytes.appendSlice(testing.allocator, &buf);
    try testing.expectError(error.InvalidFormat, read(testing.allocator, bytes.items));

    bytes.clearRetainingCapacity();
    std.mem.writeInt(u32, &buf, magic, .little);
    try bytes.appendSlice(testing.allocator, &buf);
    std.mem.writeInt(u32, &buf, version, .little);
    try bytes.appendSlice(testing.allocator, &buf);
    // Header promises one instruction but the stream ends: truncated.
    std.mem.writeInt(u32, &buf, 1, .little);
    try bytes.appendSlice(testing.allocator, &buf);
    try testing.expectError(error.InvalidFormat, read(testing.allocator, bytes.items));
}

test "record fields are fixed-width (comptime)" {
    // The comptime block above already rejects a non-fixed-width field;
    // this test just exercises one representative record shape through
    // both directions to prove the runtime path agrees with the layout.
    const rec = llir.ConstRecord{ .kind = .string, .type_ = 4, .a = 3, .b = 7 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    try appendRecord(&out, testing.allocator, rec);
    try testing.expectEqual(@as(usize, @sizeOf(llir.ConstRecord)), out.items.len);
    var r = Reader{ .bytes = out.items };
    const back = try readRecord(&r, llir.ConstRecord);
    try testing.expectEqual(rec, back);
    try testing.expectEqual(out.items.len, r.pos);
}
