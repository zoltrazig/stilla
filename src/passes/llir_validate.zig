//! Pass: LLIR structural validation (Stilla LLIR Specification §8) — the
//! v9 loader boundary. `validate(image)` checks shapes, ranges, tags,
//! and bounds only: the reserved class/code/reserved-field rejections,
//! register and special-register schemas, immediate bounds, dense
//! in-range IDs and descriptor ranges, function/block/entry PC ranges,
//! block terminator shapes, static branch/call targets, the call-shape
//! constraints (take adjacency and source register, `cond` consumption
//! across calls and block boundaries), and the frame layout bounds.
//!
//! v9 performs **no typed dataflow analysis and derives no execution
//! plan**: the opcodes carry their reps and the descriptor-carried types
//! carry the rest. `validate(image)` checks the image in place and
//! returns; the caller then hands the same image to the interpreter —
//! no validated-handle type wraps the program, and nothing is allocated
//! on the instruction path (a valid image of any size validates with 0
//! allocations — measured with counting/failing allocators). The
//! analyzer, the per-PC plan, and `loadValidated` are deleted; semantic
//! properties (SSA dominance, ownership, lifecycle ordering,
//! call-argument discipline, and the `zero` Copy/void rules — `ret
//! zero` of any type, `take zero`, syscall `a = zero`, `zero`
//! arguments, `slot_move`/ownership sequences) are proven by the
//! frontend and not re-analyzed (§8.1 — semantically trusted,
//! structurally validated; not a security boundary for external LLIR).
//! The checks below map one-to-one onto the §8.1 untrusted-input list:
//! `checkFrames` (frame/X/window layout bounds), `checkFunctionIds`
//! (per-function signature/module IDs), `checkFunctionRanges` /
//! `checkBlockRanges` / `checkEntryPcs` (PC tiling and entry shapes),
//! the side-table checks (`checkConstantsAndTypes`, `checkTypeDecls`,
//! `checkModulesAndBindings`, `checkCallDescriptors` — IDs, slices,
//! kinds, descriptor bounds), `checkInstructions` (decode, register/
//! special schemas, unused fields, in-range IDs, static branch/call
//! targets, the take contract), `checkBlockEnds` (terminator
//! shapes), and `checkCondLifetime` (`cond` consumption across calls
//! and block boundaries).

const std = @import("std");
const llir = @import("stilla").llir;

/// Validate a whole LLIR image. Returns null when valid, otherwise the
/// first violation as a message allocated from `allocator`. The caller
/// runs the same validated image directly — there is no derived
/// artifact.
pub fn validate(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    if (try checkFrames(image, allocator)) |m| return m;
    if (try checkFunctionIds(image, allocator)) |m| return m;
    if (try checkFunctionRanges(image, allocator)) |m| return m;
    if (try checkBlockRanges(image, allocator)) |m| return m;
    if (try checkEntryPcs(image, allocator)) |m| return m;
    if (try checkConstantsAndTypes(image, allocator)) |m| return m;
    if (try checkTypeDecls(image, allocator)) |m| return m;
    if (try checkSymbolicLinkage(image, allocator)) |m| return m;
    if (try checkCallDescriptors(image, allocator)) |m| return m;
    if (try checkInstructions(image, allocator)) |m| return m;
    if (try checkBlockEnds(image, allocator)) |m| return m;
    if (try checkCondLifetime(image, allocator)) |m| return m;
    return null;
}

fn fail(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !?[]const u8 {
    return @as(?[]const u8, try std.fmt.allocPrint(allocator, fmt, args));
}

/// The enum tag carrying raw integer `v`, or null when the image names
/// an unassigned value.
fn toEnum(comptime T: type, v: u32) ?T {
    inline for (std.meta.tags(T)) |tag| {
        if (@intFromEnum(tag) == v) return tag;
    }
    return null;
}

/// A flat table's row count as `u32` — every `checkRange` table bound is
/// a `u32` (the ID spaces are `u32`; spec §2).
fn tableLen(rows: anytype) u32 {
    return @intCast(rows.len);
}

fn issueText(i: llir.Issue) []const u8 {
    return switch (i) {
        .unknown_opcode => "reserved or unknown instruction word",
        .bad_register => "register operand is neither a slot nor a special register",
        .special_forbidden => "special register in a field whose schema forbids it",
        .imm_out_of_range => "immediate out of range",
        .nonzero_field => "nonzero unused field",
        .frame_too_big => "frame too big",
    };
}

// ---------------------------------------------------------------------------
// 1. Frames — layout numbers, overflow (Instruction Set §14)
// ---------------------------------------------------------------------------

/// v1 layout numbers (spec §4.1): f_count <= 109, x_count <= 65536
/// (imm16 addressing), window overflow checks.
fn checkFrames(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    for (image.functions, 0..) |f, fi| {
        if (llir.checkFrameSlots(f.f_count, f.window_count) != null) {
            return fail(allocator, "function {d}: frame too big (f_count {d} + window_count {d} exceeds the 109-register budget)", .{ fi, f.f_count, f.window_count });
        }
        if (f.x_count > 65536) {
            return fail(allocator, "function {d}: x_count {d} exceeds the imm16 addressable maximum 65536", .{ fi, f.x_count });
        }
        _ = std.math.add(u64, @as(u64, f.f_count) + f.x_count, f.window_count) catch
            return fail(allocator, "function {d}: frame layout numbers overflow", .{fi});
    }
    return null;
}

/// Per-function side-table IDs (Instruction Set §14): `signature_id`
/// must name a real row. `signature_id` is indexed by the instruction
/// walk (`ret` result handling, the static-call take contract), so the
/// bound is established before any such read.
fn checkFunctionIds(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    for (image.functions, 0..) |f, fi| {
        if (f.signature_id >= image.signatures.len) {
            return fail(allocator, "function {d}: signature_id {d} out of range ({d} signatures)", .{ fi, f.signature_id, image.signatures.len });
        }
        // The interpreter packs the signature into a `u7` arity byte at
        // load (FnEntry.arity), and the value area is bounded by the
        // frame budget anyway; reject oversized params up front so a
        // ReleaseFast load cannot silently truncate.
        const p = image.signatures[f.signature_id].params_len;
        if (p > f.f_count) {
            return fail(allocator, "function {d}: params_len {d} exceeds f_count {d}", .{ fi, p, f.f_count });
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// 2. Function/block/entry code ranges — tiling the instruction space
// ---------------------------------------------------------------------------

fn checkFunctionRanges(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    var expect: u32 = 0;
    for (image.functions, 0..) |f, fi| {
        if (f.code_start != expect) {
            return fail(allocator, "function {d}: code range [{d}, {d}) does not tile the instruction space (gap or overlap at {d})", .{ fi, f.code_start, f.code_end, expect });
        }
        if (f.code_end <= f.code_start) {
            return fail(allocator, "function {d}: empty code range [{d}, {d})", .{ fi, f.code_start, f.code_end });
        }
        expect = f.code_end;
    }
    if (expect != image.instructions.len) {
        return fail(allocator, "function code ranges do not cover the instruction space ({d} of {d} instructions)", .{ expect, image.instructions.len });
    }
    return null;
}

fn checkBlockRanges(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    var bi: usize = 0;
    for (image.functions, 0..) |f, fi| {
        var pc = f.code_start;
        while (pc < f.code_end) {
            if (bi >= image.blocks.len) {
                return fail(allocator, "function {d}: code range extends past the block table at pc {d}", .{ fi, pc });
            }
            const blk = image.blocks[bi];
            if (blk.start_pc != pc) {
                return fail(allocator, "block {d}: start_pc {d} does not tile the code range (expected {d})", .{ bi, blk.start_pc, pc });
            }
            if (blk.end_pc <= blk.start_pc) {
                return fail(allocator, "block {d}: empty block [{d}, {d})", .{ bi, blk.start_pc, blk.end_pc });
            }
            pc = blk.end_pc;
            bi += 1;
        }
    }
    if (bi != image.blocks.len) {
        return fail(allocator, "{d} block rows extend past the function code ranges", .{image.blocks.len - bi});
    }
    return null;
}

fn checkEntryPcs(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    for (image.functions, 0..) |f, fi| {
        if (f.entry_pc < f.code_start or f.entry_pc >= f.code_end) {
            return fail(allocator, "function {d}: entry_pc {d} outside the code range [{d}, {d})", .{ fi, f.entry_pc, f.code_start, f.code_end });
        }
        if (!isBlockStart(image.blocks, f.entry_pc)) {
            return fail(allocator, "function {d}: entry_pc {d} is not a block start", .{ fi, f.entry_pc });
        }
    }
    return null;
}

/// True when `pc` is the start of some block. The `BlockDesc` rows are
/// globally sorted (they tile the space function by function), so a
/// binary search suffices.
fn isBlockStart(blocks: []const llir.BlockDesc, pc: u32) bool {
    var lo: usize = 0;
    var hi: usize = blocks.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (blocks[mid].start_pc < pc) lo = mid + 1 else hi = mid;
    }
    return lo < blocks.len and blocks[lo].start_pc == pc;
}

/// True when `pc` is some function's `entry_pc` — the only legal static
/// `jal ra` target (Instruction Set §14).
fn isFunctionEntry(functions: []const llir.FunctionDesc, pc: u32) bool {
    for (functions) |f| {
        if (f.entry_pc == pc) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 3. Side tables — dense IDs, kinds, and ranges (§8.1: side-table IDs,
//    slice (start, len) pairs, descriptor kinds, frame/X/window bounds).
//    Split by table family so each trust-boundary item has one named
//    check.
// ---------------------------------------------------------------------------

fn checkConstantsAndTypes(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    // Constants (Instruction Set §13): kind valid; a string range indexes
    // the program-owned blob.
    for (image.constants, 0..) |c, i| {
        _ = toEnum(llir.ConstKind, @intFromEnum(c.kind)) orelse
            return fail(allocator, "constant {d}: invalid kind {d}", .{ i, @intFromEnum(c.kind) });
        if (c.kind == .string) {
            if (llir.checkRange(c.a, c.b, tableLen(image.strings))) |e| {
                return fail(allocator, "constant {d}: string range out of bounds ({s})", .{ i, rangeText(e) });
            }
        }
    }
    // Types: every internal reference is a dense ID or range.
    for (image.types, 0..) |t, i| {
        _ = toEnum(llir.TypeKind, @intFromEnum(t.kind)) orelse
            return fail(allocator, "type {d}: invalid kind {d}", .{ i, @intFromEnum(t.kind) });
        switch (t.kind) {
            .primitive => _ = toEnum(llir.PrimitiveId, t.a) orelse
                return fail(allocator, "type {d}: invalid primitive id {d}", .{ i, t.a }),
            .named => {
                if (t.a >= image.type_decls.len) {
                    return fail(allocator, "type {d}: declaration id {d} out of range ({d} decls)", .{ i, t.a, image.type_decls.len });
                }
                if (llir.checkRange(t.b, t.c, tableLen(image.types))) |e| {
                    return fail(allocator, "type {d}: type-argument range out of bounds ({s})", .{ i, rangeText(e) });
                }
            },
            .list, .box => if (t.a >= image.types.len) {
                return fail(allocator, "type {d}: element type {d} out of range", .{ i, t.a });
            },
            .tuple => if (llir.checkRange(t.a, t.b, tableLen(image.types))) |e| {
                return fail(allocator, "type {d}: element range out of bounds ({s})", .{ i, rangeText(e) });
            },
            .function => if (t.a >= image.signatures.len) {
                return fail(allocator, "type {d}: signature id {d} out of range", .{ i, t.a });
            },
            .module, .cleanup => {}, // fields unused
        }
    }
    return null;
}

fn checkTypeDecls(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    // Type declarations: layout, ownership, drop hook, field/variant ranges.
    for (image.type_decls, 0..) |d, i| {
        _ = toEnum(llir.TypeDeclKind, @intFromEnum(d.kind)) orelse
            return fail(allocator, "type decl {d}: invalid kind {d}", .{ i, @intFromEnum(d.kind) });
        switch (d.kind) {
            .struct_ => {
                if (d.a != llir.no_index and d.a > 1) {
                    return fail(allocator, "type decl {d}: invalid ownership id {d}", .{ i, d.a });
                }
                if (d.b != llir.no_index and d.b >= image.functions.len) {
                    return fail(allocator, "type decl {d}: drop hook FunctionId {d} out of range", .{ i, d.b });
                }
                if (d.e != llir.no_index and d.e >= image.imports.len) {
                    return fail(allocator, "type decl {d}: imported drop hook {d} out of range", .{ i, d.e });
                }
                if (d.b != llir.no_index and d.e != llir.no_index) {
                    return fail(allocator, "type decl {d}: drop hook is both local and imported", .{i});
                }
                if (llir.checkRange(d.c, d.d, tableLen(image.type_decl_fields))) |e| {
                    return fail(allocator, "type decl {d}: field range out of bounds ({s})", .{ i, rangeText(e) });
                }
                for (d.c..d.c + d.d) |k| {
                    const ft = image.type_decl_fields[k];
                    if (ft != llir.no_index and ft >= image.types.len) {
                        return fail(allocator, "type decl {d}: field type {d} out of range", .{ i, ft });
                    }
                }
            },
            .union_ => {
                if (d.a != llir.no_index and d.a > 1) {
                    return fail(allocator, "type decl {d}: invalid ownership id {d}", .{ i, d.a });
                }
                if (llir.checkRange(d.b, d.c, tableLen(image.union_variants))) |e| {
                    return fail(allocator, "type decl {d}: variant range out of bounds ({s})", .{ i, rangeText(e) });
                }
                for (d.b..d.b + d.c) |k| {
                    const v = image.union_variants[k];
                    if (llir.checkRange(v.payloads_start, v.payloads_len, tableLen(image.union_payloads))) |e| {
                        return fail(allocator, "type decl {d}: variant {d} payload range out of bounds ({s})", .{ i, k, rangeText(e) });
                    }
                    for (v.payloads_start..v.payloads_start + v.payloads_len) |j| {
                        const pt = image.union_payloads[j];
                        if (pt != llir.no_index and pt >= image.types.len) {
                            return fail(allocator, "type decl {d}: variant {d} payload type {d} out of range", .{ i, k, pt });
                        }
                    }
                }
            },
            .opaque_ => if (d.a != llir.no_index and d.a >= image.host_types.len) {
                return fail(allocator, "type decl {d}: host type id {d} out of range", .{ i, d.a });
            },
        }
    }
    // Host types: the declaring host module's symbol string and the type
    // name both range into the strings blob.
    for (image.host_types, 0..) |h, i| {
        if (llir.checkRange(h.host_start, h.host_len, tableLen(image.strings))) |e| {
            return fail(allocator, "host type {d}: module symbol range out of bounds ({s})", .{ i, rangeText(e) });
        }
        if (llir.checkRange(h.name_start, h.name_len, tableLen(image.strings))) |e| {
            return fail(allocator, "host type {d}: name range out of bounds ({s})", .{ i, rangeText(e) });
        }
    }
    return null;
}

fn checkSymbolicLinkage(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    // The artifact header: real symbol ids and function references.
    // self_symbol = no_index marks an anonymous module (a hand-built
    // single-function image); otherwise it must name a real symbol.
    if (image.self_symbol != llir.no_index and image.self_symbol >= image.symbols.len) {
        return fail(allocator, "self symbol {d} out of range ({d} symbols)", .{ image.self_symbol, image.symbols.len });
    }
    if (image.init != llir.no_index and image.init >= image.functions.len) {
        return fail(allocator, "init FunctionId {d} out of range", .{image.init});
    }
    if (image.entry_member != llir.no_index and image.entry_member >= image.symbols.len) {
        return fail(allocator, "entry member symbol {d} out of range", .{image.entry_member});
    }
    // The symbol table: byte ranges into the strings blob.
    for (image.symbols, 0..) |sym, i| {
        if (llir.checkRange(sym.start, sym.len, tableLen(image.strings))) |e| {
            return fail(allocator, "symbol {d}: byte range out of bounds ({s})", .{ i, rangeText(e) });
        }
    }
    // Imports: `(module_symbol, member_symbol)` pairs; a module-only
    // import carries member_sym = no_index.
    for (image.imports, 0..) |imp, i| {
        if (imp.module_sym >= image.symbols.len) {
            return fail(allocator, "import {d}: module symbol {d} out of range", .{ i, imp.module_sym });
        }
        if (imp.member_sym != llir.no_index and imp.member_sym >= image.symbols.len) {
            return fail(allocator, "import {d}: member symbol {d} out of range", .{ i, imp.member_sym });
        }
    }
    // Exports: sorted by symbol bytes, duplicate symbols rejected, refs
    // in range per kind, `public` a 0/1 flag.
    var prev: ?[]const u8 = null;
    for (image.exports, 0..) |row, i| {
        if (row.member_sym >= image.symbols.len) {
            return fail(allocator, "export {d}: symbol {d} out of range", .{ i, row.member_sym });
        }
        if (row.public > 1) {
            return fail(allocator, "export {d}: public flag must be 0 or 1", .{i});
        }
        _ = toEnum(llir.ExportKind, @intFromEnum(row.kind)) orelse
            return fail(allocator, "export {d}: invalid kind {d}", .{ i, @intFromEnum(row.kind) });
        switch (row.kind) {
            .const_slot => if (row.ref != llir.no_index and row.ref >= image.module_slots.len) {
                return fail(allocator, "export {d}: slot ref {d} out of range ({d} slots)", .{ i, row.ref, image.module_slots.len });
            },
            .function => if (row.ref >= image.functions.len) {
                return fail(allocator, "export {d}: FunctionId {d} out of range", .{ i, row.ref });
            },
            .nested_module => if (row.ref >= image.symbols.len) {
                return fail(allocator, "export {d}: module symbol {d} out of range", .{ i, row.ref });
            },
            .host_binding => {}, // never a first-class value; ref unused
        }
        const name = symbolBytes(image, row.member_sym);
        if (prev) |p| {
            if (std.mem.lessThan(u8, name, p)) {
                return fail(allocator, "export {d}: symbol table is not sorted", .{i});
            }
            if (std.mem.eql(u8, name, p)) {
                return fail(allocator, "export {d}: duplicate symbol '{s}'", .{ i, name });
            }
        }
        prev = name;
    }
    // Constant slots: teardown types.
    for (image.module_slots, 0..) |slot, i| {
        if (slot.type_ != llir.no_index and slot.type_ >= image.types.len) {
            return fail(allocator, "module slot {d}: type {d} out of range", .{ i, slot.type_ });
        }
    }
    return null;
}

/// The bytes of symbol `id` (the caller has range-checked it).
fn symbolBytes(image: *const llir.LlirProgram, id: u32) []const u8 {
    const r = image.symbols[id];
    return image.strings[r.start..][0..r.len];
}

fn checkCallDescriptors(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    // Signatures and their parameter rows.
    for (image.signatures, 0..) |s, i| {
        if (llir.checkRange(s.params_start, s.params_len, tableLen(image.params))) |e| {
            return fail(allocator, "signature {d}: parameter range out of bounds ({s})", .{ i, rangeText(e) });
        }
        if (s.ret != llir.no_index and s.ret >= image.types.len) {
            return fail(allocator, "signature {d}: return type {d} out of range", .{ i, s.ret });
        }
    }
    for (image.params, 0..) |p, i| {
        _ = toEnum(llir.ParamMode, @intFromEnum(p.mode)) orelse
            return fail(allocator, "param {d}: invalid mode {d}", .{ i, @intFromEnum(p.mode) });
        if (p.type_ >= image.types.len) {
            return fail(allocator, "param {d}: type {d} out of range", .{ i, p.type_ });
        }
    }
    // `call_descs` is removed; syscall descriptors: binding,
    // signature, and argument range.
    for (image.syscall_descs, 0..) |d, i| {
        if (d.host_binding_id != llir.no_index and d.host_binding_id >= image.imports.len) {
            return fail(allocator, "syscall desc {d}: import {d} out of range", .{ i, d.host_binding_id });
        }
        if (d.signature_id >= image.signatures.len) {
            return fail(allocator, "syscall desc {d}: signature id {d} out of range", .{ i, d.signature_id });
        }
        if (llir.checkRange(d.args_start, d.args_len, tableLen(image.call_args))) |e| {
            return fail(allocator, "syscall desc {d}: argument range out of bounds ({s})", .{ i, rangeText(e) });
        }
        // The parameter/argument arity match (`args_len ==
        // signature.params_len`) is a frontend guarantee, not re-proven
        // here (§8.1).
    }
    // Construct/destructure/switch descriptor ranges.
    for (image.construct_descs, 0..) |d, i| {
        if (llir.checkRange(d.args_start, d.args_len, tableLen(image.call_args))) |e| {
            return fail(allocator, "construct desc {d}: component range out of bounds ({s})", .{ i, rangeText(e) });
        }
    }
    for (image.destructure_descs, 0..) |d, i| {
        _ = toEnum(llir.DestructureKind, @intFromEnum(d.kind)) orelse
            return fail(allocator, "destructure desc {d}: invalid kind {d}", .{ i, @intFromEnum(d.kind) });
        if (llir.checkRange(d.dsts_start, d.dsts_len, tableLen(image.destructure_dsts))) |e| {
            return fail(allocator, "destructure desc {d}: result range out of bounds ({s})", .{ i, rangeText(e) });
        }
    }
    for (image.switch_descs, 0..) |d, i| {
        if (llir.checkRange(d.arms_start, d.arms_len, tableLen(image.switch_arms))) |e| {
            return fail(allocator, "switch desc {d}: arm range out of bounds ({s})", .{ i, rangeText(e) });
        }
        // Arm tags must be unique (Instruction Set §6); the implicit
        // trap default is never an arm.
        for (d.arms_start..d.arms_start + d.arms_len) |k| {
            for (k + 1..d.arms_start + d.arms_len) |j| {
                if (image.switch_arms[k].tag == image.switch_arms[j].tag) {
                    return fail(allocator, "switch desc {d}: duplicate arm tag {d}", .{ i, image.switch_arms[k].tag });
                }
            }
        }
    }
    // Destructure result types, member descriptors, and drop descriptors
    // carry the TypeIds the VM needs — no slot types exist.
    for (image.destructure_dst_types, 0..) |t, i| {
        if (t >= image.types.len) {
            return fail(allocator, "destructure_dst_types row {d}: type {d} out of range", .{ i, t });
        }
    }
    for (image.construct_descs, 0..) |d, i| {
        if (d.result_type >= image.types.len) {
            return fail(allocator, "construct desc {d}: result type {d} out of range", .{ i, d.result_type });
        }
    }
    for (image.destructure_descs, 0..) |d, i| {
        if (d.base_type >= image.types.len) {
            return fail(allocator, "destructure desc {d}: base type {d} out of range", .{ i, d.base_type });
        }
        // dsts_len must match the parallel type rows.
        const t_end = d.dsts_start + d.dsts_len;
        if (t_end > image.destructure_dst_types.len) {
            return fail(allocator, "destructure desc {d}: result type rows out of bounds", .{i});
        }
    }
    for (image.member_descs, 0..) |d, i| {
        if (d.base_type != llir.no_index and d.base_type >= image.types.len) {
            return fail(allocator, "member desc {d}: base type {d} out of range", .{ i, d.base_type });
        }
        if (d.type_ != llir.no_index and d.type_ >= image.types.len) {
            return fail(allocator, "member desc {d}: result type {d} out of range", .{ i, d.type_ });
        }
    }
    for (image.drop_descs, 0..) |d, i| {
        const typed = d.type_ != llir.no_index;
        const host = d.host_type_ != llir.no_index;
        if (typed == host) {
            return fail(allocator, "drop desc {d}: exactly one of type/host must be set", .{i});
        }
        if (typed and d.type_ >= image.types.len) {
            return fail(allocator, "drop desc {d}: type {d} out of range", .{ i, d.type_ });
        }
        if (host and d.host_type_ >= image.host_types.len) {
            return fail(allocator, "drop desc {d}: host type {d} out of range", .{ i, d.host_type_ });
        }
    }
    return null;
}

fn rangeText(e: llir.DescIssue) []const u8 {
    return switch (e) {
        .kind_mismatch => "descriptor kind mismatch",
        .range_oob => "range out of bounds",
        .range_overflow => "range overflows u32",
    };
}

// ---------------------------------------------------------------------------
// 4. Instructions — decode, schema, IDs, targets, call shape
// ---------------------------------------------------------------------------

fn checkInstructions(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    for (image.functions, 0..) |f, fi| {
        // The schema's register bound is the register-addressable count
        // f_count + window_count — the F cells plus the O window
        // aliases (spec §4.1). X and spill cells are imm16-addressed
        // and never appear in register fields.
        var pc = f.code_start;
        while (pc < f.code_end) : (pc += 1) {
            if (try checkInstrAt(image, f, @intCast(fi), llir.regCount(f), pc, allocator)) |m| return m;
        }
    }
    return null;
}

fn checkInstrAt(image: *const llir.LlirProgram, f: llir.FunctionDesc, fi: u32, slot_count: u32, pc: u32, allocator: std.mem.Allocator) !?[]const u8 {
    const instr = image.instructions[pc];
    const d = llir.decode(instr) orelse
        return fail(allocator, "function {d}: pc {d}: reserved or unknown instruction word 0x{x:0>8}", .{ fi, pc, llir.wordOf(instr) });
    const op = d.op;
    // Field-level schema: register encodings, special placement, unused
    // fields, the tbz/tbnz bit bound (Instruction Set §14).
    if (llir.checkInstr(instr, slot_count)) |issue| {
        return fail(allocator, "function {d}: pc {d}: {s}", .{ fi, pc, issueText(issue) });
    }
    switch (op) {
        // ID operands: dense, in-range references. I-format IDs ride in
        // imm16; the R-format inline IDs sit in `a` or `c` (Instruction
        // Set §4–§6).
        .const_ => if (d.imm16 >= image.constants.len) {
            return fail(allocator, "function {d}: pc {d}: const id {d} out of range ({d} constants)", .{ fi, pc, d.imm16, image.constants.len });
        },
        .fn_ref => if (d.imm16 >= image.functions.len) {
            return fail(allocator, "function {d}: pc {d}: fn_ref FunctionId {d} out of range ({d} functions)", .{ fi, pc, d.imm16, image.functions.len });
        },
        .module_ref => if (d.imm16 >= image.symbols.len) {
            return fail(allocator, "function {d}: pc {d}: module_ref SymbolId {d} out of range ({d} symbols)", .{ fi, pc, d.imm16, image.symbols.len });
        },
        .type_is, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move => if (d.c >= image.types.len) {
            return fail(allocator, "function {d}: pc {d}: inline TypeId {d} out of range", .{ fi, pc, d.c });
        },
        .load_member, .read_field, .read_tuple, .read_payload => {
            if (d.c >= image.member_descs.len) {
                return fail(allocator, "function {d}: pc {d}: member desc id {d} out of range ({d} rows)", .{ fi, pc, d.c, image.member_descs.len });
            }
        },
        .store_member => {
            if (d.imm16 >= image.member_descs.len) {
                return fail(allocator, "function {d}: pc {d}: member desc id {d} out of range ({d} rows)", .{ fi, pc, d.imm16, image.member_descs.len });
            }
        },
        .drop => {
            if (d.imm16 >= image.drop_descs.len) {
                return fail(allocator, "function {d}: pc {d}: drop desc id {d} out of range ({d} rows)", .{ fi, pc, d.imm16, image.drop_descs.len });
            }
        },
        .spill_take, .spill_put => {
            if (d.imm16 >= f.x_count) {
                return fail(allocator, "function {d}: pc {d}: spill XId {d} out of range ({d} spill cells)", .{ fi, pc, d.imm16, f.x_count });
            }
        },
        .slot_copy, .slot_move, .slot_borrow, .slot_retain => {
            if (d.imm16 >= f.window_count) {
                return fail(allocator, "function {d}: pc {d}: arg offset {d} outside the window ({d} cells)", .{ fi, pc, d.imm16, f.window_count });
            }
        },
        .construct => if (d.imm16 >= image.construct_descs.len) {
            return fail(allocator, "function {d}: pc {d}: construct desc id {d} out of range", .{ fi, pc, d.imm16 });
        },
        .unpack_struct, .unpack_tuple, .split_list => {
            // I format: `a` = base src, imm16 = DestructureDescId.
            if (d.imm16 >= image.destructure_descs.len) {
                return fail(allocator, "function {d}: pc {d}: destructure desc id {d} out of range", .{ fi, pc, d.imm16 });
            }
            const dd = image.destructure_descs[d.imm16];
            const want: llir.DestructureKind = switch (op) {
                .unpack_struct => .struct_,
                .unpack_tuple => .tuple,
                .split_list => .list,
                else => unreachable,
            };
            if (dd.kind != want) {
                return fail(allocator, "function {d}: pc {d}: destructure descriptor kind mismatch (opcode requires {s})", .{ fi, pc, @tagName(want) });
            }
            if (try checkDstRows(image, slot_count, dd, allocator, pc, fi)) |m| return m;
        },
        .unpack_variant, .borrow_variant => {
            // R format: `a` = the 7-bit DestructureDescId, `b` = base,
            // `c` = the variant tag.
            if (d.a >= image.destructure_descs.len) {
                return fail(allocator, "function {d}: pc {d}: destructure desc id {d} out of range", .{ fi, pc, d.a });
            }
            const dd = image.destructure_descs[d.a];
            if (dd.kind != .variant) {
                return fail(allocator, "function {d}: pc {d}: destructure descriptor kind mismatch (opcode requires variant)", .{ fi, pc });
            }
            if (try checkDstRows(image, slot_count, dd, allocator, pc, fi)) |m| return m;
        },
        .jal => {
            // `jal ra` is the direct call: its static target must be a
            // function entry, followed by the take-at-return-pc contract
            // (Instruction Set §14). On prefix `11101` register field
            // `ra` selects `jal`; `zero` selects the intra-function jump
            // `j`. Both decode the target from the signed 20-bit
            // offset relative to this pc.
            const target = llir.jalTarget(pc, d.imm20);
            if (!isFunctionEntry(image.functions, target)) {
                return fail(allocator, "function {d}: pc {d}: jal ra target {d} is not a function entry", .{ fi, pc, target });
            }
            if (try checkCallResultTake(image, f, fi, target, pc, allocator)) |m| return m;
        },
        .j => {
            // `j` is the unconditional intra-function jump: its target
            // must be a block start inside the current function
            // (Instruction Set §9.1, §14).
            const target = llir.jalTarget(pc, d.imm20);
            if (try checkBranchTarget(image, fi, target, allocator, pc, "j target")) |m| return m;
        },
        .jalr => {}, // base schema via checkInstr; the target and the take contract are dynamic (checked by enterCall)
        .jr => {}, // register operand + offset fields via checkInstr; the target is dynamic
        .syscall => {
            if (d.imm16 >= image.syscall_descs.len) {
                return fail(allocator, "function {d}: pc {d}: syscall desc id {d} out of range", .{ fi, pc, d.imm16 });
            }
            const desc = image.syscall_descs[d.imm16];
            // The `a = zero` discard and the zero-for-Copy-parameter
            // rules are semantic (frontend-guaranteed, §3.1); only the
            // argument-register frame bound is structural.
            if (try checkCallArgRegs(image, slot_count, desc, allocator, pc, fi)) |m| return m;
        },
        .tailcall_self => {}, // a/b are zero (checkInstr); no result (spec §5.5)
        .trap => {}, // a/b are zero (checkInstr)
        .ret => {}, // a/b schema via checkInstr; the zero/Copy result rules are semantic (§3.1)
        .switch_ => {
            if (d.imm16 >= image.switch_descs.len) {
                return fail(allocator, "function {d}: pc {d}: switch desc id {d} out of range", .{ fi, pc, d.imm16 });
            }
            const sd = image.switch_descs[d.imm16];
            for (0..sd.arms_len) |k| {
                const arm = image.switch_arms[sd.arms_start + k];
                // The arm target is a signed offset from the switch's
                // own pc (Instruction Set §11–§12).
                if (try checkBranchTarget(image, fi, llir.switchArmTarget(pc, arm.target), allocator, pc, "switch arm target")) |m| return m;
            }
        },
        else => {
            // The B-type compare-and-branches carry a signed 10-bit
            // target offset. The long-branch expansion (Instruction Set
            // §11.1) inverts a far branch to skip over an inserted
            // link-less `j`: the branch's offs10 is the +2 skip, not a
            // block target — only the unexpanded form is target-checked.
            if (llir.formatOf(op) == .b) {
                if (d.offs10 == 2 and pc + 1 < image.instructions.len and isJ(image.instructions[pc + 1])) {
                    // expanded: the +2 skip — nothing more to check here
                } else if (try checkBranchTarget(image, fi, llir.bTypeTarget(pc, d.offs10), allocator, pc, "branch target")) |m| return m;
            }
        },
    }
    return null;
}

/// The result slots of a destructure descriptor must lie in the
/// defining function's frame; a T destination has no frame cell and is
/// legal (Instruction Set §3.1 — side tables may name F or T).
fn checkDstRows(image: *const llir.LlirProgram, slot_count: u32, d: llir.DestructureDesc, allocator: std.mem.Allocator, pc: u32, fi: u32) !?[]const u8 {
    for (0..d.dsts_len) |k| {
        const dst = image.destructure_dsts[d.dsts_start + k];
        if ((!llir.isFrame(dst) or llir.frameIndex(dst) >= slot_count) and !llir.isTemp(dst)) {
            return fail(allocator, "function {d}: pc {d}: destructure result slot {d} out of the frame ({d} slots)", .{ fi, pc, dst, slot_count });
        }
    }
    return null;
}

/// The value area of a function (spec §4.2): `A = max(P, R)` — the
/// parameter count and 0/1 result count of its signature.
fn valueArea(image: *const llir.LlirProgram, fn_id: u32) u32 {
    const f = image.functions[fn_id];
    const sig = image.signatures[f.signature_id];
    const r: u32 = if (sig.ret == llir.no_index) 0 else 1;
    return @max(sig.params_len, r);
}

/// The result contract at a static `jal ra` fallthrough (Instruction Set
/// §6, §14): a non-void direct callee's fallthrough is either the generic
/// `take dst, F(L+3+O-A)` (Step 8 coalescing off) or nothing (Step 8
/// coalescing on — the result stays in the caller's result alias
/// `F(L+3+O-A)`, read directly by the fallthrough). A take that is
/// present must have the *correct source register*; a void callee must
/// see no take at its return pc.
fn checkCallResultTake(image: *const llir.LlirProgram, f: llir.FunctionDesc, fi: u32, target: u32, pc: u32, allocator: std.mem.Allocator) !?[]const u8 {
    const callee_fn = llir.functionAtPc(image.functions, target) orelse
        return fail(allocator, "function {d}: pc {d}: jal ra target {d} is not a function entry", .{ fi, pc, target });
    const sig = image.signatures[image.functions[callee_fn].signature_id];
    const a = valueArea(image, callee_fn);
    // The caller's output window must actually cover the callee's value
    // area plus its three-cell header — `A ≤ O = W - 3` — before the
    // result alias encoding is formed (a forged image can name a callee
    // with a larger area than the caller reserved).
    const o = llir.outCount(f);
    if (a > o) {
        return fail(allocator, "function {d}: pc {d}: callee value area {d} exceeds the caller output window ({d} cells)", .{ fi, pc, a, o });
    }
    const want_src: u32 = llir.frameReg(f.f_count + f.window_count - a); // F(L+3+O-A)
    if (sig.ret != llir.no_index) {
        // Non-void: accept no take (Step 8 coalesced — the fallthrough
        // reads the alias directly) or a take with the exact result
        // alias source; a take with any other source is a forged or
        // mismatched record.
        if (pc + 1 < image.instructions.len) {
            if (llir.decode(image.instructions[pc + 1])) |nd| {
                if (nd.op == .take and nd.b != want_src) {
                    return fail(allocator, "function {d}: pc {d}: non-void call take must source F{d}", .{ fi, pc, want_src });
                }
            }
        }
    } else {
        if (pc + 1 < image.instructions.len) {
            if (llir.decode(image.instructions[pc + 1])) |nd| {
                if (nd.op == .take) {
                    return fail(allocator, "function {d}: pc {d}: void callee must see no take at its return pc", .{ fi, pc });
                }
            }
        }
    }
    return null;
}

/// One branch/switch target: a decoded absolute PC that is a block start
/// inside the *current* function (spec §2, §7 — never a cross-function or
/// mid-block transfer).
fn checkBranchTarget(image: *const llir.LlirProgram, fi: u32, target: u32, allocator: std.mem.Allocator, pc: u32, what: []const u8) !?[]const u8 {
    if (llir.functionAtPc(image.functions, target) != fi) {
        return fail(allocator, "function {d}: pc {d}: {s} {d} lies outside this function's code range", .{ fi, pc, what, target });
    }
    if (!isBlockStart(image.blocks, target)) {
        return fail(allocator, "function {d}: pc {d}: {s} {d} is not a block start", .{ fi, pc, what, target });
    }
    return null;
}

/// The argument registers of one syscall descriptor: each names a slot
/// of the caller's frame (spec §5.2). `zero` is a legal argument encoding
/// whose Copy-numeric typing is a frontend guarantee (§3.1) — only the
/// frame bound is structural.
fn checkCallArgRegs(image: *const llir.LlirProgram, slot_count: u32, desc: llir.SyscallDesc, allocator: std.mem.Allocator, pc: u32, fi: u32) !?[]const u8 {
    for (0..desc.args_len) |k| {
        const reg = image.call_args[desc.args_start + k];
        if (reg != llir.zero_reg and (!llir.isFrame(reg) or llir.frameIndex(reg) >= slot_count)) {
            return fail(allocator, "function {d}: pc {d}: syscall argument register {d} out of the caller frame ({d} slots)", .{ fi, pc, reg, slot_count });
        }
    }
    return null;
}

/// Whether `instr` is a `j` — the unconditional intra-function jump
/// (Instruction Set §9.1).
fn isJ(instr: llir.Instr) bool {
    const d = llir.decode(instr) orelse return false;
    return d.op == .j;
}

// ---------------------------------------------------------------------------
// 5. Terminators — each block ends with one, and only at the end
// ---------------------------------------------------------------------------

fn checkBlockEnds(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    for (image.blocks, 0..) |blk, bi| {
        const last = image.instructions[blk.end_pc - 1];
        const lop = llir.decode(last) orelse continue; // unknown words were rejected above
        if (!isBlockTerminator(lop.op) and !isCondBranch(lop.op)) {
            return fail(allocator, "block {d}: missing terminator at pc {d}", .{ bi, blk.end_pc - 1 });
        }
        var pc = blk.start_pc;
        while (pc + 1 < blk.end_pc) : (pc += 1) {
            const iop = llir.decode(image.instructions[pc]) orelse continue; // rejected above
            if (isBlockTerminator(iop.op)) {
                // A mid-block terminator is legal in exactly two shapes:
                // a `jal ra` call (its fallthrough — a `take`
                // and then the block's real terminator — continues the
                // block), and the long-branch expansion's inserted
                // link-less `j` right after a B-type branch whose offs10
                // is the +2 skip (Instruction Set §11.1).
                if (iop.op == .jal) {
                    if (iop.a == llir.ra_reg) continue; // a call, not a block end
                } else if (iop.op == .j) {
                    // the long-branch expansion's inserted `j` right
                    // after a B-type branch whose offs10 is the +2 skip
                    // (Instruction Set §11.1) — trampoline middle record.
                    if (pc > blk.start_pc) {
                        if (llir.decode(image.instructions[pc - 1])) |prev| {
                            if (llir.formatOf(prev.op) == .b and prev.offs10 == 2) continue;
                        }
                    }
                }
                return fail(allocator, "block {d}: terminator at pc {d} is not at the block end", .{ bi, pc });
            }
        }
    }
    return null;
}

/// The control-flow terminators that end a basic block — the image of
/// `llir.lowerTerminator` (`jal`, `j`, `switch_`, `ret`, `release_ret`,
/// `tailcall_self`, `jr`, `trap`). A CFG `br` lowers to a B-type
/// compare-and-branch followed by a `j`, so the compare-and-branch is
/// not in the set; the B-type branches are legal block ends
/// in the one-record form (trailing-j elimination), handled by the
/// caller via `isCondBranch`.
fn isBlockTerminator(op: llir.Opcode) bool {
    return switch (op) {
        .jal, .j, .switch_, .ret, .release_ret, .tailcall_self, .jr, .trap => true,
        else => false,
    };
}

/// Every B-type opcode is a compare-and-branch — a legal block end since
/// the trailing-j elimination.
fn isCondBranch(op: llir.Opcode) bool {
    return llir.formatOf(op) == .b;
}

// ---------------------------------------------------------------------------
// 6. `cond` lifetime — block-local, call/block-boundary scoped
// ---------------------------------------------------------------------------

/// The structural `cond` shape rule (Instruction Set §7, §14): a
/// `cmov`/`copy`/`not` reading `cond` must find it defined earlier in
/// the same block and after any call. This is a light forward scan, not
/// a dataflow analysis: "consumed before the next writer/call/boundary"
/// is a frontend invariant the loader does not re-prove.
fn checkCondLifetime(image: *const llir.LlirProgram, allocator: std.mem.Allocator) !?[]const u8 {
    for (image.blocks) |blk| {
        var cond_defined = false;
        var pc = blk.start_pc;
        while (pc < blk.end_pc) : (pc += 1) {
            const d = llir.decode(image.instructions[pc]) orelse continue; // rejected above
            switch (d.op) {
                .jal, .jalr => cond_defined = false, // calls make cond unavailable
                .not, .copy => {
                    if (d.a == llir.cond_reg) cond_defined = true;
                    if (d.b == llir.cond_reg and !cond_defined) {
                        return fail(allocator, "pc {d}: cond read before any in-block definition (after a call or block boundary)", .{pc});
                    }
                },
                .cmov => {
                    if (!cond_defined) {
                        return fail(allocator, "pc {d}: cmov reads cond before any in-block definition (after a call or block boundary)", .{pc});
                    }
                },
                else => {
                    // Every C-Type comparison unconditionally writes cond.
                    if (llir.formatOf(d.op) == .c and llir.opInfo(d.op).a != .dst) cond_defined = true;
                    if (d.op == .bool_eq or d.op == .bool_ne or d.op == .str_eq or d.op == .str_ne) cond_defined = true;
                },
            }
        }
    }
    return null;
}
