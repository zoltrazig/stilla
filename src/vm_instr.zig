//! The VM instruction image (docs/interpreter-vm.md §1): the decoded,
//! executable form the interpreter actually steps over. Loading decodes
//! every 4-byte LLIR record exactly once into one fixed-size `VmInstr` —
//! 1:1 and order-preserving, so every LLIR pc identifies the
//! corresponding VM instruction (`vm_pc = module.code_base + llir_pc`).
//! This module is the only bridge from the LLIR wire encoding to the
//! executable image; wire decoding stays in `llir.zig`.
//!
//! Layout: `op` is `VmOpcode` — the canonical `llir.Opcode` list with an
//! `u16` tag (273 logical opcodes; the headroom above is the expansion
//! headroom, and a future tag bump is caught by the comptime size assert
//! below). The operand is a mandatory
//! `u32`: it holds the format-specific immediate, offset, or
//! side-table handle — relocated absolute pcs and `imm20` immediates
//! need the width, which a 16-bit field cannot express. The 12-byte
//! instruction carries the `u16` opcode tag plus the three 7-bit
//! register fields (three bytes of alignment padding separate them
//! from the operand); five instructions fit a 64-byte cache line, and
//! the opcode alone determines how `a`, `b`, `c`, and `operand` are
//! interpreted — no runtime format tag. Instructions never embed
//! pointers or slices; metadata and resolved members ride integer
//! handles.

const std = @import("std");
const llir = @import("llir.zig");

/// The VM opcode set: the canonical LLIR logical opcode list (same
/// table, `u8` tag). Generated from `llir_opcodes.zig` — never a second
/// handwritten table.
pub const VmOpcode = llir.Opcode;

/// One decoded VM instruction: exactly 12 bytes, align 4. The `u16`
/// opcode tag leaves three alignment bytes before the `u32` operand.
pub const VmInstr = extern struct {
    op: VmOpcode,
    a: u8,
    b: u8,
    c: u8,
    /// Format-specific immediate, offset, or side-table handle. The
    /// opcode determines the interpretation:
    ///   R — 0 (the immediate forms carry their imm7 in `c`);
    ///   B — the sign-extended 10-bit branch offset;
    ///   I — the zero-extended `imm16` (ID or lane value);
    ///   C/E — 0;
    ///   U — the sign-extended 20-bit `jal`/`auipc`/`lui` immediate.
    ///   Exception: a published `jal`'s operand is **not** the immediate —
    ///   publishArtifact rewrites it to the callee's function registry
    ///   index, so the direct-call path resolves no target; `jumpTarget`
    ///   must not be called on a `jal` read from the image.
    operand: u32,
};

comptime {
    if (@sizeOf(VmInstr) != 12) {
        @compileError("VmInstr must be exactly 12 bytes");
    }
    if (@alignOf(VmInstr) != 4) {
        @compileError("VmInstr must be 4-byte aligned");
    }
    if (@sizeOf(VmOpcode) != 2) {
        @compileError("VmOpcode must have an u16 tag");
    }
    // Five 12-byte instructions fit a 64-byte cache line.
    if (@sizeOf(VmInstr) * 5 > 64) {
        @compileError("VmInstr must pack five per cache line");
    }
    // The logical values must fit the u16 tag.
    if (@intFromEnum(VmOpcode.j) > std.math.maxInt(u16)) {
        @compileError("the largest opcode value must fit u16");
    }
}

/// The load-time rejection of a reserved or unassigned LLIR word.
pub const DecodeError = error{ReservedWord};

/// The total LLIR → VmInstr conversion: decode the wire record and pack
/// its operands into the fixed-size image instruction. Fails on any
/// reserved word — the reserved class, an unassigned code, an alignment
/// hole, a nonzero C/E reserved field, or an unclean `11101` register
/// field — before the instruction can enter the image.
pub fn decodeInstr(instr: llir.Instr) DecodeError!VmInstr {
    const d = llir.decode(instr) orelse return error.ReservedWord;
    return .{
        .op = d.op,
        .a = d.a,
        .b = d.b,
        .c = d.c,
        .operand = switch (d.format) {
            .r, .c, .e => 0,
            .b => @bitCast(@as(i32, d.offs10)),
            .i => @as(u32, d.imm16),
            .u => @bitCast(d.imm20),
        },
    };
}

// ---------------------------------------------------------------------------
// Operand helpers — signed immediates and relocated pc operands
// ---------------------------------------------------------------------------

/// The signed 10-bit branch offset of a B-type instruction.
pub inline fn branchOffset(v: VmInstr) i32 {
    return @bitCast(v.operand);
}

/// The relocated B-type branch target: `pc + offset` — offsets are
/// pc-relative and never relocated; `pc` is already the VM pc.
pub inline fn branchTarget(pc: u32, v: VmInstr) u32 {
    return pc +% @as(u32, @bitCast(branchOffset(v)));
}

/// The relocated direct-call/jump target: `pc + signExtend20(operand)`.
pub inline fn jumpTarget(pc: u32, v: VmInstr) u32 {
    return pc +% @as(u32, @bitCast(@as(i32, @bitCast(v.operand))));
}

/// The signed 7-bit immediate carried in field `c` of the R-type
/// immediate forms, sign-extended to the full cell.
pub inline fn imm7Signed(c: u8) i64 {
    const s7: i7 = @bitCast(@as(u7, @intCast(c & 0x7f)));
    return @as(i64, s7);
}

/// The signed 16-bit offset of `jalr`/`jr` (I-type `imm16`).
pub inline fn offs16Signed(v: VmInstr) i16 {
    return @bitCast(@as(u16, @truncate(v.operand)));
}

// ---------------------------------------------------------------------------
// Tests — white-box: size/layout invariants, the exhaustive 1:1 mapping,
// and the immediate/pc helpers (pipeline-level tests live in the
// frontend suites).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "VmInstr is exactly 12 bytes, align 4" {
    try testing.expectEqual(@as(usize, 12), @sizeOf(VmInstr));
    try testing.expectEqual(@as(usize, 4), @alignOf(VmInstr));
    // The extern layout: op(2) + a/b/c(3) + 3 padding + operand(4).
    try testing.expectEqual(@as(usize, 12), @sizeOf(VmOpcode) + 3 + 4 + 3);
}

test "decodeInstr maps every opcode of every format 1:1" {
    for (std.meta.tags(VmOpcode)) |op| {
        const info = llir.opInfo(op);
        const n: u32 = @intFromEnum(op);
        const a: u8 = @truncate((n * 7) & 0x7f);
        const b: u8 = @truncate((n * 11) & 0x7f);
        const c: u8 = @truncate((n * 13) & 0x7f);
        const instr = switch (info.format) {
            .r => llir.instrR(op, a, b, c),
            .b => llir.instrB(op, a, b, @intCast(c & 0x3f)),
            .i => llir.instrI(op, a, @as(u16, @truncate(n)) | 0x1234),
            .c => llir.instrC(op, a, b),
            .e => llir.instrE(op, a, b),
            .u => llir.instrU(
                op,
                if (op == .j) llir.zero_reg else if (op == .jal) llir.ra_reg else a,
                @bitCast(@as(u32, b) | (@as(u32, c) << 8)),
            ),
        };
        const v = try decodeInstr(instr);
        try testing.expectEqual(op, v.op);
        // The register fields survive; the immediate lands in `operand`
        // per the format.
        switch (info.format) {
            .r => try testing.expectEqual(@as(u32, 0), v.operand),
            .b => try testing.expectEqual(@as(i32, @intCast(c & 0x3f)), branchOffset(v)),
            .i => try testing.expectEqual(@as(u32, @as(u16, @truncate(n)) | 0x1234), v.operand),
            .c, .e => try testing.expectEqual(@as(u32, 0), v.operand),
            .u => try testing.expectEqual(@as(i32, @bitCast(@as(u32, b) | (@as(u32, c) << 8))), @as(i32, @bitCast(v.operand))),
        }
    }
}

test "decodeInstr rejects reserved words before execution" {
    // The `10` reserved class, an unassigned code, and an unclean
    // `11101` register field all fail the load, never reach the image.
    try testing.expectError(error.ReservedWord, decodeInstr(.{ 0, 0, 0, 0x80 }));
    try testing.expectError(error.ReservedWord, decodeInstr(llir.bytesOf(@as(u32, 116) << 21)));
    try testing.expectError(error.ReservedWord, decodeInstr(llir.bytesOf((0b11101 << 27) | (@as(u32, llir.cond_reg) << 20))));
    try testing.expectError(error.ReservedWord, decodeInstr(llir.bytesOf((0b111001 << 26) | (1 << 14))));
}

test "signed immediates and pc helpers" {
    // imm7: sign-extended [-64, 63], zero-extended [0, 127].
    try testing.expectEqual(@as(i64, -64), imm7Signed(0x40));
    try testing.expectEqual(@as(i64, 63), imm7Signed(0x3f));
    // The jump/branch helpers reproduce llir's target arithmetic on
    // decoded instructions.
    const j = try decodeInstr(llir.instrJ(-4));
    try testing.expectEqual(@as(u32, 96), jumpTarget(100, j));
    const beq = try decodeInstr(llir.instrB(.beq, 0x14, 0x15, -2));
    try testing.expectEqual(@as(u32, 98), branchTarget(100, beq));
    const jr = try decodeInstr(llir.instrI(.jalr, llir.temp_base, 0xffff));
    try testing.expectEqual(@as(i16, -1), offs16Signed(jr));
}

test "all 273 logical opcodes fit u16 with headroom" {
    try testing.expectEqual(@as(usize, 273), std.meta.tags(VmOpcode).len);
    var max: u32 = 0;
    for (std.meta.tags(VmOpcode)) |op| max = @max(max, @intFromEnum(op));
    try testing.expectEqual(@as(u32, 273), max);
    try testing.expect(max < 65536 - 256); // expansion headroom
}
