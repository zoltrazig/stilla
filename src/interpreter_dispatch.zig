//! Threaded opcode dispatch for the Stilla interpreter VM
//! (docs/interpreter-vm.md §1, §7): one handler per opcode, indexed by a
//! comptime table, executed in place over the decoded instruction image,
//! plus the execution-layer helpers the handlers drive (register access,
//! trap plumbing, the call/return path, the dispatch loop, and the
//! numeric/compare/cast semantics). Loaded as a submodule of
//! `interpreter`, which owns the `VmCtx` execution context.

const std = @import("std");
const llir = @import("llir.zig");
const vm_instr = @import("vm_instr.zig");
const vm_types = @import("vm_types.zig");
const interp_types = @import("interpreter_types.zig");
const interpreter = @import("interpreter.zig");
const VmCtx = interpreter.VmCtx;
const VmInstr = vm_instr.VmInstr;
const Value = vm_types.Value;
const ValueCodec = vm_types.ValueCodec;
const HeapErr = vm_types.HeapErr;
const Termination = interp_types.Termination;
const RunError = interp_types.RunError;
const readHeader = interp_types.readHeader;
const invalid_pc = interp_types.invalid_pc;
const vm_internal_pc = interp_types.vm_internal_pc;
const functionAtPc = interp_types.functionAtPc;

// ---------------------------------------------------------------------------
// Threaded dispatch handlers (docs/interpreter-vm.md §1, §7):
// one handler per opcode — comptime factories where a family shares a
// body, so the opcode literal is comptime-known and the family's
// internal switch folds away (the exhaustive comptime switch below is
// the completeness guard).
// Each handler ends by chaining: transfer-control handlers end
// `return next(self, n)` (pc already moved); everything else ends
// `return fallthrough(self, n)` (advance, then the common tail).
// Terminations and errors stop the chain out-of-band (`self.stop` /
// `self.fail` / `self.trap`). The exhaustive comptime switch that fills
// `handlers` is the completeness guard — every tag of `llir.Opcode`
// must be assigned or the compile fails.
// ---------------------------------------------------------------------------

/// One per-opcode handler; `n` is the remaining step budget. The
/// handler's instruction is fetched from `code[self.runtime.pc]` at entry
/// (`pc` always points at the executing instruction — transfer
/// handlers move it only for the *next* token). The 8-byte `VmInstr`
/// deliberately does NOT cross the tail jump: Debug-mode codegen
/// misplaces a by-value extern struct argument at the always_tail
/// boundary (spike chain3/printdispatch), so the chain carries only
/// `(self, n)` and each handler re-fetches its instruction.
const Handler = *const fn (self: *VmCtx, n: u32) void;

/// The largest `@intFromEnum` across all opcodes; the dispatch table is
/// `[max + 1]Handler` indexed by `@intFromEnum(op)`. (A sparse explicit
/// tag range cannot index `[Opcode]Handler` directly, and
/// `std.enums.EnumArray` linear-searches sparse keys.)
fn maxOpcodeValue() comptime_int {
    var m: usize = 0;
    for (std.meta.tags(llir.Opcode)) |op| m = @max(m, @intFromEnum(op));
    return m;
}

// --- loads ----------------------------------------------------------------

fn hConst(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const image = self.curImage();
    const imm: u32 = @truncate(v.operand);
    const cr = image.constants[imm];
    var val: Value = 0;
    switch (cr.kind) {
        .int, .float, .bool, .void => {
            val = if (isWidePrim(self, cr.type_))
                (@as(u64, cr.b) << 32 | cr.a)
            else if (isInt32Prim(self, cr.type_))
                ValueCodec.extendInt32Bits(cr.a)
            else
                cr.a; // u32/byte/bool/f32: the row's low bits are the canonical cell
        },
        .string => {
            // One table-owned object per distinct record; the
            // destination retains its own reference. The cache key is
            // module-qualified — const ids are per-artifact.
            const key: u64 = (@as(u64, self.curModIdx()) << 32) | imm;
            const gop = self.runtime.string_consts.getOrPut(self.allocator, key) catch |e| return fail(self, e);
            if (!gop.found_existing) {
                const bytes = image.strings[cr.a .. cr.a + cr.b];
                const h = self.runtime.heap.allocObjectIn(.str_, self.curModIdx(), cr.type_, 0, @intCast(bytes.len)) catch |e| return fail(self, e);
                const dst_bytes: [*]u8 = @ptrCast(h.cells);
                @memcpy(dst_bytes[0..bytes.len], bytes);
                gop.value_ptr.* = @intFromPtr(h);
            }
            retainCell(self, gop.value_ptr.*) catch |e| return fail(self, e);
            val = gop.value_ptr.*;
        },
    }
    write(self, v.a, val);
    return fallthrough(self, n);
}

fn hFnRef(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const imm: u32 = @truncate(v.operand);
    // The runtime materializes the executable entry PC from the
    // module-local FunctionId (Instruction Set §5.2) — the relocated
    // entry of the executing module's own function.
    write(self, v.a, self.loaded.funcs.items[self.curMod().func_base + imm].desc.entry_pc);
    return fallthrough(self, n);
}

// --- typed arithmetic (register forms) -----------------------------------

/// Widthless integer ops compute on the canonical 64-bit cells (the
/// lowering inserts the 32-bit canonicalization where the operand type
/// demands it); the float members dispatch on their rep. No
/// `canonicalIntResult` — the widthless ops write their raw 64-bit
/// result. Division traps (zero divisor, signed min / -1 overflow) are
/// deterministic trap messages.
fn arithHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const r = binOp(self, op, read(self, v.b), read(self, v.c)) catch |e| return stop(self, intTrap(self, e));
            write(self, v.a, r);
            return fallthrough(self, n);
        }
    }.run;
}

// --- typed arithmetic (immediate forms) -----------------------------------
// R-Type `dst, src, imm7`: the 7-bit immediate sits in field c. The rep
// fixes the interpretation — the `.i*` members sign-extend it, the
// `.u*` members use the raw (zero-extended) field — and the width of
// the compute.

fn arithImmHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const rep = comptime llir.repOf(op).?;
            const w: comptime_int = if (rep == .i32 or rep == .u32) 32 else 64;
            const T = std.meta.Int(.unsigned, w);
            const b: T = @truncate(read(self, v.b));
            const im: T = if (rep == .i32 or rep == .i64)
                @truncate(@as(u64, @bitCast(vm_instr.imm7Signed(v.c))))
            else
                @as(T, v.c);
            const r: T = switch (op) {
                .addi_i32, .addi_u32, .addi_i64, .addi_u64 => b +% im,
                .subi_i32, .subi_u32, .subi_i64, .subi_u64 => b -% im,
                .muli_i32, .muli_u32, .muli_i64, .muli_u64 => b *% im,
                else => unreachable,
            };
            write(self, v.a, canonicalIntResult(op, r));
            return fallthrough(self, n);
        }
    }.run;
}

fn divImmHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const rep = comptime llir.repOf(op).?;
            const w: comptime_int = if (rep == .i32 or rep == .u32) 32 else 64;
            const T = std.meta.Int(.unsigned, w);
            const signed = rep == .i32 or rep == .i64;
            const b: T = @truncate(read(self, v.b));
            const im: T = if (signed) @truncate(@as(u64, @bitCast(vm_instr.imm7Signed(v.c)))) else @as(T, v.c);
            if (im == 0) return stop(self, intTrap(self, error.DivByZero));
            const r: T = switch (op) {
                .divi_i32, .divi_i64, .divi_u32, .divi_u64 => blk: {
                    if (signed) {
                        // `i64_min / -1` traps at 64 bits; the 32-bit
                        // exact quotient 2^31 wraps to `i32_min`.
                        if (w == 64 and b == @as(T, 1) << (w - 1) and im == std.math.maxInt(T)) return stop(self, intTrap(self, error.DivOverflow));
                        break :blk @truncate(@as(u64, @bitCast(@divTrunc(signExtendTo64(b, w), signExtendTo64(im, w)))));
                    }
                    break :blk b / im;
                },
                .remi_i32, .remi_i64, .remi_u32, .remi_u64 => blk: {
                    if (signed) {
                        break :blk @truncate(@as(u64, @bitCast(@rem(signExtendTo64(b, w), signExtendTo64(im, w))))); // i*_min % -1 == 0
                    }
                    break :blk b % im;
                },
                else => unreachable,
            };
            write(self, v.a, canonicalIntResult(op, r));
            return fallthrough(self, n);
        }
    }.run;
}

fn shiftImmHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const rep = comptime llir.repOf(op).?;
            const w: comptime_int = if (rep == .i32 or rep == .u32) 32 else 64;
            const T = std.meta.Int(.unsigned, w);
            const a: T = @truncate(read(self, v.b));
            const sh: std.math.Log2Int(T) = @intCast(v.c & (w - 1));
            const r: T = switch (op) {
                .shli_i32, .shli_u32, .shli_i64, .shli_u64 => a << sh,
                .shri_i32, .shri_i64 => @truncate(@as(u64, @bitCast(@as(i64, @bitCast(signExtendTo64(a, w))) >> @as(u6, sh)))),
                .shri_u32, .shri_u64 => a >> sh,
                else => unreachable,
            };
            write(self, v.a, canonicalIntResult(op, r));
            return fallthrough(self, n);
        }
    }.run;
}

fn bitImmHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const b = read(self, v.b);
            const r = switch (op) {
                .andi => b & v.c,
                .ori => b | v.c,
                .xori => b ^ v.c,
                else => unreachable,
            };
            write(self, v.a, r);
            return fallthrough(self, n);
        }
    }.run;
}

/// Read-modify-write FMACs: `dst = dst ± b * c` — two separate wrap
/// steps, never a fused rounding.
fn fmacHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const acc = read(self, v.a);
            const b = read(self, v.b);
            const c = read(self, v.c);
            write(self, v.a, fmacOp(self, op, acc, b, c));
            return fallthrough(self, n);
        }
    }.run;
}

/// R-Type `dst, src, imm7`: the rep fixes the immediate interpretation —
/// the `.i*` members sign-extend the field, the `.u*` members use it raw
/// (zero-extended).
fn fmacImmHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const acc = read(self, v.a);
            const b = read(self, v.b);
            const rep = llir.repOf(op).?;
            const im: u64 = if (rep == .i32 or rep == .i64) @bitCast(vm_instr.imm7Signed(v.c)) else v.c;
            write(self, v.a, fmaciOp(self, op, acc, b, im));
            return fallthrough(self, n);
        }
    }.run;
}

// --- typed unary (E-Type) --------------------------------------------------

/// Typed unary (E-Type): `neg`/`abs`/`clz`/`popcount` and the float
/// rounding family, rep-dispatched; results canonicalize per rep (an
/// `.i32` result sign-extends, a `.u32` result zero-extends).
fn unaryHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            write(self, v.a, canonicalIntResult(op, unOp(self, op, read(self, v.b))));
            return fallthrough(self, n);
        }
    }.run;
}

// --- C-Type comparisons (implicit cond destination) -----------------------

fn cmpHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            self.runtime.fast_regs[llir.cond_reg] = ValueCodec.encodeBool(cmpC(self, op, read(self, v.a), read(self, v.b)));
            return fallthrough(self, n);
        }
    }.run;
}

fn cmpImmHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const a = read(self, v.a);
            const im7: u64 = @bitCast(vm_instr.imm7Signed(v.b));
            const r = switch (op) {
                .seqi => a == im7,
                .snei => a != im7,
                .slti => intOrdCmp(true, false, a, im7),
                .sltiu => intOrdCmp(true, true, a, v.b),
                .sgti => intOrdCmp(false, false, a, im7),
                .sgtiu => intOrdCmp(false, true, a, v.b),
                else => unreachable,
            };
            self.runtime.fast_regs[llir.cond_reg] = ValueCodec.encodeBool(r);
            return fallthrough(self, n);
        }
    }.run;
}

fn hBoolEq(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    self.runtime.fast_regs[llir.cond_reg] = ValueCodec.encodeBool(read(self, v.a) == read(self, v.b));
    return fallthrough(self, n);
}

fn hBoolNe(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    self.runtime.fast_regs[llir.cond_reg] = ValueCodec.encodeBool(read(self, v.a) != read(self, v.b));
    return fallthrough(self, n);
}

fn strCmpHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const equal = strEqual(self, read(self, v.a), read(self, v.b)) catch |e| return stop(self, heapTrap(self, e));
            self.runtime.fast_regs[llir.cond_reg] = ValueCodec.encodeBool(if (op == .str_eq) equal else !equal);
            return fallthrough(self, n);
        }
    }.run;
}

// --- boolean complement / select ------------------------------------------

fn hNot(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    write(self, v.a, ValueCodec.encodeBool(read(self, v.b) == 0));
    return fallthrough(self, n);
}

fn hCmov(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    // dst = cond ? b : c — a raw pattern move.
    const pick = self.runtime.fast_regs[llir.cond_reg] != 0;
    write(self, v.a, if (pick) read(self, v.b) else read(self, v.c));
    return fallthrough(self, n);
}

// --- casts (C-Type) --------------------------------------------------------

fn castHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            write(self, v.a, doCast(self, op, read(self, v.b)));
            return fallthrough(self, n);
        }
    }.run;
}

// --- transfers / move-wide -------------------------------------------------

fn hTransfer(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    // copy / move / borrow — all complete raw-cell transfers.
    write(self, v.a, read(self, v.b));
    return fallthrough(self, n);
}

/// The lane index of a move-wide opcode's suffix (`movwn0` → 0, …).
fn movwLane(comptime op: llir.Opcode) u2 {
    return switch (op) {
        .movwn1, .movwz1, .movwk1 => 1,
        .movwn2, .movwz2, .movwk2 => 2,
        .movwn3, .movwz3, .movwk3 => 3,
        else => 0,
    };
}

fn movwHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const lane_imm: u16 = @truncate(v.operand);
            const wide: Value = switch (op) {
                .movwz0, .movwz1, .movwz2, .movwz3 => llir.movwzValue(movwLane(op), lane_imm),
                .movwn0, .movwn1, .movwn2, .movwn3 => llir.movwnValue(movwLane(op), lane_imm),
                .movwk0, .movwk1, .movwk2, .movwk3 => llir.movwkValue(movwLane(op), lane_imm, read(self, v.a)),
                else => unreachable,
            };
            write(self, v.a, wide);
            return fallthrough(self, n);
        }
    }.run;
}

// --- spills / argument window ----------------------------------------------

fn hSpillTake(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const f = curFn(
        self,
    );
    const xi = self.runtime.fp + f.f_count + @as(u32, @truncate(v.operand));
    write(self, v.a, self.runtime.stack.items[xi]);
    return fallthrough(self, n);
}

fn hSpillPut(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const f = curFn(
        self,
    );
    const xi = self.runtime.fp + f.f_count + @as(u32, @truncate(v.operand));
    self.runtime.stack.items[xi] = read(self, v.a);
    return fallthrough(self, n);
}

/// `slot_retain` / `slot_move` / `slot_borrow` / `slot_copy`: one
/// argument cell into the caller's outgoing window, honoring the
/// opcode's ownership form at runtime (Instruction Set §5.5):
/// `slot_retain` retains the counted source — establishing the
/// callee's parameter owner; `slot_move` transfers the owned source
/// (it becomes uninitialized); `slot_borrow` installs a borrowed view
/// valid for one call; `slot_copy` bit-copies a plain value.
fn slotHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const f = curFn(
                self,
            );
            const addr = llir.callBase(self.runtime.fp, f) + @as(u32, @truncate(v.operand));
            const src = read(self, v.a);
            switch (op) {
                .slot_retain => retainCounted(self, src) catch |e| return stop(self, heapTrap(self, e)),
                .slot_move => write(self, v.a, ValueCodec.zero), // transfer: the source becomes uninitialized
                else => {},
            }
            self.runtime.stack.items[addr] = src;
            return fallthrough(self, n);
        }
    }.run;
}

// --- control ----------------------------------------------------------------

fn hJ(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    self.runtime.pc = vm_instr.jumpTarget(self.runtime.pc, v);
    return next(self, n);
}

fn hJal(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    // `jal ra, addr` is the direct call. Its operand carries the
    // callee's function registry index, resolved at load time
    // (publishArtifact) — no pc→function search and no entry check on
    // the call path. Step 8 coalescing may drop the post-call take, so
    // the dynamic take contract is relaxed for static `jal`.
    const t = enterCalleeId(self, v.operand, true) catch |e| return fail(self, e);
    if (t) |term| return stop(self, term);
    return next(self, n);
}

fn hJalr(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    // `jalr ra, base, offs16`: the function value in `base + offs16` is
    // an executable entry PC; `enterJalr` resolves it and checks the
    // dynamic take contract before modifying any state. The offset is a
    // signed base-plus-offset: an overflowing or wrapping target that
    // lands outside the u32 instruction space is rejected here, before
    // `enterJalr` truncates it.
    const base = read(self, v.a);
    const offs16: i16 = vm_instr.offs16Signed(v);
    const targeti: i128 = @as(i128, @intCast(base)) + @as(i128, offs16);
    if (targeti < 0 or targeti > std.math.maxInt(u32)) {
        return trap(self, "jalr target overflows the instruction address space", .{});
    }
    const t = enterJalr(self, @intCast(targeti)) catch |e| return fail(self, e);
    if (t) |term| return stop(self, term);
    return next(self, n);
}

fn hTake(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    // The generic take: transfer b's ownership to a and clear the
    // source cell. The post-call contract form is `take dst, F(L+3+O-A)`.
    const taken_val = read(self, v.b);
    write(self, v.b, ValueCodec.zero);
    write(self, v.a, taken_val);
    return fallthrough(self, n);
}

fn branchHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const taken = branchCmp(self, op, read(self, v.a), read(self, v.b));
            if (taken) {
                self.runtime.pc = vm_instr.branchTarget(self.runtime.pc, v);
                return next(self, n);
            }
            return fallthrough(self, n);
        }
    }.run;
}

fn branchImmHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const a = read(self, v.a);
            const im7: u64 = @bitCast(vm_instr.imm7Signed(v.b));
            const taken = switch (op) {
                .beqi => a == im7,
                .bnei => a != im7,
                .blti => intOrdCmp(true, false, a, im7),
                .bltiu => intOrdCmp(true, true, a, v.b),
                else => unreachable,
            };
            if (taken) {
                self.runtime.pc = vm_instr.branchTarget(self.runtime.pc, v);
                return next(self, n);
            }
            return fallthrough(self, n);
        }
    }.run;
}

fn hTbz(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const bit: u6 = @intCast(v.b & 63);
    const set = (read(self, v.a) >> bit) & 1 == 1;
    if (!set) {
        self.runtime.pc = vm_instr.branchTarget(self.runtime.pc, v);
        return next(self, n);
    }
    return fallthrough(self, n);
}

fn hTbnz(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const bit: u6 = @intCast(v.b & 63);
    const set = (read(self, v.a) >> bit) & 1 == 1;
    if (set) {
        self.runtime.pc = vm_instr.branchTarget(self.runtime.pc, v);
        return next(self, n);
    }
    return fallthrough(self, n);
}

fn hSwitch(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const image = self.curImage();
    const imm: u32 = @truncate(v.operand);
    const sd = image.switch_descs[imm];
    const tag = read(self, v.a);
    var offset: ?i32 = null;
    for (sd.arms_start..sd.arms_start + sd.arms_len) |ai| {
        if (image.switch_arms[ai].tag == tag) {
            offset = image.switch_arms[ai].target;
            break;
        }
    }
    if (offset) |o| {
        // Arm targets are signed offsets from the switch's own pc.
        self.runtime.pc = llir.switchArmTarget(self.runtime.pc, o);
        return next(self, n);
    }
    return trap(self, "switch: unmatched tag {d}", .{tag});
}

fn hJr(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const t = llir.jrTarget(read(self, v.a), vm_instr.offs16Signed(v));
    const f = curFn(
        self,
    );
    if (t < f.code_start or t >= f.code_end) {
        return trap(self, "jr target {d} outside the code range", .{t});
    }
    self.runtime.pc = @intCast(t);
    return next(self, n);
}

// --- calls / returns ---------------------------------------------------------

fn hRet(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const t = returnFrom(self, v) catch |e| return fail(self, e);
    if (t) |term| return stop(self, term); // root return or trap
    if (self.runtime.result != null) return;
    if (self.runtime.popped_hook_cont) {
        // A drop-hook continuation resumed: the drain inside `returnFrom`
        // may have armed a new hook (pc moved to its entry). Stop the
        // chain — the run loop re-drives from the restored pc, preserving
        // the between-step drain and the teardown hook loop.
        self.runtime.popped_hook_cont = false;
        return;
    }
    return next(self, n);
}

fn hReleaseRet(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    // `release_ret result, x` = `release(x); return result` (Instruction
    // Set §8) — the fused form's cleanup source dies with the frame.
    releaseCounted(self, read(self, v.b)) catch |e| return stop(self, heapTrap(self, e));
    const t = returnFrom(self, v) catch |e| return fail(self, e);
    if (t) |term| return stop(self, term);
    if (self.runtime.result != null) return;
    if (self.runtime.popped_hook_cont) {
        self.runtime.popped_hook_cont = false;
        return;
    }
    return next(self, n);
}

fn hTailcallSelf(self: *VmCtx, n: u32) void {
    tailcallSelf(
        self,
    ) catch |e| return fail(self, e);
    return next(self, n);
}

fn hTrap(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    _ = n;
    _ = v;
    return trap(self, "explicit trap", .{});
}

// --- syscall -------------------------------------------------------------------

fn hSyscall(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const image = self.curImage();
    const imm: u32 = @truncate(v.operand);
    const did = imm;
    if (did >= image.syscall_descs.len) {
        return trap(self, "syscall desc {d} out of range ({d} descs)", .{ did, image.syscall_descs.len });
    }
    const dd = image.syscall_descs[did];
    if (dd.host_binding_id >= image.imports.len) {
        return trap(self, "syscall desc {d}: host import {d} out of range", .{ did, dd.host_binding_id });
    }
    if (dd.args_start > image.call_args.len or dd.args_len > image.call_args.len - dd.args_start) {
        return trap(self, "syscall desc {d}: argument range out of bounds", .{did});
    }
    if (dd.signature_id >= image.signatures.len) {
        return trap(self, "syscall desc {d}: signature {d} out of range", .{ did, dd.signature_id });
    }
    // The signature interface (docs/host-bindings.md §3.0): the host
    // receives a zero-allocation view of the binding's signature row,
    // never a raw index into the artifact.
    const sig = interp_types.HostSignature{ .image = image, .desc = image.signatures[dd.signature_id] };
    // The host dispatch pair is symbolic: the import's
    // (module_symbol, member_symbol) bytes.
    const imp = image.imports[dd.host_binding_id];
    const mod_bytes = self.curMod().symbolBytes(imp.module_sym) orelse
        return trap(self, "syscall desc {d}: module symbol out of range", .{did});
    const member = self.curMod().symbolBytes(imp.member_sym) orelse
        return trap(self, "syscall desc {d}: member symbol out of range", .{did});
    if (dd.args_len > self.runtime.host_scratch.values.items.len) {
        self.runtime.host_scratch.values.resize(self.allocator, dd.args_len) catch |e| return fail(self, e);
    }
    // Per-call scratch: C-string bytes reset so bindC thunks start fresh
    // (capacity retained — no per-call allocation).
    self.runtime.host_scratch.bytes.clearRetainingCapacity();
    // Gather one canonical cell per argument, in order; the moves/
    // borrows were already materialized by the lowering into the arg
    // registers (spec §5.3).
    const args = self.runtime.host_scratch.values.items[0..dd.args_len];
    for (image.call_args[dd.args_start..][0..dd.args_len], 0..) |reg, i| {
        args[i] = read(self, reg);
    }
    // Dispatch: the registry (default), or the opt-out adapter. A miss
    // with no fallback is a deterministic not_implemented trap.
    const result: interp_types.HostResult = if (self.host.invoke) |inv|
        inv(self, self.host.userdata, mod_bytes, member, sig, args)
    else if (self.host.registry.lookup(mod_bytes, member)) |hit|
        hit.thunk(self, hit.userdata orelse self.host.userdata, sig, args)
    else
        return trap(self, "host binding '@{s}#{s}' is not implemented by this host", .{ mod_bytes, member });
    switch (result) {
        .value => |res| {
            if (v.a != llir.zero_reg) write(self, v.a, res);
        },
        .panic => |m| return stop(self, .{ .panic = sitePrefixed(self, m) }),
        .not_implemented => return trap(self, "host binding '@{s}#{s}' is not implemented by this host", .{ mod_bytes, member }),
    }
    return fallthrough(self, n);
}

// --- module storage --------------------------------------------------------------

fn hModuleRef(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const imm: u32 = @truncate(v.operand);
    const mi = self.resolveModuleRef(imm) catch |e| return fail(self, e);
    // A module's own symbol resolves to itself; only a *different*
    // module needs the ensure step.
    if (mi != self.curModIdx()) {
        if (self.ensureModule(mi) catch |e| return fail(self, e)) {
            return next(self, n); // initializer owns pc
        }
    }
    write(self, v.a, mi);
    return fallthrough(self, n);
}

fn hLoadMember(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const image = self.curImage();
    const md = image.member_descs[v.c];
    const ri = self.resolveImport(self.curModIdx(), md.ref, true) catch |e| return fail(self, e);
    if (ri.started_init) return next(self, n); // initializer owns pc
    retainCell(self, ri.val) catch |e| return fail(self, e);
    write(self, v.a, ri.val);
    return fallthrough(self, n);
}

fn hStoreMember(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const image = self.curImage();
    const imm: u32 = @truncate(v.operand);
    const md = image.member_descs[imm];
    const m = self.loaded.modules.items[self.curModIdx()];
    if (md.ref >= m.slots.len) return trap(self, "module slot out of range", .{});
    m.slots[md.ref] = read(self, v.a);
    m.slot_log.append(self.allocator, md.ref) catch |e| return fail(self, e);
    return fallthrough(self, n);
}

// --- construction / consuming destructures -------------------------------------

fn hConstruct(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    opConstruct(self, v) catch |e| return fail(self, e);
    return fallthrough(self, n);
}

fn hUnpackAggregate(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    // unpack_struct / unpack_tuple: payload cells transfer to their
    // destinations; only the shell dies.
    const image = self.curImage();
    const imm: u32 = @truncate(v.operand);
    const dd = image.destructure_descs[imm];
    const h = self.runtime.heap.deref(read(self, v.a)) catch |e| return stop(self, heapTrap(self, e));
    switch (h.kind) {
        .struct_, .tuple_ => {
            for (0..dd.dsts_len) |k| writeDst(self, dd.dsts_start + k, h.cell(k));
            self.runtime.heap.freeShell(h);
        },
        else => return trap(self, "destructure of a non-aggregate object", .{}),
    }
    return fallthrough(self, n);
}

fn hSplitList(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const image = self.curImage();
    const imm: u32 = @truncate(v.operand);
    const dd = image.destructure_descs[imm];
    const h = self.runtime.heap.deref(read(self, v.a)) catch |e| return stop(self, heapTrap(self, e));
    switch (h.kind) {
        .list_cons => {
            // A `[a, b, ..rest]` pattern consumes one node per bound
            // element: heads transfer to dsts[0..n), the remaining
            // suffix node to the last dst. A short list hits the
            // null/registry checks and traps.
            if (dd.dsts_len < 2) return trap(self, "split_list descriptor too small", .{});
            var cur = read(self, v.a);
            var k: usize = 0;
            while (k + 1 < dd.dsts_len) : (k += 1) {
                const node = self.runtime.heap.deref(cur) catch |e| return stop(self, heapTrap(self, e));
                writeDst(self, dd.dsts_start + k, node.cell(0)); // head transfers
                cur = node.cell(1);
                self.runtime.heap.freeShell(node);
            }
            writeDst(self, dd.dsts_start + k, cur); // the rest
        },
        else => return trap(self, "destructure of a non-aggregate object", .{}),
    }
    return fallthrough(self, n);
}

fn variantUnpackHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const dd = self.curImage().destructure_descs[v.a];
            const h = self.runtime.heap.deref(read(self, v.b)) catch |e| return stop(self, heapTrap(self, e));
            if (h.kind != .union_) return trap(self, "variant unpack of a non-union object", .{});
            for (0..dd.dsts_len) |k| {
                const pv = h.cell(1 + k);
                writeDst(self, dd.dsts_start + k, pv);
            }
            if (op == .unpack_variant) self.runtime.heap.freeShell(h);
            return fallthrough(self, n);
        }
    }.run;
}

// --- projections ------------------------------------------------------------------

fn readProjHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const md = self.curImage().member_descs[v.c];
            const h = self.runtime.heap.deref(read(self, v.b)) catch |e| return stop(self, heapTrap(self, e));
            // read_payload's MemberDesc ref indexes the active variant's
            // payload cells, which sit after the tag cell; the spec fixes
            // the ref at 0, so the payload cell is 1 + ref.
            const ref: usize = if (op == .read_payload) 1 + md.ref else md.ref;
            const fv = h.cell(ref);
            retainCell(self, fv) catch |e| return fail(self, e); // a counted read establishes a new owner
            write(self, v.a, fv);
            return fallthrough(self, n);
        }
    }.run;
}

fn hReadIndex(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const base = read(self, v.b);
    const idx: u32 = @truncate(read(self, v.c));
    if (base == 0) return trap(self, "list index {d} out of bounds (empty list)", .{idx});
    const h = self.runtime.heap.deref(base) catch |e| return stop(self, heapTrap(self, e));
    if (idx >= h.len) return trap(self, "list index {d} out of bounds ({d})", .{ idx, h.len });
    var node = h;
    var k = idx;
    while (k > 0) {
        k -= 1;
        node = self.runtime.heap.deref(node.cell(1)) catch |e| return stop(self, heapTrap(self, e));
    }
    const ev = node.cell(0);
    retainCell(self, ev) catch |e| return fail(self, e); // element type from the header
    write(self, v.a, ev);
    return fallthrough(self, n);
}

fn hReadIndexI(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const base = read(self, v.b);
    const idx: u32 = v.c;
    if (base == 0) return trap(self, "list index {d} out of bounds (empty list)", .{idx});
    const h = self.runtime.heap.deref(base) catch |e| return stop(self, heapTrap(self, e));
    if (idx >= h.len) return trap(self, "list index {d} out of bounds ({d})", .{ idx, h.len });
    var node = h;
    var k = idx;
    while (k > 0) {
        k -= 1;
        node = self.runtime.heap.deref(node.cell(1)) catch |e| return stop(self, heapTrap(self, e));
    }
    const ev = node.cell(0);
    retainCell(self, ev) catch |e| return fail(self, e);
    write(self, v.a, ev);
    return fallthrough(self, n);
}

fn hTail(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const base = read(self, v.b);
    if (base == 0) {
        write(self, v.a, 0); // tail of empty is empty
    } else {
        const h = self.runtime.heap.deref(base) catch |e| return stop(self, heapTrap(self, e));
        const nxt = h.cell(1);
        retainCell(self, nxt) catch |e| return fail(self, e); // the result owns its reference
        write(self, v.a, nxt);
    }
    return fallthrough(self, n);
}

fn hConcat(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const ha = self.runtime.heap.deref(read(self, v.b)) catch |e| return stop(self, heapTrap(self, e));
    const hb2 = self.runtime.heap.deref(read(self, v.c)) catch |e| return stop(self, heapTrap(self, e));
    const la = ha.len;
    const lb = hb2.len;
    const h = self.runtime.heap.allocObject(.str_, primTy(self, .str), 0, @intCast(la + lb)) catch |e| return fail(self, e);
    const dstb: [*]u8 = @ptrCast(h.cells);
    @memcpy(dstb[0..la], @as([*]const u8, @ptrCast(ha.cells))[0..la]);
    @memcpy(dstb[la .. la + lb], @as([*]const u8, @ptrCast(hb2.cells))[0..lb]);
    write(self, v.a, @intFromPtr(h));
    return fallthrough(self, n);
}

fn hReadTag(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const h = self.runtime.heap.deref(read(self, v.b)) catch |e| return stop(self, heapTrap(self, e));
    if (h.kind != .union_) return trap(self, "read_tag on a non-union object", .{});
    write(self, v.a, h.cell(0));
    return fallthrough(self, n);
}

// --- 'any' -------------------------------------------------------------------------

fn hTypeIs(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const h = self.runtime.heap.deref(read(self, v.b)) catch |e| return stop(self, heapTrap(self, e));
    if (h.kind != .any_) return trap(self, "type_is on a non-'any' object", .{});
    const pt: u32 = @truncate(h.cell(0));
    write(self, v.a, ValueCodec.encodeBool(pt == v.c));
    return fallthrough(self, n);
}

fn anyPackHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const payload_ty = v.c;
            const pv = read(self, v.b);
            if (op == .any_pack_copy) retainCell(self, pv) catch |e| return fail(self, e); // payload type
            const h = self.runtime.heap.allocObject(.any_, primAnyTy(
                self,
            ), 2, 0) catch |e| return fail(self, e);
            h.setCell(0, payload_ty);
            h.setCell(1, pv);
            write(self, v.a, @intFromPtr(h));
            return fallthrough(self, n);
        }
    }.run;
}

fn anyUnpackHandler(comptime op: llir.Opcode) Handler {
    return struct {
        fn run(self: *VmCtx, n: u32) void {
            const v = self.loaded.code.items[self.runtime.pc];
            const expected = v.c;
            const h = self.runtime.heap.deref(read(self, v.b)) catch |e| return stop(self, heapTrap(self, e));
            if (h.kind != .any_) return trap(self, "unpack of a non-'any' object", .{});
            const pt: u32 = @truncate(h.cell(0));
            if (pt != expected) {
                return trap(self, "'any' tag mismatch: stored {d}, expected {d}", .{ pt, expected });
            }
            const pv = h.cell(1);
            if (op == .any_unpack_copy) {
                retainCell(self, pv) catch |e| return fail(self, e);
            } else {
                // The payload moves out; only the 'any' shell dies.
                h.setCell(1, 0);
                self.runtime.heap.freeShell(h);
            }
            write(self, v.a, pv);
            return fallthrough(self, n);
        }
    }.run;
}

// --- counted lifecycle ---------------------------------------------------------------

fn hRelease(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    releaseCounted(self, read(self, v.a)) catch |e| return stop(self, heapTrap(self, e));
    return fallthrough(self, n);
}

fn hCopyRetain(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const src = read(self, v.b);
    retainCounted(self, src) catch |e| return stop(self, heapTrap(self, e));
    write(self, v.a, src);
    return fallthrough(self, n);
}

fn hReplaceCopy(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    // Retain the source first, then release the old destination owner
    // (Instruction Set §8 ordering).
    const old = read(self, v.a);
    const src = read(self, v.b);
    retainCounted(self, src) catch |e| return stop(self, heapTrap(self, e));
    releaseCounted(self, old) catch |e| return stop(self, heapTrap(self, e));
    write(self, v.a, src);
    return fallthrough(self, n);
}

fn hReplaceMove(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const old = read(self, v.a);
    const src = read(self, v.b);
    releaseCounted(self, old) catch |e| return stop(self, heapTrap(self, e));
    write(self, v.a, src);
    return fallthrough(self, n);
}

fn hDrop(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    const image = self.curImage();
    const imm: u32 = @truncate(v.operand);
    const dd = image.drop_descs[imm];
    const src = read(self, v.a);
    if (src != 0) {
        const h = self.runtime.heap.registry.get(src) orelse return trap(self, "drop of a non-registry value", .{});
        const ty: u32 = if (dd.type_ != llir.no_index) dd.type_ else h.type_id;
        destroyValue(self, ty, src) catch |e| return stop(self, heapTrap(self, e));
    }
    // The drop's effect is complete once destruction is enqueued:
    // advance past it — the chain's common tail drains (a drain that
    // arms a drop hook moves pc to the hook's entry and owns the
    // instruction stream until the hook returns).
    return fallthrough(self, n);
}

// --- undispatchable ------------------------------------------------------------------

/// The undispatchable/reserved-opcode handler: `auipc`/`lui` and the
/// enum holes never reach the image (load-time decode rejects reserved
/// words), so this traps defensively. It is also the table's default.
fn hTrapGeneric(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    _ = n;
    return trap(self, "opcode {s} is not dispatchable", .{llir.opInfo(v.op).name});
}

// --- the comptime handler table -------------------------------------------------------

/// `handlers[@intFromEnum(op)]` is the handler for `op`. Built from an
/// exhaustive switch over every tag of `llir.Opcode` — any opcode
/// without a handler is a compile error (the completeness guard the
/// switch-based dispatch used to provide, docs/interpreter-vm.md §12).
/// Non-tag slots (the enum's 6 holes) keep the undispatchable-trap
/// handler; they are unreachable at runtime because `decodeInstr`
/// rejects reserved words at load.
pub const handlers: [maxOpcodeValue() + 1]Handler = blk: {
    @setEvalBranchQuota(1 << 16);
    var t: [maxOpcodeValue() + 1]Handler = .{hTrapGeneric} ** (maxOpcodeValue() + 1);
    for (std.meta.tags(llir.Opcode)) |op| {
        t[@intFromEnum(op)] = switch (op) {
            .const_ => hConst,
            .fn_ref => hFnRef,
            .add_i32, .add_u32, .add_i64, .add_u64, .sub_i32, .sub_u32, .sub_i64, .sub_u64, .mul_i32, .mul_u32, .mul_i64, .mul_u64, .div_i32, .div_u32, .div_i64, .div_u64, .rem_i32, .rem_u32, .rem_i64, .rem_u64, .min_i32, .min_u32, .min_i64, .min_u64, .max_i32, .max_u32, .max_i64, .max_u64, .shl_i32, .shl_u32, .shl_i64, .shl_u64, .shr_i32, .shr_u32, .shr_i64, .shr_u64, .and_, .or_, .xor, .add_f32, .add_f64, .sub_f32, .sub_f64, .mul_f32, .mul_f64, .div_f32, .div_f64, .rem_f32, .rem_f64, .min_f32, .min_f64, .max_f32, .max_f64 => arithHandler(op),
            .addi_i32, .addi_u32, .addi_i64, .addi_u64, .subi_i32, .subi_u32, .subi_i64, .subi_u64, .muli_i32, .muli_u32, .muli_i64, .muli_u64 => arithImmHandler(op),
            .divi_i32, .divi_u32, .divi_i64, .divi_u64, .remi_i32, .remi_u32, .remi_i64, .remi_u64 => divImmHandler(op),
            .shli_i32, .shli_u32, .shli_i64, .shli_u64, .shri_i32, .shri_u32, .shri_i64, .shri_u64 => shiftImmHandler(op),
            .andi, .ori, .xori => bitImmHandler(op),
            .madd_i32, .madd_u32, .madd_i64, .madd_u64, .msub_i32, .msub_u32, .msub_i64, .msub_u64, .madd_f32, .madd_f64, .msub_f32, .msub_f64 => fmacHandler(op),
            .maddi_i32, .maddi_u32, .maddi_i64, .maddi_u64 => fmacImmHandler(op),
            .neg_i32, .neg_u32, .neg_i64, .neg_u64, .neg_f32, .neg_f64, .abs_i32, .abs_i64, .abs_f32, .abs_f64, .clz_i32, .clz_i64, .popcount_i32, .popcount_i64, .sqrt_f32, .sqrt_f64, .floor_f32, .floor_f64, .ceil_f32, .ceil_f64, .trunc_f32, .trunc_f64, .round_f32, .round_f64 => unaryHandler(op),
            .seq, .seq_f32, .seq_f64, .sne, .sne_f32, .sne_f64, .slt, .sltu, .slt_f32, .slt_f64, .sle_f32, .sle_f64 => cmpHandler(op),
            .seqi, .snei, .slti, .sltiu, .sgti, .sgtiu => cmpImmHandler(op),
            .bool_eq => hBoolEq,
            .bool_ne => hBoolNe,
            .str_eq, .str_ne => strCmpHandler(op),
            .not => hNot,
            .cmov => hCmov,
            .cvt_b_i32, .cvt_b_u32, .cvt_b_i64, .cvt_b_u64, .cvt_b_f32, .cvt_b_f64, .cvt_i32_b, .cvt_i32_u32, .cvt_i32_i64, .cvt_i32_u64, .cvt_i32_f32, .cvt_i32_f64, .cvt_u32_b, .cvt_u32_i32, .cvt_u32_i64, .cvt_u32_u64, .cvt_u32_f32, .cvt_u32_f64, .cvt_i64_b, .cvt_i64_i32, .cvt_i64_u32, .cvt_i64_u64, .cvt_i64_f32, .cvt_i64_f64, .cvt_u64_b, .cvt_u64_i32, .cvt_u64_u32, .cvt_u64_i64, .cvt_u64_f32, .cvt_u64_f64, .cvt_f32_b, .cvt_f32_i32, .cvt_f32_u32, .cvt_f32_i64, .cvt_f32_u64, .cvt_f32_f64, .cvt_f64_b, .cvt_f64_i32, .cvt_f64_u32, .cvt_f64_i64, .cvt_f64_u64, .cvt_f64_f32 => castHandler(op),
            .copy, .move, .borrow => hTransfer,
            .movwn0, .movwn1, .movwn2, .movwn3, .movwz0, .movwz1, .movwz2, .movwz3, .movwk0, .movwk1, .movwk2, .movwk3 => movwHandler(op),
            .spill_take => hSpillTake,
            .spill_put => hSpillPut,
            .slot_copy, .slot_move, .slot_borrow, .slot_retain => slotHandler(op),
            .j => hJ,
            .jal => hJal,
            .jalr => hJalr,
            .take => hTake,
            .beq, .beq_f32, .beq_f64, .bne, .bne_f32, .bne_f64, .blt, .bltu, .blt_f32, .blt_f64, .ble, .bleu, .ble_f32, .ble_f64 => branchHandler(op),
            .beqi, .bnei, .blti, .bltiu => branchImmHandler(op),
            .tbz => hTbz,
            .tbnz => hTbnz,
            .switch_ => hSwitch,
            .jr => hJr,
            .ret => hRet,
            .release_ret => hReleaseRet,
            .tailcall_self => hTailcallSelf,
            .trap => hTrap,
            .syscall => hSyscall,
            .module_ref => hModuleRef,
            .load_member => hLoadMember,
            .store_member => hStoreMember,
            .construct => hConstruct,
            .unpack_struct, .unpack_tuple => hUnpackAggregate,
            .split_list => hSplitList,
            .unpack_variant, .borrow_variant => variantUnpackHandler(op),
            .read_field, .read_tuple, .read_payload => readProjHandler(op),
            .read_index => hReadIndex,
            .read_indexi => hReadIndexI,
            .tail => hTail,
            .concat => hConcat,
            .read_tag => hReadTag,
            .type_is => hTypeIs,
            .any_pack_copy, .any_pack_move => anyPackHandler(op),
            .any_unpack_copy, .any_unpack_move => anyUnpackHandler(op),
            .release => hRelease,
            .copy_retain => hCopyRetain,
            .replace_copy => hReplaceCopy,
            .replace_move => hReplaceMove,
            .drop => hDrop,
            .auipc, .lui => hTrapGeneric,
        };
    }
    break :blk t;
};
comptime {
    // Verify the table's tag→handler mapping at comptime (spike:
    // an always_tail through a misaligned table would dispatch to the
    // wrong handler).
    if (handlers[@intFromEnum(llir.Opcode.ret)] != hRet) @compileError("table: ret misaligned");
    if (handlers[@intFromEnum(llir.Opcode.construct)] != hConstruct) @compileError("table: construct misaligned");
    if (handlers[@intFromEnum(llir.Opcode.take)] != hTake) @compileError("table: take misaligned");
}

// ---------------------------------------------------------------------------
// Execution-layer helpers (moved from `interpreter.zig`): register access,
// trap plumbing, the call/return path, the dispatch loop, numeric/compare/
// cast semantics, and the handler-used heap lifecycle ops. These are free
// functions taking `self: *VmCtx` — the `VmCtx` struct exposes no method
// surface for them; handlers, host adapters, and tests call them directly.
// ---------------------------------------------------------------------------

fn saturateF32ToI32(f: f32) i32 {
    if (std.math.isNan(f)) return 0;
    if (f >= 2147483648.0) return std.math.maxInt(i32);
    if (f <= -2147483649.0) return std.math.minInt(i32);
    return @intFromFloat(@trunc(f));
}

fn saturateF32ToU32(f: f32) Value {
    // Truncate toward zero at binary32 precision; saturate into
    // [0, 2^32) — NaN maps to 0.
    if (std.math.isNan(f) or f <= 0) return 0;
    if (f >= 4294967296.0) return 0xffff_ffff;
    return @as(Value, @intFromFloat(@trunc(f)));
}

fn saturateF32ToByte(f: f32) Value {
    if (std.math.isNan(f) or f <= 0) return 0;
    if (f >= 255.0) return 0xff;
    return @as(Value, @intFromFloat(@trunc(f)));
}

fn saturateF64ToI32(d: f64) i32 {
    // Truncate toward zero at binary64 precision (no f32 narrowing — a
    // value between 2^31 and 2^32 must saturate, not round).
    if (std.math.isNan(d)) return 0;
    if (d >= 2147483648.0) return std.math.maxInt(i32);
    if (d <= -2147483649.0) return std.math.minInt(i32);
    return @intFromFloat(@trunc(d));
}

fn saturateF64ToU32(d: f64) Value {
    if (std.math.isNan(d) or d <= 0) return 0;
    if (d >= 4294967296.0) return 0xffff_ffff;
    return @as(Value, @intFromFloat(@trunc(d)));
}

fn saturateF64ToByte(d: f64) Value {
    if (std.math.isNan(d) or d <= 0) return 0;
    if (d >= 255.0) return 0xff;
    return @as(Value, @intFromFloat(@trunc(d)));
}

/// Register read: specials supply the operand type's canonical
/// all-zero cell — the type comes from the resolved contract, never
/// from bits (docs/interpreter-vm.md §4.2). `ra` is never read
/// here (the validator restricts it to the call handlers). Frame
/// registers resolve through the piecewise map (spec §3.1): locals
/// `F(reg) = fp + frameIndex(reg)` for `frameIndex(reg) < f_count`,
/// window aliases
/// `F(reg) = callBase(fp, f) + (frameIndex(reg) - f_count)` for
/// `frameIndex(reg) >= f_count`. The zero/cond/ra/T block is one
/// bounds check into the fast bank.
pub inline fn read(self: *VmCtx, reg: llir.ValueReg) Value {
    if (reg < llir.fast_reg_count) return self.runtime.fast_regs[reg]; // zero (0), cond (1), ra (2), T0–T15 (3..18)
    return self.runtime.stack.items[
        llir.frameCell(self.runtime.fp, curFn(
            self,
        ), reg)
    ];
}

/// Register write: `zero` and `ra` drop after effects; everything
/// else stores the raw cell. Frame registers resolve through the
/// same piecewise map as `read`.
pub inline fn write(self: *VmCtx, reg: llir.ValueReg, v: Value) void {
    if (reg < llir.fast_reg_count) {
        // zero (index 0) and ra (index 2, the reserved hole) are
        // discard-only: zero writes drop, ra is call-convention-only.
        if (reg != llir.zero_reg and reg != llir.ra_reg) self.runtime.fast_regs[reg] = v;
        return;
    }
    self.runtime.stack.items[
        llir.frameCell(self.runtime.fp, curFn(
            self,
        ), reg)
    ] = v;
}

pub inline fn curFn(self: *VmCtx) llir.FunctionDesc {
    return self.loaded.funcs.items[self.runtime.current_fn].desc;
}

fn trapMsg(self: *VmCtx, comptime fmt: []const u8, args: anytype) Termination {
    // The site travels in the message (`Termination.panic`,
    // interpreter_types.zig): the CLI prints it verbatim, so a panic
    // output names where execution stopped.
    const site = siteDescription(self);
    defer if (site) |s| self.allocator.free(s);
    const m = if (site) |s|
        std.fmt.allocPrint(self.allocator, "trap at pc {d} in {s}: " ++ fmt, .{self.runtime.pc} ++ .{s} ++ args) catch
            return .{ .panic = "out of memory while formatting a trap" }
    else
        std.fmt.allocPrint(self.allocator, "trap at pc {d}: " ++ fmt, .{self.runtime.pc} ++ args) catch
            return .{ .panic = "out of memory while formatting a trap" };
    return .{ .panic = m };
}

/// "<module-symbol>#<local-function-id>" for the function executing
/// at `pc`. Best-effort: never traps itself.
fn siteDescription(self: *VmCtx) ?[]const u8 {
    const m = self.curMod();
    return std.fmt.allocPrint(self.allocator, "{s}#{d}", .{ m.symbol, self.runtime.current_fn - m.func_base }) catch null;
}

/// Prefix a host-supplied panic message with the trap site, so CLI
/// panic output names where execution stopped even for `builtin.panic`.
/// Consumes `m` (frees it) and returns the owned prefixed message.
pub fn sitePrefixed(self: *VmCtx, m: []const u8) []const u8 {
    // Copy `m` into an owned message (Termination owns it). `m` is
    // NOT freed: host panic messages may be string literals or
    // str-cell slices, never owned by the VM.
    const site = siteDescription(self) orelse
        return self.allocator.dupe(u8, m) catch m;
    defer self.allocator.free(site);
    return std.fmt.allocPrint(self.allocator, "panic in {s} at pc {d}: {s}", .{ site, self.runtime.pc, m }) catch
        self.allocator.dupe(u8, m) catch m;
}

/// Enter a dynamic callee (`jalr`, spec §5.3): resolve the runtime
/// target against the whole function registry (every loaded module)
/// and validate that it is a function entry, then hand off to the
/// shared frame-setup core `enterCalleeId`. Static `jal` does not
/// route through here — its callee registry index is resolved at
/// load (publishArtifact) and read straight from the instruction.
pub fn enterJalr(self: *VmCtx, target: u32) !?Termination {
    const callee_id = functionAtPc(self.loaded.funcs.items, target) orelse
        return trapMsg(self, "call target {d} is not a function entry", .{target});
    // Only a function entry is a legal call target — `functionAtPc`
    // returns the containing function for any interior pc, so a
    // dynamic `jalr` into the middle of a function must be rejected,
    // never silently redirected to the entry (spec §5.2).
    const callee = self.loaded.funcs.items[callee_id].desc;
    if (target != callee.entry_pc) {
        return trapMsg(self, "call target {d} is not a function entry", .{target});
    }
    return enterCalleeId(self, callee_id, false);
}

/// The one **failure-atomic** call handler shared by `jal ra` and
/// `jalr`: validate the callee, the value-area/window bounds, the
/// take-at-return-pc contract, and the full frame end — then
/// commit: `ra = pc + 1`, the three-cell header `{ saved_fp,
/// saved_fn, saved_ra }` at `[fp_callee - 3, fp_callee)`, and the
/// frame switch. Any failure happens before a header write, an `ra`
/// write, or a frame switch. `enterJalr` resolves the dynamic
/// target and forwards the registry index; static `jal` forwards
/// the index already stored in its operand by the load.
pub fn enterCalleeId(self: *VmCtx, callee_id: u32, allow_coalesced: bool) !?Termination {
    const callee = self.loaded.funcs.items[callee_id].desc;
    const a: u32 = self.loaded.funcs.items[callee_id].a();
    if (callee.f_count < a) {
        return trapMsg(self, "callee frame too small for the value area", .{});
    }
    // The value area plus its three-cell header must fit inside the
    // caller's output window — `A ≤ O` (spec §5.3); the result
    // alias `F(L+3+O-A)` is a caller register.
    const caller = curFn(
        self,
    );
    if (a > llir.outCount(caller)) {
        return trapMsg(self, "callee value area exceeds the caller output window", .{});
    }
    if (self.runtime.sp < a) return trapMsg(self, "call underflows the stack", .{});
    const new_fp = self.runtime.sp - a;
    const end: usize = llir.frameEnd(new_fp, callee);
    try self.ensure(end); // reserve before any write (failure atomicity)
    if (!takeContract(self, callee_id, caller, a, self.runtime.pc + 1, allow_coalesced)) {
        return trapMsg(self, "take contract mismatch at the call return pc", .{});
    }
    // Commit: ra = pc + 1; the header records the caller's frame
    // base and function index, and this callee's return pc (nested
    // calls may overwrite `ra` without losing the outer link).
    const ra = self.runtime.pc + 1;
    const hb = new_fp - 3;
    self.runtime.stack.items[hb + 0] = self.runtime.fp; // saved_fp: the caller's frame base
    self.runtime.stack.items[hb + 1] = self.runtime.current_fn; // saved_fn: the caller's function registry index
    self.runtime.stack.items[hb + 2] = ra; // saved_ra: this callee's return pc
    self.runtime.fp = new_fp;
    self.runtime.sp = @intCast(end);
    self.runtime.pc = callee.entry_pc;
    self.runtime.current_fn = callee_id;
    return null;
}

/// The result contract at a call's return pc (spec §5.2): a non-void
/// callee must either see a *matching* `take dst, F(L+3+O-A)`
/// immediately after the call's fallthrough — the take's source
/// register derives the implied `A = L + 3 + O - src`, which must
/// equal the dynamic callee's value area — or, for a static `jal`
/// (Step 8 coalesced: `allow_coalesced`), no take at all (the result
/// stays in the caller's result alias). A void callee must see no
/// take. The loader checks it for static `jal`; `enterCalleeId`
/// performs the same check for `jalr` after resolving the actual
/// callee.
fn takeContract(self: *VmCtx, callee_id: u32, caller: llir.FunctionDesc, a: u32, ret_pc: u32, allow_coalesced: bool) bool {
    if (ret_pc >= self.loaded.code.items.len) return false;
    const nd = self.loaded.code.items[ret_pc];
    if (self.loaded.funcs.items[callee_id].hasRet()) {
        // A coalesced call (static jal) may have no take — the
        // fallthrough consumes the result alias directly.
        if (nd.op != .take) return allow_coalesced;
        return nd.b == llir.frameReg(caller.f_count + caller.window_count - a);
    }
    return nd.op != .take;
}

/// Leave a frame (spec §5.4): decode + validate the header, publish
/// the result to slot 0, restore the caller's `sp/fp/pc`. The root
/// header (`invalid_pc`) terminates normally.
pub fn returnFrom(self: *VmCtx, v: VmInstr) !?Termination {
    const fe = self.loaded.funcs.items[self.runtime.current_fn];
    const a: u32 = fe.a();
    const result: Value = read(self, v.a);
    const hdr = readHeader(self.runtime.stack.items, self.runtime.fp);
    if (!hdr.check(self.loaded.funcs.items, self.runtime.fp)) {
        return trapMsg(self, "corrupt frame header", .{});
    }
    if (hdr.saved_ra == invalid_pc) {
        return Termination{ .normal = result };
    }
    // Publish the result to slot 0 — the callee's F0, which is the
    // caller's value-area slot 0 (`callBase(fp_caller) + (W - A)`);
    // a void return writes nothing. The caller's take
    // consumes the slot.
    if (fe.hasRet()) {
        self.runtime.stack.items[self.runtime.fp] = result;
    }
    // Restore the caller: sp = fp_callee + A; fp = saved_fp;
    // current_fn = saved_fn; pc = saved_ra.
    self.runtime.sp = self.runtime.fp + a;
    self.runtime.fp = hdr.saved_fp;
    if (hdr.saved_ra == vm_internal_pc) {
        const cont = self.runtime.continuations.pop() orelse return trapMsg(self, "missing VM continuation", .{});
        // The interrupted frame's identity is already in the header
        // (`saved_fp`, restored above; `saved_fn`); its `sp` is its
        // frame end — `sp` equals `frameEnd(current frame)` at every
        // instruction boundary, and the runtime call was pushed from
        // one.
        self.runtime.current_fn = hdr.saved_fn;
        self.runtime.sp = llir.frameEnd(hdr.saved_fp, self.loaded.funcs.items[hdr.saved_fn].desc);
        switch (cont.kind) {
            .hook => {
                // Resume the interrupted instruction: `resume_pc` is
                // the pc at the time the destruction drain armed the
                // hook — the instruction after the drop/release that
                // enqueued the doomed object (the `.drop` arm advances
                // before draining). Draining may arm a new hook,
                // which takes over pc. The flag tells the `ret`
                // handler to stop the chain so the run loop re-drives
                // from the (possibly new) hook state.
                self.runtime.pc = cont.resume_pc;
                self.runtime.popped_hook_cont = true;
                try self.drainDestroyWork();
            },
            .module => |m| {
                self.loaded.modules.items[m].state = .initialized;
                self.runtime.pc = cont.resume_pc;
            },
        }
        return null;
    }
    self.runtime.pc = hdr.saved_ra;
    self.runtime.current_fn = hdr.saved_fn; // the caller, recorded at the call — O(1), no scan
    return null; // keep running
}

/// Self-tailcall (spec §11.2): reuses the frame — no header is
/// written, `fp` is preserved, `ra` is not rewritten, and the stack
/// cannot grow. The `slot_*` preparation records have written the new
/// arguments into the frame's own window; atomically move prepared
/// window slot `W - P + k` into parameter cell `Fk` for every
/// parameter `k`, clearing each window slot, then set `sp` to the
/// frame end and `pc` to the entry.
pub fn tailcallSelf(self: *VmCtx) !void {
    const f = curFn(
        self,
    );
    const fe = self.loaded.funcs.items[self.runtime.current_fn];
    const p: u32 = fe.arity.params;
    const base = f.window_count - p;
    for (0..p) |k| {
        const wslot = llir.callBase(self.runtime.fp, f) + base + @as(u32, @intCast(k));
        const v = self.runtime.stack.items[wslot];
        self.runtime.stack.items[wslot] = ValueCodec.zero;
        // Parameter cell Fk aliases `fp + k` (parameters always live
        // in the F area: `p <= f_count`).
        self.runtime.stack.items[self.runtime.fp + @as(u32, @intCast(k))] = v;
    }
    self.runtime.sp = llir.frameEnd(self.runtime.fp, f);
    self.runtime.pc = f.entry_pc;
}

/// Execute one decoded instruction; returns a termination when the
/// context stops (root ret, panic/trap). Public for tests and
/// step-wise hosts. The VM indexes its decoded image directly — no
/// wire decoding happens on the execution path.
///
/// The execution model is token-based indirect threading
/// (docs/interpreter-vm.md §1, §7): the decoded opcode
/// (`VmInstr.op`) indexes a comptime handler table and each
/// instruction is one indirect `always_tail` jump to its per-opcode
/// handler; handlers tail-jump to the next instruction's handler.
/// Threaded functions return `void` — termination and errors travel
/// out-of-band in `result` / `pending_err` / `popped_hook_cont`.
pub fn step(self: *VmCtx) !?Termination {
    if (self.runtime.terminated) return Termination{ .normal = 0 };
    self.runtime.result = null;
    self.runtime.pending_err = null;
    self.runtime.popped_hook_cont = false;
    dispatch(self, 1);
    if (self.runtime.pending_err) |e| return e;
    if (self.runtime.result) |t| {
        self.runtime.terminated = true;
        return t;
    }
    return null;
}

pub fn intTrap(self: *VmCtx, e: IntErr) Termination {
    return switch (e) {
        error.DivByZero => trapMsg(self, "division by zero", .{}),
        error.DivOverflow => trapMsg(self, "signed division overflow (min / -1)", .{}),
    };
}

/// Stop the chain with a termination (normal root return, panic, or
/// trap message): the dispatch loop observes `result` and returns.
pub inline fn stop(self: *VmCtx, t: Termination) void {
    self.runtime.result = t;
}

/// Stop the chain with a trap message.
pub inline fn trap(self: *VmCtx, comptime fmt: []const u8, args: anytype) void {
    self.runtime.result = trapMsg(self, fmt, args);
}

/// Stop the chain with a Zig error to propagate from `step` (the
/// RunError surface is unchanged — every failing helper's error set
/// is a subset of `RunError`).
pub inline fn fail(self: *VmCtx, e: RunError) void {
    self.runtime.pending_err = e;
}

/// Entry: dispatch the instruction `v` — one indirect jump to its
/// per-opcode handler. Called only by `step` and `runLoop` (with a
/// step budget `n`). The chain's functions all share the handler
/// signature: `@call(.always_tail, ...)` requires the caller's
/// signature to match the callee's.
pub fn dispatch(self: *VmCtx, n: u32) void {
    const v = self.loaded.code.items[self.runtime.pc];
    return @call(.always_tail, handlers[@intFromEnum(v.op)], .{ self, n });
}

/// Common chain tail: drain destruction (may arm a drop hook → moves
/// pc to the hook's entry), stop at the step budget, fetch the next
/// token, and tail-jump to its handler. `v` is the just-executed
/// instruction (carried only to keep the chain signature uniform).
pub inline fn next(self: *VmCtx, n: u32) void {
    if (self.runtime.destroy_work.items.len != 0) {
        self.drainDestroyWork() catch |e| return fail(self, e);
    }
    if (n == 1) return; // step mode: exactly one instruction
    const nv = self.loaded.code.items[self.runtime.pc];
    return @call(.always_tail, handlers[@intFromEnum(nv.op)], .{ self, n - 1 });
}

/// Fallthrough ops: advance pc, then the common tail.
pub inline fn fallthrough(self: *VmCtx, n: u32) void {
    self.runtime.pc += 1;
    return next(self, n);
}

pub fn strEqual(self: *VmCtx, a: Value, b: Value) HeapErr!bool {
    if (a == b) return true;
    const ah = try self.runtime.heap.deref(a);
    const bh = try self.runtime.heap.deref(b);
    if (ah.kind != .str_ or bh.kind != .str_) return error.TypeMismatch;
    const ab = @as([*]const u8, @ptrCast(ah.cells))[0..ah.len];
    const bb = @as([*]const u8, @ptrCast(bh.cells))[0..bh.len];
    return std.mem.eql(u8, ab, bb);
}

/// True when `ty` names a heap-represented value (pointer cells).
fn isRefType(self: *VmCtx, ty: u32) bool {
    const types = self.metaImage().types;
    if (ty >= types.len) return false;
    return switch (types[ty].kind) {
        .list, .box, .named => true,
        .primitive => blk: {
            const pa = types[ty].a;
            const p: llir.PrimitiveId = if (pa <= @intFromEnum(llir.PrimitiveId.hostdata)) @enumFromInt(pa) else break :blk false;
            break :blk p == .str or p == .any or p == .hostdata;
        },
        else => false,
    };
}

/// Retain a cell whose static type is `ty`: scalars are values, not
/// pointers, so only reference-typed cells touch the registry.
pub fn retainCell(self: *VmCtx, addr: Value) HeapErr!void {
    // The registry is the runtime type authority: registered
    // objects retain by their header's own type; unregistered
    // cells (scalars, or values written by validated code) are
    // silently skipped. The explicit membership traps for the
    // counted lifecycle opcodes stay in their dispatch arms.
    if (addr == 0) return;
    const h = self.runtime.heap.registry.get(addr) orelse return;
    if (!isRefType(self, h.type_id)) return;
    if (!h.isCounted()) return; // unique shells are not shared
    h.track.CopyValue += 1;
}

/// Destroy a value by exact type metadata — enqueued, then expanded
/// by `drainDestroyWork` (children before shells, no recursion).
pub fn destroyValue(self: *VmCtx, type_id: u32, addr: Value) !void {
    if (addr == 0) return;
    try self.runtime.destroy_work.append(self.allocator, .{ .value = .{ .type_id = type_id, .addr = addr } });
}

/// Release one counted reference: decrement; destruction enqueues
/// at zero. Forged pointers trap before anything mutates; a counted
/// lifecycle op on a unique shell is a contract violation.
pub fn releaseCounted(self: *VmCtx, addr: Value) HeapErr!void {
    if (addr == 0) return;
    const h = self.runtime.heap.registry.get(addr) orelse return error.ForgedPointer;
    if (!h.isCounted()) return error.TypeMismatch;
    if (h.track.CopyValue > 0) h.track.CopyValue -= 1;
    if (h.track.CopyValue == 0) try destroyValue(self, h.type_id, addr);
}

pub fn retainCounted(self: *VmCtx, addr: Value) HeapErr!void {
    if (addr == 0) return;
    const h = self.runtime.heap.registry.get(addr) orelse return error.ForgedPointer;
    if (!h.isCounted()) return error.TypeMismatch;
    h.track.CopyValue += 1;
}

/// `construct`: allocate the aggregate described by the descriptor
/// and retain each counted component written into it.
pub fn opConstruct(self: *VmCtx, d: VmInstr) HeapErr!void {
    const image = self.curImage();
    const dd = image.construct_descs[@truncate(d.operand)];
    const ty = dd.result_type;
    const row = image.types[ty];
    var out: Value = 0;
    switch (row.kind) {
        .list => {
            // Immutable cons chain built right to left; zero
            // components build the canonical empty list cell.
            // Each node records its suffix length (the number of
            // elements from this node to the end) so the head's
            // `len` is the list's element count — the O(1) read
            // `list#len` and `read_index` rely on (M2).
            var nxt: Value = 0;
            var suffix_len: u32 = 0;
            var k = dd.args_len;
            while (k > 0) {
                k -= 1;
                const h = try self.runtime.heap.allocObjectIn(.list_cons, self.curModIdx(), ty, 2, 0);
                const ev = read(self, image.call_args[dd.args_start + k]);
                h.setCell(0, ev);
                try retainCell(self, ev);
                h.setCell(1, nxt);
                h.len = suffix_len + 1;
                suffix_len += 1;
                nxt = @intFromPtr(h);
            }
            out = nxt;
        },
        .box => {
            const h = try self.runtime.heap.allocObjectIn(.box_, self.curModIdx(), ty, 0, 1);
            const v = read(self, image.call_args[dd.args_start]);
            h.setCell(0, v);
            try retainCell(self, v); // boxed element type
            out = @intFromPtr(h);
        },
        .tuple => {
            // The tuple row's range is `{ a = start, b = len }`
            // into `types` — the element count is `b`, not
            // `b - a` (the range start is a table offset).
            const n: usize = row.b;
            const h = try self.runtime.heap.allocObjectIn(.tuple_, self.curModIdx(), ty, n, 0);
            for (0..n) |k| {
                const v = read(self, image.call_args[dd.args_start + @as(u32, @intCast(k))]);
                h.setCell(k, v);
                try retainCell(self, v); // tuple element type
            }
            out = @intFromPtr(h);
        },
        .named => {
            const decl = image.type_decls[row.a];
            switch (decl.kind) {
                .struct_ => {
                    const n: usize = decl.d -| decl.c;
                    const h = try self.runtime.heap.allocObjectIn(.struct_, self.curModIdx(), ty, n, 0);
                    for (0..n) |k| {
                        const v = read(self, image.call_args[dd.args_start + @as(u32, @intCast(k))]);
                        h.setCell(k, v);
                        const ft = image.type_decl_fields[decl.c + k];
                        if (ft != llir.no_index) try retainCell(self, v); // field type
                    }
                    out = @intFromPtr(h);
                },
                .union_ => {
                    const h = try self.runtime.heap.allocObjectIn(.union_, self.curModIdx(), ty, 1 + dd.args_len, 0);
                    h.setCell(0, dd.tag);
                    const variant = image.union_variants[decl.b + dd.tag];
                    for (0..dd.args_len) |k| {
                        const v = read(self, image.call_args[dd.args_start + @as(u32, @intCast(k))]);
                        h.setCell(1 + k, v);
                        const pt = image.union_payloads[variant.payloads_start + k];
                        if (pt != llir.no_index) try retainCell(self, v); // payload type
                    }
                    out = @intFromPtr(h);
                },
                else => return error.BadConstruct,
            }
        },
        else => return error.BadConstruct,
    }
    write(self, d.a, out);
}

/// True when `ty` names one of the 64-bit scalar types whose
/// canonical cells carry all 64 bits.
pub inline fn isWidePrim(self: *VmCtx, ty: u32) bool {
    const types = self.metaImage().types;
    if (ty >= types.len) return false;
    const td = types[ty];
    if (td.kind != .primitive) return false;
    return switch (td.a) {
        @intFromEnum(llir.PrimitiveId.int64),
        @intFromEnum(llir.PrimitiveId.uint64),
        @intFromEnum(llir.PrimitiveId.float64),
        => true,
        else => false,
    };
}

pub inline fn isInt32Prim(self: *VmCtx, ty: u32) bool {
    const types = self.metaImage().types;
    if (ty >= types.len) return false;
    const td = types[ty];
    return td.kind == .primitive and td.a == @intFromEnum(llir.PrimitiveId.int32);
}

pub inline fn canonicalIntResult(op: llir.Opcode, value: Value) Value {
    return switch (llir.repOf(op) orelse return value) {
        .i32 => ValueCodec.extendInt32Bits(@truncate(value)),
        .u32 => @as(u64, @as(u32, @truncate(value))),
        else => value,
    };
}

pub fn heapTrap(self: *VmCtx, e: HeapErr) Termination {
    return switch (e) {
        error.ForgedPointer => trapMsg(self, "pointer failed the live-object registry check", .{}),
        error.NullDeref => trapMsg(self, "illegal null (null is only the empty list)", .{}),
        error.TypeMismatch => trapMsg(self, "object header type does not match the expected type", .{}),
        error.OutOfMemory => trapMsg(self, "out of memory", .{}),
        error.StackOverflow => trapMsg(self, "stack limit exceeded", .{}),
        error.BadConstruct => trapMsg(self, "construct of an unexpected type shape", .{}),
    };
}

pub fn primAnyTy(self: *VmCtx) u32 {
    return primTy(self, .any);
}

/// The TypeId of one primitive family in this image's type table
/// (no_index when absent).
pub fn primTy(self: *VmCtx, id: llir.PrimitiveId) u32 {
    for (self.metaImage().types, 0..) |td, i| {
        if (td.kind == .primitive and td.a == @intFromEnum(id)) return @intCast(i);
    }
    return llir.no_index;
}

/// Write a destructure destination from the side-table row.
/// Destructure rows name plain F cells or T registers (never
/// window aliases or specials — the validator enforces it).
pub fn writeDst(self: *VmCtx, dst_idx: usize, v: Value) void {
    const dst = self.curImage().destructure_dsts[dst_idx];
    if (dst < llir.fast_reg_count) {
        // Destructure destinations are F cells or T registers — never
        // zero or ra — so both guards are defensive.
        if (dst != llir.zero_reg and dst != llir.ra_reg) self.runtime.fast_regs[dst] = v;
    } else {
        self.runtime.stack.items[self.runtime.fp + llir.frameIndex(dst)] = v;
    }
}

// Numeric helpers — explicit width handling per the frozen numeric
// semantics (mod 2^32, shift counts mod 32, division traps). The
// resolved representation decides signedness where the merged opcode
// family leaves it open (`div` on uint32 cells divides unsigned).

pub const IntErr = error{ DivByZero, DivOverflow };

/// One register-form integer operation over raw 32-bit patterns.
/// `wide` selects the unsigned interpretation wherever the opcode
/// family is signedness-ambiguous.
// v9 rep-dispatched arithmetic helpers. The `Fam` enum is the
// semantic family of a typed opcode; `familyOf` classifies via one
// exhaustive grouped switch. Integer arithmetic wraps modulo 2³² or
// 2⁶⁴ (WebAssembly semantics); the rep carries signedness for the
// sign-sensitive ops (div/rem/min/max/shr).

const Fam = enum {
    add,
    sub,
    mul,
    div,
    rem,
    min,
    max,
    shl,
    shr,
    and_,
    or_,
    xor,
    madd,
    msub,
    neg,
    abs,
    clz,
    popcount,
    sqrt,
    floor,
    ceil,
    trunc,
    round,
    seq,
    sne,
    slt,
    sle,
    beq,
    bne,
    blt,
    ble,
    cvt,
    none,
};

inline fn familyOf(op: llir.Opcode) Fam {
    return switch (op) {
        .add_i32, .add_u32, .add_i64, .add_u64, .add_f32, .add_f64 => .add,
        .sub_i32, .sub_u32, .sub_i64, .sub_u64, .sub_f32, .sub_f64 => .sub,
        .mul_i32, .mul_u32, .mul_i64, .mul_u64, .mul_f32, .mul_f64 => .mul,
        .div_i32, .div_u32, .div_i64, .div_u64, .div_f32, .div_f64 => .div,
        .rem_i32, .rem_u32, .rem_i64, .rem_u64, .rem_f32, .rem_f64 => .rem,
        .min_i32, .min_u32, .min_i64, .min_u64, .min_f32, .min_f64 => .min,
        .max_i32, .max_u32, .max_i64, .max_u64, .max_f32, .max_f64 => .max,
        .shl_i32, .shl_u32, .shl_i64, .shl_u64 => .shl,
        .shr_i32, .shr_u32, .shr_i64, .shr_u64 => .shr,
        .and_, .or_, .xor => .and_,
        .madd_i32, .madd_u32, .madd_i64, .madd_u64, .madd_f32, .madd_f64 => .madd,
        .msub_i32, .msub_u32, .msub_i64, .msub_u64, .msub_f32, .msub_f64 => .msub,
        .neg_i32, .neg_u32, .neg_i64, .neg_u64, .neg_f32, .neg_f64 => .neg,
        .abs_i32, .abs_i64, .abs_f32, .abs_f64 => .abs,
        .clz_i32, .clz_i64 => .clz,
        .popcount_i32, .popcount_i64 => .popcount,
        .sqrt_f32, .sqrt_f64 => .sqrt,
        .floor_f32, .floor_f64 => .floor,
        .ceil_f32, .ceil_f64 => .ceil,
        .trunc_f32, .trunc_f64 => .trunc,
        .round_f32, .round_f64 => .round,
        .seq, .seq_f32, .seq_f64 => .seq,
        .sne, .sne_f32, .sne_f64 => .sne,
        .slt, .sltu, .slt_f32, .slt_f64 => .slt,
        .sle_f32, .sle_f64 => .sle,
        .beq, .beq_f32, .beq_f64 => .beq,
        .bne, .bne_f32, .bne_f64 => .bne,
        .blt, .bltu, .blt_f32, .blt_f64 => .blt,
        .ble, .bleu, .ble_f32, .ble_f64 => .ble,
        .cvt_b_i32, .cvt_b_u32, .cvt_b_i64, .cvt_b_u64, .cvt_b_f32, .cvt_b_f64, .cvt_i32_b, .cvt_i32_u32, .cvt_i32_i64, .cvt_i32_u64, .cvt_i32_f32, .cvt_i32_f64, .cvt_u32_b, .cvt_u32_i32, .cvt_u32_i64, .cvt_u32_u64, .cvt_u32_f32, .cvt_u32_f64, .cvt_i64_b, .cvt_i64_i32, .cvt_i64_u32, .cvt_i64_u64, .cvt_i64_f32, .cvt_i64_f64, .cvt_u64_b, .cvt_u64_i32, .cvt_u64_u32, .cvt_u64_i64, .cvt_u64_f32, .cvt_u64_f64, .cvt_f32_b, .cvt_f32_i32, .cvt_f32_u32, .cvt_f32_i64, .cvt_f32_u64, .cvt_f32_f64, .cvt_f64_b, .cvt_f64_i32, .cvt_f64_u32, .cvt_f64_i64, .cvt_f64_u64, .cvt_f64_f32 => .cvt,
        else => .none,
    };
}

/// One register-form binary operation. The typed integer opcode names
/// its rep: the VM truncates each canonical cell to the named width,
/// computes at that width, and canonicalizes the result (an `.i32`
/// result sign-extends, a `.u32` result zero-extends — Instruction Set
/// §4). Signed division sign-extends to `i64` for the divide itself, so
/// the 32-bit `int32_min / -1` case computes the exact quotient
/// `2^31` whose low 32 bits wrap to `int32_min` — no trap, per the
/// Runtime Specification; the 64-bit `i64_min / -1` case traps
/// (`error.DivOverflow`). The float members dispatch on their rep.
pub inline fn binOp(self: *VmCtx, op: llir.Opcode, av: Value, bv: Value) IntErr!Value {
    _ = self;
    const fam = familyOf(op);
    if (op == .add_f32 or op == .sub_f32 or op == .mul_f32 or op == .div_f32 or op == .rem_f32 or op == .min_f32 or op == .max_f32) {
        const a = ValueCodec.decodeFloat32(av) orelse 0;
        const b = ValueCodec.decodeFloat32(bv) orelse 0;
        const r: f32 = switch (fam) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => a / b,
            .rem => @rem(a, b), // IEEE: x % 0.0 is NaN — never traps
            .min => vm_types.fminIeee(f32, a, b),
            .max => vm_types.fmaxIeee(f32, a, b),
            else => unreachable,
        };
        return ValueCodec.encodeFloat32(r);
    }
    if (op == .add_f64 or op == .sub_f64 or op == .mul_f64 or op == .div_f64 or op == .rem_f64 or op == .min_f64 or op == .max_f64) {
        const a: f64 = @bitCast(av);
        const b: f64 = @bitCast(bv);
        const r: f64 = switch (fam) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => a / b,
            .rem => @rem(a, b), // IEEE: x % 0.0 is NaN — never traps
            .min => vm_types.fminIeee(f64, a, b),
            .max => vm_types.fmaxIeee(f64, a, b),
            else => unreachable,
        };
        return @bitCast(r);
    }
    // The widthless bitwise ops carry no rep (`repOf` is null) and write
    // their raw 64-bit result; the lowering canonicalizes to the operand
    // width where a narrower type demands it.
    if (op == .and_ or op == .or_ or op == .xor) {
        const a: u64 = av;
        const b: u64 = bv;
        return switch (op) {
            .and_ => a & b,
            .or_ => a | b,
            .xor => a ^ b,
            else => unreachable,
        };
    }
    // The typed integer path. The canonical-cell contract makes every
    // width computable at 64 bits: an `i32` cell is the sign-extension
    // of its low 32 bits (so signed 64-bit arithmetic on the cell gives
    // the exact 32-bit signed result, whose low bits canonicalize), and
    // a `u32` cell is zero-extended (so unsigned 64-bit arithmetic is
    // the exact width result). Only the shift-count mask is width-
    // specific; `canonicalIntResult` restores the rep's cell form.
    const rep = llir.repOf(op) orelse unreachable;
    const signed = rep == .i32 or rep == .i64;
    const count_mask: u6 = if (rep == .i32 or rep == .u32) 31 else 63;
    const a: u64 = av;
    const b: u64 = bv;
    return switch (fam) {
        .add => canonicalIntResult(op, a +% b),
        .sub => canonicalIntResult(op, a -% b),
        .mul => canonicalIntResult(op, a *% b),
        .div => blk: {
            if (b == 0) return error.DivByZero;
            if (signed) {
                // `i64_min / -1` traps — an `i32` canonical cell can
                // never equal `i64_min`, so the check only ever fires at
                // the 64-bit rep; the 32-bit `i32_min / -1` exact
                // quotient 2^31 truncates to `i32_min` (no trap, the
                // Runtime Specification's wrap).
                if (a == (1 << 63) and b == std.math.maxInt(u64)) return error.DivOverflow;
                const sa: i64 = @bitCast(a);
                const sb: i64 = @bitCast(b);
                break :blk canonicalIntResult(op, @as(u64, @bitCast(@divTrunc(sa, sb))));
            }
            break :blk a / b; // zero-extended cells: exact at the width
        },
        .rem => blk: {
            if (b == 0) return error.DivByZero;
            if (signed) {
                const sa: i64 = @bitCast(a);
                const sb: i64 = @bitCast(b);
                break :blk canonicalIntResult(op, @as(u64, @bitCast(@rem(sa, sb)))); // i*_min % -1 == 0, never traps
            }
            break :blk a % b;
        },
        .min => if (signed) @bitCast(@min(@as(i64, @bitCast(a)), @as(i64, @bitCast(b)))) else @min(a, b),
        .max => if (signed) @bitCast(@max(@as(i64, @bitCast(a)), @as(i64, @bitCast(b)))) else @max(a, b),
        .shl => canonicalIntResult(op, a << @as(u6, @intCast(b & count_mask))),
        .shr => if (signed)
            canonicalIntResult(op, @as(u64, @bitCast(@as(i64, @bitCast(a)) >> @as(u6, @intCast(b & count_mask)))))
        else
            canonicalIntResult(op, a >> @as(u6, @intCast(b & count_mask))),
        else => unreachable,
    };
}

/// The sign extension of a width-`w` unsigned value to `i64` (the
/// canonical-cell form of a signed value; a 64-bit value is itself).
inline fn signExtendTo64(v: anytype, comptime w: u16) i64 {
    if (w == 64) return @bitCast(@as(u64, v));
    const s: u6 = 64 - @as(u16, w);
    return @as(i64, @bitCast(@as(u64, v) << s)) >> s;
}

/// Read-modify-write FMAC: `dst = dst ± b * c` — two separate wrap
/// steps at the rep's width, never a fused rounding. The floats keep
/// IEEE semantics; the typed integer forms wrap and canonicalize per
/// rep.
pub inline fn fmacOp(self: *VmCtx, op: llir.Opcode, acc: Value, b: Value, c: Value) Value {
    _ = self;
    const fam = familyOf(op);
    if (op == .madd_f32 or op == .msub_f32) {
        const a = ValueCodec.decodeFloat32(acc) orelse 0;
        const x = ValueCodec.decodeFloat32(b) orelse 0;
        const y = ValueCodec.decodeFloat32(c) orelse 0;
        const r: f32 = if (fam == .madd) a + x * y else a - x * y;
        return ValueCodec.encodeFloat32(r);
    }
    if (op == .madd_f64 or op == .msub_f64) {
        const a: f64 = @bitCast(acc);
        const x: f64 = @bitCast(b);
        const y: f64 = @bitCast(c);
        const r: f64 = if (fam == .madd) a + x * y else a - x * y;
        return @bitCast(r);
    }
    const rep = llir.repOf(op) orelse unreachable;
    if (rep == .i32 or rep == .u32) {
        const a: u32 = @truncate(acc);
        const x: u32 = @truncate(b);
        const y: u32 = @truncate(c);
        const r: u32 = if (fam == .madd) a +% x *% y else a -% x *% y;
        return canonicalIntResult(op, r);
    }
    return if (fam == .madd) acc +% b *% c else acc -% b *% c;
}

/// Read-modify-write immediate FMAC: `dst = dst + b * imm7` — the
/// immediate already sign/zero-extended per opcode (Instruction Set
/// §10), two separate wrap steps.
/// Read-modify-write immediate FMAC: `dst = dst + b * imm7` — the
/// immediate already sign/zero-extended per rep (Instruction Set
/// §10), two separate wrap steps at the rep's width.
pub inline fn fmaciOp(self: *VmCtx, op: llir.Opcode, acc: Value, b: Value, imm: u64) Value {
    _ = self;
    const rep = llir.repOf(op) orelse unreachable;
    if (rep == .i32 or rep == .u32) {
        const a: u32 = @truncate(acc);
        const x: u32 = @truncate(b);
        const i: u32 = @truncate(imm);
        return canonicalIntResult(op, a +% x *% i);
    }
    return acc +% b *% imm;
}

/// One unary operation (E-Type, rep-dispatched): `neg` wraps on the
/// minimum, `abs` is IEEE `fabs` / the signed-integer minimum
/// (WebAssembly semantics), `clz`/`popcount` count the pattern, and
/// the float rounding family is IEEE.
pub inline fn unOp(self: *VmCtx, op: llir.Opcode, av: Value) Value {
    _ = self;
    const rep = llir.repOf(op) orelse unreachable;
    const fam = familyOf(op);
    return switch (rep) {
        .i32, .u32 => blk: {
            const a32: u32 = @truncate(av);
            break :blk switch (fam) {
                .neg => 0 -% a32, // two's-complement at 32 bits; unaryHandler canonicalizes
                .abs => if (rep == .i32) blk2: {
                    const sa: i32 = @bitCast(a32);
                    break :blk2 @as(u32, @bitCast(if (sa == std.math.minInt(i32)) sa else @as(i32, @intCast(@abs(sa)))));
                } else a32,
                .clz => @clz(a32),
                .popcount => @popCount(a32),
                else => unreachable,
            };
        },
        .i64, .u64 => blk: {
            const a: u64 = av;
            break :blk switch (fam) {
                .neg => 0 -% a, // two's-complement at 64 bits
                .abs => if (rep == .i64) blk2: {
                    const sa: i64 = @bitCast(a);
                    break :blk2 @as(u64, @bitCast(if (sa == std.math.minInt(i64)) sa else @as(i64, @intCast(@abs(sa)))));
                } else a,
                .clz => @clz(a),
                .popcount => @popCount(a),
                else => unreachable,
            };
        },
        .f32 => blk: {
            const a = ValueCodec.decodeFloat32(av) orelse 0;
            break :blk switch (fam) {
                .neg => ValueCodec.encodeFloat32(-a),
                .abs => ValueCodec.encodeFloat32(@abs(a)),
                .sqrt => ValueCodec.encodeFloat32(std.math.sqrt(a)),
                .floor => ValueCodec.encodeFloat32(@floor(a)),
                .ceil => ValueCodec.encodeFloat32(@ceil(a)),
                .trunc => ValueCodec.encodeFloat32(@trunc(a)),
                .round => ValueCodec.encodeFloat32(std.math.round(a)), // ties away from zero
                else => unreachable,
            };
        },
        .f64 => blk: {
            const a: f64 = @bitCast(av);
            break :blk switch (fam) {
                .neg => @bitCast(-a),
                .abs => @bitCast(@abs(a)),
                .sqrt => @bitCast(std.math.sqrt(a)),
                .floor => @bitCast(@floor(a)),
                .ceil => @bitCast(@ceil(a)),
                .trunc => @bitCast(@trunc(a)),
                .round => @bitCast(std.math.round(a)),
                else => unreachable,
            };
        },
    };
}

/// The C-Type comparison (`seq`/`sne`/`slt`/`sle`, rep-dispatched)
/// — writes the implicit `cond`. IEEE ordered/NaN semantics: `seq`
/// false on NaN, `sne` true, `slt`/`sle` false on NaN.
pub inline fn cmpC(self: *VmCtx, op: llir.Opcode, a: Value, b: Value) bool {
    _ = self;
    return switch (op) {
        .seq => a == b,
        .sne => a != b,
        .slt => intOrdCmp(true, false, a, b),
        .sltu => intOrdCmp(true, true, a, b),
        .seq_f32, .seq_f64 => eqCmp(llir.repOf(op).?, a, b),
        .sne_f32, .sne_f64 => !eqCmp(llir.repOf(op).?, a, b),
        .slt_f32, .slt_f64 => ordCmp(true, llir.repOf(op).?, a, b),
        .sle_f32, .sle_f64 => leCmp(llir.repOf(op).?, a, b),
        else => unreachable,
    };
}

/// The B-Type register branch (`beq`/`bne`/`blt`/`ble`, `bltu`/
/// `bleu`, and their `f32`/`f64` variants, rep-dispatched): integer
/// equality is a bit-pattern test; the
/// float equality forms are IEEE — false when either operand is
/// NaN (`0.0 / 0.0 == 0.0 / 0.0` is false even for identical
/// payloads), and `sne` is its complement.
pub inline fn branchCmp(self: *VmCtx, op: llir.Opcode, a: Value, b: Value) bool {
    _ = self;
    return switch (op) {
        .beq => a == b,
        .bne => a != b,
        .blt => intOrdCmp(true, false, a, b),
        .bltu => intOrdCmp(true, true, a, b),
        .ble => !intOrdCmp(false, false, a, b),
        .bleu => !intOrdCmp(false, true, a, b),
        .beq_f32, .beq_f64 => eqCmp(llir.repOf(op).?, a, b),
        .bne_f32, .bne_f64 => !eqCmp(llir.repOf(op).?, a, b),
        .blt_f32, .blt_f64 => ordCmp(true, llir.repOf(op).?, a, b),
        .ble_f32, .ble_f64 => leCmp(llir.repOf(op).?, a, b),
        else => unreachable,
    };
}

/// The ordered less-or-equal `a <= b` at a rep — IEEE ordered for
/// floats, false when either operand is NaN (the `sle` primitive
/// has no integer reps).
inline fn leCmp(rep: llir.Rep, a: Value, b: Value) bool {
    return switch (rep) {
        .f32 => blk: {
            const x = ValueCodec.decodeFloat32(a) orelse return false;
            const y = ValueCodec.decodeFloat32(b) orelse return false;
            break :blk x <= y;
        },
        .f64 => blk: {
            const x: f64 = @bitCast(a);
            const y: f64 = @bitCast(b);
            break :blk x <= y;
        },
        else => unreachable,
    };
}

/// IEEE equality at a rep: raw bit equality for the integer reps;
/// for floats, `x == y` is false when either operand is NaN.
inline fn eqCmp(rep: llir.Rep, a: Value, b: Value) bool {
    return switch (rep) {
        .i32, .u32, .i64, .u64 => a == b,
        .f32 => blk: {
            const x = ValueCodec.decodeFloat32(a) orelse return false;
            const y = ValueCodec.decodeFloat32(b) orelse return false;
            break :blk x == y;
        },
        .f64 => blk: {
            const x: f64 = @bitCast(a);
            const y: f64 = @bitCast(b);
            break :blk x == y;
        },
    };
}

pub inline fn intOrdCmp(less: bool, unsigned: bool, a: Value, b: Value) bool {
    if (unsigned) return if (less) a < b else a > b;
    const x: i64 = @bitCast(a);
    const y: i64 = @bitCast(b);
    return if (less) x < y else x > y;
}

/// One ordered comparison `a < b` (`less = true`) or `a > b`
/// (`less = false`) at a rep — integers per signedness, floats
/// IEEE ordered (false on NaN).
pub inline fn ordCmp(less: bool, rep: llir.Rep, a: Value, b: Value) bool {
    return switch (rep) {
        .i32 => blk: {
            const x: i64 = @as(i32, @bitCast(@as(u32, @truncate(a))));
            const y: i64 = @as(i32, @bitCast(@as(u32, @truncate(b))));
            break :blk if (less) x < y else x > y;
        },
        .u32 => blk: {
            const x: u64 = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(a))))));
            const y: u64 = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(b))))));
            break :blk if (less) x < y else x > y;
        },
        .i64 => blk: {
            const x: i64 = @bitCast(a);
            const y: i64 = @bitCast(b);
            break :blk if (less) x < y else x > y;
        },
        .u64 => blk: {
            break :blk if (less) a < b else a > b;
        },
        .f32 => blk: {
            const x = ValueCodec.decodeFloat32(a) orelse return false;
            const y = ValueCodec.decodeFloat32(b) orelse return false;
            break :blk if (less) x < y else x > y;
        },
        .f64 => blk: {
            const x: f64 = @bitCast(a);
            const y: f64 = @bitCast(b);
            break :blk if (less) x < y else x > y;
        },
    };
}

/// One C-Type cast `cvt.<src>.<dst>` (the 42 explicit spellings):
/// integer→integer truncates to the target width (the same-width
/// `i64 ↔ u64` forms reinterpret the full 64-bit cell), int→float
/// converts (round-to-nearest; precision may be lost), float→int
/// truncates toward zero and saturates on NaN/
/// out-of-range (NaN becomes zero, the 64-bit targets saturating to
/// `[i64_min, i64_max]` / `[0, 2⁶⁴)`), `f32 → f64` is exact, `f64 →
/// f32` rounds to nearest, ties-to-even; the `b` forms keep or
/// produce the low 8 bits.
pub inline fn doCast(self: *VmCtx, op: llir.Opcode, src: Value) Value {
    _ = self;
    return switch (op) {
        .cvt_b_i32 => ValueCodec.extendInt32Bits(@truncate(src & 0xff)),
        .cvt_b_u32 => @as(u64, @as(u32, @truncate(src & 0xff))),
        .cvt_b_i64, .cvt_b_u64 => @as(u64, @as(u8, @truncate(src & 0xff))),
        .cvt_i32_b, .cvt_u32_b => src & 0xff,
        .cvt_i64_b, .cvt_u64_b => src & 0xff,
        .cvt_i32_u32 => @as(u64, @as(u32, @truncate(src))),
        .cvt_u32_i32 => ValueCodec.extendInt32Bits(@truncate(src)),
        .cvt_i32_i64, .cvt_i32_u64 => ValueCodec.extendInt32Bits(@truncate(src)),
        .cvt_u32_i64, .cvt_u32_u64 => @as(u64, @as(u32, @truncate(src))),
        .cvt_i64_i32, .cvt_u64_i32 => ValueCodec.extendInt32Bits(@truncate(src)),
        .cvt_i64_u32, .cvt_u64_u32 => @as(u64, @as(u32, @truncate(src))),
        .cvt_i64_u64, .cvt_u64_i64 => src,
        .cvt_b_f32 => ValueCodec.encodeFloat32(@floatFromInt(@as(u8, @truncate(src)))),
        .cvt_b_f64 => @bitCast(@as(f64, @floatFromInt(@as(u8, @truncate(src))))),
        .cvt_i32_f32 => ValueCodec.encodeFloat32(@floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(src)))))),
        .cvt_i32_f64 => @bitCast(@as(f64, @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(src))))))),
        .cvt_u32_f32 => ValueCodec.encodeFloat32(@floatFromInt(@as(u32, @truncate(src)))),
        .cvt_u32_f64 => @bitCast(@as(f64, @floatFromInt(@as(u32, @truncate(src))))),
        .cvt_i64_f32 => ValueCodec.encodeFloat32(@floatFromInt(@as(i64, @bitCast(src)))),
        .cvt_i64_f64 => @bitCast(@as(f64, @floatFromInt(@as(i64, @bitCast(src))))),
        .cvt_u64_f32 => ValueCodec.encodeFloat32(@floatFromInt(src)),
        .cvt_u64_f64 => @bitCast(@as(f64, @floatFromInt(src))),
        .cvt_f32_b => saturateF32ToByte(ValueCodec.decodeFloat32(src) orelse 0),
        .cvt_f32_i32 => ValueCodec.encodeInt32(saturateF32ToI32(ValueCodec.decodeFloat32(src) orelse 0)),
        .cvt_f32_u32 => ValueCodec.encodeUint32(@truncate(saturateF32ToU32(ValueCodec.decodeFloat32(src) orelse 0))),
        .cvt_f32_i64 => @bitCast(saturateF32ToI64(ValueCodec.decodeFloat32(src) orelse 0)),
        .cvt_f32_u64 => saturateF32ToU64(ValueCodec.decodeFloat32(src) orelse 0),
        .cvt_f32_f64 => @bitCast(@as(f64, ValueCodec.decodeFloat32(src) orelse 0)), // widen: exact
        .cvt_f64_b => saturateF64ToByte(@bitCast(src)),
        .cvt_f64_i32 => ValueCodec.encodeInt32(saturateF64ToI32(@bitCast(src))),
        .cvt_f64_u32 => ValueCodec.encodeUint32(@truncate(saturateF64ToU32(@bitCast(src)))),
        .cvt_f64_i64 => @bitCast(saturateF64ToI64(@bitCast(src))),
        .cvt_f64_u64 => saturateF64ToU64(@bitCast(src)),
        .cvt_f64_f32 => ValueCodec.encodeFloat32(@floatCast(@as(f64, @bitCast(src)))), // narrow
        else => unreachable,
    };
}

/// `f32` → `i64` (truncating toward zero). Total — casts never trap:
/// NaN becomes zero, and values at/above 2⁶³ or below −2⁶³ saturate to
/// the `i64` range (the boundaries are exact powers of two, so the
/// comparison is precise at binary32 precision).
fn saturateF32ToI64(f: f32) i64 {
    if (std.math.isNan(f)) return 0;
    if (f >= 9223372036854775808.0) return std.math.maxInt(i64);
    if (f <= -9223372036854775808.0) return std.math.minInt(i64);
    return @intFromFloat(@trunc(f));
}

/// `f32` → `u64` (truncating toward zero). Total — NaN or a nonpositive
/// source becomes zero, a source at/above 2⁶⁴ saturates to `u64_max`
/// (2⁶⁴ is an exact power of two at binary32 precision).
fn saturateF32ToU64(f: f32) Value {
    if (std.math.isNan(f) or f <= 0) return 0;
    if (f >= 18446744073709551616.0) return std.math.maxInt(u64);
    return @intFromFloat(@trunc(f));
}

/// `f64` → `i64` (truncating toward zero). Total — NaN becomes zero,
/// values at/above 2⁶³ or below −2⁶³ saturate to the `i64` range
/// (the boundaries are exact powers of two at binary64 precision).
fn saturateF64ToI64(d: f64) i64 {
    if (std.math.isNan(d)) return 0;
    if (d >= 9223372036854775808.0) return std.math.maxInt(i64);
    if (d <= -9223372036854775808.0) return std.math.minInt(i64);
    return @intFromFloat(@trunc(d));
}

/// `f64` → `u64` (truncating toward zero). Total — NaN or a nonpositive
/// source becomes zero, a source at/above 2⁶⁴ saturates to `u64_max`.
fn saturateF64ToU64(d: f64) Value {
    if (std.math.isNan(d) or d <= 0) return 0;
    if (d >= 18446744073709551616.0) return std.math.maxInt(u64);
    return @intFromFloat(@trunc(d));
}
