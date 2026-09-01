//! Test file: `frontend LLIR normalize` — Phase 3.2 normalization
//! verification (the frozen records of every normalization family) plus
//! the `MiniVm` frame-contract state model, and Phase 3.3 the corpus
//! normalization harness. Split out of the former `src/frontend_tests.zig`;
//! `MiniVm` and the normalization helpers are local to this file.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const llir = @import("llir.zig");
const lower = @import("lower.zig");
const cfg_parse = @import("passes/cfg_parse.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const cfg_validate = @import("passes/cfg_validate.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
const compileOpt = helpers.compileOpt;
const findFunc = helpers.findFunc;
// ---------------------------------------------------------------------------
// Phase 3.2 — normalization verification (TODO 3.2): the frozen LLIR
// records of every normalization family (arithmetic, construct, direct /
// value calls, syscall, phi edge copies and swap cycles, switch,
// multi-result destructure, tailcall, cleanup, dynamic drop) plus a
// minimal VM state model that verifies the frame contract: special
// register read / write semantics, call/ret/tailcall `pc`/`sp`/`fp`
// transitions, call
// headers, parameter placement at `r0..r(P-1)`, and the `FunctionDesc`
// rebuild after a `ret` resumes the caller. The model is a test-side
// state model, not an interpreter — the project does not implement one.
// ---------------------------------------------------------------------------

/// The minimal VM state model (spec §3.2): `pc`/`sp`/`fp` plus a flat
/// stack. Values are `u32` bit patterns; the frame layout follows spec
/// §4 — the fixed three-cell header (`saved_fp`, `saved_fn`, `saved_ra`) sits
/// immediately below each `fp` and is decoded by position, slots are
/// `fp`-relative, and the specials are registers with no stack address
/// (spec §3.1). Reading `zero` yields the operand type's zero; writing
/// `zero` discards. Traps and syscall side effects are observable
/// even when the destination is `zero`. The current function is always
/// rebuilt from
/// `pc` via `llir.functionAtPc` — never cached — so the resumed
/// caller after a `ret` is re-derived exactly as a real VM would.
const MiniVm = struct {
    program: *const llir.LlirProgram,
    stack: []u32,
    pc: u32,
    sp: u32,
    fp: u32,
    /// Syscall side effects executed — a `zero`-destined or void syscall
    /// still counts (spec §3.1, §7).
    side_effects: usize = 0,
    /// A trap has fired: the VM halts, no further frame work happens.
    trapped: bool = false,

    /// Read a register: a special yields the operand type's zero (0
    /// bits — the zero of byte/bool/int32/uint32/f32, spec §3.1); a
    /// register resolves piecewise (spec §4.1) — `F(reg)` is the local
    /// cell `fp + reg` below `L+3`, and an output-window alias above.
    /// The special's meaning is carried by the encoding alone, so one
    /// bit test (`isSpecial`) classifies the operand — no
    /// role-dependent branch.
    fn read(self: *const MiniVm, reg: llir.ValueReg) u32 {
        if (llir.isSpecial(reg)) return 0;
        return self.stack[self.cellOf(reg)];
    }

    /// Write a register: a special discards; a register stores its
    /// piecewise-resolved frame cell.
    fn write(self: *MiniVm, reg: llir.ValueReg, value: u32) void {
        if (llir.isSpecial(reg)) return;
        self.stack[self.cellOf(reg)] = value;
    }

    /// The physical cell of `F(reg)` (spec §4.1): `fp + reg` for
    /// `reg < L+3`; the output-window alias `callBase + 3 +
    /// (reg - L - 3)` — equivalently `fp + x_count + reg` — at or
    /// above.
    fn cellOf(self: *const MiniVm, reg: llir.ValueReg) usize {
        const f = self.function();
        const i = llir.frameIndex(reg);
        if (i < f.f_count + 3) return self.fp + i;
        return self.fp + f.x_count + i;
    }

    /// The current function, rebuilt from `pc` (spec §2: any valid pc
    /// recovers a unique function by its containing code range).
    fn function(self: *const MiniVm) llir.FunctionDesc {
        return self.program.functions[llir.functionAtPc(self.program.functions, self.pc).?];
    }

    /// A call (spec §5.3): the compiler has already emitted the
    /// argument moves that placed each argument into its window slot —
    /// the callee's parameter registers `r0..r(P-1)`, aliasing the
    /// caller's top `A = max(P, R)` cells. The call itself writes the
    /// three-cell header `{ saved_fp, saved_fn, saved_ra }` at
    /// `[fp_callee - 3, fp_callee)` (inside the caller's reserved
    /// window region), moves `fp` to `sp - A`, advances `sp` to the
    /// callee's frame end, and jumps `pc` to the callee's entry — no
    /// staging, no hidden writes.
    fn enterCall(self: *MiniVm, target: u32) void {
        const callee_id = llir.functionAtPc(self.program.functions, target).?;
        const callee = self.program.functions[callee_id];
        const sig = self.program.signatures[callee.signature_id];
        const a: u32 = @max(sig.params_len, @as(u32, if (sig.ret == llir.no_index) 0 else 1));
        // Header at `[sp - A - 3, sp - A)`: { saved_fp, saved_fn,
        // saved_ra }, decoded by position (spec §5.3). `saved_fp` is the
        // caller's frame base at call time; `saved_fn` the caller's
        // function index (the real VM restores its current-function
        // cache from it; this model re-derives from `pc`).
        const caller_fn = llir.functionAtPc(self.program.functions, self.pc).?;
        self.stack[self.sp - a - 3 + 0] = self.fp;
        self.stack[self.sp - a - 3 + 1] = caller_fn;
        self.stack[self.sp - a - 3 + 2] = self.pc + 1;
        self.fp = self.sp - a; // the callee's r0 aliases the caller's value-area slot 0
        self.sp = llir.frameEnd(self.fp, callee);
        self.pc = callee.entry_pc;
        // The parameters are already in r0..r(P-1) — the caller's
        // argument moves wrote them there before the call record.
    }

    /// The failure-atomic entry (spec §5.3): validate the callee entry,
    /// the value area against the caller output window, and the
    /// return-PC take contract *before* committing any header/frame/pc
    /// state. On failure the caller's state is byte-identical and the
    /// callee is not entered. This is the reference-model mirror of the
    /// interpreter's own dynamic take-mismatch test.
    fn tryEnterCall(self: *MiniVm, target: u32) !void {
        const before_fp = self.fp;
        const before_sp = self.sp;
        const before_pc = self.pc;
        errdefer {
            // Failure atomicity: nothing committed.
            self.fp = before_fp;
            self.sp = before_sp;
            self.pc = before_pc;
        }
        const callee_id = llir.functionAtPc(self.program.functions, target) orelse
            return error.NotAnEntry;
        const callee = self.program.functions[callee_id];
        if (target != callee.entry_pc) return error.NotAnEntry;
        const sig = self.program.signatures[callee.signature_id];
        const a: u32 = @max(sig.params_len, @as(u32, if (sig.ret == llir.no_index) 0 else 1));
        const caller = self.function();
        if (a > llir.outCount(caller)) return error.WindowTooSmall;
        if (self.sp < a) return error.Underflow;
        // Return-PC take contract (spec §5.2): a non-void call's
        // fallthrough must be a take whose source is the result alias
        // `F(L+3+O-A)`; a void call's fallthrough must hold none.
        const nd = llir.decode(self.program.instructions[self.pc + 1]);
        if (sig.ret != llir.no_index) {
            const ok = nd != null and nd.?.op == .take and
                nd.?.b == llir.frameReg(caller.f_count + caller.window_count - a);
            if (!ok) return error.TakeMismatch;
        } else {
            if (nd != null and nd.?.op == .take) return error.TakeMismatch;
        }
        // Commit.
        self.enterCall(target);
    }

    /// A `ret` (spec §5.4): read the result, publish it to the
    /// callee's slot 0 (the caller's value-area slot — consumed by the
    /// caller's take), then restore the caller: read the
    /// three-cell header at `fp - 3`, `sp = fp + A`, `fp = saved_fp`,
    /// `pc = saved_ra`. `ret zero` supplies the return type's zero; a
    /// void ret publishes nothing.
    fn returnFrom(self: *MiniVm, instr: llir.Instr) void {
        const d = llir.decode(instr).?;
        const f = self.function();
        const sig = self.program.signatures[f.signature_id];
        const a: u32 = @max(sig.params_len, @as(u32, if (sig.ret == llir.no_index) 0 else 1));
        const result: u32 = if (llir.isSpecial(d.a)) 0 else self.stack[self.fp + llir.frameIndex(d.a)];
        const hb = llir.headerBase(self.fp);
        const saved_fp = self.stack[hb + 0];
        const saved_fn = self.stack[hb + 1];
        const saved_ra = self.stack[hb + 2];
        // Publish the result to slot 0 — the callee's F0, which is the
        // caller's value-area slot (spec §5.4).
        if (sig.ret != llir.no_index) {
            self.stack[self.fp] = result;
        }
        self.sp = self.fp + a; // the caller's frame end
        // The header carries the caller's frame base directly:
        // `fp = saved_fp`. A root header carries the `invalid_pc`
        // sentinel; this model only returns to real callers. `saved_fn`
        // names the caller — the real VM restores its current-function
        // cache from it.
        _ = saved_fn;
        self.fp = saved_fp;
        self.pc = saved_ra;
    }

    /// The caller-side generic `take dst, src` (spec §5.2): the
    /// just-completed call's result sits in the caller register
    /// `F(L+3+O-A)` — the take's source encoding `L + W - A`; transfer
    /// it into `dst` and clear the source cell — no retain.
    fn take(self: *MiniVm, instr: llir.Instr) void {
        const d = llir.decode(instr).?;
        const v = self.read(d.b);
        self.write(d.b, 0);
        self.write(d.a, v);
    }

    /// A self-tailcall (spec §5.5): same frame — `fp` preserved.
    /// Phase 5: the compiler has already emitted explicit copy records
    /// to place each argument in its target param slot. tailcall_self
    /// is now a pure jump — no staging, no hidden writes.
    fn tailcallSelf(self: *MiniVm) void {
        const f = self.function();
        self.sp = llir.frameEnd(self.fp, f);
        self.pc = f.entry_pc;
    }

    /// One execution helper, only for the acceptance: a division-style
    /// op checks its trap condition (divisor == 0) *before* writing the
    /// result — a `zero` destination must not suppress the trap (spec §3.1).
    fn execDiv(self: *MiniVm, instr: llir.Instr) void {
        const d = llir.decode(instr).?;
        const divisor = self.read(d.c);
        if (divisor == 0) {
            self.trapped = true;
            return;
        }
        const dividend = self.read(d.b);
        self.write(d.a, @bitCast(@divTrunc(@as(i32, @bitCast(dividend)), @as(i32, @bitCast(divisor)))));
    }

    /// One execution helper, only for the acceptance: a syscall records
    /// its side effect *before* the destination write — a `zero`
    /// destination must not suppress the side effect (spec §3.1, §7).
    fn execSyscall(self: *MiniVm, instr: llir.Instr) void {
        const d = llir.decode(instr).?;
        self.side_effects += 1;
        self.write(d.a, 0);
    }
};

/// The zero bit pattern of each *Copy* numeric/boolean primitive — the
/// value a `zero` read yields (spec §3.1). Every one of them is the 0
/// word, which is exactly what a real interpreter must materialize for a
/// `zero` source: `int32` 0, `uint32` 0, `float32` 0.0, `byte` 0, `bool`
/// false. `str`/`any`/`hostdata` are never `zero`-readable (phase-3
/// validator rejects them).
fn zeroOf(prim: llir.PrimitiveId) u64 {
    return switch (prim) {
        .byte, .bool, .int32, .uint32, .int64, .uint64, .float32, .float64 => 0,
        .str, .any, .hostdata => unreachable,
    };
}

/// The pc of the first `ret` record in a function's code range — the
/// straight-line fixtures used by the frame-contract tests have exactly
/// one.
fn firstRetPc(image: *const llir.LlirProgram, fid: llir.FunctionId) u32 {
    const f = image.functions[fid];
    for (f.code_start..f.code_end) |pc| {
        const d = llir.decode(image.instructions[pc]) orelse continue;
        if (d.op == .ret) return @intCast(pc);
    }
    unreachable;
}

/// One normalization-matrix expectation: the opcode family must appear
/// at least `min` times in the lowered image.
const OpcodeMin = struct {
    op: llir.Opcode,
    min: usize,
};

fn countOpcode(image: *const llir.LlirProgram, op: llir.Opcode) usize {
    var n: usize = 0;
    for (image.instructions) |instr| {
        const d = llir.decode(instr) orelse continue;
        if (d.op == op) n += 1;
    }
    return n;
}

/// The shared phase-3.2 normalization invariants for one lowered image:
/// every record is exactly 8 bytes, every reference validates (the 3.1
/// validator — the acceptance's "all references legal"), and the
/// required opcode families are present.
fn checkNormalized(name: []const u8, image: llir.LlirProgram, expects: []const OpcodeMin) !void {
    try testing.expectEqual(@as(usize, 4), @sizeOf(llir.Instr));
    if (try llir_validate.validate(&image, testing.allocator)) |m| {
        std.log.err("3.2 {s}: normalized image rejected: {s}", .{ name, m });
        return error.TestUnexpectedResult;
    }
    for (expects) |e| {
        const n = countOpcode(&image, e.op);
        if (n < e.min) {
            std.log.err("3.2 {s}: expected at least {d} {s} record(s), found {d}", .{ name, e.min, llir.opInfo(e.op).name, n });
            return error.TestUnexpectedResult;
        }
    }
}

/// Compile a Stilla module, lower it to LLIR, and run the
/// normalization invariants — including the input CFG being unmodified
/// (spec §1: LLIR is a read-only projection of `cfg_validate`'d
/// AIR).
fn expectSourceNormalizes(name: []const u8, source: []const u8, expects: []const OpcodeMin) !void {
    var c = try compileText("app", &.{.{ "app", source }});
    defer c.deinit();
    const program = c.program orelse return error.TestUnexpectedResult;
    const before = try irText(&program);
    defer testing.allocator.free(before);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();
    const after = try irText(&program);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try checkNormalized(name, image, expects);
}

/// Same, for a text-form AIR fixture (`cfg_parse.parseText`).
fn expectTextNormalizes(name: []const u8, ir: []const u8, expects: []const OpcodeMin) !void {
    var t = try cfg_parse.parseText(ir);
    defer t.arena.deinit();
    const before = try irText(&t.program);
    defer testing.allocator.free(before);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    const after = try irText(&t.program);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try checkNormalized(name, image, expects);
}

test "3.2 LLIR normalization matrix: every record family normalizes to a valid 8-byte image" {
    // One fixture per normalization family (TODO 3.2); each is lowered
    // and checked for the 8-byte record invariant, a fully-valid image
    // (3.1), an unmodified input CFG, and the family's records.

    // arithmetic — register ops plus an immediate fusion (2.14).
    try expectSourceNormalizes(
        "arithmetic",
        \\fn m(a: int32, b: int32) -> int32 { (a + b) * 2 - a / b }
        \\fn main() -> int32 { m(10, 2) }
    ,
        &.{
            .{ .op = .add, .min = 1 },
            .{ .op = .muli, .min = 1 },
            .{ .op = .sub, .min = 1 },
            .{ .op = .div, .min = 1 },
        },
    );

    // construct — a struct literal is one record + a descriptor; the
    // move-destructure back is `unpack_struct` (the single-result
    // `read_field` projections are documented placeholders, TODO 2.15
    // summary).
    try expectSourceNormalizes(
        "construct",
        \\struct Pair { x: int32; y: int32; }
        \\fn main() -> int32 {
        \\    let p = Pair{ x: 1, y: 2 };
        \\    let Pair { x, y } = move p;
        \\    x + y
        \\}
    ,
        &.{
            .{ .op = .construct, .min = 1 },
            .{ .op = .unpack_struct, .min = 1 },
        },
    );

    // direct call — the v9 `jal ra` (a direct call record: the
    // U-type `jal` with the `ra` link).
    try expectSourceNormalizes(
        "direct call",
        \\fn id(x: int32) -> int32 { x }
        \\fn main() -> int32 { id(7) }
    ,
        &.{.{ .op = .jal, .min = 1 }},
    );

    // value call — the function value is a module member: module_ref +
    // load_member loads the entry PC, `jalr` resolves the callee from
    // the slot.
    try expectSourceNormalizes(
        "value call",
        \\fn add(a: int32, b: int32) -> int32 { a + b }
        \\fn apply(f: fn(int32, int32) -> int32, a: int32, b: int32) -> int32 { f(a, b) }
        \\fn main() -> int32 { apply(add, 1, 2) }
    ,
        &.{
            .{ .op = .module_ref, .min = 1 },
            .{ .op = .load_member, .min = 1 },
            .{ .op = .jalr, .min = 1 },
        },
    );

    // syscall.
    try expectSourceNormalizes(
        "syscall",
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print(builtin.str(42));
        \\}
    ,
        &.{.{ .op = .syscall, .min = 1 }},
    );

    // switch — a non-consuming union match dispatches on the tag and
    // unpacks the arm's payload by reference (the `read_tag` that feeds
    // the switch is among the documented placeholder projections).
    try expectSourceNormalizes(
        "switch",
        \\union Shape { Circle(int32), Rect(int32, int32) }
        \\fn area(s: Shape) -> int32 {
        \\    match (s) { Shape::Circle(r) => r, Shape::Rect(w, h) => w * h }
        \\}
        \\fn main() -> int32 { area(Shape::Circle(3)) }
    ,
        &.{
            .{ .op = .construct, .min = 1 },
            .{ .op = .switch_, .min = 1 },
            .{ .op = .borrow_variant, .min = 1 },
        },
    );

    // multi-result destructure — a three-element tuple unpacks into
    // three result slots.
    try expectSourceNormalizes(
        "multi-result destructure",
        \\fn take3(t: tuple[int32, int32, int32]) -> int32 {
        \\    let (a, b, c) = move t;
        \\    a + b + c
        \\}
        \\fn main() -> int32 { take3((1, 2, 3)) }
    ,
        &.{
            .{ .op = .construct, .min = 1 },
            .{ .op = .unpack_tuple, .min = 1 },
        },
    );

    // phi edge copies — linear scan may coalesce one incoming edge.
    try expectTextNormalizes(
        "phi edge copies",
        \\module "app" {
        \\func @join(a: int32, b: int32, c: bool) -> int32 {
        \\entry:
        \\    br %2 ? l : r
        \\l:
        \\    j m
        \\r:
        \\    j m
        \\m:
        \\    %3: int32 = phi [%0, l], [%1, r]
        \\    ret %3
        \\}
        \\}
    ,
        &.{.{ .op = .copy, .min = 1 }},
    );

    // phi swap cycle — a three-cycle breaks as stage + 3 transfers
    // through a type-matched scratch slot (2.8).
    try expectTextNormalizes(
        "phi swap cycle",
        \\module "app" {
        \\func @cycle() -> int32 {
        \\entry:
        \\    %0: int32 = const 0
        \\    j body
        \\body:
        \\    %1: int32 = phi [%0, entry], [%2, body]
        \\    %2: int32 = phi [%0, entry], [%3, body]
        \\    %3: int32 = phi [%0, entry], [%1, body]
        \\    j body
        \\}
        \\}
    ,
        &.{.{ .op = .copy, .min = 4 }},
    );

    // self tailcall. The comparison `lt %0, %2` uses a threshold const
    // of 100: the v9 immediate window is [-64, 63], so the const stays a
    // register operand.
    try expectTextNormalizes(
        "self tailcall",
        \\module "app" {
        \\func @count(n: int32, acc: int32) -> int32 {
        \\entry:
        \\    %2: int32 = const 100
        \\    %3: bool = lt %0, %2
        \\    br %3 ? done : rec
        \\rec:
        \\    %4: int32 = sub %1, %2
        \\    tailcall @count, %0, %4
        \\done:
        \\    ret %1
        \\}
        \\}
    ,
        &.{.{ .op = .tailcall_self, .min = 1 }},
    );

    // cleanup — v1 (Instruction Set §4): no token ops exist. The non-consuming
    // else-edge destroys the owner unconditionally before the merge.
    try expectSourceNormalizes(
        "cleanup edge drop",
        \\struct File { fd: int32; drop(file) {} }
        \\fn consume(move f: File) -> void {}
        \\fn main() -> void {
        \\    let f = File{ fd: 1 };
        \\    if (true) { consume(move f); } else { }
        \\}
    ,
        &.{
            .{ .op = .drop, .min = 1 },
        },
    );

    // dynamic drop — a definitely-owned unique `any` is dropped
    // unconditionally by the residual runtime `drop` (2.13).
    try expectSourceNormalizes(
        "dynamic drop",
        \\const builtin = import("builtin");
        \\fn wrap(a: int32) -> any { a }
        \\fn main() -> void {
        \\    let u = wrap(1);
        \\    let _ = u;
        \\}
    ,
        &.{.{ .op = .drop, .min = 1 }},
    );
}

test "3.2 special-register contract: zero reads, zero writes, traps and side effects survive, void and zero returns" {
    // A hand-built two-callee image: `f1` returns zero (`ret zero` on a
    // non-void signature), `f2` is void. The caller's records exercise
    // the special-register rules; the MiniVm drives them. (The image is
    // a MiniVm fixture, not a lowering output — the matrix test
    // validates real images.)
    //
    // caller (f0) code [0, 10): 0 = div zero, r1, r2; 1 = div
    //   zero, r1, zero; 2 = syscall zero; 3 = jal ra → f1 (result
    //   discarded by the `take zero` at 4); 5 = jal ra → f1
    //   (ret zero → real zero taken at 6); 7 = jal ra → f2 (void, no
    //   take); 8 = ret r1; 9 = trap.
    // copy callee (f1) code [10, 12): 10 = ret zero; 11 = trap.
    // void callee (f2) code [12, 14): 12 = ret zero (result ignored);
    //   13 = trap.
    const caller = llir.FunctionDesc{
        .code_start = 0,
        .code_end = 10,
        .entry_pc = 0,
        .signature_id = 0,
        .f_count = 4,
        .x_count = 0,
        .window_count = 5, // max over calls of 3 + A: f1 has A = 2, f2 has A = 0
    };
    const copy_callee = llir.FunctionDesc{
        .code_start = 10,
        .code_end = 12,
        .entry_pc = 10,
        .signature_id = 1,
        .f_count = 2,
        .x_count = 0,
        .window_count = 0,
    };
    const void_callee = llir.FunctionDesc{
        .code_start = 12,
        .code_end = 14,
        .entry_pc = 12,
        .signature_id = 2,
        .f_count = 0,
        .x_count = 0,
        .window_count = 0,
    };
    const functions = [_]llir.FunctionDesc{ caller, copy_callee, void_callee };
    // f1's entry at pc 10, f2's at pc 12; the caller's calls are the
    // U-type `jal ra` with pc-relative imm20 targets.
    const image = llir.LlirProgram{
        .instructions = &.{
            llir.instrR(.div, llir.zero_reg, llir.frame_base + 1, llir.frame_base + 2),
            llir.instrR(.div, llir.zero_reg, llir.frame_base + 1, llir.zero_reg),
            llir.instrI(.syscall, llir.zero_reg, 0),
            llir.instrU(.jal, llir.ra_reg, 7), // → 10 (f1)
            llir.instrE(.take, llir.zero_reg, llir.frame_base + 7), // F(L+3+O-A) = F(4+5-2) = F7
            llir.instrU(.jal, llir.ra_reg, 5), // → 10 (f1)
            llir.instrE(.take, llir.frame_base + 1, llir.frame_base + 7),
            llir.instrU(.jal, llir.ra_reg, 5), // → 12 (f2)
            llir.instrE(.ret, llir.frame_base + 1, 0),
            llir.instrE(.trap, 0, 0),
            llir.instrE(.ret, llir.zero_reg, 0),
            llir.instrE(.trap, 0, 0),
            llir.instrE(.ret, llir.zero_reg, 0),
            llir.instrE(.trap, 0, 0),
        },
        .functions = &functions,
        .blocks = &.{},
        .constants = &.{},
        .types = &.{
            .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.int32), .b = 0, .c = 0 },
        },
        .type_decls = &.{},
        .type_decl_fields = &.{},
        .union_variants = &.{},
        .union_payloads = &.{},
        .host_types = &.{},
        .self_symbol = 0,
        .init = llir.no_index,
        .entry_member = llir.no_index,
        .symbols = &.{ .{ .start = 0, .len = 0 }, .{ .start = 0, .len = 0 } },
        .imports = &.{.{ .module_sym = 0, .member_sym = 1 }},
        .exports = &.{},
        .module_slots = &.{},
        .signatures = &.{
            .{ .params_start = 0, .params_len = 0, .ret = 0 }, // f0: () -> int32
            .{ .params_start = 0, .params_len = 2, .ret = 0 }, // f1: (int32, int32) -> int32
            .{ .params_start = 2, .params_len = 0, .ret = llir.no_index }, // f2: () -> void
        },
        .params = &.{
            .{ .mode = .plain, .type_ = 0 },
            .{ .mode = .plain, .type_ = 0 },
        },
        .call_args = &.{ 2, 3 },
        .syscall_descs = &.{.{ .host_binding_id = 0, .signature_id = 2, .args_start = 0, .args_len = 0 }},
        .construct_descs = &.{},
        .destructure_dsts = &.{},
        .destructure_descs = &.{},
        .switch_arms = &.{},
        .switch_descs = &.{},
        .destructure_dst_types = &.{},
        .member_descs = &.{},
        .drop_descs = &.{},
        .strings = &.{},
    };

    // Every record in the fixture passes the field-level schema check
    // under the caller's whole register-addressable count (4 F cells
    // plus the 4 window aliases; the specials are legal in every
    // position used).
    for (image.instructions) |instr| {
        try testing.expect(llir.checkInstr(instr, caller.f_count + caller.window_count) == null);
    }

    var stack = [_]u32{0x5a5a5a5a} ** 64;
    var vm = MiniVm{ .program = &image, .stack = &stack, .pc = 0, .sp = 0, .fp = 3 };
    vm.sp = llir.frameEnd(3, caller);

    // Reading zero always yields the operand type's zero — 0 is the zero
    // bit pattern of every Copy numeric/boolean primitive (spec §3.1).
    inline for (.{ llir.PrimitiveId.byte, .bool, .int32, .uint32, .float32 }) |p| {
        try testing.expectEqual(zeroOf(p), vm.read(llir.zero_reg));
    }

    // Writing zero discards: no stack cell changes; a real slot stores.
    const stack_before = stack;
    vm.write(llir.zero_reg, 42);
    try testing.expectEqualSlices(u32, &stack_before, &stack);
    vm.write(llir.frame_base + 3, 7);
    try testing.expectEqual(@as(u32, 7), stack[3 + 3]);

    // A zero destination does not suppress a trap: dividing by the zero
    // divisor (0) traps before any write; a nonzero divisor computes
    // and discards into zero.
    vm.write(llir.frame_base + 1, 1);
    vm.execDiv(image.instructions[0]); // r1 / r2 = 1 / 2 → 0, discarded
    try testing.expect(!vm.trapped);
    vm.execDiv(image.instructions[1]); // r1 / zero = 1 / 0 → trap
    try testing.expect(vm.trapped);

    // A zero destination does not suppress syscall side effects.
    vm.execSyscall(image.instructions[2]);
    try testing.expectEqual(@as(usize, 1), vm.side_effects);

    // A void call: no `take` follows the `jal ra`, and its
    // `ret zero` (result ignored) resumes the caller at pc + 1.
    vm.pc = 7;
    const void_call = image.instructions[7];
    vm.enterCall(llir.jalTarget(7, llir.decode(void_call).?.imm20));
    try testing.expectEqual(@as(u32, 12), vm.pc); // f2's entry
    const void_ret = image.instructions[vm.pc];
    try testing.expect(llir.isZeroReg(llir.decode(void_ret).?.a)); // void ret carries zero (no result)
    vm.returnFrom(void_ret);
    try testing.expectEqual(@as(u32, 8), vm.pc); // resume at pc + 1
    try testing.expectEqual(@as(u32, 3), vm.fp); // caller fp restored

    // A discarded result: `take zero` drops the callee's returned
    // zero into `zero`; the caller's F cells are byte-identical after
    // the take (the call wrote only the header, and the take cleared
    // the result-alias register).
    vm.pc = 3;
    const discard_call = image.instructions[3];
    vm.enterCall(llir.jalTarget(3, llir.decode(discard_call).?.imm20));
    const after_enter = stack;
    vm.returnFrom(image.instructions[vm.pc]); // f1's ret zero
    try testing.expectEqualSlices(u32, after_enter[3..7], stack[3..7]); // caller F cells unchanged
    vm.pc = 4;
    const take_zero = image.instructions[4];
    try testing.expect(llir.isZeroReg(llir.decode(take_zero).?.a)); // discarded take
    vm.take(take_zero);
    try testing.expectEqual(@as(u32, 0), stack[7 + 0 + (7 - 4)]); // result-alias cell F7 cleared

    // ret zero returns a real zero: the caller's real slot receives 0.
    // The argument moves the compiler would have emitted are simulated
    // by writing f1's two arguments into its window slots — the caller's
    // top two cells (spec §5.3) — before the call record runs.
    vm.pc = 5;
    const zero_call = image.instructions[5];
    stack[vm.sp - 2 + 0] = 11; // window slot 0 → f1's param r0
    stack[vm.sp - 2 + 1] = 22; // window slot 1 → f1's param r1
    vm.enterCall(llir.jalTarget(5, llir.decode(zero_call).?.imm20));
    try testing.expectEqual(@as(u32, 11), stack[vm.fp + 0]); // r0
    try testing.expectEqual(@as(u32, 22), stack[vm.fp + 1]); // r1
    vm.returnFrom(image.instructions[vm.pc]); // f1's ret zero
    try testing.expectEqual(@as(u32, 6), vm.pc); // at the take
    vm.take(image.instructions[6]); // take the zero into r1
    try testing.expectEqual(@as(u32, 0), stack[vm.fp + 1]); // real zero in the real return slot
}

test "3.2 frame contract: direct and value calls — header, params, pc/sp/fp transitions, resume rebuild" {
    // Direct call: main -> add3(1, 2, 3). The MiniVm drives the call
    // record and the callee's ret, asserting every transition of spec
    // §5.3/§5.4 and the FunctionDesc rebuild after the resume.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn add3(a: int32, b: int32, c: int32) -> int32 { a + b + c }
            \\fn main() -> int32 { add3(1, 2, 3) }
        },
    });
    defer c.deinit();
    const program = c.program orelse return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();
    try testing.expect((try llir_validate.validate(&image, testing.allocator)) == null);

    const add3 = b.func_ids.get(findFunc(&program, "app.add3")).?;
    const main = b.func_ids.get(findFunc(&program, "app.main")).?;
    const found = blk: {
        for (image.instructions, 0..) |rec, pc| {
            const d = llir.decode(rec) orelse continue;
            if (d.op == .jal and d.a == llir.ra_reg and llir.jalTarget(@intCast(pc), d.imm20) == image.functions[add3].entry_pc) break :blk .{ @as(u32, @intCast(pc)), d };
        }
        break :blk null;
    };
    const found_rec = found orelse return error.TestUnexpectedResult;
    const call_pc = found_rec[0];
    const call_dec = found_rec[1];
    // The v9 call record is a `jal ra` — no call descriptor: the
    // callee's signature is read from the function table directly at
    // the resolved target (spec §5.2).
    const callee_sig = image.functions[add3].signature_id;
    try testing.expectEqual(@as(u32, 3), image.signatures[callee_sig].params_len);

    var stack = [_]u32{0} ** 96;
    var vm = MiniVm{ .program = &image, .stack = &stack, .pc = 0, .sp = 0, .fp = 3 };
    // The caller (main) is mid-execution at the call record: root frame
    // at fp = 3, sp at main's frame end.
    vm.pc = call_pc;
    vm.sp = llir.frameEnd(3, image.functions[main]);
    const arg_vals = [_]u32{ 1, 2, 3 };
    // The compiler-emitted argument moves place each argument into its
    // window slot — the callee's parameter register (spec §5.3).
    for (0..3) |k| stack[vm.sp - 3 + @as(u32, @intCast(k))] = arg_vals[k];

    // call: the three-cell header goes at [fp_callee - 3, fp_callee) with
    // fp_callee = sp - A (A = max(3 params, 1 result) = 3); sp = the
    // callee's frame end; pc = the callee entry; the parameters are
    // already in r0..r(P-1) — the call performs no staging.
    const old_sp = vm.sp;
    const callee = image.functions[add3];
    vm.enterCall(llir.jalTarget(call_pc, call_dec.imm20));
    try testing.expectEqual(old_sp - 3, vm.fp);
    try testing.expectEqual(callee.entry_pc, vm.pc);
    try testing.expectEqual(llir.frameEnd(vm.fp, callee), vm.sp);
    // The three header cells at [sp - A - 3, sp - A) (spec §5.3 step 4).
    try testing.expectEqual(@as(u32, 3), stack[old_sp - 6 + 0]); // saved_fp = the caller's frame base (root fp = 3)
    try testing.expectEqual(call_pc + 1, stack[old_sp - 6 + 2]); // saved_ra = pc + 1
    // Params in r0..r(P-1) — the window cells the moves wrote (spec §5.3).
    for (0..3) |k| try testing.expectEqual(arg_vals[k], stack[vm.fp + k]);

    // ret: the result is read before restoring, published to the
    // callee's slot 0, then sp/fp/pc are restored. Step 8 coalescing:
    // `main` returns the call result directly, so no post-call `take`
    // exists — the result stays in the caller's result alias
    // `F(L+3+O-A)` and the fallthrough `ret` reads it.
    const ret_pc = firstRetPc(&image, add3);
    vm.pc = ret_pc;
    vm.write(llir.decode(image.instructions[ret_pc]).?.a, 6); // the computed sum
    vm.returnFrom(image.instructions[ret_pc]);
    try testing.expectEqual(old_sp, vm.sp);
    try testing.expectEqual(@as(u32, 3), vm.fp);
    try testing.expectEqual(call_pc + 1, vm.pc); // the caller's fallthrough
    const rt = llir.decode(image.instructions[call_pc + 1]).?;
    try testing.expectEqual(llir.Opcode.ret, rt.op); // coalesced: ret reads the alias
    const fd_main = image.functions[main];
    const alias = fd_main.f_count + fd_main.window_count - 3; // A = max(3 params, 1 result)
    try testing.expectEqual(@as(u32, 6), stack[3 + alias]); // result stays in the alias cell
    // The resumed caller's FunctionDesc is rebuilt from the pc — never
    // cached (spec §2, §3.2).
    try testing.expectEqual(@as(?llir.FunctionId, main), llir.functionAtPc(image.functions, vm.pc));
    try testing.expectEqual(image.functions[main], vm.function());

    // Value call: apply(add, 10, 20) — fn_ref stores the callee entry
    // PC in a slot; `jalr ra, base, 0` resolves the callee from that
    // slot. The callee's signature is read from the function table at
    // the resolved target (the `f` argument is the callee selector, not
    // a parameter).
    var c2 = try compileText("app", &.{
        .{
            "app",
            \\fn add(a: int32, b: int32) -> int32 { a + b }
            \\fn apply(f: fn(int32, int32) -> int32, a: int32, b: int32) -> int32 { f(a, b) }
            \\fn main() -> int32 {
            \\    let z = apply(add, 10, 20);
            \\    z
            \\}
        },
    });
    defer c2.deinit();
    const program2 = c2.program orelse return error.TestUnexpectedResult;
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var b2 = cfg_lower_llir.Builder.init(arena2.allocator(), &program2);
    const image2 = try b2.lowerLlir();
    try testing.expect((try llir_validate.validate(&image2, testing.allocator)) == null);

    const add2 = b2.func_ids.get(findFunc(&program2, "app.add")).?;
    const apply2 = b2.func_ids.get(findFunc(&program2, "app.apply")).?;
    const call_i = blk: {
        for (image2.instructions, 0..) |rec, pc| {
            const d = llir.decode(rec) orelse continue;
            if (d.op == .jalr) break :blk .{ d, @as(u32, @intCast(pc)) };
        }
        break :blk null;
    }.?;
    // The only jalr is apply's `f(a, b)`: the base register is apply's
    // own parameter f (slot 0), which main's module_ref + load_member
    // loaded and passed in.
    try testing.expect(llir.isFrame(call_i[0].a));
    try testing.expect(llir.frameIndex(call_i[0].a) < image2.functions[apply2].f_count);

    var stack2 = [_]u32{0} ** 96;
    var vm2 = MiniVm{ .program = &image2, .stack = &stack2, .pc = 0, .sp = 0, .fp = 3 };
    vm2.pc = call_i[1];
    vm2.sp = llir.frameEnd(3, image2.functions[apply2]);
    // Executing load_member (in main) passed the function value — the
    // callee's entry PC — into apply's parameter slot; the callee
    // resolves from that slot, never from a static id. The argument
    // moves place a and b into add's window slots — apply's top two
    // cells.
    vm2.write(call_i[0].a, image2.functions[add2].entry_pc);
    stack2[vm2.sp - 2 + 0] = 10;
    stack2[vm2.sp - 2 + 1] = 20;
    try testing.expectEqual(image2.functions[add2].entry_pc, vm2.read(call_i[0].a)); // the base slot holds the fn value

    const old_sp2 = vm2.sp;
    const callee2 = image2.functions[add2];
    vm2.enterCall(@as(u32, @truncate(llir.jrTarget(@as(u64, vm2.read(call_i[0].a)), @as(i16, @bitCast(call_i[0].imm16))))));
    try testing.expectEqual(old_sp2 - 2, vm2.fp);
    try testing.expectEqual(callee2.entry_pc, vm2.pc);
    try testing.expectEqual(llir.frameEnd(vm2.fp, callee2), vm2.sp);
    try testing.expectEqual(@as(u32, 10), stack2[vm2.fp + 0]); // r0 = a
    try testing.expectEqual(@as(u32, 20), stack2[vm2.fp + 1]); // r1 = b

    const ret2_pc = firstRetPc(&image2, add2);
    vm2.pc = ret2_pc;
    vm2.write(llir.decode(image2.instructions[ret2_pc]).?.a, 30);
    vm2.returnFrom(image2.instructions[ret2_pc]);
    try testing.expectEqual(old_sp2, vm2.sp);
    try testing.expectEqual(@as(u32, 3), vm2.fp);
    try testing.expectEqual(call_i[1] + 1, vm2.pc); // at the caller's take
    const take2 = llir.decode(image2.instructions[call_i[1] + 1]).?;
    try testing.expectEqual(llir.Opcode.take, take2.op);
    vm2.take(image2.instructions[call_i[1] + 1]);
    try testing.expectEqual(@as(u32, 30), stack2[3 + llir.frameIndex(take2.a)]);
    try testing.expectEqual(image2.functions[apply2], vm2.function());
}

test "3.2 frame contract: executing the emitted argument moves into the window" {
    // An argument live across another call cannot be homed in the
    // window, so both call sites emit a real argument move (spec §5.3).
    // The MiniVm executes the move record, then the call; the callee
    // reads its parameter from r0..r(P-1) — the window cell the move
    // wrote.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn f(x: int32) -> int32 { x }
            \\fn main() -> int32 {
            \\    let a = 1;
            \\    let r = f(a) + f(a);
            \\    r
            \\}
        },
    });
    defer c.deinit();
    const program = c.program orelse return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();
    try testing.expect((try llir_validate.validate(&image, testing.allocator)) == null);

    const f = b.func_ids.get(findFunc(&program, "app.f")).?;
    const main = b.func_ids.get(findFunc(&program, "app.main")).?;
    const mfd = image.functions[main];
    _ = &mfd;
    // Both calls to f carry one argument move immediately before the
    // call record, targeting the window.
    var calls: usize = 0;
    var first_move: ?llir.Instr = null;
    var first_call_pc: ?u32 = null;
    for (image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op != .jal or d.a != llir.ra_reg or llir.jalTarget(@intCast(pc), d.imm20) != image.functions[f].entry_pc) continue;
        calls += 1;
        const mv = image.instructions[pc - 1];
        if (first_move == null) {
            first_move = mv;
            first_call_pc = @intCast(pc);
        }
        // v9: the argument write is a slot_* I-format record — a = the F
        // source, imm16 = the absolute outgoing-window offset.
        const d_mv = llir.decode(mv).?;
        const off = d_mv.imm16;
        try testing.expect(off < mfd.window_count);
        try testing.expect(llir.isFrame(d_mv.a));
        try testing.expect(llir.frameIndex(d_mv.a) < mfd.f_count); // a caller F cell
    }
    try testing.expectEqual(@as(usize, 2), calls);
    const mv = first_move.?;
    const call_pc = first_call_pc.?;
    const d_mv = llir.decode(mv).?;
    const off = d_mv.imm16;

    var stack = [_]u32{0} ** 96;
    var vm = MiniVm{ .program = &image, .stack = &stack, .pc = 0, .sp = 0, .fp = 3 };
    vm.pc = call_pc - 1; // at the slot_* record
    vm.sp = llir.frameEnd(3, mfd);
    vm.write(d_mv.a, 1); // `a`'s value in its source cell
    // Execute the argument preparation (Instruction Set §5): the window cell at
    // the record's absolute offset receives the caller's value.
    stack[vm.fp + @as(u32, mfd.f_count) + mfd.x_count + off] = stack[vm.fp + llir.frameIndex(d_mv.a)];
    vm.pc = call_pc;
    const call_rec = image.instructions[call_pc];
    vm.enterCall(llir.jalTarget(call_pc, llir.decode(call_rec).?.imm20));
    // The callee's F0 aliases the window cell the slot_* wrote.
    try testing.expectEqual(@as(u32, 1), stack[vm.fp + 0]);
    // The header sat two cells below the window, inside the caller's
    // reserved window region.
    try testing.expectEqual(@as(u32, 3), stack[llir.headerBase(vm.fp) + 0]); // saved_fp = the caller's frame base (root fp = 3)
}

test "3.2 frame contract: tailcall_self reuses the frame as a pure jump" {
    // The self-tailcall (spec §5.5): same fp; Phase 5 emits explicit
    // copies to r0..r(P-1) before the jump, so the instruction itself
    // only resets sp to the frame end and pc back to the entry.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\func @count(n: int32, acc: int32) -> int32 {
        \\entry:
        \\    %2: int32 = const 100
        \\    %3: bool = lt %0, %2
        \\    br %3 ? done : rec
        \\rec:
        \\    %4: int32 = sub %1, %2
        \\    tailcall @count, %0, %4
        \\done:
        \\    ret %1
        \\}
        \\}
    );
    defer t.arena.deinit();
    const program = &t.program;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expect((try llir_validate.validate(&image, testing.allocator)) == null);

    const count = b.func_ids.get(program.funcs[0]).?;
    const fd = image.functions[count];
    const tc = blk: {
        for (image.instructions, 0..) |rec, pc| {
            const d = llir.decode(rec) orelse continue;
            if (d.op == .tailcall_self) break :blk .{ d, @as(u32, @intCast(pc)) };
        }
        break :blk null;
    }.?;
    // No descriptor: the pure-jump record carries zeros in a/b.
    try testing.expectEqual(@as(u32, 0), tc[0].a);
    try testing.expectEqual(@as(u32, 0), tc[0].b);

    var stack = [_]u32{0} ** 96;
    var vm = MiniVm{ .program = &image, .stack = &stack, .pc = 0, .sp = 0, .fp = 3 };
    vm.pc = tc[1];
    vm.sp = llir.frameEnd(3, fd);
    // One iteration's worth of live state: n = 5 in r0, the just-computed
    // acc - 1 = 4 in r1. The compiler-emitted copies would have already
    // placed these values in r0..r(P-1) before the tailcall instruction.
    vm.write(llir.frame_base + 0, 5); // r0 = n
    vm.write(llir.frame_base + 1, 4); // r1 = acc

    const fp_before = vm.fp;
    vm.tailcallSelf();
    // fp preserved — no new frame, no header.
    try testing.expectEqual(fp_before, vm.fp);
    // Phase 5: the compiler emitted explicit copies before the tailcall,
    // so the args are already in r0..r(P-1). tailcallSelf is a pure
    // jump — no staging, no hidden writes.
    try testing.expectEqual(@as(u32, 5), stack[vm.fp + 0]);
    try testing.expectEqual(@as(u32, 4), stack[vm.fp + 1]);
    // sp reset to the frame end, pc back at the entry.
    try testing.expectEqual(llir.frameEnd(vm.fp, fd), vm.sp);
    try testing.expectEqual(fd.entry_pc, vm.pc);
}

// ---------------------------------------------------------------------------
// Phase 3.2 — frame contract, part 2 (TODO 3.5): the three-cell header with
// the argument/result slot-0 overlap — zero-parameter non-void (A = 1),
// argument-0 ownership consumption before result publication, take
// adjacency to its call, and call-entry validation failure atomicity. These
// are driven through `MiniVm` — the reference state model — without
// duplicating the interpreter's own dynamic take-mismatch test.
// ---------------------------------------------------------------------------

// Build a `fn() -> int32` caller calling a `fn(x: int32) -> int32` callee
// with A = 1: the argument slot 0 and the result slot 0 are the same
// cell (spec §5.2). The caller frame carries F0 (result), the callee
// aliases slot 0 as its F0 (r0). `slot_move` is the argument move; the
// call writes the three-cell header; `ret` publishes slot 0; the take
// clears it.
test "3.2 frame contract: zero-param non-void and the argument/result slot-0 overlap" {
    // f0 (caller): () -> int32, W = 3 + A = 4 (A = 1 for the 1-param
    // callee). F0 = result slot.
    //   pc 0: slot_move F0?? — no: the caller has no argument, so the
    //   callee takes one. The caller must pass 7 into the window slot;
    //   it materializes it into F0 then slot_move F0, offs = W - A = 3.
    //   pc 0: movwz0 F0 = 7
    //   pc 1: slot_move F0, 3       (window slot at callBase + 3)
    //   pc 2: jal ra → callee
    //   pc 3: take F0, F4           (F(L+3+O-A) = F(1+3+1-1) = F4)
    //   pc 4: ret F0
    // f1 (callee): (x: int32) -> int32, A = 1, F0 = x aliases slot 0.
    //   pc 5: ret F0
    const caller = llir.FunctionDesc{
        .code_start = 0,
        .code_end = 5,
        .entry_pc = 0,
        .signature_id = 0,
        .f_count = 1,
        .x_count = 0,
        .window_count = 4, // 3 + A where A = 1
    };
    const callee = llir.FunctionDesc{
        .code_start = 5,
        .code_end = 6,
        .entry_pc = 5,
        .signature_id = 1,
        .f_count = 1,
        .x_count = 0,
        .window_count = 0,
    };
    const image = llir.LlirProgram{
        .instructions = &.{
            llir.instrI(.movwz0, llir.frame_base + 0, 7), // pc 0
            llir.instrI(.slot_move, llir.frame_base + 0, 3), // pc 1
            llir.instrU(.jal, llir.ra_reg, 3), // pc 2 → 5
            llir.instrE(.take, llir.frame_base + 0, llir.frame_base + 4), // pc 3
            llir.instrE(.ret, llir.frame_base + 0, 0), // pc 4
            llir.instrE(.ret, llir.frame_base + 0, 0), // pc 5
        },
        .functions = &.{ caller, callee },
        .blocks = &.{ .{ .start_pc = 0, .end_pc = 5 }, .{ .start_pc = 5, .end_pc = 6 } },
        .constants = &.{},
        .types = &.{
            .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.int32), .b = 0, .c = 0 },
        },
        .type_decls = &.{},
        .type_decl_fields = &.{},
        .union_variants = &.{},
        .union_payloads = &.{},
        .host_types = &.{},
        .self_symbol = 0,
        .init = llir.no_index,
        .entry_member = llir.no_index,
        .symbols = &.{},
        .imports = &.{},
        .exports = &.{},
        .module_slots = &.{},
        .signatures = &.{
            .{ .params_start = 0, .params_len = 0, .ret = 0 }, // f0: () -> int32
            .{ .params_start = 0, .params_len = 1, .ret = 0 }, // f1: (int32) -> int32
        },
        .params = &.{.{ .mode = .plain, .type_ = 0 }},
        .call_args = &.{},
        .syscall_descs = &.{},
        .construct_descs = &.{},
        .destructure_dsts = &.{},
        .destructure_descs = &.{},
        .switch_arms = &.{},
        .switch_descs = &.{},
        .destructure_dst_types = &.{},
        .member_descs = &.{},
        .drop_descs = &.{},
        .strings = &.{},
    };
    var stack = [_]u32{0} ** 64;
    var vm = MiniVm{ .program = &image, .stack = &stack, .pc = 0, .sp = 0, .fp = 2 };
    vm.sp = llir.frameEnd(2, caller);
    // Execute the caller's records up to the call.
    vm.write(llir.frame_base + 0, 7); // the caller's F0 = 7
    // slot_move F0, offs=3 → window slot at callBase(2, caller) + 3.
    const arg_off: u32 = 3;
    const addr = llir.callBase(2, image.functions[0]) + arg_off;
    stack[addr] = stack[2 + 0];
    // A = max(1 param, 1 result) = 1.
    const A: u32 = 1;
    vm.pc = 2;
    const old_sp = vm.sp;
    vm.enterCall(llir.jalTarget(2, llir.decode(image.instructions[2]).?.imm20));
    // Callee fp aliases the window top: fp = sp - A; its r0 (F0) is the
    // slot the slot_move wrote.
    try testing.expectEqual(old_sp - A, vm.fp);
    try testing.expectEqual(@as(u32, 7), stack[vm.fp + 0]); // callee F0 == arg 0
    // callee ret publishes its F0 to slot 0 (same cell), restores.
    vm.returnFrom(image.instructions[vm.pc]);
    try testing.expectEqual(old_sp, vm.sp);
    try testing.expectEqual(@as(u32, 2), vm.fp);
    try testing.expectEqual(@as(u32, 3), vm.pc); // at the caller's take
    // The result is in value-area slot 0 = callBase + (W - A).
    const w_out = llir.callBase(2, caller) + (caller.window_count - A);
    try testing.expectEqual(@as(u32, 7), stack[w_out]);
    // The take clears its source (the result alias) and lands the
    // value in the caller's F0.
    vm.take(image.instructions[3]);
    try testing.expectEqual(@as(u32, 0), stack[w_out]);
    try testing.expectEqual(@as(u32, 7), stack[2 + 0]);
}

test "3.2 frame contract: argument-0 owner is consumed before the result publishes" {
    // The value area is A cells; slot 0 is both the first argument and
    // the unique result. When the callee returns, `returnFrom` publishes
    // the result to slot 0 — but the arg-0 *owner* must already have
    // been consumed/released before that publication (spec §5.4). This
    // is a MiniVm contract invariant: we model it by asserting that any
    // owner whose slot is reused is cleared by the time the result is
    // published. Here the callee takes a Copy scalar, so there is no
    // distinct owner handle — the invariant is that `returnFrom` writes
    // the result without retaining (slot 0 holds exactly the result).
    var l = try compileText("app", &.{
        .{ "app", "fn id(x: int32) -> int32 { x }\nfn main() -> int32 { id(5) }" },
    });
    defer l.deinit();
    const program = l.program orelse return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();
    try testing.expect((try llir_validate.validate(&image, testing.allocator)) == null);
    // The arg move into the window and the `ret` publish are separate
    // records; the slot-0 overlap means the arg must be moved (owner
    // transferred into the window) before the call, and the result
    // published there without a second retain. Lowering must not emit a
    // copy onto slot 0 after the call.
    const id = b.func_ids.get(findFunc(&program, "app.id")).?;
    const main = b.func_ids.get(findFunc(&program, "app.main")).?;
    var call_pc: u32 = 0;
    for (image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op == .jal and d.a == llir.ra_reg and llir.jalTarget(@intCast(pc), d.imm20) == image.functions[id].entry_pc) {
            call_pc = @intCast(pc);
            break;
        }
    }
    try testing.expect(call_pc != 0);
    // The record immediately before the call is the argument move; there
    // is no copy between them. A Copy scalar transfers via `slot_copy`;
    // an owner via `slot_move`. Both are the same slot-0 mechanism.
    const before = llir.decode(image.instructions[call_pc - 1]).?;
    try testing.expect(before.op == .slot_move or before.op == .slot_copy or before.op == .slot_borrow);
    // Step 8 coalescing: `main` returns the call result directly, so the
    // post-call `take` is dropped — the fallthrough `ret` reads the
    // result alias F(L+3+O-A) directly.
    try testing.expectEqual(llir.Opcode.ret, llir.decode(image.instructions[call_pc + 1]).?.op);
    const nd = llir.decode(image.instructions[call_pc + 1]).?;
    const callee_id = llir.functionAtPc(image.functions, llir.jalTarget(call_pc, llir.decode(image.instructions[call_pc]).?.imm20)).?;
    const sig = image.signatures[image.functions[callee_id].signature_id];
    const caller = image.functions[llir.functionAtPc(image.functions, call_pc).?];
    const A: u32 = @max(sig.params_len, @as(u32, 1));
    try testing.expectEqual(llir.frameReg(caller.f_count + caller.window_count - A), nd.a);
    _ = main;
}

test "3.2 frame contract: every call's take is adjacent with the result-alias source" {
    // Static `jal ra` calls: a non-void callee must have a `take`
    // immediately at pc+1 whose source is the result alias
    // `F(L+3+O-A)`; a void callee must see no take at its fallthrough.
    // Scan a lowering and assert both.
    var l = try compileText("app", &.{
        .{
            "app",
            \\fn f(x: int32) -> int32 { x }
            \\fn g() -> void {}
            \\fn main() -> int32 {
            \\    let a = f(1);
            \\    g();
            \\    a
            \\}
        },
    });
    defer l.deinit();
    const program = l.program orelse return error.TestUnexpectedResult;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &program);
    const image = try b.lowerLlir();
    try testing.expect((try llir_validate.validate(&image, testing.allocator)) == null);
    const f = b.func_ids.get(findFunc(&program, "app.f")).?;
    const g = b.func_ids.get(findFunc(&program, "app.g")).?;
    var calls: usize = 0;
    for (image.instructions, 0..) |rec, pc| {
        const d = llir.decode(rec) orelse continue;
        if (d.op != .jal or d.a != llir.ra_reg) continue;
        calls += 1;
        const target = llir.jalTarget(@intCast(pc), d.imm20);
        const callee_id = llir.functionAtPc(image.functions, target).?;
        const sig = image.signatures[image.functions[callee_id].signature_id];
        if (callee_id == f) {
            // Non-void: adjacent take with the result-alias source.
            const nd = llir.decode(image.instructions[pc + 1]) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(llir.Opcode.take, nd.op);
            const A: u32 = @max(sig.params_len, 1);
            const caller = image.functions[llir.functionAtPc(image.functions, @intCast(pc)).?];
            try testing.expectEqual(llir.frameReg(caller.f_count + caller.window_count - A), nd.b);
        } else if (callee_id == g) {
            // Void: no take at the fallthrough.
            const nd = llir.decode(image.instructions[pc + 1]) orelse return error.TestUnexpectedResult;
            try testing.expect(nd.op != .take);
        } else {
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(usize, 2), calls);
}

test "3.2 frame contract: call-entry validation failure leaves no half frame" {
    // `tryEnterCall` validates the callee entry, window capacity, and
    // the take contract before committing. On any failure the
    // caller's fp/sp/pc are byte-identical and no header is written.
    const caller = llir.FunctionDesc{
        .code_start = 0,
        .code_end = 3,
        .entry_pc = 0,
        .signature_id = 0,
        .f_count = 1,
        .x_count = 0,
        .window_count = 4, // W = 3 + A → O = 1, so the take check runs
    };
    const callee = llir.FunctionDesc{
        .code_start = 3,
        .code_end = 5,
        .entry_pc = 3,
        .signature_id = 1,
        .f_count = 1,
        .x_count = 0,
        .window_count = 0,
    };
    // caller: pc2 jal ra → pc 4 (callee? no: entry 3). We target a
    // non-entry pc (4) to trigger NotAnEntry, and a ret pc with no take
    // to trigger TakeMismatch.
    const image = llir.LlirProgram{
        .instructions = &.{
            llir.instrU(.jal, llir.ra_reg, 1), // pc 0 → 1
            llir.instrE(.ret, 0, 0), // pc 1
            llir.instrE(.ret, 0, 0), // pc 2
            llir.instrE(.ret, 0, 0), // pc 3
            llir.instrE(.ret, 0, 0), // pc 4
        },
        .functions = &.{ caller, callee },
        .blocks = &.{ .{ .start_pc = 0, .end_pc = 3 }, .{ .start_pc = 3, .end_pc = 5 } },
        .constants = &.{},
        .types = &.{
            .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.int32), .b = 0, .c = 0 },
        },
        .type_decls = &.{},
        .type_decl_fields = &.{},
        .union_variants = &.{},
        .union_payloads = &.{},
        .host_types = &.{},
        .self_symbol = 0,
        .init = llir.no_index,
        .entry_member = llir.no_index,
        .symbols = &.{},
        .imports = &.{},
        .exports = &.{},
        .module_slots = &.{},
        .signatures = &.{
            .{ .params_start = 0, .params_len = 0, .ret = 0 }, // f0
            .{ .params_start = 0, .params_len = 0, .ret = 0 }, // f1
        },
        .params = &.{},
        .call_args = &.{},
        .syscall_descs = &.{},
        .construct_descs = &.{},
        .destructure_dsts = &.{},
        .destructure_descs = &.{},
        .switch_arms = &.{},
        .switch_descs = &.{},
        .destructure_dst_types = &.{},
        .member_descs = &.{},
        .drop_descs = &.{},
        .strings = &.{},
    };
    var stack = [_]u32{0} ** 64;
    var vm = MiniVm{ .program = &image, .stack = &stack, .pc = 0, .sp = 0, .fp = 2 };
    vm.sp = llir.frameEnd(2, caller);
    const fp0 = vm.fp;
    const sp0 = vm.sp;
    const pc0 = vm.pc;
    // Non-entry target (4 is inside the callee but not its entry 3).
    try testing.expectError(error.NotAnEntry, vm.tryEnterCall(4));
    try testing.expectEqual(fp0, vm.fp);
    try testing.expectEqual(sp0, vm.sp);
    try testing.expectEqual(pc0, vm.pc);
    // Take mismatch: an entry target whose return pc holds no take
    // (the `ret` at pc 1) is rejected before any commit.
    try testing.expectError(error.TakeMismatch, vm.tryEnterCall(3));
    try testing.expectEqual(fp0, vm.fp);
    try testing.expectEqual(sp0, vm.sp);
    try testing.expectEqual(pc0, vm.pc);
    // The header cells below the window were never written.
    try testing.expectEqual(@as(u32, 0), stack[llir.headerBase(sp0 - 1)]);
}

// ---------------------------------------------------------------------------
// Phase 3.3 — corpus normalization harness (TODO 3.3): the LLIR
// projection wired into the optimizer corpus harness (8.9). Every
// example compiles through the executable pipeline (optimizer + drop
// lowering), lowers to LLIR, and is validated (3.1) and measured:
// instruction count, the serialized bytes of the fixed records (the
// 8-byte instructions plus the per-function/per-block descriptors) vs
// the side tables (every flat row, descriptors broken out), the frame
// slot counts, and the total image bytes.
// ---------------------------------------------------------------------------

/// Serialized bytes of an image's fixed records — the 8-byte
/// instructions plus the per-function/per-block descriptors a VM pages
/// in to dispatch and frame (spec §2).
fn fixedRecordBytes(image: *const llir.LlirProgram) usize {
    return image.instructions.len * @sizeOf(llir.Instr) +
        image.functions.len * @sizeOf(llir.FunctionDesc) +
        image.blocks.len * @sizeOf(llir.BlockDesc);
}

/// Serialized bytes of the descriptor side tables — the
/// syscall/construct/destructure/switch/cleanup descriptors and
/// their row tables (Instruction Set §7). "Descriptor bytes" in the
/// 3.3 report. (`call_descs` is gone in v9 — direct calls are
/// `jal ra`, indirect `jalr`, neither carrying a descriptor.)
fn descriptorBytes(image: *const llir.LlirProgram) usize {
    return image.call_args.len * @sizeOf(llir.ValueReg) +
        image.syscall_descs.len * @sizeOf(llir.SyscallDesc) +
        image.construct_descs.len * @sizeOf(llir.ConstructDesc) +
        image.destructure_descs.len * @sizeOf(llir.DestructureDesc) +
        image.destructure_dsts.len * @sizeOf(llir.ValueReg) +
        image.switch_descs.len * @sizeOf(llir.SwitchDesc) +
        image.switch_arms.len * @sizeOf(llir.SwitchArm) +
        image.member_descs.len * @sizeOf(llir.MemberDesc) +
        image.drop_descs.len * @sizeOf(llir.DropDesc);
}

/// Serialized bytes of every non-fixed row — all flat side tables
/// (spec §2, Instruction Set §8), descriptors included: the whole
/// image minus the fixed records.
fn sideTableBytes(image: *const llir.LlirProgram) usize {
    return descriptorBytes(image) +
        image.constants.len * @sizeOf(llir.ConstRecord) +
        image.types.len * @sizeOf(llir.TypeDesc) +
        image.type_decls.len * @sizeOf(llir.TypeDeclDesc) +
        image.type_decl_fields.len * @sizeOf(llir.TypeId) +
        image.union_variants.len * @sizeOf(llir.UnionVariant) +
        image.union_payloads.len * @sizeOf(llir.TypeId) +
        image.host_types.len * @sizeOf(llir.HostTypeDesc) +
        image.symbols.len * @sizeOf(llir.SymRange) +
        image.imports.len * @sizeOf(llir.ImportDesc) +
        image.exports.len * @sizeOf(llir.ExportDesc) +
        image.module_slots.len * @sizeOf(llir.ModuleSlot) +
        image.signatures.len * @sizeOf(llir.SignatureDesc) +
        image.params.len * @sizeOf(llir.ParamDesc) +
        image.destructure_dst_types.len * @sizeOf(llir.TypeId) +
        image.member_descs.len * @sizeOf(llir.MemberDesc) +
        image.drop_descs.len * @sizeOf(llir.DropDesc) +
        image.strings.len;
}

test "3.3 LLIR normalization harness: corpus normalize, validate, and measure" {
    // The v9-corpus subset used by the normalization measurement.
    const corpus = [_][]const u8{
        "examples/ownership.st", "examples/match.st", "examples/floats.st",
    };
    const io = std.testing.io;
    var total_instrs: usize = 0;
    var total_fixed: usize = 0;
    var total_side: usize = 0;
    var total_desc: usize = 0;
    var total_slots: u64 = 0;
    var max_frame: u32 = 0;
    const tty = std.Io.File.stderr().isTty(std.testing.io) catch false;
    for (corpus) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(src);
        var c = try compileOpt("app", &.{.{ "app", src }});
        defer c.deinit();
        const program = &c.program.?;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
        const image = try b.lowerLlir();

        // The corpus normalizes: every image is fully valid (3.1 — all
        // references legal) and every record passes the schema check
        // under its function's frame.
        if (try llir_validate.validate(&image, testing.allocator)) |m| {
            std.log.err("3.3 {s}: rejected: {s}", .{ path, m });
            return error.TestUnexpectedResult;
        }
        var image_max_frame: u32 = 0;
        for (image.functions) |fd| {
            const slots = fd.f_count;
            for (image.instructions[fd.code_start..fd.code_end]) |rec| {
                try testing.expectEqual(@as(?llir.Issue, null), llir.checkInstr(rec, slots));
            }
            const frame = @as(u32, fd.f_count) + fd.x_count + fd.window_count;
            image_max_frame = @max(image_max_frame, frame);
            total_slots += frame;
        }
        max_frame = @max(max_frame, image_max_frame);

        const fixed = fixedRecordBytes(&image);
        const side = sideTableBytes(&image);
        const desc = descriptorBytes(&image);
        total_instrs += image.instructions.len;
        total_fixed += fixed;
        total_side += side;
        total_desc += desc;
        // The report distinguishes the fixed records from the side
        // tables (descriptors broken out); gated on a TTY like 8.9 —
        // under `zig build test` stderr is a captured pipe.
        if (tty) {
            std.log.info(
                "3.3 {s}: {d} instr, {d} B fixed records, {d} B side tables ({d} B descriptors), max frame {d} slots, {d} B image",
                .{ path, image.instructions.len, fixed, side, desc, image_max_frame, fixed + side },
            );
        }
    }
    // The corpus exercises every byte-size class: instructions, the
    // descriptor tables (calls/matches/constructs are everywhere), and
    // the rest of the side tables (types/signatures/strings).
    try testing.expect(total_instrs > 0);
    try testing.expect(total_desc > 0);
    try testing.expect(total_side > total_desc);
    if (tty) {
        std.log.info(
            "3.3 corpus: {d} instr, {d} B fixed + {d} B side tables = {d} B; {d} frame slots (max {d})",
            .{ total_instrs, total_fixed, total_side, total_fixed + total_side, total_slots, max_frame },
        );
    }
}

test "3.2 LLIR normalization: host syscalls and any dynamic types normalize together" {
    // Phase 6: a program mixing `any` packing/recovery of a 64-bit
    // payload with builtin syscalls lowers to a valid image carrying
    // the payload TypeIds on the any instructions and the binding
    // signature on the syscall.
    try expectSourceNormalizes(
        "host_any",
        \\const builtin = import("builtin");
        \\fn wrap(a: int64) -> any { a }
        \\fn main() -> void {
        \\    let v: int64 = 9007199254740993;
        \\    let a = wrap(v);
        \\    let w = (move a) as int64;
        \\    builtin.print(builtin.str(1));
        \\}
    ,
        &.{
            // The i64 payload is Copy, so the return pack copies; the
            // unique-any recovery consumes the shell (move).
            .{ .op = .any_pack_copy, .min = 1 },
            .{ .op = .any_unpack_move, .min = 1 },
            .{ .op = .syscall, .min = 1 },
        },
    );
}
