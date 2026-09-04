//! Pass: LLIR assembly — symbolic text projection of a frozen
//! `llir.LlirProgram` image (Stilla LLIR Specification §1;
//! TODO 5.1). In: the image plus the `*const cfg.IrProgram` it was
//! lowered from — the image carries the module specifiers but no other
//! names (spec §2), so module identity is symbolized through the image
//! (`ModuleDesc.spec_*` into `strings`) and every other name symbol
//! comes from the source program. Out: a deterministic
//! symbolic assembly text.
//!
//! Conventions (TODO 5.1):
//!   - function header is the qualified name `func @mod.name`;
//!   - basic blocks are symbolic labels, function-qualified for global
//!     uniqueness (`$mod.fn.name`, falling back to a source-block name
//!     or `b{k}` inside the qualification; `f{i}b{k}` if the qualified
//!     form overflows the label buffer); `j`/`br`/`switch` targets are
//!     always the label, never an absolute PC;
//!   - registers stay physical `rN` / `zero` / `discard` (the slot is a
//!     fixed-width
//!     fact, not a name);
//!   - id operands are symbolized wherever the data lets us
//!     (`fn_ref`→`@mod.name`, `module_ref`→`@mod`, `load_member` /
//!     `store_member`→`@mod.member`, `type_is`→a rendered type,
//!     `const`→a literal, the syscall host binding→`@mod.member`);
//!     module prefixes resolve from the image, member/function names
//!     from the source program;
//!   - any id we cannot symbolize prints as `#<kind><N>` (e.g. `#c3` =
//!     CallDescId 3) and is resolved by the trailing symbol table, which
//!     also maps every label to its absolute PC and every module id
//!     (`#m<N>`) to its specifier — read from the image (`ModuleDesc.spec_*`
//!     into `strings`), not the source program.
//!
//! The image and its source program are read-only: nothing is modified.

const std = @import("std");
const cfg = @import("stilla").cfg;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

/// Render the program image as symbolic assembly into an owned slice.
/// `builder` is the lowered source program's Builder — the sole source of
/// names AND of the expanded block order (stage 7 edge blocks are part of
/// the image layout, so the per-function block split and the CFG-block
/// names come from `builder.ordered_blocks`/`block_ranges`, not from
/// `program.funcs`). Deterministic for a fixed (builder, image)
/// pair; the image and program are never mutated.
pub fn print(
    builder: *const Builder,
    image: llir.LlirProgram,
    allocator: std.mem.Allocator,
) error{OutOfMemory}![]u8 {
    var p = Printer{ .builder = builder, .program = builder.program, .image = image, .allocator = allocator };
    defer p.deinit();
    try p.run();
    return p.out.toOwnedSlice(allocator);
}

/// The kind of an unresolved id operand — picks the `#<letter>` token and
/// the symbol-table description.
const UidKind = enum {
    function,
    module,
    type_,
    member,
    slot,
    syscall,
    construct,
    destructure,
    switch_,
    const_,
    signature,
};

const UidRow = struct { kind: UidKind, id: u32 };

const Printer = struct {
    builder: *const Builder,
    program: *const cfg.IrProgram,
    image: llir.LlirProgram,
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    /// Persistent label names — one `[64]u8` per block, in program block
    /// order (each function's in `cfg.BlockOrder`, matching the image).
    label_bufs: std.ArrayList([64]u8) = .empty,
    label_lens: std.ArrayList(u8) = .empty,
    label_pcs: std.ArrayList(u32) = .empty,
    /// The current function's image block rows and parallel labels
    /// (`labels[j]` points into `label_bufs`; valid until the next
    /// function appends).
    blk: []const llir.BlockDesc = &.{},
    labels: [][]const u8 = &.{},
    /// Unresolved id rows for the trailing symbol table.
    uid: std.ArrayList(UidRow) = .empty,

    fn run(self: *Printer) error{OutOfMemory}!void {
        try self.w("\n", .{});
        try self.w("; LLIR assembly — symbolic projection of the Stilla program image\n", .{});
        try self.w("; {d} functions, {d} instructions\n", .{ self.image.functions.len, self.image.instructions.len });
        try self.w("\n", .{});

        // Functions in FunctionId order pair 1:1 with `program.funcs`;
        // their blocks tile the code range in image order == the per
        // function expanded `ordered_blocks` the Builder sorted into
        // `block_ranges` (stage-7 edge blocks included).
        var bi: usize = 0;
        for (self.image.functions, 0..) |fd, fi| {
            // image.functions pairs 1:1 with the Builder's scoped
            // `ordered_funcs` — the entry module's functions for a
            // per-module artifact, not the whole-program `program.funcs`.
            const f = self.builder.ordered_funcs.items[fi];
            const r = self.builder.block_ranges.items[fi];
            const blocks = self.image.blocks[bi .. bi + r.len];
            try self.printFunc(f, fd, blocks, @intCast(r.start), @intCast(fi));
            bi += r.len;
        }

        try self.printSymbolTable();
    }

    fn printFunc(self: *Printer, f: *const cfg.IrFunc, fd: llir.FunctionDesc, blocks: []const llir.BlockDesc, start_bi: usize, fi: u32) error{OutOfMemory}!void {
        try self.w("func ", .{});
        try self.appendFuncName(f);
        // v1 frame numbers (spec §4.1): F cells, X spill cells, and
        // the outgoing-window size.
        try self.w(" {{  ; F{d} X{d} W{d}\n", .{ fd.f_count, fd.x_count, fd.window_count });

        // The image's per-function block order is exactly the Builder's
        // expanded `ordered_blocks` range (stage 7 interleaves LLIR-only
        // edge blocks after their predecessor), so each block's name is
        // its source block's — empty for an edge block, which falls back
        // to `b{k}`.
        self.blk = blocks;
        self.labels = try self.allocator.alloc([]const u8, blocks.len);
        defer self.allocator.free(self.labels);
        const base = self.label_bufs.items.len;
        // Reserve capacity for this function's labels up front.
        while (self.label_bufs.items.len < base + blocks.len) {
            try self.label_bufs.append(self.allocator, [_]u8{0} ** 64);
            try self.label_lens.append(self.allocator, 0);
            try self.label_pcs.append(self.allocator, 0);
        }
        var fbuf: [128]u8 = undefined;
        const fname = funcBase(f, self.artifactSpec(), &fbuf);
        for (blocks, 0..) |bd, j| {
            // The label is the function-qualified block name, so symbols
            // stay unique across the whole image: the trailing symbol
            // table maps each label to exactly one PC, which a bare
            // `$entry` repeated per function would not. Prefer the cfg
            // block name when it is non-empty and unique in this
            // function; otherwise fall back to `b{k}` (a stage-7 edge
            // block has no source name). If the qualification overflows
            // the 64-byte buffer, fall back to the always-fitting unique
            // `f{i}b{k}`. The stored label carries the leading `$`
            // (branch targets and the symbol table both use it).
            const nm = self.builder.ordered_blocks.items[start_bi + j].name;
            var tmp: [64]u8 = undefined;
            var bare: []u8 = undefined;
            if (nm.len > 0 and nm.len <= 62 and !self.nameUsed(nm, j)) {
                @memcpy(tmp[0..nm.len], nm);
                bare = tmp[0..nm.len];
            } else {
                bare = std.fmt.bufPrint(&tmp, "b{d}", .{j}) catch unreachable;
            }
            var qual: [64]u8 = undefined;
            const qualified = if (fname.len + 1 + bare.len <= 62)
                std.fmt.bufPrint(&qual, "{s}.{s}", .{ fname, bare }) catch unreachable
            else
                std.fmt.bufPrint(&qual, "f{d}b{d}", .{ fi, j }) catch unreachable;
            const store = &self.label_bufs.items[base + j];
            store[0] = '$';
            @memcpy(store[1 .. 1 + qualified.len], qualified);
            self.label_lens.items[base + j] = @intCast(1 + qualified.len);
            self.label_pcs.items[base + j] = bd.start_pc;
            self.labels[j] = store[0 .. 1 + qualified.len];
        }

        for (blocks, 0..) |bd, j| {
            try self.w(".block {s}  ; 0x{x:0>4}..0x{x:0>4}\n", .{ self.labels[j], bd.start_pc, bd.end_pc });
            var pc = bd.start_pc;
            while (pc < bd.end_pc) : (pc += 1) try self.printInstr(f, pc);
        }
        try self.w("}}\n", .{});
    }

    /// True when `nm` already names an earlier block (`0 .. j`) in this
    /// function — duplicate labels must fall back to `b{k}`.
    fn nameUsed(self: *const Printer, nm: []const u8, j: usize) bool {
        for (self.labels[0..j]) |other| {
            // Stored labels carry a leading `$`; compare the bare name.
            if (other.len > 1 and std.mem.eql(u8, nm, other[1..])) return true;
        }
        return false;
    }

    fn printInstr(self: *Printer, f: *const cfg.IrFunc, pc: u32) error{OutOfMemory}!void {
        const instr = self.image.instructions[pc];
        const d = llir.decode(instr) orelse {
            // A raw word dump of the unknown/reserved row — the first
            // byte is not necessarily the opcode (v9, Instruction Set
            // §2), so print the whole little-endian word.
            try self.w("    ?? 0x{x:0>8}\n", .{llir.wordOf(instr)});
            return;
        };
        const op = d.op;
        const info = llir.opInfo(op);
        try self.w("    {s}", .{info.name});
        switch (op) {
            .j => {
                // The unconditional intra-function jump — encoded as
                // `jal`'s U-type word whose register field carries
                // `zero`, its no-link mark (Instruction Set §9.1):
                // `j imm20`, a pc-relative label.
                try self.w(" ", .{});
                try self.w("{s}", .{self.labelForPc(llir.jalTarget(pc, d.imm20)) orelse "?target"});
            },
            .jal => {
                // `jal ra` is the direct call: the pc-relative target
                // names the callee when it resolves to a function
                // entry.
                try self.w(" ", .{});
                const target = llir.jalTarget(pc, d.imm20);
                if (llir.functionAtPc(self.image.functions, target)) |fid| {
                    if (fid < self.builder.ordered_funcs.items.len) {
                        try self.appendFuncName(self.builder.ordered_funcs.items[fid]);
                    } else {
                        try self.w("0x{x}", .{target});
                    }
                } else {
                    try self.w("0x{x}", .{target});
                }
            },
            .auipc => {
                // The 20-bit displacement sign-extended and shifted
                // left 12 — a signed pc delta, too wide for a block
                // label, so print the signed delta (Instruction Set
                // §9).
                try self.w(" ", .{});
                try self.writeReg(d.a);
                const disp: u64 = llir.auipcTarget(0, d.imm20);
                if (disp & (1 << 63) != 0) {
                    try self.w(" -0x{x}", .{0 -% disp}); // two's-complement magnitude
                } else {
                    try self.w(" +0x{x}", .{disp});
                }
            },
            .lui => {
                try self.w(" ", .{});
                try self.writeReg(d.a);
                try self.w(", {d}", .{d.imm20});
            },
            .jalr => {
                // `jalr ra, base, offs16`: the `ra` link token is
                // required but not encoded.
                try self.w(" ra, ", .{});
                try self.writeReg(d.a);
                try self.w(", {d}", .{@as(i16, @bitCast(d.imm16))});
            },
            .jr => {
                // Register-relative jump: the base register plus the
                // signed 16-bit offset (reach ±2¹⁵; Instruction Set
                // §6). The base is dynamic, so print the register and
                // the signed offset delta.
                try self.w(" ", .{});
                try self.writeReg(d.a);
                try self.w(" {d}", .{@as(i16, @bitCast(d.imm16))});
            },
            .switch_ => {
                try self.w(" ", .{});
                try self.writeReg(d.a);
                try self.w(" ", .{});
                try self.writeId(f, op, d.imm16);
                try self.appendSwitchArms(d.imm16, pc);
            },
            .drop => {
                // I format: a = source, imm16 = DropDescId.
                try self.w(" ", .{});
                try self.writeReg(d.a);
                try self.w(" ", .{});
                try self.writeId(f, op, d.imm16);
            },
            else => {
                if (info.format == .b) {
                    // B-type: lhs, the middle field (register / imm7 /
                    // bit index), and the target label.
                    try self.w(" ", .{});
                    try self.writeReg(d.a);
                    try self.w(", ", .{});
                    switch (info.b) {
                        .src => try self.writeReg(d.b),
                        .imm, .mask => try self.w("{d}", .{d.b}),
                        else => unreachable,
                    }
                    try self.w(", {s}", .{self.labelForPc(llir.bTypeTarget(pc, d.offs10)) orelse "?target"});
                } else {
                    // Generic positional rendering of the register
                    // fields plus the immediate/ID per format. `.none`
                    // fields are omitted; id fields are symbolized per
                    // opcode.
                    const Field = struct { value: u32, role: llir.Field };
                    var fields: [3]Field = undefined;
                    var n: usize = 0;
                    switch (info.format) {
                        .r => {
                            fields[0] = .{ .value = d.a, .role = info.a };
                            fields[1] = .{ .value = d.b, .role = info.b };
                            fields[2] = .{ .value = d.c, .role = info.c };
                            n = 3;
                        },
                        .c, .e => {
                            fields[0] = .{ .value = d.a, .role = info.a };
                            fields[1] = .{ .value = d.b, .role = info.b };
                            n = 2;
                        },
                        .i => {
                            fields[0] = .{ .value = d.a, .role = info.a };
                            fields[1] = .{ .value = d.imm16, .role = info.b };
                            n = 2;
                        },
                        .b, .u => unreachable, // handled above
                    }
                    var first = true;
                    for (fields[0..n]) |field| {
                        if (field.role == .none) continue;
                        if (!first) try self.w(",", .{});
                        first = false;
                        try self.w(" ", .{});
                        switch (field.role) {
                            .dst, .dst_real, .dst_movw, .dst_u, .src, .src_real, .src_f, .src_t, .link, .cond, .tested => try self.writeReg(@intCast(field.value)),
                            .imm, .mask, .imm16 => try self.w("{d}", .{field.value}),
                            .offs16 => try self.w("{d}", .{@as(i16, @bitCast(@as(u16, @truncate(field.value))))}),
                            .imm20 => try self.w("{d}", .{@as(i32, @bitCast(field.value))}),
                            .id => try self.writeId(f, op, field.value),
                            .offs10 => unreachable, // B-type only
                            .none => unreachable,
                        }
                    }
                }
            },
        }
        try self.w("\n", .{});
    }

    /// Write a register operand: `zero`, `discard`, `cond`, or the
    /// physical slot `rN`. The encoding is self-describing (spec §3.1) —
    /// the printer never consults the operand's role.
    fn writeReg(self: *Printer, v: llir.ValueReg) error{OutOfMemory}!void {
        if (llir.isZeroReg(v)) {
            try self.w("zero", .{});
        } else if (llir.isRaReg(v)) {
            try self.w("ra", .{});
        } else if (llir.isCondReg(v)) {
            try self.w("cond", .{});
        } else if (llir.isTemp(v)) {
            try self.w("T{d}", .{llir.tempIndex(v)});
        } else {
            try self.w("r{d}", .{v});
        }
    }

    /// The label of the block whose start PC equals `pc`, or null.
    fn labelForPc(self: *const Printer, pc: u32) ?[]const u8 {
        for (self.blk, self.labels) |bd, lbl| {
            if (bd.start_pc == pc) return lbl;
        }
        return null;
    }

    /// Write a switch descriptor's arms as `{ tag => $label, tag => $label }`.
    /// Each arm target is a signed offset from the switch's own `pc`
    /// (Instruction Set §11–§12).
    fn appendSwitchArms(self: *Printer, sid: llir.SwitchDescId, pc: u32) error{OutOfMemory}!void {
        if (sid >= self.image.switch_descs.len) {
            try self.w(" ;; SwitchDescId {d} out of range", .{sid});
            return;
        }
        const desc = self.image.switch_descs[sid];
        try self.w(" {{", .{});
        for (desc.arms_start..desc.arms_start + desc.arms_len) |k| {
            const arm = self.image.switch_arms[k];
            const lbl = self.labelForPc(llir.switchArmTarget(pc, arm.target)) orelse "?target";
            try self.w(" {d} => {s},", .{ arm.tag, lbl });
        }
        try self.w(" }}", .{});
    }

    /// Write `op`'s id operand at field `i` (0/1/2 = a/b/c): a symbol
    /// where resolvable, else a `#<kind><N>` token recorded in the table.
    fn writeId(self: *Printer, f: *const cfg.IrFunc, op: llir.Opcode, value: u32) error{OutOfMemory}!void {
        switch (op) {
            .const_ => {
                if (value < self.image.constants.len) {
                    try self.appendConst(self.image.constants[value]);
                } else {
                    try self.uidToken(.const_, value);
                }
            },
            .fn_ref => {
                if (value < self.builder.ordered_funcs.items.len) {
                    try self.appendFuncName(self.builder.ordered_funcs.items[value]);
                } else {
                    try self.uidToken(.function, value);
                }
            },
            .module_ref => {
                // Image-driven: the operand is a `SymbolId` whose bytes
                // are the canonical module specifier, resolved through
                // the image's symbol table.
                if (self.symbolBytes(value)) |spec| {
                    try self.w("@{s}", .{spec});
                } else {
                    try self.uidToken(.module, value);
                }
            },
            .type_is, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move => {
                if (value < self.image.types.len) {
                    try self.appendType(value);
                } else {
                    try self.uidToken(.type_, value);
                }
            },
            .load_member => {
                if (!try self.writeMemberName(f, value)) try self.uidToken(.member, value);
            },
            .store_member => {
                if (!try self.writeSlotName(f, value)) try self.uidToken(.slot, value);
            },
            .syscall => {
                if (!try self.writeSyscallName(value)) try self.uidToken(.syscall, value);
            },
            .construct => try self.uidToken(.construct, value),
            .unpack_struct, .unpack_tuple, .unpack_variant, .split_list, .borrow_variant => try self.uidToken(.destructure, value),
            .switch_ => try self.uidToken(.switch_, value),
            else => try self.w("{d}", .{value}),
        }
    }

    /// Write `@mod.member` for the `load_member` descriptor: its `ref`
    /// is an `ImportDesc` index whose `(module_symbol, member_symbol)`
    /// pair is image data — both parts resolve through the image's
    /// symbol table. False when any range is corrupt.
    fn writeMemberName(self: *Printer, f: *const cfg.IrFunc, desc_idx: u32) error{OutOfMemory}!bool {
        _ = f;
        if (desc_idx >= self.image.member_descs.len) return false;
        const imp_i = self.image.member_descs[desc_idx].ref;
        if (imp_i >= self.image.imports.len) return false;
        const imp = self.image.imports[imp_i];
        const spec = self.symbolBytes(imp.module_sym) orelse return false;
        const member = self.symbolBytes(imp.member_sym) orelse return false;
        try self.w("@{s}.{s}", .{ spec, member });
        return true;
    }

    /// Write `@mod.member` for the constant member whose storage slot is
    /// `slot` — the `store_member` operand space (module slot index,
    /// distinct from the member index; air.md §7).
    fn writeSlotName(self: *Printer, f: *const cfg.IrFunc, slot: u32) error{OutOfMemory}!bool {
        _ = f;
        const spec = self.artifactSpec() orelse return false;
        var m: ?*const cfg.IrModule = null;
        for (self.program.modules) |mod| {
            if (std.mem.eql(u8, mod.name, spec)) m = mod;
        }
        const members = (m orelse return false).members orelse return false;
        for (members) |mm| switch (mm.kind) {
            .const_slot => |s| {
                if (s != null and s.? == slot) {
                    try self.w("@{s}.{s}", .{ spec, mm.name });
                    return true;
                }
                // void constants occupy no storage (ref == null);
                // they are never `store_member` targets.
            },
            else => {},
        };
        return false;
    }

    /// Write the syscall host binding as `@mod.member`; both parts are
    /// an `ImportDesc`'s symbols resolved through the image. False when
    /// any range is corrupt.
    fn writeSyscallName(self: *Printer, sysid: llir.SyscallDescId) error{OutOfMemory}!bool {
        if (sysid >= self.image.syscall_descs.len) return false;
        const desc = self.image.syscall_descs[sysid];
        if (desc.host_binding_id >= self.image.imports.len) return false;
        const imp = self.image.imports[desc.host_binding_id];
        const spec = self.symbolBytes(imp.module_sym) orelse return false;
        const member = self.symbolBytes(imp.member_sym) orelse return false;
        try self.w("@{s}.{s}", .{ spec, member });
        return true;
    }

    fn appendFuncName(self: *Printer, f: *const cfg.IrFunc) error{OutOfMemory}!void {
        // `f.name.text` is already module-qualified for user functions
        // (`app.main`); text-form AIR carries unqualified names. The
        // lifecycle init function is named just `init`, so qualify it
        // (`app.init`) with the artifact's own module symbol.
        var buf: [128]u8 = undefined;
        try self.w("@{s}", .{funcBase(f, self.artifactSpec(), &buf)});
    }

    /// The artifact's own module symbol — the module identity all
    /// module-local names qualify with.
    fn artifactSpec(self: *const Printer) ?[]const u8 {
        return self.symbolBytes(self.image.self_symbol);
    }

    /// The bytes of symbol `id` — null when the id is out of range or
    /// the range is corrupt (the printer never validates; it degrades
    /// to `#` tokens).
    fn symbolBytes(self: *const Printer, id: u32) ?[]const u8 {
        if (id >= self.image.symbols.len) return null;
        const r = self.image.symbols[id];
        if (llir.checkRange(r.start, r.len, @intCast(self.image.strings.len)) != null) return null;
        return self.image.strings[r.start..][0..r.len];
    }

    /// Token + record for an unresolved id: `#<letter><N>`.
    fn uidToken(self: *Printer, kind: UidKind, id: u32) error{OutOfMemory}!void {
        try self.w("#{c}{d}", .{ uidLetter(kind), id });
        for (self.uid.items) |row| {
            if (row.kind == kind and row.id == id) return;
        }
        try self.uid.append(self.allocator, .{ .kind = kind, .id = id });
    }

    /// Render a `ConstRecord` as a literal.
    fn appendConst(self: *Printer, rec: llir.ConstRecord) error{OutOfMemory}!void {
        switch (rec.kind) {
            .int => {
                const v: i64 = @bitCast((@as(u64, rec.b) << 32) | rec.a);
                try self.w("{d}", .{v});
            },
            .float => {
                // binary64 payloads (phase 5) carry a nonzero high word;
                // binary32 keeps b == 0 and prints from the low word.
                if (rec.b != 0) {
                    const d: f64 = @bitCast((@as(u64, rec.b) << 32) | rec.a);
                    try self.w("{d}", .{d});
                    return;
                }
                const f: f32 = @bitCast(rec.a);
                if (std.math.isNan(f)) {
                    try self.w("nan", .{});
                } else if (std.math.isInf(f)) {
                    if (f < 0) {
                        try self.w("-inf", .{});
                    } else {
                        try self.w("inf", .{});
                    }
                } else {
                    try self.w("{d}", .{f});
                }
            },
            .bool => {
                if (rec.a != 0) {
                    try self.w("true", .{});
                } else {
                    try self.w("false", .{});
                }
            },
            .string => try self.appendString(self.image.strings[rec.a .. rec.a + rec.b]),
            .void => try self.w("void", .{}),
        }
    }

    fn appendString(self: *Printer, s: []const u8) error{OutOfMemory}!void {
        try self.w("\"", .{});
        for (s) |c| switch (c) {
            '"' => try self.w("\\\"", .{}),
            '\\' => try self.w("\\\\", .{}),
            '\n' => try self.w("\\n", .{}),
            '\r' => try self.w("\\r", .{}),
            '\t' => try self.w("\\t", .{}),
            else => try self.w("{c}", .{c}),
        };
        try self.w("\"", .{});
    }

    /// Render a `TypeDesc` row (`type_is` operands, signature params).
    fn appendType(self: *Printer, tid: llir.TypeId) error{OutOfMemory}!void {
        if (tid >= self.image.types.len) {
            try self.uidToken(.type_, tid);
            return;
        }
        const t = self.image.types[tid];
        switch (t.kind) {
            .primitive => {
                const n = @typeInfo(llir.PrimitiveId).@"enum".fields.len;
                if (t.a < n) {
                    try self.w("{s}", .{@tagName(@as(llir.PrimitiveId, @enumFromInt(t.a)))});
                } else {
                    try self.uidToken(.type_, tid);
                }
            },
            .named => {
                if (self.program.typeDecl(t.a)) |decl| {
                    try self.w("@{s}", .{decl.name()});
                } else {
                    try self.uidToken(.type_, tid);
                }
            },
            .list => {
                try self.w("list[", .{});
                try self.appendType(t.a);
                try self.w("]", .{});
            },
            .box => {
                try self.w("box[", .{});
                try self.appendType(t.a);
                try self.w("]", .{});
            },
            .tuple => {
                try self.w("(", .{});
                for (t.a..t.a + t.b) |k| {
                    if (k > t.a) try self.w(", ", .{});
                    try self.appendType(@intCast(k));
                }
                try self.w(")", .{});
            },
            .function => try self.appendSignature(t.a),
            .module => try self.w("module", .{}),
            .cleanup => try self.w("cleanup", .{}),
        }
    }

    /// Render a signature `(p0, p1) -> ret`.
    fn appendSignature(self: *Printer, sig_id: llir.SignatureId) error{OutOfMemory}!void {
        if (sig_id >= self.image.signatures.len) {
            try self.uidToken(.signature, sig_id);
            return;
        }
        const sig = self.image.signatures[sig_id];
        try self.w("(", .{});
        for (sig.params_start..sig.params_start + sig.params_len) |k| {
            if (k > sig.params_start) try self.w(", ", .{});
            const p = self.image.params[k];
            if (p.mode != .plain) try self.w("{s} ", .{@tagName(p.mode)});
            try self.appendType(p.type_);
        }
        try self.w(") -> ", .{});
        if (sig.ret == llir.no_index) {
            try self.w("void", .{});
        } else {
            try self.appendType(sig.ret);
        }
    }

    fn printSymbolTable(self: *Printer) error{OutOfMemory}!void {
        try self.w("\n", .{});
        try self.w("; ---------------------------------------------------------------------------\n", .{});
        try self.w("; symbol table\n", .{});
        try self.w("; ---------------------------------------------------------------------------\n", .{});
        // The artifact's symbol table, projected from the image itself —
        // the bytes are image data (Instruction Set §13) and the
        // projection must stay field-faithful. `%s<N>` matches the
        // SymbolId token convention.
        try self.w("; symbols (SymbolId -> bytes)\n", .{});
        for (self.image.symbols, 0..) |r, i| {
            try self.w("; %s{d} = ", .{i});
            if (llir.checkRange(r.start, r.len, @intCast(self.image.strings.len)) != null) {
                try self.w("<out of bounds>\n", .{});
                continue;
            }
            try self.appendString(self.image.strings[r.start..][0..r.len]);
            try self.w("\n", .{});
        }
        try self.w("; labels (block name -> start PC)\n", .{});
        var buf: [64]u8 = undefined;
        for (self.label_pcs.items, 0..) |pc, i| {
            const n = @min(@as(usize, self.label_lens.items[i]), buf.len);
            @memcpy(buf[0..n], self.label_bufs.items[i][0..n]);
            try self.w("{s} = 0x{x:0>4}\n", .{ buf[0..n], pc });
        }
        if (self.uid.items.len > 0) {
            try self.w("; unresolved ids (kind -> id)\n", .{});
            for (self.uid.items) |row| {
                try self.w("#{c}{d} = {s} {d}\n", .{ uidLetter(row.kind), row.id, uidKindName(row.kind), row.id });
            }
        }
    }

    fn w(self: *Printer, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try self.out.print(self.allocator, fmt, args);
    }

    /// Free the persistent supporting lists; `out` is returned to the
    /// caller via `toOwnedSlice` and must not be freed here.
    fn deinit(self: *Printer) void {
        self.label_bufs.deinit(self.allocator);
        self.label_lens.deinit(self.allocator);
        self.label_pcs.deinit(self.allocator);
        self.uid.deinit(self.allocator);
    }
};

/// The function's module-qualified base name: the image specifier of
/// its module, a `.`, and the source name with the frontend's
/// `{module_spec}.` qualification stripped (text-form names are bare
/// and have no prefix to strip) — buffered, the returned slice borrows
/// `buf`. `spec` null (an image module row that cannot answer) degrades
/// to the bare name.
fn funcBase(f: *const cfg.IrFunc, spec: ?[]const u8, buf: []u8) []const u8 {
    const s = spec orelse return f.name.text;
    var base = f.name.text;
    if (f.module_spec) |ms| {
        if (base.len > ms.len and std.mem.startsWith(u8, base, ms) and base[ms.len] == '.') base = base[ms.len + 1 ..];
    }
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ s, base }) catch f.name.text;
}

fn uidLetter(kind: UidKind) u8 {
    return switch (kind) {
        .function => 'f',
        .module => 'm',
        .type_ => 't',
        .member => 'e',
        .slot => 's',
        .syscall => 'y',
        .construct => 'o',
        .destructure => 'd',
        .switch_ => 'w',
        .const_ => 'k',
        .signature => 'g',
    };
}

fn uidKindName(kind: UidKind) []const u8 {
    return switch (kind) {
        .function => "FunctionId",
        .module => "ModuleId",
        .type_ => "TypeId",
        .member => "MemberId",
        .slot => "SlotId",
        .syscall => "SyscallDescId",
        .construct => "ConstructDescId",
        .destructure => "DestructureDescId",
        .switch_ => "SwitchDescId",
        .const_ => "ConstId",
        .signature => "SignatureId",
    };
}
