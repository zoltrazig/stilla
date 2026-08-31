//! The frozen LLIR image model (Stilla LLIR Specification) plus the v9
//! instruction codec (Stilla LLIR Instruction Set): the 4-byte fixed-width
//! six-format encoding, the logical `Opcode` set, the shared
//! `encode`/`decode` mapping, the register model (F / `zero` / `ra` / T /
//! `cond`), the frame and call arithmetic, and the descriptor and
//! side-table records. The opcode tables are machine-generated from
//! `.v8gen/table.json` (`llir_opcodes.zig`); everything here mirrors the
//! two v9 specification documents and must be updated with them.
//!
//! The v9 defining property: the type of every typed operation rides in
//! the logical opcode (the rep suffix — `add.i32`, `div.u64`, `seq.f32`),
//! so a serialized instruction record carries its own numeric semantics
//! and loading constructs no execution plan and no typed instruction
//! stream. The v9 binary reader rejects any other version before a
//! single table count is decoded.

const std = @import("std");
const cfg = @import("cfg.zig");
const opcodes = @import("llir_opcodes.zig");

/// The symbolic assembly projection of a frozen `LlirProgram` image.
/// Re-exported here so callers can render assembly purely through the
/// LLIR module (5.2); the implementation lives in
/// `passes/llir_asm.zig` and reads names only from the source
/// `cfg.IrProgram` (the image itself carries no names). `asm` is a Zig
/// keyword, so the renamed binding uses the `llir.print` spelling.
pub const print = @import("passes/llir_asm.zig").print;

// ---------------------------------------------------------------------------
// 0. The generated opcode table (llir_opcodes.zig) — re-exported
// ---------------------------------------------------------------------------

/// The logical opcode set: `Opcode = enum(u16)`, the complete
/// alignment-constrained set of Instruction Set §4–§9 — 234 opcodes with
/// explicit logical values (the alignment holes between typed families
/// are not members and carry no `opInfo`).
pub const Opcode = opcodes.Opcode;
/// The six instruction formats (Instruction Set §2.2).
pub const Format = opcodes.Format;
/// The numeric representation of a typed family member.
pub const Rep = opcodes.Rep;
/// One operand field's schema (role + special permission).
pub const Field = opcodes.Field;
/// One schema row: format, encoded selector, rep, operand schema, trap/term.
pub const OpInfo = opcodes.OpInfo;
/// The schema row of every logical opcode.
pub const opInfo = opcodes.opInfo;

// ---------------------------------------------------------------------------
// 1. The instruction record (Instruction Set §2)
// ---------------------------------------------------------------------------

/// Every instruction is exactly 32 bits: four canonical little-endian
/// bytes. A serialized word is never bitcast over a host-endian struct;
/// the only access paths are `encode`/`decode` (and the explicit
/// little-endian `wordOf`/`bytesOf` helpers). The logical opcode and
/// the encoded selector are different objects: the word's code field is
/// per-format (9 bits in R, 6 in B/I/C/E, 5 in U) and only `opInfo`
/// connects it to the logical `Opcode`.
pub const Instr = [4]u8;

comptime {
    if (@sizeOf(Instr) != 4) {
        @compileError("llir.Instr must be exactly 4 bytes");
    }
}

/// Assemble the little-endian word of an instruction record — the only
/// place words are assembled from bytes.
pub inline fn wordOf(instr: Instr) u32 {
    return @as(u32, instr[0]) |
        (@as(u32, instr[1]) << 8) |
        (@as(u32, instr[2]) << 16) |
        (@as(u32, instr[3]) << 24);
}

/// Split a little-endian word into the four canonical bytes.
pub inline fn bytesOf(w: u32) Instr {
    return .{
        @truncate(w),
        @truncate(w >> 8),
        @truncate(w >> 16),
        @truncate(w >> 24),
    };
}

// ---------------------------------------------------------------------------
// 2. The codec — encode/decode through the single opInfo table
// ---------------------------------------------------------------------------

/// The operand fields of one decoded instruction, per format. The
/// register fields land in `a`/`b` (`c` for R's third operand); the
/// immediates land in their named fields (`imm16` for I, `offs10` for B,
/// `imm20` for U). `format` and `op` are the decoded opcode identity.
pub const Decoded = struct {
    op: Opcode,
    format: Format,
    a: u8,
    b: u8,
    c: u8,
    imm16: u16,
    offs10: i16,
    imm20: i32,
};

/// The format of an opcode — straight from `opInfo`.
pub fn formatOf(op: Opcode) Format {
    return opInfo(op).format;
}

/// The rep of a typed family member, or null for an untyped opcode.
pub fn repOf(op: Opcode) ?Rep {
    return opInfo(op).rep;
}

/// Encode an R-type instruction: `00 | code(9) | a(7) | b(7) | c(7)`.
pub fn instrR(op: Opcode, a: u8, b: u8, c: u8) Instr {
    const info = opInfo(op);
    std.debug.assert(info.format == .r);
    return bytesOf((@as(u32, info.code) << 21) | (@as(u32, a & 0x7f) << 14) | (@as(u32, b & 0x7f) << 7) | (c & 0x7f));
}

/// Encode a B-type instruction: `01 | code(6) | lhs(7) | rhs_or_imm7(7) | offs10`.
pub fn instrB(op: Opcode, lhs: u8, mid: u8, offs10: i16) Instr {
    const info = opInfo(op);
    std.debug.assert(info.format == .b);
    return bytesOf((0b01 << 30) | (@as(u32, info.code) << 24) | (@as(u32, lhs & 0x7f) << 17) | (@as(u32, mid & 0x7f) << 10) | @as(u32, @as(u16, @bitCast(offs10)) & 0x3ff));
}

/// Encode an I-type instruction: `110 | code(6) | a(7) | imm16`.
pub fn instrI(op: Opcode, a: u8, imm16: u16) Instr {
    const info = opInfo(op);
    std.debug.assert(info.format == .i);
    return bytesOf((0b110 << 29) | (@as(u32, info.code) << 23) | (@as(u32, a & 0x7f) << 16) | imm16);
}

/// Encode a C-type instruction: `111000 | code(6) | reserved(6)=0 | a(7) | b(7)`.
pub fn instrC(op: Opcode, a: u8, b: u8) Instr {
    const info = opInfo(op);
    std.debug.assert(info.format == .c);
    return bytesOf((0b111000 << 26) | (@as(u32, info.code) << 20) | (@as(u32, a & 0x7f) << 7) | (b & 0x7f));
}

/// Encode an E-type instruction: `111001 | code(6) | reserved(6)=0 | a(7) | b(7)`.
pub fn instrE(op: Opcode, a: u8, b: u8) Instr {
    const info = opInfo(op);
    std.debug.assert(info.format == .e);
    return bytesOf((0b111001 << 26) | (@as(u32, info.code) << 20) | (@as(u32, a & 0x7f) << 7) | (b & 0x7f));
}

/// Encode the unconditional jump as `jal`'s U-type word with the
/// register field carrying `zero` — `11101 | 0x6d | imm20` — its
/// no-link mark; conceptually a distinct opcode, same encoding slot.
/// The low 20 bits are the signed pc-relative offset
/// (Instruction Set §9.1).
pub fn instrJ(offs20: i32) Instr {
    return instrU(.j, zero_reg, offs20);
}

/// Encode a U-type instruction: `op(5) | a(7) | imm20` — the three
/// 5-bit prefixes select `jal`/`auipc`/`lui`; `j` shares `jal`'s slot
/// and must carry the `zero` encoding (its decoder discriminator).
pub fn instrU(op: Opcode, a: u8, imm20: i32) Instr {
    const info = opInfo(op);
    std.debug.assert(info.format == .u and (op != .j or a == zero_reg));
    const prefix: u32 = switch (info.code) {
        0 => 0b11101, // jal
        1 => 0b11110, // auipc
        2 => 0b11111, // lui
        else => unreachable,
    };
    return bytesOf((prefix << 27) | (@as(u32, a & 0x7f) << 20) | (@as(u32, @bitCast(imm20)) & 0xfffff));
}

/// The reverse `(format, code) → Opcode` mapping, derived at comptime
/// from the canonical `opInfo` table — no second handwritten mapping.
/// Exception: `.j` shares `(.u, 0)` with `.jal` and stays out of the
/// table — the set's only field-discriminated encoding (register field
/// 0 on `jal`'s prefix, Instruction Set §9.1).
const code_to_op: [6][512]?Opcode = initCodeToOp();

fn initCodeToOp() [6][512]?Opcode {
    @setEvalBranchQuota(100_000);
    var t: [6][512]?Opcode = undefined;
    for (0..6) |f| {
        for (0..512) |c| t[f][c] = null;
    }
    for (std.meta.tags(Opcode)) |op| {
        if (op == .j) continue;
        const info = opInfo(op);
        t[@intFromEnum(info.format)][info.code] = op;
    }
    return t;
}

/// The logical opcode behind a `(format, code)` pair, or null for an
/// unassigned/reserved code.
pub fn opFromCode(format: Format, code: u16) ?Opcode {
    return code_to_op[@intFromEnum(format)][code];
}

fn sext10(raw: u16) i16 {
    return @as(i16, @bitCast(raw << 6)) >> 6;
}

fn sext20(raw: u32) i32 {
    return @as(i32, @bitCast(raw << 12)) >> 12;
}

/// Decode one instruction record into its logical opcode and operands,
/// or null for a reserved word: the `10` reserved class, an unassigned
/// code in any format, an alignment hole, a nonzero C/E reserved field,
/// or an unassigned `11` prefix.
pub fn decode(instr: Instr) ?Decoded {
    const w = wordOf(instr);
    const top = (w >> 30) & 0b11;
    if (top == 0b00) {
        const code: u16 = @truncate((w >> 21) & 0x1ff);
        const op = opFromCode(.r, code) orelse return null;
        return .{
            .op = op,
            .format = .r,
            .a = @truncate((w >> 14) & 0x7f),
            .b = @truncate((w >> 7) & 0x7f),
            .c = @truncate(w & 0x7f),
            .imm16 = 0,
            .offs10 = 0,
            .imm20 = 0,
        };
    }
    if (top == 0b01) {
        const code: u16 = @truncate((w >> 24) & 0x3f);
        const op = opFromCode(.b, code) orelse return null;
        return .{
            .op = op,
            .format = .b,
            .a = @truncate((w >> 17) & 0x7f),
            .b = @truncate((w >> 10) & 0x7f),
            .c = 0,
            .imm16 = 0,
            .offs10 = sext10(@truncate(w & 0x3ff)),
            .imm20 = 0,
        };
    }
    if (top == 0b10) return null; // reserved class
    const t3 = (w >> 29) & 0b111;
    if (t3 == 0b110) {
        const code: u16 = @truncate((w >> 23) & 0x3f);
        const op = opFromCode(.i, code) orelse return null;
        return .{
            .op = op,
            .format = .i,
            .a = @truncate((w >> 16) & 0x7f),
            .b = 0,
            .c = 0,
            .imm16 = @truncate(w & 0xffff),
            .offs10 = 0,
            .imm20 = 0,
        };
    }
    if (t3 != 0b111) return null;
    const s6 = (w >> 26) & 0x3f;
    if (s6 == 0b111000 or s6 == 0b111001) {
        const code: u16 = @truncate((w >> 20) & 0x3f);
        if (((w >> 14) & 0x3f) != 0) return null; // reserved field must be zero
        const fmt: Format = if (s6 == 0b111000) .c else .e;
        const op = opFromCode(fmt, code) orelse return null;
        return .{
            .op = op,
            .format = fmt,
            .a = @truncate((w >> 7) & 0x7f),
            .b = @truncate(w & 0x7f),
            .c = 0,
            .imm16 = 0,
            .offs10 = 0,
            .imm20 = 0,
        };
    }
    const s5 = (w >> 27) & 0x1f;
    const code: u16 = if (s5 == 0b11101) 0 else if (s5 == 0b11110) 1 else if (s5 == 0b11111) 2 else return null;
    const a: u8 = @truncate((w >> 20) & 0x7f);
    // The set's only field-discriminated encoding: prefix `11101` holds
    // both jumps — `ra` → `jal` (direct call), `zero` → `j` (no link,
    // no frame); any other register value is unclean (Instruction Set §9.1).
    const op: Opcode = if (code != 0)
        opFromCode(.u, code) orelse return null
    else if (a == ra_reg)
        .jal
    else if (a == zero_reg)
        .j
    else
        return null;
    return .{
        .op = op,
        .format = .u,
        .a = a,
        .b = 0,
        .c = 0,
        .imm16 = 0,
        .offs10 = 0,
        .imm20 = sext20(w & 0xfffff),
    };
}

// ---------------------------------------------------------------------------
// 3. Operand registers and the special registers (Instruction Set §3)
// ---------------------------------------------------------------------------

/// A register operand: an F frame register, a T temp register, or one
/// of the three specials (`zero`, `cond`, `ra`). Fixed-width `u8`. The
/// specials and T bank form the contiguous low block `[0, frame_base)`,
/// so the VM indexes them directly into one fast bank (no decode
/// arithmetic, Instruction Set §3.1.1). `ra` is a reserved hole inside
/// that block: call-convention-only, never a scratch cell.
pub const ValueReg = u8;

/// The frame register count: F0–F108 (`0x13–0x7f`), 109 frame cells at
/// `stack[fp + (r - frame_base)]` (spec §3.1, Instruction Set §3.1).
/// Validation caps the frame register count at `frame_count_max`, so
/// a slot can never collide with the fast bank or `ra`.
pub const frame_count_max: ValueReg = 109;

/// Special register with a dual role (RISC-V `x0` style): reading it
/// produces the all-zero bit pattern for the scalar type its
/// instruction's rep requires; writing it discards the result (one
/// encoding, role-dependent meaning). Writing `zero` performs no retain,
/// release,
/// or ownership transfer; the frontend only writes Copy/void results to
/// `zero` (a trusted semantic invariant, not a loader check). Encoded at
/// index 0 of the fast bank, whose cell is kept permanently all-zero.
pub const zero_reg: ValueReg = 0x00;

/// The single condition register: the block-local short-lived
/// destination of the C-Type comparisons, and a legal operand of
/// `not`/`copy`/`cmov` per Instruction Set §3.2. Not a frame slot;
/// fast-bank index 1.
pub const cond_reg: ValueReg = 0x01;

/// The fixed link register. Only `jal`'s explicit link destination,
/// `jalr`'s implicit link destination, and the return path may touch it;
/// the structural validator rejects every other read or write. Encoded
/// at fast-bank index 2 as a *reserved hole*: call-convention-only,
/// never a scratch cell — the return address lives in the caller-frame
/// header, not here, so this cell stays dead (reads never reach it;
/// writes are discarded).
pub const ra_reg: ValueReg = 0x02;

/// The first T register: T0 = `0x03` (Instruction Set §3.1.1). The T
/// bank is the VM's single 16-cell volatile storage bank, shared across
/// frames, not part of any frame and not counted against the frame
/// budget; every `jal ra`/`jalr`/non-self tailcall logically clobbers it.
pub const temp_base: ValueReg = 0x03;

/// The T bank size: T0–T15 (`0x03–0x12`), 16 registers.
pub const temp_count: u8 = 16;

/// The first F register: F0 = `0x13`. Frames occupy `0x13–0x7f` (109
/// encodings, exactly `frame_count_max`); the frame-relative index is
/// `r - frame_base`.
pub const frame_base: ValueReg = 0x13;

/// The fast-bank size: `zero` (0), `cond` (1), `ra` (2, a reserved
/// hole), T0–T15 (3–18) — every encoding below `frame_base` indexes
/// `[fast_reg_count]Value` directly. Equals `temp_base + temp_count`
/// and `frame_base` (the first F encoding).
pub const fast_reg_count: u8 = frame_base;

/// Root-frame saved-frame-base and saved-return-address sentinel, and
/// the "no index" sentinels (Instruction Set §2, spec §4.3).
pub const invalid_pc: u32 = 0xffffffff;
pub const no_index: u32 = 0xffffffff;

/// The union `construct` tag sentinel: `ConstructDesc.tag == no_tag`
/// for a struct, tuple, or list construction.
pub const no_tag: u32 = 0xffffffff;

/// An F frame register: `r >= frame_base` → `stack[fp + (r - frame_base)]`
/// (spec §3.1). The `0x80–0xff` encodings are invalid, never frames.
pub fn isFrame(r: u8) bool {
    return r >= frame_base and r < frame_base + frame_count_max;
}

/// The frame-relative index of an F register: `frameIndex(F0) == 0`,
/// `frameIndex(F108) == 108`. Only meaningful for `isFrame` registers.
pub fn frameIndex(r: u8) u8 {
    return r - frame_base;
}

/// The encoding of the frame register at logical index `i`:
/// `frameReg(0) == F0 == 0x13`. Valid for `i < frame_count_max`.
pub fn frameReg(i: u32) u32 {
    return @as(u32, frame_base) + i;
}

/// A T temp register: T0–T15 (`0x03–0x12`) → `fast_regs[r]` — the T
/// encodings index the fast bank directly, no subtraction.
pub fn isTemp(r: u8) bool {
    return r >= temp_base and r < temp_base + temp_count;
}

/// The T bank index of a T register: `tempIndex(0x03) == 0`,
/// `tempIndex(0x12) == 15`.
pub fn tempIndex(r: u8) u8 {
    return r - temp_base;
}

/// A special register: exactly `zero`, `ra`, or `cond` — every other
/// encoding is either an F/T register or an invalid register.
pub fn isSpecial(r: u8) bool {
    return r == zero_reg or r == ra_reg or r == cond_reg;
}

pub fn isZeroReg(v: ValueReg) bool {
    return v == zero_reg;
}

pub fn isRaReg(v: ValueReg) bool {
    return v == ra_reg;
}

pub fn isCondReg(v: ValueReg) bool {
    return v == cond_reg;
}

// ---------------------------------------------------------------------------
// Lifecycle value-states (Instruction Set §4) — the central ownership-mode
// classification every stage shares.
// ---------------------------------------------------------------------------

/// The ownership mode of one LLIR value-state. Types and ownership are
/// value-state, never bank/slot properties: any F/T/X cell may hold any
/// mode.
pub const OwnMode = enum {
    plain,
    counted,
    unique,
    borrowed,
};

/// The lifecycle mode of `t`. Borrowed is never inferred here — it is a
/// property of the *value* (its defining op), not of the type.
pub fn modeOf(t: cfg.Type) OwnMode {
    return switch (t) {
        .primitive => |k| switch (k) {
            .str => .counted,
            .any, .hostdata => .unique,
            else => .plain,
        },
        .list, .box => .counted,
        // Deferred or aggregate source-unique shapes: the frontend
        // expanded every statically-expandable destruction, so what
        // survives here destroys via `drop` + DropDesc.
        else => .unique,
    };
}

// ---------------------------------------------------------------------------
// Target arithmetic (Instruction Set §10, §11)
// ---------------------------------------------------------------------------

/// Decode a B-type branch target: `pc + signExtend10(offs10)` (reach
/// `[-512, 511]` at instruction granularity).
pub fn bTypeTarget(pc: u32, offs10: i16) u32 {
    return pc +% @as(u32, @bitCast(@as(i32, offs10)));
}

/// Decode a `jal` target: `pc + signExtend20(imm20)` (reach
/// `[-524288, 524287]`).
pub fn jalTarget(pc: u32, imm20: i32) u32 {
    return pc +% @as(u32, @bitCast(imm20));
}

/// Decode a `switch` arm target: `pc + target` — the arm's signed
/// 32-bit offset from the `switch` instruction's own `pc` (reach ±2³¹,
/// the full index space; Instruction Set §11–§12).
pub fn switchArmTarget(pc: u32, offs: i32) u32 {
    return pc +% @as(u32, @bitCast(offs));
}

/// Decode a `jr`/`jalr` target: `base + signExtend16(offs16)` — the
/// base register holds a dynamic instruction index (the runtime pc is a
/// host word; the 16-bit offset is fully effective on both 32-bit and
/// 64-bit hosts).
pub fn jrTarget(base: u64, offs16: i16) u64 {
    return base +% @as(u64, @bitCast(@as(i64, offs16)));
}

/// Decode an `auipc` target: `pc + (signExtend20(imm20) << 12)` (reach
/// ±2³¹). On a 32-bit host the result truncates to `u32`.
pub fn auipcTarget(pc: u64, imm20: i32) u64 {
    return pc +% @as(u64, @bitCast(@as(i64, imm20) << 12));
}

/// The signed 10-bit offset of a B-type branch from `pc` to `target`,
/// or null when the target is out of reach.
pub fn fit10Signed(target: u32, pc: u32) ?i16 {
    const off: i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(pc));
    if (off < -512 or off > 511) return null;
    return @intCast(off);
}

/// The signed 20-bit offset of a `jal` from `pc` to `target`, or null
/// when out of reach.
pub fn fit20Signed(target: u32, pc: u32) ?i32 {
    const off: i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(pc));
    if (off < -524288 or off > 524287) return null;
    return off;
}

/// The signed 16-bit offset of a `jr`/`jalr` from its base register to
/// `target`, or null when out of reach.
pub fn fit16Signed(base: u64, target: u64) ?i16 {
    const off: i64 = @as(i64, @intCast(target)) - @as(i64, @intCast(base));
    if (off < -32768 or off > 32767) return null;
    return @intCast(off);
}

// ---------------------------------------------------------------------------
// Move-wide lane arithmetic (Instruction Set §6) — the shared shift/mask
// computations of the twelve move-wide opcodes.
// ---------------------------------------------------------------------------

/// The lane shift of move-wide suffix `n` (0–3): `S = n * 16`.
pub fn movwLaneShift(n: u2) u6 {
    return @as(u6, n) * 16;
}

/// The lane mask of move-wide suffix `n`: `M = 0xffff << S`.
pub fn movwLaneMask(n: u2) u64 {
    return @as(u64, 0xffff) << movwLaneShift(n);
}

/// The `movwzN` result: `H = zeroExtend64(imm16) << S`.
pub fn movwzValue(n: u2, imm: u16) u64 {
    return @as(u64, imm) << movwLaneShift(n);
}

/// The `movwnN` result: `~H`.
pub fn movwnValue(n: u2, imm: u16) u64 {
    return ~movwzValue(n, imm);
}

/// The `movwkN` result: `(dst & ~M) | H`.
pub fn movwkValue(n: u2, imm: u16, dst: u64) u64 {
    return (dst & ~movwLaneMask(n)) | movwzValue(n, imm);
}

/// Dense, program-local ID spaces (spec §2). Each ID is the index of its
/// row in the corresponding flat side table. The inline reference width
/// is per-opcode — 16-bit in I format (`imm16`), 7-bit in R format —
/// while the table indexes themselves stay `u32` (Instruction Set §2).
pub const FunctionId = u32;
pub const BlockId = u32;
pub const TypeId = u32;
pub const ConstId = u32;
pub const SignatureId = u32;
pub const HostTypeId = u32;
pub const SlotId = u32;
pub const SyscallDescId = u32;
pub const ConstructDescId = u32;
pub const DestructureDescId = u32;
pub const SwitchDescId = u32;

/// Symbolic cross-module identity (spec §2): a `SymbolId` indexes the
/// artifact's `symbols` table; its bytes are a canonical module specifier
/// or an exact member name, compared byte-exactly. Module-internal
/// entities keep their dense local ids — only cross-module identity is
/// symbolic.

// ---------------------------------------------------------------------------
// 5. Frames and calls (spec §4, §5)
// ---------------------------------------------------------------------------

/// The fixed three-cell frame header immediately before `fp` (spec §4.3):
/// `headerBase(fp) = fp - 3`, cells the caller's saved frame base
/// `saved_fp`, the caller's function registry index `saved_fn` (VM-side,
/// so `ret` restores the interpreter's current-function cache in O(1)),
/// and the current callee's saved return address `saved_ra`.
/// The root header carries `invalid_pc` in all three cells, distinguished by
/// position; it is a VM setup detail, never a LLIR operand. `ret` reads
/// the header at `fp - 3` to restore the caller
/// (`fp = saved_fp`, `ra = saved_ra`).
pub const CallHeader = struct {
    saved_fp: u32,
    saved_fn: u32,
    saved_ra: u32,
};

/// One function: its absolute code range, signature, module, and the
/// static frame layout numbers (spec §4.1). There are no per-slot
/// types, scratch bank, or cleanup cells — every F/X cell holds the
/// same host-word `Value` representation and the exact types ride in
/// the opcodes' reps and the descriptor-carried types.
///
/// ```text
/// [fp - 3, fp)              incoming header (root uses sentinels)
/// [fp, fp + F)              F-addressable cells        (f_count <= 109)
/// [fp + F, fp + F + X)      X spill cells              (imm16 addressing)
/// [fp + F + X, sp)          outgoing call area         (window_count)
/// ```
/// `f_count` covers the parameters (`F0..F(P-1)` alias the caller's
/// window at entry); `x_count <= 65536` so `spill_take`/`spill_put`'s
/// `imm16` addresses every X cell; `window_count` is the outgoing call
/// area — max over call sites of `3 + A` where `A = max(parameter_count,
/// result_count)` (the value area plus the three header cells the callee
/// writes below it).
pub const FunctionDesc = struct {
    code_start: u32,
    code_end: u32,
    entry_pc: u32,
    signature_id: SignatureId,
    /// Directly addressable F cells (u16 per spec §4.1; <= 109).
    f_count: u16,
    /// Spill cells addressed by `spill_take`/`spill_put`'s imm16
    /// (<= 65536).
    x_count: u32,
    /// Outgoing call-area cells: max over call sites of `3 + A`.
    window_count: u16,
};

/// One basic block: its absolute half-open instruction range (spec §2).
/// Branches target absolute PCs, not block IDs; `BlockDesc` exists for
/// validation (targets must be block starts inside the current function)
/// and diagnostics.
pub const BlockDesc = struct {
    start_pc: u32,
    end_pc: u32,
};

/// Frame arithmetic (spec §4.1): all pure, so the call/ret/tailcall
/// contract is testable without an interpreter.
pub fn headerBase(fp: u32) u32 {
    return fp - 3;
}

/// The first stack cell past this function's frame cells: the base of
/// its outgoing call area — `fp + f_count + x_count` (spec §4.1).
pub fn callBase(fp: u32, f: FunctionDesc) u32 {
    return fp + @as(u32, f.f_count) + f.x_count;
}

/// The first stack cell past the whole reserved region:
/// `call_base + window_count`. A call sets the callee `fp` to
/// `sp - A`, inside the caller's window.
pub fn frameEnd(fp: u32, f: FunctionDesc) u32 {
    return callBase(fp, f) + f.window_count;
}

/// A call sets the callee `fp` to `sp - A` (spec §5.3): the callee's
/// parameter registers `F0..F(P-1)` alias the caller's outgoing-window
/// top `A` cells, written by `slot_*` records. The header lands at
/// `[fp_callee - 3, fp_callee)`, three cells below the window, inside the
/// caller's reserved window region.
pub fn calleeFrameStart(sp: u32, value_area: u32) u32 {
    return sp - value_area;
}

/// The callee frame's end, from the caller's `sp` (spec §4.1).
pub fn calleeFrameEnd(sp: u32, callee: FunctionDesc, value_area: u32) u32 {
    return frameEnd(calleeFrameStart(sp, value_area), callee);
}

/// O — the output-window cell count (spec §4.1): the outgoing window
/// minus its three-cell header reserve. Zero for a leaf (`window_count`
/// 0); a caller's window always carries at least the three header cells,
/// so `O = window_count - 3`. A forged window of 1–3 cells yields 0 (a
/// call whose `A >= 1` is then rejected by `A <= outCount`).
pub fn outCount(f: FunctionDesc) u32 {
    if (f.window_count <= 3) return 0;
    return f.window_count - 3;
}

/// The register-addressable count — `L + 3 + O = f_count +
/// window_count` (spec §4.1). The last `window_count` logical frame
/// indexes are the window aliases: the three-cell header reserve followed
/// by the `O` output aliases. A leaf (`window_count` 0) has no aliases,
/// so its register space is exactly its F bank. The budget `regCount <=
/// 109` keeps every frame encoding below `0x80` (enforced by the frame
/// check in Step 6).
pub fn regCount(f: FunctionDesc) u32 {
    return @as(u32, f.f_count) + f.window_count;
}

/// The register encoding of output-window alias `O(i)`
/// (spec §4.1): `F(L + 3 + i)`, the output alias immediately after the
/// header reserve. Valid for `i < outCount(f)`. Returns the *encoding*,
/// `frame_base + logical index`.
pub fn outReg(f: FunctionDesc, i: u32) u32 {
    return frameReg(@as(u32, f.f_count) + 3 + i);
}

/// The physical stack cell of register operand `reg` in the frame at
/// `fp` (spec §4.1): locals `F(reg) = fp + frameIndex(reg)` for
/// `frameIndex(reg) < f_count`; the window aliases
/// `F(reg) = callBase(fp, f) + (frameIndex(reg) - f_count)` for
/// `frameIndex(reg) >= f_count` — equivalently `fp + x_count +
/// frameIndex(reg)` (the X cells are never register-addressed). The
/// result alias of a non-void call, `outReg(f, outCount(f) - a)`,
/// resolves to the top cell of the window's value area — the cell the
/// callee's `ret` publishes into.
pub fn frameCell(fp: u32, f: FunctionDesc, reg: u32) u32 {
    const i = reg - @as(u32, frame_base);
    if (i >= f.f_count) return fp + f.x_count + i;
    return fp + i;
}

/// The unique function containing `pc`, from its `[code_start, code_end)`
/// range, or null when `pc` lies outside every range (spec §2). Ranges
/// must be non-overlapping and cover the whole instruction space; the
/// validator checks that.
pub fn functionAtPc(functions: []const FunctionDesc, pc: u32) ?FunctionId {
    for (functions, 0..) |f, i| {
        if (pc >= f.code_start and pc < f.code_end) return @intCast(i);
    }
    return null;
}

// ---------------------------------------------------------------------------
// 6. Descriptors (spec §2, Instruction Set §12) — variable-length operands stay atomic
// ---------------------------------------------------------------------------

/// A system call: the host binding target, its specialized signature, and
/// its argument registers (read from the current frame; a syscall never
/// changes frames, spec §7). `host_binding_id` is the `ImportDesc` index
/// of the `(module_symbol, member_symbol)` host pair.
pub const SyscallDesc = struct {
    host_binding_id: u32,
    signature_id: SignatureId,
    args_start: u32,
    args_len: u32,
};

/// A union construction carries its discriminant; `tag == no_tag` for
/// struct/tuple/list constructions (the kind is the destination's type).
/// `result_type` carries the constructed value's `TypeId` — the VM and
/// validator read the result type here, never from a slot table.
pub const ConstructDesc = struct {
    tag: u32,
    args_start: u32,
    args_len: u32,
    result_type: TypeId,
};

/// Which shape a destructure descriptor names (Instruction Set §12). The
/// opcode must match the descriptor's kind — `unpack_struct` requires
/// `.struct`, `unpack_tuple` `.tuple`, `unpack_variant` and
/// `borrow_variant` `.variant`, `split_list` `.list`.
pub const DestructureKind = enum(u32) {
    struct_,
    tuple,
    variant,
    list,
};

/// One multi-result destructure: the result slots, in result order,
/// selected from the flat `destructure_dsts` table (registers) with the
/// parallel `destructure_dst_types` rows giving each result's `TypeId`.
/// `base_type` carries the consumed base's `TypeId`;
/// `borrow_variant` results are borrowed views of these same types.
pub const DestructureDesc = struct {
    kind: DestructureKind,
    base_type: TypeId,
    dsts_start: u32,
    dsts_len: u32,
};

/// One member/field access record (Instruction Set §13): the accessed
/// object's base TypeId (`no_index` for the write-only `store_member`),
/// the result's TypeId (for `store_member`, the stored value's type),
/// and the reference — `load_member`'s dense `MemberId`,
/// `store_member`'s `SlotId`, or `read_field` / `read_tuple` /
/// `read_payload`'s field/index. The VM reads layout from this row; it
/// never consults a slot-type table.
pub const MemberDesc = struct {
    base_type: TypeId,
    type_: TypeId,
    ref: u32,
};

/// The static destruction descriptor of one residual `drop` (Instruction
/// Set §6): exactly one of `type_` / `host_type_` is set, the other
/// `no_index`. A typed drop destroys an `any` value by its runtime
/// tag; a host drop dispatches the host-backed opaque type's
/// destructor through `host_types[host_type_]`. Counted owners never
/// reach `drop` — they `release`.
pub const DropDesc = struct {
    type_: TypeId,
    host_type_: HostTypeId,
};

/// One `switch` arm: a tag and its target, a **signed offset relative
/// to the `switch` instruction's own `pc`** — the signed difference in
/// instruction indexes (the decoded target is `pc + target`, Instruction
/// Set §11), the same convention as `jal`/B-type branches. The arm's
/// tags must be unique (validator); an unmatched tag traps (the implicit
/// default, Instruction Set §6). The lowering emits one descriptor per
/// `switch` — identical targets at different pcs encode different
/// offsets, so arm interning is invalid (Instruction Set §12).
pub const SwitchArm = struct {
    tag: u32,
    target: i32,
};

/// A `switch` descriptor: its arms from the flat `switch_arms` table.
pub const SwitchDesc = struct {
    arms_start: u32,
    arms_len: u32,
};

// ---------------------------------------------------------------------------
// 7. Side-table records (spec §2, Instruction Set §13) — fixed-width, no pointers/names
// ---------------------------------------------------------------------------

/// The payload kind of a constant. `int` carries an `i64` (`a` low, `b`
/// high words); sign and width come from `type_`. `string` indexes
/// `strings` with `{ a: start, b: len }`. Every constant names its
/// `TypeId` — the source for the destination cell's exact type (there is
/// no slot-type table to consult).
pub const ConstKind = enum(u32) { int, float, bool, string, void };
pub const ConstRecord = struct {
    kind: ConstKind,
    type_: TypeId,
    a: u32,
    b: u32,
};

/// The primitive type IDs of the LLIR type table (Instruction Set §13).
pub const PrimitiveId = enum(u32) {
    byte,
    bool,
    int32,
    uint32,
    float32,
    str,
    any,
    hostdata,
    /// 64-bit widths appended after the v1 set: serialized values of
    /// the existing rows never change.
    i64,
    u64,
    f64,
};

/// The kind of one `TypeDesc` row.
pub const TypeKind = enum(u32) {
    primitive,
    named,
    list,
    box,
    tuple,
    function,
    module,
    cleanup,
};

/// One serialized `cfg.Type` (spec §2, Instruction Set §13):
/// - `.primitive`: `a` = `PrimitiveId`;
/// - `.named`: `a` = declaration `TypeId`, `{ b, c }` = type-argument
///   range into `types`;
/// - `.list` / `.box`: `a` = element `TypeId`;
/// - `.tuple`: `{ a, b }` = element range into `types`;
/// - `.function`: `a` = `SignatureId`;
/// - `.module` / `.cleanup`: fields unused.
pub const TypeDesc = struct {
    kind: TypeKind,
    a: u32,
    b: u32,
    c: u32,
};

/// The kind of one `TypeDeclDesc` row — a serialized `cfg.TypeDecl`
/// (air.md §9.1): the concrete layout, ownership, and destruction info a
/// backend needs for `construct` / `unpack_*` / `drop`, without the
/// source module graph.
pub const TypeDeclKind = enum(u32) { struct_, union_, opaque_ };

/// One serialized `cfg.TypeDecl`:
/// - `.struct_`: `a` = ownership (`OwnershipId`), `b` = drop-hook local
///   `FunctionId` or `no_index`, `{ c, d }` = field-type range into
///   `type_decl_fields`, `e` = `ImportDesc` index of an imported drop
///   hook or `no_index` (at most one of `b`/`e` is set);
/// - `.union_`: `a` = ownership, `{ b, c }` = variant range into
///   `union_variants`, `d`/`e` unused;
/// - `.opaque`: `a` = `HostTypeId` (dense index into `host_types`).
pub const TypeDeclDesc = struct {
    kind: TypeDeclKind,
    a: u32,
    b: u32,
    c: u32,
    d: u32,
    e: u32,
};

/// The host identity behind an opaque nominal type (Instruction Set §13,
/// Runtime §3): the declaring host module's canonical symbol plus the
/// written type name — both `{start, len}` ranges into the `strings`
/// blob, never numeric module ids.
pub const HostTypeDesc = struct {
    host_start: u32,
    host_len: u32,
    name_start: u32,
    name_len: u32,
};

/// One union variant of a `TypeDeclDesc`: its payload types from the
/// flat `union_payloads` table (names are non-semantic).
pub const UnionVariant = struct {
    payloads_start: u32,
    payloads_len: u32,
};

/// A function signature: parameter rows from the flat `params` table and
/// the result type (Instruction Set §13). Modes are the *declared* parameter
/// modes — `plain | borrow | move` — preserved so indirect signature
/// equality is exact; the runtime derives transfer behavior for `plain`
/// from the parameter type's ownership.
pub const ParamMode = enum(u32) { plain, borrow, move };
pub const SignatureDesc = struct {
    params_start: u32,
    params_len: u32,
    ret: TypeId,
};
pub const ParamDesc = struct {
    mode: ParamMode,
    type_: TypeId,
};

/// Symbolic cross-module linkage (spec §2, Instruction Set §13). Only
/// cross-module identity is symbolic; module-internal entities stay
/// dense local ids.
///
/// A `SymbolId` resolves through `symbols` to a canonical module
/// specifier or an exact member name. An `ImportDesc` is a
/// `(module_symbol, member_symbol)` pair — a cross-module member,
/// function, module, or host reference; a module-only import (a
/// `module_ref` target other than the artifact's own module) sets
/// `member_sym = no_index`. The sorted `exports` table holds the
/// module's public members plus every function, keyed by symbol.
pub const SymbolId = u32;
pub const SymRange = struct {
    start: u32,
    len: u32,
};
pub const ImportDesc = struct {
    module_sym: SymbolId,
    member_sym: SymbolId,
};
pub const ExportKind = enum(u32) { const_slot, function, nested_module, host_binding };
pub const ExportDesc = struct {
    member_sym: SymbolId,
    kind: ExportKind,
    /// Per kind: a `SlotId`, a local `FunctionId`, a `SymbolId`
    /// (nested module), or unused (`host_binding`).
    ref: u32,
    /// 1 when the row is a declared member (a `load_member` may
    /// resolve it); 0 for non-member function rows.
    public: u32,
};

/// One constant slot of a module (Runtime §2.5): its teardown type.
pub const ModuleSlot = struct {
    type_: TypeId,
};

// ---------------------------------------------------------------------------
// 8. The program image (spec §2)
// ---------------------------------------------------------------------------

/// The read-only backend artifact of **one module** (spec §2): its
/// instruction array plus typed flat side tables. No table row contains a
/// pointer, slice, or name; strings index the artifact-owned `strings`
/// blob with `{ start, len }` records. Cross-module identity is symbolic
/// (`self_symbol` / `symbols` / `imports` / `exports`) — there is no
/// program-global module/member/host-binding table. **`call_descs` is
/// removed** — direct calls are `jal ra` and indirect calls `jalr`,
/// neither referencing a call descriptor.
pub const LlirProgram = struct {
    instructions: []const Instr,
    functions: []const FunctionDesc,
    blocks: []const BlockDesc,
    /// This module's canonical symbol, its init function (local
    /// `FunctionId`, `no_index` when absent), and the symbolic entry
    /// member (`no_index` when the artifact has no entry — every
    /// non-root artifact).
    self_symbol: u32,
    init: u32,
    entry_member: u32,
    /// Symbolic linkage: the `SymbolId` table, the sorted
    /// `(module_symbol, member_symbol)` imports, and the sorted export
    /// table (public members plus every function).
    symbols: []const SymRange,
    imports: []const ImportDesc,
    exports: []const ExportDesc,
    /// This module's constant slots (Runtime §2.5).
    module_slots: []const ModuleSlot,
    constants: []const ConstRecord,
    types: []const TypeDesc,
    type_decls: []const TypeDeclDesc,
    type_decl_fields: []const TypeId,
    union_variants: []const UnionVariant,
    union_payloads: []const TypeId,
    host_types: []const HostTypeDesc,
    signatures: []const SignatureDesc,
    params: []const ParamDesc,
    call_args: []const ValueReg,
    syscall_descs: []const SyscallDesc,
    construct_descs: []const ConstructDesc,
    destructure_dsts: []const ValueReg,
    /// Parallel to `destructure_dsts`: each result's `TypeId`, in the
    /// same result order.
    destructure_dst_types: []const TypeId,
    destructure_descs: []const DestructureDesc,
    switch_arms: []const SwitchArm,
    switch_descs: []const SwitchDesc,
    member_descs: []const MemberDesc,
    drop_descs: []const DropDesc,
    strings: []const u8,
};
// ---------------------------------------------------------------------------
// 9. Field-level schema checks (Instruction Set §14 — the load-time
//    structural boundary; the full structural validator is phase 3)
// ---------------------------------------------------------------------------

/// A field-level schema violation.
pub const Issue = enum {
    /// Not an assigned opcode value (reserved class/code, alignment hole,
    /// nonzero C/E reserved field).
    unknown_opcode,
    /// A register-role field is neither a valid slot, a T register,
    /// nor a special register — including reserved encodings and
    /// out-of-frame slots.
    bad_register,
    /// A special register in a field whose schema forbids it — `ra`
    /// outside a `jal` link or `jalr` token, `cond` outside its schema
    /// positions, `zero` in a real-slot position.
    special_forbidden,
    /// An immediate exceeds its opcode's bound (`tbz`/`tbnz` bit ≥ 64).
    imm_out_of_range,
    /// A `none`-role field must be 0.
    nonzero_field,
    /// The frame's slot count is too large for the F register space
    /// (spec §3.1: `count <= frame_count_max`, 109 slots `0x13–0x7f`).
    frame_too_big,
};

/// Check a function's register budget (v10, spec §4.1): the whole
/// register-addressable span — locals `L` plus the window `W = 2 + O`
/// (header reserve + output window) — must fit the F bank
/// (`L + 3 + O <= 109`) so no frame register encoding can leave the
/// `0x13–0x7f` range. X cells are imm16-addressed and never collide;
/// they stay excluded from the check.
pub fn checkFrameSlots(value_slots: u32, window_count: u32) ?Issue {
    if (value_slots > frame_count_max) return .frame_too_big;
    if (value_slots + window_count > frame_count_max) return .frame_too_big;
    return null;
}

/// A register operand `v` is legal when it names a frame cell or
/// window alias below `reg_count` (`f_count + window_count`), a T
/// register, or — when allowed — `zero`. `reg_count <= 109` keeps every
/// F/O encoding below `0x80`.
fn validOperand(v: u8, reg_count: u32, allow_zero: bool) bool {
    if (isFrame(v) and frameIndex(v) < reg_count) return true; // F slot or O window alias
    if (isTemp(v)) return true;
    return allow_zero and v == zero_reg;
}

fn checkField(f: Field, v: u8, reg_count: u32) ?Issue {
    return switch (f) {
        .dst, .src, .dst_u => if (validOperand(v, reg_count, true)) null else .bad_register,
        .dst_real, .dst_movw, .src_real, .tested => if (validOperand(v, reg_count, false)) null else .bad_register,
        .src_f => if (isFrame(v) and frameIndex(v) < reg_count) null else .bad_register,
        .src_t => if (isTemp(v)) null else .bad_register,
        .link => if (v == ra_reg) null else .bad_register,
        .cond => if (validOperand(v, reg_count, true) or isCondReg(v)) null else .bad_register,
        .none => if (v != 0) .nonzero_field else null,
        .imm, .mask, .offs10, .imm16, .offs16, .imm20, .id => null, // range checks are the validator's
    };
}

/// Field-level schema check of one instruction. `reg_count` is the
/// current function's register-addressable count
/// `f_count + window_count` (spec §4.1): F cells `< f_count` and the
/// window aliases `[f_count, f_count + window_count)` (logical frame
/// indexes; the encodings add `frame_base`). X cells are only
/// ever named by `spill_take`/`spill_put`'s imm16 and outgoing-window
/// cells by `slot_*`'s imm16, so neither can appear in a register
/// field. Table-range checks for id/imm fields and target-PC checks
/// are the structural validator's job.
pub fn checkInstr(instr: Instr, reg_count: u32) ?Issue {
    const d = decode(instr) orelse return .unknown_opcode;
    // `j`'s schema lives entirely in decode: prefix `11101` admits only
    // the no-link `zero` form (this opcode) and `ra` (`jal`), the rest of
    // the word being the imm20 offset.
    if (d.op == .j) return null;
    const info = opInfo(d.op);
    return checkField(info.a, d.a, reg_count) orelse
        checkField(info.b, d.b, reg_count) orelse
        checkField(info.c, d.c, reg_count) orelse
        switch (d.op) {
            .tbz, .tbnz => if (d.b > 63) .imm_out_of_range else null,
            else => null,
        };
}

/// Generic `{ start, len }` range check against a table's length.
pub fn checkRange(start: u32, len: u32, table_len: u32) ?DescIssue {
    if (start > 0xffffffff - len) return .range_overflow;
    if (start + len > table_len) return .range_oob;
    return null;
}

/// A descriptor-level violation (kind mismatch or range error).
pub const DescIssue = enum {
    /// The opcode and the descriptor kind disagree.
    kind_mismatch,
    /// A `{ start, len }` range falls outside its table.
    range_oob,
    /// `start + len` overflows `u32`.
    range_overflow,
};

// ---------------------------------------------------------------------------
// 10. CFG → LLIR lowering rules (Instruction Set §4–§9) — the schema-level
//     contract phase 2 implements. Every op and terminator of
//     `cfg.op_table` / `cfg.Terminator` has exactly one rule.
// ---------------------------------------------------------------------------

/// The typed-op families whose LLIR opcode is chosen by operand type.
pub const TypedKind = enum {
    add,
    sub,
    mul,
    div,
    rem,
    shl,
    shr,
    bitand,
    bitor,
    bitxor,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    neg,
    cast,
    abs,
    min,
    max,
    clz,
    popcount,
};

/// The composite rules a phase-2 pass expands.
pub const Composite = enum {
    /// `phi` → phi elimination: ordinary `copy`/`move`/`borrow`
    /// instructions on each predecessor edge, ordered so every source
    /// is read before its destination is written; a copy cycle breaks
    /// through one scratch slot.
    phi,
    /// `call` → `jal ra` (direct) or `jalr ra, base, offs16` (indirect)
    /// with the `slot_*` preparation records and the generic `take`.
    call,
    /// `select` → `copy cond, %cond` + `cmov dst, %a, %b`: load
    /// the bool condition into the condition register, then the
    /// branchless pattern move picks `%a` when set, `%b` otherwise.
    select,
};

/// How one CFG op lowers.
pub const Lowering = union(enum) {
    /// A single LLIR opcode with the same name.
    direct: Opcode,
    /// One of the type-specialized opcodes, resolved by `typedOpcode`
    /// from the operand (and, for `cast`, result) type.
    typed: TypedKind,
    /// Expanded by a phase-2 lowering rule.
    composite: Composite,
    /// v1 lifecycle token: the cleanup_arm/disarm/drop trio never
    /// reaches the image.
    cleanup_token,
};

/// The lowering rule for every executable op. Exhaustive over
/// `cfg.OpTag`: adding a CFG op without a rule here is a compile error.
pub fn lower(tag: cfg.OpTag) Lowering {
    return switch (tag) {
        .const_ => .{ .direct = .const_ },
        .module_ref => .{ .direct = .module_ref },
        .fn_ref => .{ .direct = .fn_ref },
        .neg => .{ .typed = .neg },
        .abs => .{ .typed = .abs },
        .clz => .{ .typed = .clz },
        .popcount => .{ .typed = .popcount },
        .not_ => .{ .direct = .not },
        .num_cast => .{ .typed = .cast },
        .type_is => .{ .direct = .type_is },
        .any_pack_copy => .{ .direct = .any_pack_copy },
        .any_pack_move => .{ .direct = .any_pack_move },
        .any_unpack_copy => .{ .direct = .any_unpack_copy },
        .any_unpack_move => .{ .direct = .any_unpack_move },
        .add => .{ .typed = .add },
        .sub => .{ .typed = .sub },
        .mul => .{ .typed = .mul },
        .div => .{ .typed = .div },
        .rem => .{ .typed = .rem },
        .min => .{ .typed = .min },
        .max => .{ .typed = .max },
        .shl => .{ .typed = .shl },
        .shr => .{ .typed = .shr },
        .bitand => .{ .typed = .bitand },
        .bitor => .{ .typed = .bitor },
        .bitxor => .{ .typed = .bitxor },
        .concat => .{ .direct = .concat },
        .eq => .{ .typed = .eq },
        .ne => .{ .typed = .ne },
        .lt => .{ .typed = .lt },
        .le => .{ .typed = .le },
        .gt => .{ .typed = .gt },
        .ge => .{ .typed = .ge },
        .copy => .{ .direct = .copy },
        .borrow => .{ .direct = .borrow },
        .move_ => .{ .direct = .move },
        .drop_ => .{ .direct = .drop },
        // v1: cleanup tokens never reach the image.
        .cleanup_arm => .cleanup_token,
        .cleanup_disarm => .cleanup_token,
        .cleanup_drop => .cleanup_token,
        .load_member => .{ .direct = .load_member },
        .store_member => .{ .direct = .store_member },
        .construct => .{ .direct = .construct },
        .read_field => .{ .direct = .read_field },
        .read_tuple => .{ .direct = .read_tuple },
        .read_index => .{ .direct = .read_index },
        .tail => .{ .direct = .tail },
        .unpack_struct => .{ .direct = .unpack_struct },
        .unpack_tuple => .{ .direct = .unpack_tuple },
        .unpack_variant => .{ .direct = .unpack_variant },
        .split_list => .{ .direct = .split_list },
        .read_tag => .{ .direct = .read_tag },
        .read_payload => .{ .direct = .read_payload },
        .borrow_variant => .{ .direct = .borrow_variant },
        .call => .{ .composite = .call },
        .syscall => .{ .direct = .syscall },
        .phi => .{ .composite = .phi },
        .select => .{ .composite = .select },
    };
}

/// The lowering rule for every terminator. A CFG `br` has no single
/// LLIR image — `emitControl` lowers it to a B-type compare-and-branch
/// plus a link-less `j`; a CFG `j` lowers to `.j`.
pub fn lowerTerminator(tag: std.meta.Tag(cfg.Terminator)) Opcode {
    return switch (tag) {
        .ret => .ret,
        .j => .j,
        .br => unreachable,
        .@"switch" => .switch_,
        .tailcall => .tailcall_self,
        .trap => .trap,
    };
}

/// The `Rep` of a primitive type, or null for a type with no rep
/// (byte/bool/str/any/hostdata and the non-primitives).
fn typeRep(t: cfg.Type) ?Rep {
    return switch (t) {
        .primitive => |k| switch (k) {
            .int32 => .i32,
            .uint32 => .u32,
            .i64 => .i64,
            .u64 => .u64,
            .float32 => .f32,
            .f64 => .f64,
            else => null,
        },
        else => null,
    };
}

/// The typed family member `<base>.<rep>` — comptime name lookup over
/// the canonical table, or null when the family has no such rep (e.g.
/// `abs.u32`, the unsigned identity, or any float immediate family).
fn famOp(comptime base: []const u8, rep: ?Rep) ?Opcode {
    const r = rep orelse return null;
    inline for (std.meta.tags(Opcode)) |op| {
        const info = opInfo(op);
        if (info.rep == r) {
            const dot = std.mem.indexOfScalar(u8, info.name, '.');
            if (dot) |d| {
                if (std.mem.eql(u8, info.name[0..d], base)) return op;
            }
        }
    }
    return null;
}

/// The widthless integer op or the float rep member for a family: the
/// integer-4 members collapsed to one opcode (`add` for every integer
/// type — the operand cells are canonical 64-bit values, so the width
/// no longer rides in the opcode); the float members keep their
/// `f32`/`f64` reps. `int_name` is the enum spelling (trailing
/// underscore for the keyword escapes `and_`/`or_`), `float_base` the
/// dotted family base (`add`), null for non-arithmetic types.
fn intOrFloat(comptime int_name: []const u8, comptime float_base: []const u8, t: cfg.Type) ?Opcode {
    return switch (t) {
        .primitive => |k| switch (k) {
            .int32, .uint32, .i64, .u64 => @field(Opcode, int_name),
            .float32, .f64 => famOp(float_base, typeRep(t)),
            else => null,
        },
        else => null,
    };
}

/// The signed/unsigned widthless pair of a family (compare/branch
/// style): the plain opcode on the signed types, the `u` form on the
/// unsigned ones, the float rep member for floats. `div`/`divu`,
/// `rem`/`remu`, `min`/`minu`, `max`/`maxu`, `shr`/`shru`.
fn signedOrUnsigned(comptime signed_name: []const u8, comptime unsigned_name: []const u8, comptime float_base: []const u8, t: cfg.Type) ?Opcode {
    return switch (t) {
        .primitive => |k| switch (k) {
            .int32, .i64 => @field(Opcode, signed_name),
            .uint32, .u64 => @field(Opcode, unsigned_name),
            .float32, .f64 => famOp(float_base, typeRep(t)),
            else => null,
        },
        else => null,
    };
}

/// The sign-agnostic bit-count families (`clz`, `popcount`): the count
/// is taken at the operand's width, so the unsigned integer types alias
/// the signed member of the same width (`clz.u32` → `clz.i32`). Null for
/// floats and non-primitives.
fn bitCountOp(comptime base: []const u8, t: cfg.Type) ?Opcode {
    return switch (t) {
        .primitive => |k| switch (k) {
            .int32, .uint32 => @field(Opcode, base ++ "_i32"),
            .i64, .u64 => @field(Opcode, base ++ "_i64"),
            else => null,
        },
        else => null,
    };
}

/// Resolve a typed family to its opcode for concrete operand types, or
/// null when the type has no such operation (e.g. `byte` arithmetic, or
/// `float32` `%`). `src` is the operand type; `dst` is used only for
/// `cast`, where it is the result type (the CFG's `num_cast` target).
/// Integer arithmetic is **widthless**: every integer type resolves to
/// the same opcode (`add` on `int32`/`uint32`/`i64`/`u64` alike — the
/// cells are canonical 64-bit values, so the operation is computed at
/// 64 bits and the lowering inserts the 32-bit canonicalization
/// (`sext32`/`zext32`) where the type demands it). The result-bits
/// families that distinguish signedness keep a compare/branch-style
/// pair: `div`/`divu`, `rem`/`remu`, `min`/`minu`, `max`/`maxu`,
/// `shr`/`shru`. Float width stays explicit in the rep suffix. The
/// E-type unary families (`neg`/`abs`/`clz`/`popcount`) keep their
/// full integer-4 + float-2 reps — they are width-sensitive for the
/// result (`clz(0)` is 32 on `i32` vs 64 on `i64`, `popcount` counts
/// the extension bits, `neg`/`abs` wrap on the minimum).
/// Comparisons resolve to the C-Type `seq`/`sne`/`slt`/`sle` families
/// (the destination is the implicit `cond`); `sle` is the one float
/// non-strict ordering primitive (`a <= b` ≡ `sle a, b`, `a >= b` ≡
/// `sle b, a` — the swap preserves the NaN behavior), `sgt lhs, rhs` ≡
/// `slt rhs, lhs` is the strict swap alias, and integer `le`/`ge` are
/// synthesized as `not(slt)` by the lowering — so `typedOpcode(.gt, _)`
/// is null, and `typedOpcode(.le, _)`/`typedOpcode(.ge, _)` are null on
/// the integer reps.
pub fn typedOpcode(kind: TypedKind, src: cfg.Type, dst: cfg.Type) ?Opcode {
    return switch (kind) {
        .add => intOrFloat("add", "add", src),
        .sub => intOrFloat("sub", "sub", src),
        .mul => intOrFloat("mul", "mul", src),
        .div => signedOrUnsigned("div", "divu", "div", src),
        .rem => signedOrUnsigned("rem", "remu", "rem", src),
        .shl => intOrFloat("shl", "shl", src),
        .shr => signedOrUnsigned("shr", "shru", "shr", src),
        .bitand => intOrFloat("and_", "and", src),
        .bitor => intOrFloat("or_", "or", src),
        .bitxor => intOrFloat("xor", "xor", src),
        .min => signedOrUnsigned("min", "minu", "min", src),
        .max => signedOrUnsigned("max", "maxu", "max", src),
        .neg => intOrFloat("neg", "neg", src),
        .abs => famOp("abs", typeRep(src)),
        .clz => bitCountOp("clz", src),
        .popcount => bitCountOp("popcount", src),
        // C-Type comparisons: `seq`/`sne`/`slt`/`sle`, implicit cond.
        .eq => cmpFam("seq", src),
        .ne => cmpFam("sne", src),
        .lt => cmpFam("slt", src),
        .le => switch (src.primitive) {
            .float32, .f64 => famOp("sle", typeRep(src)),
            else => null,
        },
        .ge => switch (src.primitive) {
            .float32, .f64 => famOp("sle", typeRep(src)),
            else => null,
        },
        // Operand-swap alias: `a > b` ≡ `slt b, a` (swap preserves the
        // NaN behavior of every predicate).
        .gt => null,
        .cast => castOp(src, dst),
    };
}

/// Integer comparisons carry signedness but no width; float width remains
/// explicit. Scalar bool/string equality keeps its dedicated opcode.
fn cmpFam(comptime base: []const u8, src: cfg.Type) ?Opcode {
    const ordering = comptime std.mem.eql(u8, base, "slt");
    return switch (src) {
        .primitive => |k| switch (k) {
            .int32, .i64 => if (std.mem.eql(u8, base, "sle")) null else @field(Opcode, base),
            .uint32, .u64, .byte => if (std.mem.eql(u8, base, "sle")) null else @field(Opcode, if (ordering) base ++ "u" else base),
            .float32, .f64 => famOp(base, typeRep(src)),
            .bool => if (std.mem.eql(u8, base, "seq")) .bool_eq else if (std.mem.eql(u8, base, "sne")) .bool_ne else null,
            .str => if (std.mem.eql(u8, base, "seq")) .str_eq else if (std.mem.eql(u8, base, "sne")) .str_ne else null,
            else => null,
        },
        else => null,
    };
}

/// The v9 cast opcode for the Core §16.3 pair `(src, dst)`: the explicit
/// `cvt.<src>.<dst>` spellings over the seven cast types
/// `b, i32, u32, i64, u64, f32, f64` — the identity entries have no
/// opcode (null).
fn castOp(src: cfg.Type, dst: cfg.Type) ?Opcode {
    return switch (src) {
        .primitive => |ks| switch (dst) {
            .primitive => |kd| switch (ks) {
                .byte => switch (kd) {
                    .int32 => .cvt_b_i32,
                    .uint32 => .cvt_b_u32,
                    .i64 => .cvt_b_i64,
                    .u64 => .cvt_b_u64,
                    .float32 => .cvt_b_f32,
                    .f64 => .cvt_b_f64,
                    else => null,
                },
                .int32 => switch (kd) {
                    .byte => .cvt_i32_b,
                    .uint32 => .cvt_i32_u32,
                    .i64 => .cvt_i32_i64,
                    .u64 => .cvt_i32_u64,
                    .float32 => .cvt_i32_f32,
                    .f64 => .cvt_i32_f64,
                    else => null,
                },
                .uint32 => switch (kd) {
                    .byte => .cvt_u32_b,
                    .int32 => .cvt_u32_i32,
                    .i64 => .cvt_u32_i64,
                    .u64 => .cvt_u32_u64,
                    .float32 => .cvt_u32_f32,
                    .f64 => .cvt_u32_f64,
                    else => null,
                },
                .i64 => switch (kd) {
                    .byte => .cvt_i64_b,
                    .int32 => .cvt_i64_i32,
                    .uint32 => .cvt_i64_u32,
                    .u64 => .cvt_i64_u64,
                    .float32 => .cvt_i64_f32,
                    .f64 => .cvt_i64_f64,
                    else => null,
                },
                .u64 => switch (kd) {
                    .byte => .cvt_u64_b,
                    .int32 => .cvt_u64_i32,
                    .uint32 => .cvt_u64_u32,
                    .i64 => .cvt_u64_i64,
                    .float32 => .cvt_u64_f32,
                    .f64 => .cvt_u64_f64,
                    else => null,
                },
                .float32 => switch (kd) {
                    .byte => .cvt_f32_b,
                    .int32 => .cvt_f32_i32,
                    .uint32 => .cvt_f32_u32,
                    .i64 => .cvt_f32_i64,
                    .u64 => .cvt_f32_u64,
                    .f64 => .cvt_f32_f64,
                    else => null,
                },
                .f64 => switch (kd) {
                    .byte => .cvt_f64_b,
                    .int32 => .cvt_f64_i32,
                    .uint32 => .cvt_f64_u32,
                    .i64 => .cvt_f64_i64,
                    .u64 => .cvt_f64_u64,
                    .float32 => .cvt_f64_f32,
                    else => null,
                },
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

/// The immediate variant of a typed family (`dst = b op imm7`), or null
/// when the type has no such form. The integer immediate families are
/// integer-4 only (no float forms); comparison immediates are C-Type and
/// write `cond`; unary families have no immediate forms.
fn cmpImmOp(comptime base: []const u8, src: cfg.Type) ?Opcode {
    return switch (src) {
        .primitive => |k| switch (k) {
            .int32, .i64 => @field(Opcode, base),
            .uint32, .u64, .byte => @field(Opcode, base ++ "u"),
            else => null,
        },
        else => null,
    };
}

fn hasIntComparison(src: cfg.Type) bool {
    return switch (src) {
        .primitive => |k| k == .int32 or k == .uint32 or k == .i64 or k == .u64 or k == .byte,
        else => false,
    };
}

/// The immediate variant of a widthless integer family: the `u` form
/// (zero-extended imm7, window `[0, 127]`) on the unsigned types, the
/// plain form (sign-extended imm7, window `[-64, 63]`) on the signed
/// ones — compare/branch style (`slti`/`sltiu`, `blti`/`bltiu`).
/// `addi`/`addiu`, `subi`/`subiu`, `muli`/`muliu`, `divi`/`diviu`,
/// `remi`/`remiu`, `shri`/`shriu`. Floats have no immediate forms.
fn signedOrUnsignedImm(comptime signed_name: []const u8, comptime unsigned_name: []const u8, t: cfg.Type) ?Opcode {
    return switch (t) {
        .primitive => |k| switch (k) {
            .int32, .i64 => @field(Opcode, signed_name),
            .uint32, .u64 => @field(Opcode, unsigned_name),
            else => null,
        },
        else => null,
    };
}

/// The integer-only immediate form with a uniform zero-extended
/// immediate (shift counts and bitwise masks — a single opcode).
fn intImm(comptime name: []const u8, t: cfg.Type) ?Opcode {
    return switch (t) {
        .primitive => |k| switch (k) {
            .int32, .uint32, .i64, .u64 => @field(Opcode, name),
            else => null,
        },
        else => null,
    };
}

pub fn typedOpcodeImm(kind: TypedKind, src: cfg.Type) ?Opcode {
    return switch (kind) {
        .add => signedOrUnsignedImm("addi", "addiu", src),
        .sub => signedOrUnsignedImm("subi", "subiu", src),
        .mul => signedOrUnsignedImm("muli", "muliu", src),
        .div => signedOrUnsignedImm("divi", "diviu", src),
        .rem => signedOrUnsignedImm("remi", "remiu", src),
        .shl => intImm("shli", src),
        .shr => signedOrUnsignedImm("shri", "shriu", src),
        .bitand => intImm("andi", src),
        .bitor => intImm("ori", src),
        .bitxor => intImm("xori", src),
        .lt => cmpImmOp("slti", src),
        .gt => cmpImmOp("sgti", src),
        .eq => if (hasIntComparison(src)) .seqi else null,
        .ne => if (hasIntComparison(src)) .snei else null,
        .le, .neg, .cast, .abs, .min, .max, .clz, .popcount => null,
        .ge => cmpImmOp("sgti", src),
    };
}

/// The fused multiply-accumulate opcode for a type (`dst = dst + b *
/// c`): the widthless `madd` on the integer types, the float rep
/// member for floats; null for non-numeric types.
pub fn maddOpcode(src: cfg.Type) ?Opcode {
    return switch (src) {
        .primitive => |k| switch (k) {
            .int32, .uint32, .i64, .u64 => .madd,
            .float32, .f64 => famOp("madd", typeRep(src)),
            else => null,
        },
        else => null,
    };
}

/// The fused multiply-accumulate-immediate opcode (`dst = dst + b *
/// imm`), or null for non-numeric types. The imm7 interpretation
/// follows the type's signedness (`maddi` sign-extends on the signed
/// types, `maddiu` zero-extends on the unsigned ones). No float form —
/// the float immediate variants do not exist.
pub fn maddiOpcode(src: cfg.Type) ?Opcode {
    return switch (src) {
        .primitive => |k| switch (k) {
            .int32, .i64 => .maddi,
            .uint32, .u64 => .maddiu,
            else => null,
        },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests — white-box: the codec's own invariants (black-box pipeline tests
// live in frontend_llir_core_tests.zig).
// ---------------------------------------------------------------------------

test "Instr is exactly 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Instr));
}

test "codec: every assigned opcode round-trips through encode/decode" {
    // One representative word per opcode (fields chosen to exercise the
    // operand fields), decode(encode(op)) == op for every opcode.
    for (std.meta.tags(Opcode)) |op| {
        const info = opInfo(op);
        const a: u8 = @truncate((@as(u32, @intFromEnum(op)) * 7) & 0x7f);
        const b: u8 = @truncate((@as(u32, @intFromEnum(op)) * 11) & 0x7f);
        const c: u8 = @truncate((@as(u32, @intFromEnum(op)) * 13) & 0x7f);
        const instr = switch (info.format) {
            .r => instrR(op, a, b, c),
            .b => instrB(op, a, b, @intCast(c)),
            .i => instrI(op, a, @as(u16, b) | (@as(u16, c) << 8)),
            .c => instrC(op, a, b),
            .e => instrE(op, a, b),
            // Prefix-11101 words must carry their legal register values:
            // `j` the `zero` encoding, `jal`'s link exactly ra.
            .u => instrU(
                op,
                if (op == .j) zero_reg else if (op == .jal) ra_reg else a,
                @bitCast(@as(u32, b) | (@as(u32, c) << 8)),
            ),
        };
        const d = decode(instr) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(op, d.op);
        try std.testing.expectEqual(info.format, d.format);
        // Re-encoding the decoded fields reproduces the word.
        const again = switch (info.format) {
            .r => instrR(d.op, d.a, d.b, d.c),
            .b => instrB(d.op, d.a, d.b, d.offs10),
            .i => instrI(d.op, d.a, d.imm16),
            .c => instrC(d.op, d.a, d.b),
            .e => instrE(d.op, d.a, d.b),
            .u => instrU(d.op, d.a, d.imm20),
        };
        try std.testing.expectEqualSlices(u8, &instr, &again);
    }
}

test "codec: format counts match the frozen distribution (71/20/42/37/31/4)" {
    var counts = [_]u32{0} ** 6;
    for (std.meta.tags(Opcode)) |op| counts[@intFromEnum(formatOf(op))] += 1;
    try std.testing.expectEqual(@as(u32, 71), counts[@intFromEnum(Format.r)]);
    try std.testing.expectEqual(@as(u32, 20), counts[@intFromEnum(Format.b)]);
    try std.testing.expectEqual(@as(u32, 64), counts[@intFromEnum(Format.c)]);
    try std.testing.expectEqual(@as(u32, 37), counts[@intFromEnum(Format.e)]);
    try std.testing.expectEqual(@as(u32, 31), counts[@intFromEnum(Format.i)]);
    try std.testing.expectEqual(@as(u32, 4), counts[@intFromEnum(Format.u)]);
    // v10: `result_take` is deleted and the generic `take` closes the
    // E-type run, the integer `neg` collapsed to one widthless opcode,
    // and `clz`/`popcount` dropped their unsigned members — plus the
    // C-type 64-bit integer cast matrix — 227 logical
    // opcodes, values 1–234 (E slots 157–159 and 169/171/173/175 retired
    // unused).
    try std.testing.expectEqual(@as(usize, 227), std.meta.tags(Opcode).len);
}

test "codec: reserved class, reserved codes, reserved fields, and holes are rejected" {
    // The `10` reserved class.
    try std.testing.expectEqual(@as(?Decoded, null), decode(.{ 0, 0, 0, 0x80 }));
    // R-type codes 0–70 are all assigned; 71+ are reserved.
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf(@as(u32, 71) << 21)));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf(@as(u32, 149) << 21)));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf(@as(u32, 154) << 21)));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b01 << 30) | (50 << 24))));
    // E-type codes 6/7 are the 32-bit canonicalization pair
    // (sext32/zext32); 43 is the generic `take`.
    try std.testing.expectEqual(Opcode.sext32, decode(bytesOf((0b111001 << 26) | (6 << 20))).?.op);
    try std.testing.expectEqual(Opcode.zext32, decode(bytesOf((0b111001 << 26) | (7 << 20))).?.op);
    try std.testing.expectEqual(Opcode.take, decode(bytesOf((0b111001 << 26) | (43 << 20))).?.op);
    // clz/popcount keep the signed width selectors 12/14/16/18; the
    // retired unsigned codes 13/15/17/19 are rejected as holes.
    try std.testing.expectEqual(Opcode.clz_i32, decode(bytesOf((0b111001 << 26) | (12 << 20))).?.op);
    try std.testing.expectEqual(Opcode.clz_i64, decode(bytesOf((0b111001 << 26) | (14 << 20))).?.op);
    try std.testing.expectEqual(Opcode.popcount_i32, decode(bytesOf((0b111001 << 26) | (16 << 20))).?.op);
    try std.testing.expectEqual(Opcode.popcount_i64, decode(bytesOf((0b111001 << 26) | (18 << 20))).?.op);
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111001 << 26) | (13 << 20))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111001 << 26) | (15 << 20))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111001 << 26) | (17 << 20))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111001 << 26) | (19 << 20))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111001 << 26) | (44 << 20))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b110 << 29) | (32 << 23))));
    // The reserved I-type selector 10 (the former `result_take`) is
    // unassigned: v10 rejects it on its code alone.
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b110 << 29) | (10 << 23))));
    // The former E-selector-63 J-Type carve-out is gone: clean words at
    // selector 63 are unassigned and dirty ones fail the reserved-field
    // check. Prefix `11101` splits by register field: `ra` → `jal`,
    // `0` → `j`, any other register value rejected (Instruction Set §9.1).
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111001 << 26) | (63 << 20))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111001 << 26) | (63 << 20) | 0xffffc)));
    try std.testing.expectEqual(Opcode.jal, decode(bytesOf((0b11101 << 27) | (@as(u32, ra_reg) << 20) | 4)).?.op);
    try std.testing.expectEqual(Opcode.j, decode(bytesOf((0b11101 << 27) | (@as(u32, zero_reg) << 20) | 4)).?.op);
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b11101 << 27) | (@as(u32, cond_reg) << 20))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b11101 << 27) | (@as(u32, frame_base) << 20))));
    // Nonzero C/E reserved fields.
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111000 << 26) | (1 << 14))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b111001 << 26) | (1 << 14))));
    // Unassigned `11` prefixes.
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b100 << 29))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b101 << 29))));
    // Families are contiguous runs in table order: `add` = 1,
    // `add.f64` = 3, `sub` = 4 — the logical values 1–234 carry a
    // member at every index except the retired E-type slots 157–159 and
    // 169/171/173/175, and decode works through the dense code space.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Opcode.add));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Opcode.add_f64));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Opcode.sub));
    try std.testing.expectEqual(@as(usize, 227), std.meta.tags(Opcode).len);
}

test "codec: removed B-type codes are reserved; ble/bleu decode" {
    // The removed immediate branches left codes 28/29/32/33/36/37
    // reserved (B-type codes 0–19 are assigned, 20+ reserved). The
    // `ble`/`bleu` families own codes 10–13 (after the `blt` family's
    // 6–9).
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b01 << 30) | (28 << 24))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b01 << 30) | (29 << 24))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b01 << 30) | (32 << 24))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b01 << 30) | (33 << 24))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b01 << 30) | (36 << 24))));
    try std.testing.expectEqual(@as(?Decoded, null), decode(bytesOf((0b01 << 30) | (37 << 24))));
    try std.testing.expectEqual(Opcode.ble, decode(bytesOf((0b01 << 30) | (10 << 24))).?.op);
    try std.testing.expectEqual(Opcode.bleu, decode(bytesOf((0b01 << 30) | (11 << 24))).?.op);
    try std.testing.expectEqual(Opcode.ble_f32, decode(bytesOf((0b01 << 30) | (12 << 24))).?.op);
    try std.testing.expectEqual(Opcode.ble_f64, decode(bytesOf((0b01 << 30) | (13 << 24))).?.op);
}

test "codec: golden words from Instruction Set §16" {
    const G = struct {
        fn bytes(comptime w: u32) [4]u8 {
            return .{ @truncate(w), @truncate(w >> 8), @truncate(w >> 16), @truncate(w >> 24) };
        }
    };
    try std.testing.expectEqualSlices(u8, &G.bytes(0x00050a96), &instrR(.add, frame_base + 1, frame_base + 2, frame_base + 3));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xe10009ff), &instrC(.slti, frame_base, 0x7f));
    try std.testing.expectEqualSlices(u8, &G.bytes(0x522617ff), &instrB(.tbz, frame_base, 5, -1));
    try std.testing.expectEqualSlices(u8, &G.bytes(0x402857fe), &instrB(.beq, frame_base + 1, frame_base + 2, -2));
    try std.testing.expectEqualSlices(u8, &G.bytes(0x4e29fc00), &instrB(.blti, frame_base + 1, 0x7f, 0));
    try std.testing.expectEqualSlices(u8, &G.bytes(0x4f29fc00), &instrB(.bltiu, frame_base + 1, 0x7f, 0));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xe82fffff), &instrU(.jal, ra_reg, -1));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xe80ffffc), &instrJ(-4));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xc583ffff), &instrI(.jalr, temp_base, 0xffff));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xe1b00994), &instrC(.cvt_i32_u32, frame_base, frame_base + 1));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xe0000a15), &instrC(.seq, frame_base + 1, frame_base + 2));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xe4000994), &instrE(.neg, frame_base, frame_base + 1));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xe6800000), &instrE(.ret, 0, 0));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xf9300001), &instrU(.lui, frame_base, 1));
    try std.testing.expectEqualSlices(u8, &G.bytes(0xf13fffff), &instrU(.auipc, frame_base, -1));
    // And decode the golden words back to the named opcodes.
    try std.testing.expectEqual(Opcode.add, decode(instrR(.add, frame_base + 1, frame_base + 2, frame_base + 3)).?.op);
    try std.testing.expectEqual(Opcode.tbz, decode(instrB(.tbz, frame_base, 5, -1)).?.op);
    try std.testing.expectEqual(@as(i16, -1), decode(instrB(.tbz, frame_base, 5, -1)).?.offs10);
    try std.testing.expectEqual(Opcode.j, decode(instrJ(-4)).?.op);
    try std.testing.expectEqual(Format.u, decode(instrJ(-4)).?.format);
    try std.testing.expectEqual(@as(i32, -4), decode(instrJ(-4)).?.imm20);
    try std.testing.expectEqual(zero_reg, decode(instrJ(-4)).?.a);
    // …and the very same word with `ra` decodes as the call.
}

test "codec: sign extension — offs10, imm20, offs16, auipc << 12" {
    try std.testing.expectEqual(@as(u32, 600 - 512), bTypeTarget(600, -512));
    try std.testing.expectEqual(@as(u32, 100 + 511), bTypeTarget(100, 511));
    try std.testing.expectEqual(@as(u32, 524388 - 524288), jalTarget(524388, -524288));
    try std.testing.expectEqual(@as(u32, 100 + 524287), jalTarget(100, 524287));
    // switch arm: the i32 offset is a signed pc delta from the switch's
    // own pc (Instruction Set §11–§12) — backward arms are negative.
    try std.testing.expectEqual(@as(u32, 300 - 25), switchArmTarget(300, -25));
    try std.testing.expectEqual(@as(u32, 100 + 31), switchArmTarget(100, 31));
    try std.testing.expectEqual(@as(u32, 8), switchArmTarget(12, -4));
    try std.testing.expectEqual(@as(u64, 33768 - 32768), jrTarget(33768, -32768));
    try std.testing.expectEqual(@as(u64, 1000 + 32767), jrTarget(1000, 32767));
    // auipc: signExtend20(imm) << 12 — `auipc F0, 1` gives pc + 0x1000.
    try std.testing.expectEqual(@as(u64, 100 + 0x1000), auipcTarget(100, 1));
    try std.testing.expectEqual(@as(u64, 0x1000 + 100 - 0x1000), auipcTarget(0x1000 + 100, -1));
    // fit helpers: exact two's-complement intervals.
    try std.testing.expectEqual(@as(?i16, -512), fit10Signed(600 - 512, 600));
    try std.testing.expectEqual(@as(?i16, 511), fit10Signed(100 + 511, 100));
    try std.testing.expectEqual(@as(?i16, null), fit10Signed(100 + 512, 100));
    try std.testing.expectEqual(@as(?i32, null), fit20Signed(524389 - 524289, 524389));
    try std.testing.expectEqual(@as(?i16, null), fit16Signed(1000, 1000 + 32768));
}

test "register model: encodings, ranges, and decode helpers" {
    try std.testing.expectEqual(@as(ValueReg, 109), frame_count_max);
    try std.testing.expectEqual(@as(ValueReg, 0x00), zero_reg);
    try std.testing.expectEqual(@as(ValueReg, 0x01), cond_reg);
    try std.testing.expectEqual(@as(ValueReg, 0x02), ra_reg);
    try std.testing.expectEqual(@as(ValueReg, 0x03), temp_base);
    try std.testing.expectEqual(@as(u8, 16), temp_count);
    try std.testing.expectEqual(@as(ValueReg, 0x13), frame_base);
    // The fast bank is exactly the [0, frame_base) block: zero, cond,
    // ra (a reserved hole), T0–T15.
    try std.testing.expectEqual(@as(u8, 0x13), fast_reg_count);
    try std.testing.expectEqual(@as(u8, frame_base), fast_reg_count);
    // F0–F108 are the 0x13–0x7f encodings; 0x00/0x01/0x02 the specials;
    // 0x03–0x12 T; 0x80+ invalid.
    try std.testing.expect(!isFrame(0));
    try std.testing.expect(isFrame(frame_base));
    try std.testing.expect(isFrame(0x7f));
    try std.testing.expect(!isFrame(0x80));
    try std.testing.expectEqual(@as(u8, 0), frameIndex(frame_base));
    try std.testing.expectEqual(@as(u8, 108), frameIndex(0x7f));
    try std.testing.expectEqual(@as(u32, frame_base), frameReg(0));
    try std.testing.expectEqual(@as(u32, 0x7f), frameReg(108));
    try std.testing.expect(isTemp(temp_base));
    try std.testing.expect(isTemp(0x11));
    try std.testing.expect(isTemp(0x12)); // T15
    try std.testing.expect(!isTemp(0x02)); // ra
    try std.testing.expect(!isTemp(0x01));
    try std.testing.expect(!isTemp(frame_base));
    try std.testing.expectEqual(@as(u8, 0), tempIndex(temp_base));
    try std.testing.expectEqual(@as(u8, 15), tempIndex(0x12));
    try std.testing.expect(isSpecial(zero_reg));
    try std.testing.expect(isSpecial(ra_reg));
    try std.testing.expect(isSpecial(cond_reg));
    try std.testing.expect(!isSpecial(temp_base));
    try std.testing.expect(!isSpecial(frame_base));
    try std.testing.expect(!isSpecial(0x80));
}

test "frame arithmetic: three-cell header, window = 3 + A, slot-0 overlap" {
    // A caller with F=6, X=1, W=7 (largest call site A=4) — spec §4.1.
    const caller = FunctionDesc{ .code_start = 0, .code_end = 10, .entry_pc = 0, .signature_id = 0, .f_count = 6, .x_count = 1, .window_count = 7 };
    const fp: u32 = 100;
    try std.testing.expectEqual(@as(u32, 97), headerBase(fp));
    try std.testing.expectEqual(@as(u32, 107), callBase(fp, caller));
    try std.testing.expectEqual(@as(u32, 114), frameEnd(fp, caller));
    // A = 3 call: fp_callee = sp - 3, header at [sp-6, sp-3).
    const sp: u32 = 114;
    try std.testing.expectEqual(@as(u32, 111), calleeFrameStart(sp, 3));
    const callee = FunctionDesc{ .code_start = 0, .code_end = 20, .entry_pc = 0, .signature_id = 1, .f_count = 4, .x_count = 0, .window_count = 5 };
    try std.testing.expectEqual(@as(u32, 120), calleeFrameEnd(sp, callee, 3));
    // The three-cell header is 12 bytes.
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(CallHeader));
    const h = CallHeader{ .saved_fp = 100, .saved_fn = 2, .saved_ra = 42 };
    try std.testing.expectEqual(@as(u32, 100), h.saved_fp);
    try std.testing.expectEqual(@as(u32, 2), h.saved_fn);
    try std.testing.expectEqual(@as(u32, 42), h.saved_ra);
}

test "frame math: the call/ret contract from spec §5.3–§5.4" {
    // Caller C (F=6, X=1, W=7) calls the 3-parameter function F.
    const c = FunctionDesc{ .code_start = 0, .code_end = 10, .entry_pc = 0, .signature_id = 0, .f_count = 6, .x_count = 1, .window_count = 7 };
    const fp_c: u32 = 100;
    const sp_caller = frameEnd(fp_c, c);
    const A: u32 = 3;
    const fp_f = calleeFrameStart(sp_caller, A);
    try std.testing.expectEqual(@as(u32, 111), fp_f); // sp_caller - A
    try std.testing.expectEqual(@as(u32, 108), headerBase(fp_f)); // sp_caller - A - 3
    // ret: sp = fp_f + A = sp_caller; fp = saved_fp.
    try std.testing.expectEqual(sp_caller, fp_f + A);
    // The result slot is callee F0 = caller window cell W - A.
    try std.testing.expectEqual(@as(u32, 4), 7 - A);
}

test "alias arithmetic: O count, register count, outReg, and frameCell" {
    // Caller C (F=6, X=1, W=7) from the sibling tests.
    const c = FunctionDesc{ .code_start = 0, .code_end = 10, .entry_pc = 0, .signature_id = 0, .f_count = 6, .x_count = 1, .window_count = 7 };
    // O = W - 3 (the three header cells); regCount = L + 3 + O = L + W.
    try std.testing.expectEqual(@as(u32, 4), outCount(c));
    try std.testing.expectEqual(@as(u32, 13), regCount(c));
    // O(i) = F(L + 3 + i): the output aliases sit right after the header.
    // `outReg` returns the *encoding* (frame_base + logical index).
    try std.testing.expectEqual(@as(u32, frameReg(9)), outReg(c, 0));
    try std.testing.expectEqual(@as(u32, frameReg(12)), outReg(c, 3));
    try std.testing.expect(frameIndex(@intCast(outReg(c, 3))) < regCount(c));
    // frameCell: locals are fp + frameIndex(reg); window aliases skip the X
    // cells and resolve to callBase + (frameIndex(reg) - L) = fp + x_count
    // + frameIndex(reg).
    const fp: u32 = 100;
    try std.testing.expectEqual(@as(u32, 100), frameCell(fp, c, frame_base));
    try std.testing.expectEqual(@as(u32, 105), frameCell(fp, c, frameReg(5))); // last local F5
    try std.testing.expectEqual(callBase(fp, c), frameCell(fp, c, frameReg(6))); // F6 = header reserve = window base
    try std.testing.expectEqual(@as(u32, 107), frameCell(fp, c, frameReg(6)));
    // The result alias of the A=3 call — outReg(L+3+O-3) = outReg(1) = 10 —
    // is the callee fp (sp - 3), matching the sibling test's result slot.
    try std.testing.expectEqual(@as(u32, frameReg(10)), outReg(c, outCount(c) - 3));
    try std.testing.expectEqual(@as(u32, 111), frameCell(fp, c, outReg(c, outCount(c) - 3)));
    // A leaf has no window: O = 0 and the register space is exactly F.
    const leaf = FunctionDesc{ .code_start = 0, .code_end = 5, .entry_pc = 0, .signature_id = 0, .f_count = 8, .x_count = 2, .window_count = 0 };
    try std.testing.expectEqual(@as(u32, 0), outCount(leaf));
    try std.testing.expectEqual(@as(u32, 8), regCount(leaf));
    try std.testing.expectEqual(@as(u32, 107), frameCell(fp, leaf, frameReg(7))); // last local, before the X region
    // A forged window of 1–3 cells yields O = 0 (rejects any A >= 1 call).
    const forged = FunctionDesc{ .code_start = 0, .code_end = 5, .entry_pc = 0, .signature_id = 0, .f_count = 2, .x_count = 0, .window_count = 3 };
    try std.testing.expectEqual(@as(u32, 0), outCount(forged));
}

test "checkInstr: field-level register/special/none validation" {
    // A valid R add: dst F0, src F1, src zero.
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrR(.add, frame_base, frame_base + 1, zero_reg), 4));
    // Out-of-frame register (logical index 5 beyond the 4-slot frame).
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrR(.add, frame_base, frame_base + 1, @intCast(frameReg(5))), 4));
    // ra in a source position is rejected.
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrR(.add, frame_base, ra_reg, frame_base + 1), 4));
    // cond outside its schema positions.
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrR(.add, cond_reg, frame_base, frame_base + 1), 4));
    // borow/move require real slots.
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrE(.borrow, frame_base, zero_reg), 4));
    // ret's result source may be zero; its b must be zero.
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrE(.ret, zero_reg, 0), 4));
    try std.testing.expectEqual(Issue.nonzero_field, checkInstr(instrE(.ret, 0, 1), 4));
    try std.testing.expectEqual(Issue.nonzero_field, checkInstr(instrE(.trap, 1, 0), 4));
    // Prefix 11101 splits by register field: ra is `jal`, zero is `j`,
    // anything else is an unclean word rejected at decode (§9.1).
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrU(.jal, ra_reg, 4), 4));
    try std.testing.expectEqual(Issue.unknown_opcode, checkInstr(instrU(.jal, cond_reg, 4), 4));
    try std.testing.expectEqual(Issue.unknown_opcode, checkInstr(instrU(.jal, 5, 4), 4));
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrJ(4), 4));
    // auipc/lui dst: never ra or cond.
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrU(.lui, zero_reg, 1), 4));
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrU(.lui, ra_reg, 1), 4));
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrU(.auipc, cond_reg, 1), 4));
    // tbz bit index must be < 64.
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrB(.tbz, frame_base, 63, 1), 4));
    try std.testing.expectEqual(Issue.imm_out_of_range, checkInstr(instrB(.tbz, frame_base, 64, 1), 4));
    // movw dst: real F/T only.
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrI(.movwz0, temp_base, 1), 4));
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrI(.movwz0, zero_reg, 1), 4));
    // spill a: T only.
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrI(.spill_take, temp_base, 0), 4));
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrI(.spill_take, 0, 0), 4));
    // Unknown opcode (the `10` reserved class).
    try std.testing.expectEqual(Issue.unknown_opcode, checkInstr(.{ 0, 0, 0, 0x80 }, 4));
    try std.testing.expectEqual(Issue.frame_too_big, checkFrameSlots(110, 0));
    try std.testing.expectEqual(@as(?Issue, null), checkFrameSlots(109, 0));
    // v10 budget: the window counts against the same 109 —
    // `L + 3 + O <= 109` (`regCount = f_count + window_count`).
    try std.testing.expectEqual(Issue.frame_too_big, checkFrameSlots(108, 2)); // 108 + 2 = 110 > 109
    try std.testing.expectEqual(@as(?Issue, null), checkFrameSlots(107, 2)); // 109 exactly: the boundary
    try std.testing.expectEqual(@as(?Issue, null), checkFrameSlots(109, 0)); // O = 0: no calls, window unused
    // X stays excluded: a huge spill count never trips this check.
    try std.testing.expectEqual(@as(?Issue, null), checkFrameSlots(50, 2));
}

test "checkInstr: the O window aliases are legal register operands" {
    // A caller with L = 6, W = 7 has regCount = 13: F0-F5 locals, the
    // header reserve F6-F7, and O0..O4 (F8..F12) as output aliases.
    const reg_count: u32 = 13;
    // An add may read an O alias as a source/dst operand.
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrR(.add, frame_base, aliasEncoding(0), aliasEncoding(4)), reg_count));
    // move/borrow (dst_real/src_real) may name O aliases too.
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrE(.move, aliasEncoding(0), frame_base), reg_count));
    try std.testing.expectEqual(@as(?Issue, null), checkInstr(instrE(.borrow, aliasEncoding(4), aliasEncoding(1)), reg_count));
    // A register at exactly reg_count (its encoding) is still out of range.
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrR(.add, frame_base, frame_base + 1, @intCast(frameReg(reg_count))), reg_count));
    // Narrowing: with reg_count = 6 (a leaf), O aliases are rejected.
    try std.testing.expectEqual(Issue.bad_register, checkInstr(instrR(.add, frame_base, frame_base + 1, aliasEncoding(0)), 6));
}

fn aliasEncoding(i: u32) u8 {
    return @intCast(frameReg(8 + i)); // O(i) for the test's L=6, W=7 caller
}
test "typed opcodes resolve at every supported width (widthless integer schema)" {
    // Arithmetic: widthless on the integer types (the cells are
    // canonical 64-bit values), rep-suffixed on the floats.
    try std.testing.expectEqual(Opcode.add, typedOpcode(.add, .{ .primitive = .int32 }, undefined).?);
    try std.testing.expectEqual(Opcode.add, typedOpcode(.add, .{ .primitive = .uint32 }, undefined).?);
    try std.testing.expectEqual(Opcode.add, typedOpcode(.add, .{ .primitive = .i64 }, undefined).?);
    try std.testing.expectEqual(Opcode.add, typedOpcode(.add, .{ .primitive = .u64 }, undefined).?);
    try std.testing.expectEqual(Opcode.add_f32, typedOpcode(.add, .{ .primitive = .float32 }, undefined).?);
    try std.testing.expectEqual(Opcode.add_f64, typedOpcode(.add, .{ .primitive = .f64 }, undefined).?);
    // Signedness rides in the opcode, compare/branch style (no width).
    try std.testing.expectEqual(Opcode.div, typedOpcode(.div, .{ .primitive = .int32 }, undefined).?);
    try std.testing.expectEqual(Opcode.divu, typedOpcode(.div, .{ .primitive = .uint32 }, undefined).?);
    try std.testing.expectEqual(Opcode.div_f32, typedOpcode(.div, .{ .primitive = .float32 }, undefined).?);
    try std.testing.expectEqual(Opcode.rem_f64, typedOpcode(.rem, .{ .primitive = .f64 }, undefined).?);
    try std.testing.expectEqual(Opcode.shr, typedOpcode(.shr, .{ .primitive = .i64 }, undefined).?);
    try std.testing.expectEqual(Opcode.shru, typedOpcode(.shr, .{ .primitive = .uint32 }, undefined).?);
    // Shifts/bitwise: widthless on the integer types.
    try std.testing.expectEqual(Opcode.shl, typedOpcode(.shl, .{ .primitive = .i64 }, undefined).?);
    try std.testing.expectEqual(Opcode.shru, typedOpcode(.shr, .{ .primitive = .uint32 }, undefined).?);
    try std.testing.expectEqual(Opcode.xor, typedOpcode(.bitxor, .{ .primitive = .u64 }, undefined).?);
    try std.testing.expectEqual(Opcode.and_, typedOpcode(.bitand, .{ .primitive = .int32 }, undefined).?);
    try std.testing.expectEqual(Opcode.or_, typedOpcode(.bitor, .{ .primitive = .u64 }, undefined).?);
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcode(.shl, .{ .primitive = .byte }, undefined));
    // min/max: signed/unsigned pairs plus the float reps.
    try std.testing.expectEqual(Opcode.min_f32, typedOpcode(.min, .{ .primitive = .float32 }, undefined).?);
    try std.testing.expectEqual(Opcode.maxu, typedOpcode(.max, .{ .primitive = .u64 }, undefined).?);
    try std.testing.expectEqual(Opcode.minu, typedOpcode(.min, .{ .primitive = .uint32 }, undefined).?);
    try std.testing.expectEqual(Opcode.max, typedOpcode(.max, .{ .primitive = .int32 }, undefined).?);
    // The E-type unaries keep their widthful reps (width-sensitive
    // results); integer neg is widthless (sign-agnostic), the floats
    // keep theirs; abs is i32/i64/f32/f64 only.
    try std.testing.expectEqual(Opcode.neg, typedOpcode(.neg, .{ .primitive = .uint32 }, undefined).?);
    try std.testing.expectEqual(Opcode.neg_f64, typedOpcode(.neg, .{ .primitive = .f64 }, undefined).?);
    try std.testing.expectEqual(Opcode.abs_i32, typedOpcode(.abs, .{ .primitive = .int32 }, undefined).?);
    try std.testing.expectEqual(Opcode.abs_f32, typedOpcode(.abs, .{ .primitive = .float32 }, undefined).?);
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcode(.abs, .{ .primitive = .uint32 }, undefined));
    // clz/popcount: sign-agnostic, so the unsigned types alias the
    // signed member of the same width.
    try std.testing.expectEqual(Opcode.clz_i32, typedOpcode(.clz, .{ .primitive = .uint32 }, undefined).?);
    try std.testing.expectEqual(Opcode.clz_i32, typedOpcode(.clz, .{ .primitive = .int32 }, undefined).?);
    try std.testing.expectEqual(Opcode.clz_i64, typedOpcode(.clz, .{ .primitive = .u64 }, undefined).?);
    try std.testing.expectEqual(Opcode.popcount_i64, typedOpcode(.popcount, .{ .primitive = .i64 }, undefined).?);
    try std.testing.expectEqual(Opcode.popcount_i64, typedOpcode(.popcount, .{ .primitive = .u64 }, undefined).?);
    // Comparisons: the C-Type families with implicit cond.
    try std.testing.expectEqual(Opcode.seq, typedOpcode(.eq, .{ .primitive = .int32 }, undefined).?);
    try std.testing.expectEqual(Opcode.sne, typedOpcode(.ne, .{ .primitive = .u64 }, undefined).?);
    try std.testing.expectEqual(Opcode.slt_f32, typedOpcode(.lt, .{ .primitive = .float32 }, undefined).?);
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcode(.ge, .{ .primitive = .i64 }, undefined));
    try std.testing.expectEqual(Opcode.sle_f64, typedOpcode(.ge, .{ .primitive = .f64 }, undefined).?);
    // Byte comparisons lower through the u32 reps.
    try std.testing.expectEqual(Opcode.seq, typedOpcode(.eq, .{ .primitive = .byte }, undefined).?);
    // Bool/str equality.
    try std.testing.expectEqual(Opcode.bool_eq, typedOpcode(.eq, .{ .primitive = .bool }, undefined).?);
    try std.testing.expectEqual(Opcode.str_ne, typedOpcode(.ne, .{ .primitive = .str }, undefined).?);
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcode(.lt, .{ .primitive = .bool }, undefined));
    // le/gt: gt is the slt operand-swap alias (null); float le is the
    // sle primitive, integer le is synthesized (null).
    try std.testing.expectEqual(Opcode.sle_f32, typedOpcode(.le, .{ .primitive = .float32 }, undefined).?);
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcode(.le, .{ .primitive = .int32 }, undefined));
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcode(.gt, .{ .primitive = .float32 }, undefined));
    // Casts: the 42 explicit cvt.<src>.<dst> spellings over the seven
    // conversion types.
    try std.testing.expectEqual(Opcode.cvt_i32_u32, typedOpcode(.cast, .{ .primitive = .int32 }, .{ .primitive = .uint32 }).?);
    try std.testing.expectEqual(Opcode.cvt_b_f64, typedOpcode(.cast, .{ .primitive = .byte }, .{ .primitive = .f64 }).?);
    try std.testing.expectEqual(Opcode.cvt_f64_f32, typedOpcode(.cast, .{ .primitive = .f64 }, .{ .primitive = .float32 }).?);
    try std.testing.expectEqual(Opcode.cvt_u32_i32, typedOpcode(.cast, .{ .primitive = .uint32 }, .{ .primitive = .int32 }).?);
    try std.testing.expectEqual(Opcode.cvt_i32_i64, typedOpcode(.cast, .{ .primitive = .int32 }, .{ .primitive = .i64 }).?);
    try std.testing.expectEqual(Opcode.cvt_i64_u64, typedOpcode(.cast, .{ .primitive = .i64 }, .{ .primitive = .u64 }).?);
    try std.testing.expectEqual(Opcode.cvt_u64_f32, typedOpcode(.cast, .{ .primitive = .u64 }, .{ .primitive = .float32 }).?);
    try std.testing.expectEqual(Opcode.cvt_f64_i64, typedOpcode(.cast, .{ .primitive = .f64 }, .{ .primitive = .i64 }).?);
    // The full 7 × 7 matrix minus the identity entries: 42 distinct
    // opcodes, one per non-identity pair.
    {
        const types = [_]cfg.Type{
            .{ .primitive = .byte },
            .{ .primitive = .int32 },
            .{ .primitive = .uint32 },
            .{ .primitive = .i64 },
            .{ .primitive = .u64 },
            .{ .primitive = .float32 },
            .{ .primitive = .f64 },
        };
        var seen = [_]bool{false} ** 256;
        var n: usize = 0;
        for (types) |s| {
            for (types) |d| {
                if (std.meta.eql(s, d)) {
                    // No identity casts.
                    try std.testing.expectEqual(@as(?Opcode, null), typedOpcode(.cast, s, d));
                    continue;
                }
                const op = typedOpcode(.cast, s, d) orelse return error.CastMissing;
                try std.testing.expect(!seen[@intFromEnum(op)]);
                seen[@intFromEnum(op)] = true;
                n += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 42), n);
    }
}

test "typed immediate opcodes: widthless integer families, no float forms" {
    // The imm7 interpretation follows the type's signedness: the plain
    // (sign-extended) form on the signed types, the `u` (zero-extended)
    // form on the unsigned ones.
    try std.testing.expectEqual(Opcode.addi, typedOpcodeImm(.add, .{ .primitive = .int32 }).?);
    try std.testing.expectEqual(Opcode.addiu, typedOpcodeImm(.add, .{ .primitive = .uint32 }).?);
    try std.testing.expectEqual(Opcode.subi, typedOpcodeImm(.sub, .{ .primitive = .i64 }).?);
    try std.testing.expectEqual(Opcode.muliu, typedOpcodeImm(.mul, .{ .primitive = .u64 }).?);
    try std.testing.expectEqual(Opcode.divi, typedOpcodeImm(.div, .{ .primitive = .int32 }).?);
    try std.testing.expectEqual(Opcode.remiu, typedOpcodeImm(.rem, .{ .primitive = .uint32 }).?);
    try std.testing.expectEqual(Opcode.shli, typedOpcodeImm(.shl, .{ .primitive = .u64 }).?);
    try std.testing.expectEqual(Opcode.shri, typedOpcodeImm(.shr, .{ .primitive = .int32 }).?);
    try std.testing.expectEqual(Opcode.shriu, typedOpcodeImm(.shr, .{ .primitive = .uint32 }).?);
    try std.testing.expectEqual(Opcode.andi, typedOpcodeImm(.bitand, .{ .primitive = .uint32 }).?);
    try std.testing.expectEqual(Opcode.ori, typedOpcodeImm(.bitor, .{ .primitive = .i64 }).?);
    try std.testing.expectEqual(Opcode.xori, typedOpcodeImm(.bitxor, .{ .primitive = .u64 }).?);
    // C-Type integer comparison immediates.
    try std.testing.expectEqual(Opcode.slti, typedOpcodeImm(.lt, .{ .primitive = .int32 }).?);
    try std.testing.expectEqual(Opcode.seqi, typedOpcodeImm(.eq, .{ .primitive = .u64 }).?);
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcodeImm(.add, .{ .primitive = .float32 }));
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcodeImm(.le, .{ .primitive = .int32 }));
    try std.testing.expectEqual(@as(?Opcode, null), typedOpcodeImm(.neg, .{ .primitive = .int32 }));
    try std.testing.expectEqual(Opcode.madd_f32, maddOpcode(.{ .primitive = .float32 }).?);
    try std.testing.expectEqual(Opcode.madd, maddOpcode(.{ .primitive = .int32 }).?);
    try std.testing.expectEqual(Opcode.maddi, maddiOpcode(.{ .primitive = .int32 }).?);
    try std.testing.expectEqual(Opcode.maddiu, maddiOpcode(.{ .primitive = .uint32 }).?);
    try std.testing.expectEqual(@as(?Opcode, null), maddiOpcode(.{ .primitive = .float32 }));
}

test "repOf decodes the rep of every typed family member" {
    // The widthless integer arithmetic ops carry no rep — signedness
    // rides in the opcode (compare/branch style), never in a width.
    try std.testing.expectEqual(@as(?Rep, null), repOf(.add));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.divu));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.shru));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.minu));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.addiu));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.and_));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.madd));
    // The float members keep their explicit reps.
    try std.testing.expectEqual(Rep.f32, repOf(.add_f32).?);
    try std.testing.expectEqual(Rep.f64, repOf(.add_f64).?);
    try std.testing.expectEqual(Rep.f32, repOf(.beq_f32).?);
    try std.testing.expectEqual(@as(?Rep, null), repOf(.blt));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.seq));
    try std.testing.expectEqual(Rep.f64, repOf(.sle_f64).?);
    // The E-type unaries keep their widthful reps except the widthless
    // neg (two's complement is sign-agnostic); clz/popcount keep only
    // the signed width selectors i32/i64 (counts are sign-agnostic),
    // abs wraps on the minimum.
    try std.testing.expectEqual(@as(?Rep, null), repOf(.neg));
    try std.testing.expectEqual(Rep.i32, repOf(.clz_i32).?);
    try std.testing.expectEqual(Rep.i64, repOf(.clz_i64).?);
    try std.testing.expectEqual(Rep.i32, repOf(.popcount_i32).?);
    // The declared abs order: i32, i64, f32, f64.
    try std.testing.expectEqual(Rep.i64, repOf(.abs_i64).?);
    try std.testing.expectEqual(Rep.f32, repOf(.abs_f32).?);
    // Untyped opcodes have no rep.
    try std.testing.expectEqual(@as(?Rep, null), repOf(.ret));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.cmov));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.sext32));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.zext32));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.jal));
}

test "widthless families: integer ops carry no rep, floats keep theirs" {
    // Every widthless integer arithmetic op (register and immediate
    // forms, signed/unsigned pairs) has a null rep — the width was
    // removed from the opcode. The float members of the same families
    // keep their `f32`/`f64` reps.
    const int_ops = [_]Opcode{ .add, .sub, .mul, .div, .divu, .rem, .remu, .min, .minu, .max, .maxu, .shl, .shr, .shru, .and_, .or_, .xor, .madd, .msub, .neg, .addi, .addiu, .subi, .subiu, .muli, .muliu, .divi, .diviu, .remi, .remiu, .shli, .shri, .shriu, .andi, .ori, .xori, .maddi, .maddiu };
    inline for (int_ops) |op| try std.testing.expectEqual(@as(?Rep, null), repOf(op));
    const float_members = [_]Opcode{ .add_f32, .add_f64, .sub_f32, .sub_f64, .mul_f32, .mul_f64, .div_f32, .div_f64, .rem_f32, .rem_f64, .min_f32, .min_f64, .max_f32, .max_f64, .madd_f32, .madd_f64, .msub_f32, .msub_f64 };
    inline for (float_members) |op| try std.testing.expect(repOf(op) != null);
}

test "family layout: families are contiguous runs in table order" {
    // The v9 renumber made every family a contiguous run — no alignment
    // holes, no inherited width slots. The integer `neg` collapsed to a
    // single widthless opcode at 156; the `neg.f32`/`neg.f64` float
    // members sit at 160/161, the 32-bit canonicalization pair at
    // 162/163, the integer unary families follow, and `abs` keeps its
    // declared-order exception (i32, i64, f32, f64 — no unsigned
    // members). The retired integer-neg slots 157–159 and the retired
    // unsigned clz/popcount slots 169/171/173/175 stay unused.
    try std.testing.expectEqual(@as(u8, 156), @intFromEnum(Opcode.neg));
    try std.testing.expectEqual(@as(?Rep, null), repOf(.neg));
    try std.testing.expectEqual(@as(u8, 160), @intFromEnum(Opcode.neg_f32));
    try std.testing.expectEqual(@as(u8, 161), @intFromEnum(Opcode.neg_f64));
    // clz/popcount keep only the signed width selectors: `clz.i32` = 168,
    // `clz.i64` = 170, `popcount.i32` = 172, `popcount.i64` = 174 — the
    // unsigned slots 169/171/173/175 are retired (counts are
    // sign-agnostic, so the unsigned types alias the signed member).
    try std.testing.expectEqual(@as(u8, 168), @intFromEnum(Opcode.clz_i32));
    try std.testing.expectEqual(@as(u8, 170), @intFromEnum(Opcode.clz_i64));
    try std.testing.expectEqual(@as(u8, 172), @intFromEnum(Opcode.popcount_i32));
    try std.testing.expectEqual(@as(u8, 174), @intFromEnum(Opcode.popcount_i64));
    try std.testing.expectEqual(Rep.i32, repOf(.clz_i32).?);
    try std.testing.expectEqual(Rep.i64, repOf(.clz_i64).?);
    try std.testing.expectEqual(Rep.i32, repOf(.popcount_i32).?);
    try std.testing.expectEqual(Rep.i64, repOf(.popcount_i64).?);
    // The float-2 families: contiguous f32, f64.
    const two = [_][]const u8{ "neg", "sqrt", "floor", "ceil", "trunc", "round" };
    inline for (two) |fam| {
        const op32 = @field(Opcode, fam ++ "_f32");
        const op64 = @field(Opcode, fam ++ "_f64");
        try std.testing.expectEqual(@as(u8, @intFromEnum(op32) + 1), @intFromEnum(op64));
        try std.testing.expectEqual(Rep.f32, repOf(op32).?);
        try std.testing.expectEqual(Rep.f64, repOf(op64).?);
    }
    // `abs` — the declared-order exception (Instruction Set §7): the
    // members are contiguous 164..167 but carry i32, i64, f32, f64,
    // so the rep is NOT the member offset.
    try std.testing.expectEqual(@as(u8, 164), @intFromEnum(Opcode.abs_i32));
    try std.testing.expectEqual(@as(u8, 165), @intFromEnum(Opcode.abs_i64));
    try std.testing.expectEqual(@as(u8, 166), @intFromEnum(Opcode.abs_f32));
    try std.testing.expectEqual(@as(u8, 167), @intFromEnum(Opcode.abs_f64));
    try std.testing.expectEqual(Rep.i32, repOf(.abs_i32).?);
    try std.testing.expectEqual(Rep.i64, repOf(.abs_i64).?);
    try std.testing.expectEqual(Rep.f32, repOf(.abs_f32).?);
    try std.testing.expectEqual(Rep.f64, repOf(.abs_f64).?);
    // The widthless integer families are single members in the run;
    // signed/unsigned pairs are consecutive (signed first): `add` = 1,
    // `sub` = 4, `div` = 10 / `divu` = 11, `shr` = 37 / `shru` = 38,
    // `maddi` = 54 / `maddiu` = 55.
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Opcode.add));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Opcode.sub));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(Opcode.divu));
    try std.testing.expectEqual(@as(u8, 38), @intFromEnum(Opcode.shru));
    try std.testing.expectEqual(@as(u8, 55), @intFromEnum(Opcode.maddiu));
}

test "move-wide lane arithmetic" {
    try std.testing.expectEqual(@as(u6, 0), movwLaneShift(0));
    try std.testing.expectEqual(@as(u6, 48), movwLaneShift(3));
    try std.testing.expectEqual(@as(u64, 0xffff), movwLaneMask(0));
    try std.testing.expectEqual(@as(u64, 0xffff000000000000), movwLaneMask(3));
    try std.testing.expectEqual(@as(u64, 0x12340000), movwzValue(1, 0x1234));
    try std.testing.expectEqual(@as(u64, ~@as(u64, 0x12340000)), movwnValue(1, 0x1234));
    try std.testing.expectEqual(@as(u64, 0x00000000ffff9abc), movwkValue(0, 0x9abc, 0x00000000ffffffff));
}

test "opcode names are unique and lower() covers every CFG op and terminator" {
    // The enum is the name space: duplicate names are compile errors.
    // Every cfg op and terminator must have a lowering rule — the
    // exhaustive `lower`/`lowerTerminator` switches enforce this at
    // compile time; spot-check a few rules here.
    try std.testing.expectEqual(TypedKind.add, lower(.add).typed);
    try std.testing.expect(std.meta.activeTag(lower(.copy)) == .direct);
    try std.testing.expectEqual(Opcode.copy, lower(.copy).direct);
    try std.testing.expectEqual(Opcode.ret, lowerTerminator(.ret));
    try std.testing.expectEqual(Opcode.j, lowerTerminator(.j));
    try std.testing.expectEqual(Opcode.tailcall_self, lowerTerminator(.tailcall));
    try std.testing.expectEqual(Opcode.trap, lowerTerminator(.trap));
}
