//! Test file: `frontend LLIR validate` — the v9 structural rejections
//! of `src/passes/llir_validate.zig` (Stilla LLIR Specification §8):
//! each test lowers a small program (or hand-builds an image), mutates
//! one field of the image, and asserts the validator rejects the class
//! named by the test. The validator is structural only (decode,
//! register/special schemas,
//! immediate and ID bounds, branch/call targets, the take
//! contract, block terminators, `cond` lifetime, frame layout), so the
//! old phase-1 plan tests are gone and the stage-2 typed-matrix tests
//! now assert structural validity of the type-specialized opcodes.
//! `LoweredImage`, `lowerForValidation`, `firstPcOf`, and
//! `expectRejected` are local to this file.
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
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const compileOpt = helpers.compileOpt;

/// Phase 3.1 helper: parse a text-AIR program and lower it to a LLIR
/// image, keeping both arenas alive so the tests can corrupt the image
/// in place (via `@constCast`) and re-validate.
const LoweredImage = struct {
    /// The text-parser arena (kept alive for the whole test run; the
    /// image itself is fully materialized in `arena`).
    t_arena: std.heap.ArenaAllocator,
    /// The lowering arena owning the image's slices.
    arena: std.heap.ArenaAllocator,
    image: llir.LlirProgram,
};

fn lowerForValidation(text: []const u8) !LoweredImage {
    var t = try cfg_parse.parseText(text);
    errdefer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    const image = try b.lowerLlir();
    return .{ .t_arena = t.arena, .arena = arena, .image = image };
}

/// The pc of the first instruction with opcode `op`, or null.
fn firstPcOf(image: *const llir.LlirProgram, op: llir.Opcode) ?u32 {
    for (image.instructions, 0..) |rec, pc| {
        if (llir.decode(rec)) |d| {
            if (d.op == op) return @intCast(pc);
        }
    }
    return null;
}

/// Expect `validate` to reject `image` with a message containing
/// `needle`.
fn expectRejected(image: *const llir.LlirProgram, needle: []const u8) !void {
    const msg = (try llir_validate.validate(image, testing.allocator)) orelse {
        std.log.err("expected LLIR validation to reject with '{s}', but the image passed", .{needle});
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, needle) != null);
}

test "3.1 LLIR validation: valid lowered images pass" {
    // Text AIR: arithmetic, comparison, a branch, a direct call, a
    // fn_ref, and void/value rets.
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @callee(x: int32) -> int32 {
        \\    entry:
        \\        ret %0
        \\    }
        \\    func @f(a: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 2
        \\        %2: int32 = add %0, %1
        \\        %3: bool = gt %2, %0
        \\        %4: fn (int32) -> int32 = fn_ref @callee
        \\        br %3 ? l_t : l_f
        \\    l_t:
        \\        %5: int32 = call @callee, %2
        \\        ret %5
        \\    l_f:
        \\        ret %0
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    if (try llir_validate.validate(&li.image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("3.1 valid image rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }

    // Compiled programs through the full pipeline (optimizer + drop
    // lowering): unions/switches/destructures/phi joins and
    // maybe-unique cleanup paths.
    const corpus = [_][]const u8{
        "examples/match.st", "examples/floats.st",
    };
    const io = std.testing.io;
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
        if (try llir_validate.validate(&image, testing.allocator)) |m| {
            defer testing.allocator.free(m);
            std.log.err("3.1 valid image rejected for {s}: {s}", .{ path, m });
            return error.TestUnexpectedResult;
        }
    }
}

test "3.1 LLIR validation: invalid FunctionId (fn_ref out of range)" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @callee() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\    func @f() -> void {
        \\    entry:
        \\        %0: fn () -> void = fn_ref @callee
        \\        ret
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const pc = firstPcOf(&li.image, .fn_ref).?;
    const d = llir.decode(li.image.instructions[pc]).?;
    @constCast(li.image.instructions)[pc] = llir.instrI(.fn_ref, d.a, @intCast(li.image.functions.len));
    try expectRejected(&li.image, "fn_ref FunctionId");
}

test "3.1 LLIR validation: cross-function and out-of-range branch offsets" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @callee() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\    func @f(a: bool) -> bool {
        \\    entry:
        \\        br %0 ? l1 : l2
        \\    l1:
        \\        ret %0
        \\    l2:
        \\        ret %0
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const br_pc = (firstPcOf(&li.image, .bne) orelse firstPcOf(&li.image, .beq)).?;
    const br_fn = llir.functionAtPc(li.image.functions, br_pc).?;
    // The then-target names a block of the *other* function: the decoded
    // target (pc + offs10) is a block start, but not inside the current
    // function's range. The condition is a bool parameter, so the
    // lowering emitted `bne %0, zero, $l1; j $l2` — or, since
    // `l1` is the next block in the layout, the trailing-j elimination
    // inverted it to the one-record `beq %0, zero, $l2` — the offset
    // is the compare-and-branch's signed 10-bit field either way.
    const other = li.image.functions[(br_fn + 1) % li.image.functions.len].entry_pc;
    const brd = llir.decode(li.image.instructions[br_pc]).?;
    @constCast(li.image.instructions)[br_pc] = llir.instrB(brd.op, brd.a, brd.b, llir.fit10Signed(other, br_pc).?);
    try expectRejected(&li.image, "lies outside this function's code range");
    // A target past the end of the instruction space is equally rejected.
    var past_offs = llir.fit10Signed(@intCast(li.image.instructions.len), br_pc).?;
    if (past_offs == 2) past_offs += 1; // never collide with the long-branch +2 skip marker
    @constCast(li.image.instructions)[br_pc] = llir.instrB(brd.op, brd.a, brd.b, past_offs);
    try expectRejected(&li.image, "lies outside this function's code range");
}

test "3.1 LLIR validation: overlapping function code ranges" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\    func @g() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    // Function 1 starts where function 0 started: the ranges overlap
    // (and the tile check rejects the gap/overlap at the boundary).
    @constCast(li.image.functions)[1].code_start = 0;
    try expectRejected(&li.image, "does not tile");
}

test "3.1 LLIR validation: out-of-frame register operand" {
    // A register-register add: a `const` + op pair would be fused by
    // the peephole (2.14) into an immediate variant, so no `add`
    // record would exist to corrupt.
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = add %0, %1
        \\        ret %2
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const pc = firstPcOf(&li.image, .add).?;
    const fi = llir.functionAtPc(li.image.functions, pc).?;
    const slots = li.image.functions[fi].f_count + li.image.functions[fi].x_count;
    const d = llir.decode(li.image.instructions[pc]).?;
    // One past the frame is not a valid register (and not a special).
    @constCast(li.image.instructions)[pc] = llir.instrR(d.op, d.a, @intCast(llir.frameReg(slots)), d.c);
    try expectRejected(&li.image, "register operand is neither a slot nor a special register");
}

test "3.1 LLIR validation: wrong destructure descriptor kind" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(p: Pair) -> int32 {
        \\    entry:
        \\        %1: int32, %2: int32 = unpack_struct %0
        \\        ret %1
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const pc = firstPcOf(&li.image, .unpack_struct).?;
    const desc_id = llir.decode(li.image.instructions[pc]).?.imm16;
    // The opcode says `unpack_struct`; the descriptor now says `.tuple`.
    @constCast(li.image.destructure_descs)[desc_id].kind = .tuple;
    try expectRejected(&li.image, "destructure descriptor kind mismatch");
}

test "3.1 LLIR validation: wrong take source after a non-void call" {
    // The v10 call-shape contract: a non-void `jal ra` call must be
    // followed by `take dst, F(L+3+O-A)` — the take's source register is
    // the caller's result alias (Instruction Set §6, §14). A forged
    // source register is rejected before any dataflow.
    var li2 = try lowerForValidation(
        \\module "app" {
        \\    func @g() -> str {
        \\    entry:
        \\        %0: str = const "x"
        \\        ret %0
        \\    }
        \\    func @h(a: str) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1
        \\        ret %1
        \\    }
        \\    func @main() -> int32 {
        \\    entry:
        \\        %0: str = call @g
        \\        %1: int32 = call @h, %0
        \\        %2: int32 = const 0
        \\        ret %2
        \\    }
        \\}
    );
    defer li2.t_arena.deinit();
    defer li2.arena.deinit();
    const jal_pc = blk: {
        for (li2.image.instructions, 0..) |rec, pc| {
            if (llir.decode(rec)) |d| {
                if (d.op == .jal and d.a == llir.ra_reg) break :blk @as(u32, @intCast(pc));
            }
        }
        unreachable;
    };
    const rt_pc = jal_pc + 1;
    const rt_d = llir.decode(li2.image.instructions[rt_pc]) orelse return error.TestUnexpectedResult;
    try testing.expect(rt_d.op == .take);
    @constCast(li2.image.instructions)[rt_pc] = llir.instrE(.take, rt_d.a, 0); // wrong source: not the result alias
    try expectRejected(&li2.image, "non-void call take must source");
}

test "3.1 LLIR validation: register operand that is neither a slot nor a special" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = add %0, %1
        \\        ret %2
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const pc = firstPcOf(&li.image, .add).?;
    const d = llir.decode(li.image.instructions[pc]).?;
    // 0x40 is not an F slot of this 3-slot frame (f_count ≤ 109), not a
    // T register (0x6f–0x7e), and not a special — an invalid register
    // operand.
    @constCast(li.image.instructions)[pc] = llir.instrR(d.op, d.a, d.b, 0x40);
    try expectRejected(&li.image, "register operand is neither a slot nor a special register");
}

test "3.1 LLIR validation: stack/frame-size overflow" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    // f_count must stay ≤ frame_count_max (109, F0–F108) so a register
    // operand can never collide with the specials (spec §4.1): 0x8000
    // already exceeds the bound.
    @constCast(li.image.functions)[0].f_count = 0x8000;
    try expectRejected(&li.image, "frame too big");
}

test "3.1 LLIR validation: jr is a terminator with a real-slot base and imm offset" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: bool) -> bool {
        \\    entry:
        \\        br %0 ? l1 : l2
        \\    l1:
        \\        ret %0
        \\    l2:
        \\        ret %0
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const ret_pc = firstPcOf(&li.image, .ret).?;
    // jr is a terminator: a block ending in it validates (the base
    // register is dynamic, so no static target check applies — only the
    // register operand is schema-checked; the 16-bit offset is an
    // ordinary immediate).
    @constCast(li.image.instructions)[ret_pc] = llir.instrI(.jr, llir.frame_base, 0xffff);
    if (try llir_validate.validate(&li.image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("jr terminator rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }
    // The base register must be a real slot: a special is rejected.
    const d = llir.decode(li.image.instructions[ret_pc]).?;
    @constCast(li.image.instructions)[ret_pc] = llir.instrI(.jr, llir.zero_reg, d.imm16);
    try expectRejected(&li.image, "register operand is neither a slot nor a special register");
}

test "3.1 LLIR validation: auipc is not a terminator; its imm20 spans the U fields" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: bool) -> bool {
        \\    entry:
        \\        br %0 ? l1 : l2
        \\    l1:
        \\        ret %0
        \\    l2:
        \\        ret %0
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const ret_pc = firstPcOf(&li.image, .ret).?;
    // auipc is not a block terminator (v9): a block ending in it lacks
    // a terminator and is rejected. All U fields carry the 20-bit
    // displacement — ordinary immediates, so any value is legal — and
    // no static target check applies (the runtime traps on an
    // out-of-range pc).
    @constCast(li.image.instructions)[ret_pc] = llir.instrU(.auipc, 0, -1);
    try expectRejected(&li.image, "missing terminator");
    // The decoded displacement is pc + (imm20 << 12): imm20 = -1 →
    // -4096 from the record's pc.
    const d = llir.decode(li.image.instructions[ret_pc]).?;
    try testing.expectEqual(@as(u64, @as(u64, ret_pc) -% 4096), llir.auipcTarget(ret_pc, d.imm20));
}

test "3.1 LLIR validation: trap's reserved reason field must be zero" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = add %0, %1
        \\        ret %2
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const ret_pc = firstPcOf(&li.image, .ret).?;
    // trap is a terminator; the only legal form carries a zero reason
    // field (Instruction Set §5.3 — reserved for future trap codes).
    @constCast(li.image.instructions)[ret_pc] = llir.instrE(.trap, 0, 0);
    if (try llir_validate.validate(&li.image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("all-zero trap rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }
    // Any nonzero reason byte violates the contract.
    @constCast(li.image.instructions)[ret_pc] = llir.instrE(.trap, 1, 0);
    try expectRejected(&li.image, "nonzero");
}

test "3.1 LLIR validation: jalr base is schema-checked (a special is rejected)" {
    // An indirect call is `jalr base, offs16`: the base is a function-
    // value register (`.src`), never a special. Rewriting it to `cond`
    // is a forged record.
    var c = try compileText("app", &.{.{
        "app",
        \\fn inc(x: int32) -> int32 { x + 1 }
        \\fn apply(f: fn(int32) -> int32, v: int32) -> int32 { f(v) }
        \\fn main() -> int32 { apply(inc, 41) }
    }});
    defer c.deinit();
    const program = &(c.program orelse return error.TestUnexpectedResult);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    var image = try b.lowerLlir();
    const call_pc = firstPcOf(&image, .jalr).?;
    const d = llir.decode(image.instructions[call_pc]).?;
    @constCast(image.instructions)[call_pc] = llir.instrI(.jalr, llir.cond_reg, d.imm16);
    try expectRejected(&image, "register operand is neither a slot nor a special register");
}

test "3.1 LLIR validation: forged store_member row id is rejected before any dataflow" {
    // `store_member`'s member row id spans imm16; a forged id must be
    // caught by the shape check — not by an out-of-bounds
    // `member_descs` read in a later pass.
    var t = try cfg_parse.parseText(
        \\module "app" {
        \\    func @init() -> void {
        \\    entry:
        \\        %0: int32 = const 7
        \\        store_member #0, %0
        \\        ret
        \\    }
        \\}
    );
    defer t.arena.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), &t.program);
    var image = try b.lowerLlir();
    try testing.expect(image.member_descs.len > 0);
    const recs = try arena.allocator().alloc(llir.Instr, image.instructions.len);
    @memcpy(recs, image.instructions);
    for (recs, 0..) |rec, i| {
        if (llir.decode(rec)) |d| {
            if (d.op == .store_member) {
                recs[i] = llir.instrI(.store_member, d.a, @intCast(image.member_descs.len));
            }
        }
    }
    image.instructions = recs;
    try expectRejected(&image, "member desc id");
}

// ---------------------------------------------------------------------------
// The phase-1 typed-dataflow verifier and its execution plan were deleted
// (v9 opcodes carry their reps; the loader validates shapes only). The
// former phase-1 rejections (join type conflicts, T
// staging across calls, zero-source cmovs, non-counted releases, return
// type mismatches) have no structural counterpart and are gone. What
// remains is structural: positive coverage of loop/phi and slot-reuse
// fixtures, and the side-table rejection that survives (a forged
// PrimitiveId type row).
// ---------------------------------------------------------------------------

/// The TypeId of the primitive row `p`, or null when this image never
/// interns it.
fn primRowIn(image: *const llir.LlirProgram, p: llir.PrimitiveId) ?u32 {
    for (image.types, 0..) |td, i| {
        if (td.kind == .primitive and td.a == @intFromEnum(p)) return @intCast(i);
    }
    return null;
}

test "phase-1 structural: loop and slot-reuse fixtures validate" {
    // Loop: the join merges identical types on both edges; the
    // compare-and-branches and the trailing `j`s stay in range.
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(n: int32) -> int32 {
        \\    entry:
        \\        br %0 ? body : done
        \\    body:
        \\        %1: int32 = sub %0, %0
        \\        %2: bool = lt %1, %0
        \\        br %2 ? body : done
        \\    done:
        \\        ret %0
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    if (try llir_validate.validate(&li.image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("loop fixpoint fixture rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }
    // Disjoint lifetimes: `(a + b) * 2 - a / b` reuses `b`'s expired
    // slot for an int result while `a` stays live — legal precisely
    // because the slot is not live-in at any conflicting join (and, in
    // v9, because the validator is structural: slot reuse is a frontend
    // concern, not re-analyzed at load).
    var li2 = try lowerForValidation(
        \\module "app" {
        \\    func @m(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = add %0, %1
        \\        %3: int32 = const 2
        \\        %4: int32 = mul %2, %3
        \\        %5: int32 = div %0, %1
        \\        %6: int32 = sub %4, %5
        \\        ret %6
        \\    }
        \\}
    );
    defer li2.t_arena.deinit();
    defer li2.arena.deinit();
    if (try llir_validate.validate(&li2.image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("slot-reuse fixture rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }
}

test "phase-1 structural: forged unknown PrimitiveId type rows are rejected" {
    // A type row naming a primitive id above the frozen set (f64 is the
    // last) is a forged image — the side-table walk rejects it before
    // any instruction is interpreted.
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = const 3
        \\        %3: int32 = add %0, %2
        \\        %4: bool = lt %3, %1
        \\        br %4 ? t : e
        \\    t:
        \\        ret %2
        \\    e:
        \\        ret %1
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const row = primRowIn(&li.image, .int32) orelse return error.TestUnexpectedResult;
    const rows = try testing.allocator.alloc(llir.TypeDesc, li.image.types.len);
    defer testing.allocator.free(rows);
    @memcpy(rows, li.image.types);
    // Overwrite the int32 row with a forged id above the frozen ceiling
    // (i64/u64/f64 are appended after the v1 set; the next value is
    // unknown).
    rows[row] = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.float64) + 1, .b = 0, .c = 0 };
    var mutated = li.image;
    mutated.types = rows;
    try expectRejected(&mutated, "invalid primitive id");
}

// ---------------------------------------------------------------------------
// Stage-2 — structural coverage of the type-specialized opcode families
// (the v9 structural validation): the
// i64/u64 integer family, the f64 family, the conversion matrix, the
// move-wide lane opcodes, and the reserved/unassigned word rejections.
// The hand-built images exercise the codec and the register/immediate
// schemas; the old per-PC plan-rep assertions are gone with the plan.
// ---------------------------------------------------------------------------

/// Primitive type rows in row order: byte, bool, int32, uint32, float32,
/// i64, u64, f64 — the row ids the fixtures below reference directly.
const prim = [_]llir.TypeDesc{
    .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.byte), .b = 0, .c = 0 },
    .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.bool), .b = 0, .c = 0 },
    .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.int32), .b = 0, .c = 0 },
    .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.uint32), .b = 0, .c = 0 },
    .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.float32), .b = 0, .c = 0 },
    .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.int64), .b = 0, .c = 0 },
    .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.uint64), .b = 0, .c = 0 },
    .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.float64), .b = 0, .c = 0 },
};
const t_byte: u32 = 0;
const t_bool: u32 = 1;
const t_int32: u32 = 2;
const t_uint32: u32 = 3;
const t_float32: u32 = 4;
const t_i64: u32 = 5;
const t_u64: u32 = 6;
const t_f64: u32 = 7;

/// One instruction record, encoded per its opcode's format. The three
/// operands map per format: R `(a, b, c)`; B `(lhs, mid, offs10)`; I
/// `(a, imm16 = b | c << 8)`; C `(a, b)`; E `(a, b)`. Register-role
/// operands are written as logical frame indexes and encoded here;
/// immediate/none fields pass through raw. Specials must be passed
/// through the raw `llir.instr*` builders instead (they carry their
/// own encodings).
fn ir(op: llir.Opcode, a: u8, b: u8, c: u8) llir.Instr {
    const info = llir.opInfo(op);
    return switch (llir.formatOf(op)) {
        .r => llir.instrR(op, enc(info.a, a), enc(info.b, b), enc(info.c, c)),
        .b => llir.instrB(op, enc(info.a, a), enc(info.b, b), @intCast(c)),
        .i => llir.instrI(op, enc(info.a, a), @as(u16, b) | (@as(u16, c) << 8)),
        .c => llir.instrC(op, enc(info.a, a), enc(info.b, b)),
        .e => llir.instrE(op, enc(info.a, a), enc(info.b, b)),
        .u => unreachable, // no fixture uses the U format
    };
}

/// Encode a register-role operand: the fixture's logical frame index
/// becomes its register encoding (`F(n) = frame_base + n`).
fn enc(role: llir.Field, v: u8) u8 {
    return switch (role) {
        .none, .imm, .mask, .offs10, .imm16, .offs16, .imm20, .id => v,
        else => llir.frame_base + v,
    };
}

/// An integer constant record (payload `lo | hi << 8`; the image only
/// reads `type_`).
fn intConst(ty: u32, lo: u8, hi: u8) llir.ConstRecord {
    return .{ .kind = .int, .type_ = ty, .a = lo, .b = hi };
}

/// A float constant record.
fn floatConst(ty: u32, bits: u8) llir.ConstRecord {
    return .{ .kind = .float, .type_ = ty, .a = bits, .b = 0 };
}

/// Caller-owned storage backing the image's internal tables (blocks,
/// functions, signatures): the returned image borrows these slices, so
/// the storage must outlive it — declared in the test frame next to
/// the image.
const ImageStorage = struct {
    blocks: [8]llir.BlockDesc = undefined,
    functions: [1]llir.FunctionDesc = undefined,
    signatures: [1]llir.SignatureDesc = undefined,
};

/// Hand-built single-function image: one block covering the whole code
/// range, no parameters, the given primitive rows and constants, and
/// `ret_type` as the signature's return type. Every other side table is
/// empty; the caller's slices and `st` keep the image alive.
fn buildImage(instructions: []const llir.Instr, f_count: u16, types: []const llir.TypeDesc, constants: []const llir.ConstRecord, ret_type: u32, st: *ImageStorage) llir.LlirProgram {
    st.blocks[0] = .{ .start_pc = 0, .end_pc = @intCast(instructions.len) };
    return buildImageBase(instructions, st.blocks[0..1], f_count, types, constants, ret_type, st);
}

/// `buildImage` with explicit block-end pcs (ascending, the last one
/// the instruction count) — the multi-block form the branch fixtures
/// need.
fn buildImageBlocks(instructions: []const llir.Instr, block_ends: []const u32, f_count: u16, types: []const llir.TypeDesc, constants: []const llir.ConstRecord, ret_type: u32, st: *ImageStorage) llir.LlirProgram {
    var start: u32 = 0;
    for (block_ends, 0..) |end, bi| {
        st.blocks[bi] = .{ .start_pc = start, .end_pc = end };
        start = end;
    }
    return buildImageBase(instructions, st.blocks[0..block_ends.len], f_count, types, constants, ret_type, st);
}

fn buildImageBase(instructions: []const llir.Instr, blocks: []const llir.BlockDesc, f_count: u16, types: []const llir.TypeDesc, constants: []const llir.ConstRecord, ret_type: u32, st: *ImageStorage) llir.LlirProgram {
    st.functions[0] = .{
        .code_start = 0,
        .code_end = @intCast(instructions.len),
        .entry_pc = 0,
        .signature_id = 0,
        // module 0 (the empty module row above)
        .f_count = f_count,
        .x_count = 0,
        .window_count = 0,
    };
    st.signatures[0] = .{ .params_start = 0, .params_len = 0, .ret = ret_type };
    return .{
        .instructions = instructions,
        .functions = st.functions[0..1],
        .blocks = blocks,
        .signatures = st.signatures[0..1],
        .types = types,
        .constants = constants,
        .type_decls = &.{},
        .type_decl_fields = &.{},
        .union_variants = &.{},
        .union_payloads = &.{},
        .host_types = &.{},
        .self_symbol = llir.no_index, // anonymous single-function fixture
        .init = llir.no_index,
        .entry_member = llir.no_index,
        .symbols = &.{},
        .imports = &.{},
        .exports = &.{},
        .module_slots = &.{},
        .params = &.{},
        .destructure_dst_types = &.{},
        .call_args = &.{},
        .syscall_descs = &.{},
        .construct_descs = &.{},
        .destructure_dsts = &.{},
        .destructure_descs = &.{},
        .switch_arms = &.{},
        .switch_descs = &.{},
        .member_descs = &.{},
        .drop_descs = &.{},
        .strings = &.{},
    };
}

/// Expect the image to validate; print the rejection when it does not.
fn expectValid(image: *const llir.LlirProgram) !void {
    if (try llir_validate.validate(image, testing.allocator)) |m| {
        defer testing.allocator.free(m);
        std.log.err("expected a valid image, rejected: {s}", .{m});
        return error.TestUnexpectedResult;
    }
}

test "stage-2 structural: move-wide legal matrix" {
    // movwz defines, movwk read-modify-writes, movwn complements —
    // all twelve opcodes across the four lanes, with the 0x0000 /
    // 0xffff boundaries, on one cell.
    const image = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.movwz0, 0, 0xff, 0xff), // %0 = 0x0000_0000_0000_ffff
            ir(.movwk1, 0, 0xab, 0x89), // %0 = 0x0000_0000_89ab_ffff
            ir(.movwk2, 0, 0x67, 0x45), // %0 = 0x0000_4567_89ab_ffff
            ir(.movwk3, 0, 0x23, 0x01), // %0 = 0x0123_4567_89ab_ffff
            ir(.movwn0, 0, 0x00, 0x00), // %0 = ~0 = all ones
            ir(.movwz3, 0, 0xff, 0xff), // %0 = 0xffff_0000_0000_0000
            ir(.movwk0, 0, 0x00, 0x00), // %0 = 0xffff_0000_0000_0000
            ir(.movwz1, 0, 0x00, 0x00), // lane 1 cleared
            ir(.movwz2, 0, 0xff, 0xff), // %0 = 0xffff_ffff_0000_0000
            ir(.movwn1, 0, 0xff, 0xff), // %0 = 0xffff_0000_ffff_0000
            ir(.movwn2, 0, 0x00, 0x00), // %0 = 0x0000_ffff_ffff_0000
            ir(.movwn3, 0, 0xff, 0xff), // %0 = 0xffff_ffff_ffff_0000
            ir(.ret, 0, 0, 0),
        }, 1, &prim, &.{}, t_u64, &st);
    };
    try expectValid(&image);
    // A T staging destination: movwz defines T0, movwk replaces a
    // lane, `move` carries it into the frame before the block ends.
    const image2 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            llir.instrI(.movwz0, llir.temp_base, 0xcdef), // imm16 = 0xef | 0xcd << 8
            llir.instrI(.movwk1, llir.temp_base, 0x89ab), // imm16 = 0xab | 0x89 << 8
            llir.instrE(.move, llir.frame_base, llir.temp_base),
            ir(.ret, 0, 0, 0),
        }, 1, &prim, &.{}, t_u64, &st);
    };
    try expectValid(&image2);
}

test "stage-2 structural: movw dst forbids the zero special" {
    // The move-wide destination is a real cell (`.dst_movw`): writing
    // `zero` is rejected by the register schema.
    var image5 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.movwk0, 0, 0x01, 0x00),
            ir(.ret, 0, 0, 0),
        }, 1, &prim, &.{}, t_u64, &st);
    };
    @constCast(image5.instructions)[0] = llir.instrI(.movwk0, llir.zero_reg, 0x0100);
    try expectRejected(&image5, "register operand is neither a slot nor a special register");
}

test "stage-2 structural: reserved and unassigned words are rejected" {
    var image = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.movwz0, 0, 0x01, 0x00),
            ir(.ret, 0, 0, 0),
        }, 1, &prim, &.{}, t_u64, &st);
    };
    // The `10` reserved class (Instruction Set §2): no format decodes it.
    @constCast(image.instructions)[1] = llir.bytesOf(0b10 << 30);
    try expectRejected(&image, "reserved or unknown");
    // An unassigned R code: 154 is the first code past cmov (153).
    @constCast(image.instructions)[1] = llir.bytesOf(@as(u32, 154) << 21);
    try expectRejected(&image, "reserved or unknown");
    // A nonzero C-type reserved field (bits 14:9) is a reserved word.
    @constCast(image.instructions)[1] = llir.bytesOf((0b111000 << 26) | (@as(u32, 32) << 20) | (1 << 14));
    try expectRejected(&image, "reserved or unknown");
}

test "stage-2 structural: i64/u64 integer family matrix" {
    // Legal: signed ops on i64, unified ops on both widths, a C-type
    // comparison, and a 64-bit compare-and-branch.
    const image = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: i64
            ir(.const_, 1, 1, 0), // %1: i64
            ir(.add, 2, 0, 1),
            ir(.div, 2, 0, 1), // signed i64 division
            ir(.shr, 2, 0, 1), // arithmetic shift
            ir(.neg, 2, 0, 0),
            ir(.clz_i64, 2, 0, 0),
            ir(.slt, 0, 1, 0), // C-type comparison → cond
            ir(.ret, 2, 0, 0),
        }, 3, &prim, &.{ intConst(t_i64, 1, 0), intConst(t_i64, 2, 0) }, t_bool, &st);
    };
    try expectValid(&image);

    // Legal u64 with a branch on 64-bit operands (target = block start).
    const image2 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImageBlocks(&.{
            ir(.const_, 0, 0, 0), // %0: u64
            ir(.const_, 1, 1, 0), // %1: u64
            ir(.divu, 2, 0, 1),
            ir(.shru, 2, 0, 1),
            ir(.sltu, 0, 1, 0), // %cond = (%0 < %1)
            ir(.bltu, 0, 1, 1), // branch on u64 → next block
            ir(.ret, 2, 0, 0),
        }, &.{ 6, 7 }, 3, &prim, &.{ intConst(t_u64, 1, 0), intConst(t_u64, 2, 0) }, t_bool, &st);
    };
    try expectValid(&image2);

    // tbz's bit index is schema-bounded (b ≤ 63): 64 is out of range.
    var image3 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImageBlocks(&.{
            ir(.const_, 0, 0, 0), // %0: u64
            ir(.tbz, 0, 64, 1), // target = next block; bit 64
            ir(.ret, 0, 0, 0),
        }, &.{ 2, 3 }, 1, &prim, &.{intConst(t_u64, 1, 0)}, t_u64, &st);
    };
    try expectRejected(&image3, "immediate out of range");
}

test "stage-2 structural: f64 family matrix" {
    // Legal: the binary/unary/comparison family on f64 operands. The
    // `gt` predicate is an operand-swap alias of `slt` (no opcode);
    // `copysign` has no direct opcode and is synthesized.
    const image = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: f64
            ir(.const_, 1, 1, 0), // %1: f64
            ir(.add_f64, 2, 0, 1),
            ir(.mul_f64, 2, 0, 1),
            ir(.rem_f64, 2, 0, 1),
            ir(.madd_f64, 2, 0, 1),
            ir(.msub_f64, 2, 0, 1),
            ir(.neg_f64, 2, 0, 0),
            ir(.sqrt_f64, 2, 0, 0),
            ir(.floor_f64, 2, 0, 0),
            ir(.round_f64, 2, 0, 0),
            ir(.seq_f64, 0, 1, 0), // %cond = (%0 == %1)
            ir(.sle_f64, 0, 1, 0), // %cond = (%0 <= %1)
            ir(.ret, 2, 0, 0),
        }, 3, &prim, &.{ floatConst(t_f64, 1), floatConst(t_f64, 2) }, t_bool, &st);
    };
    try expectValid(&image);
}

test "stage-2 structural: cond lifetime — reads before an in-block definition" {
    // A `copy F0, cond` with no preceding C-type comparison in the
    // block reads an undefined cond (Instruction Set §7, §14): the
    // register schema accepts the record, the lifetime check rejects
    // it.
    var image = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            llir.instrE(.copy, llir.frame_base, llir.cond_reg), // copy F0, cond — cond undefined
            ir(.ret, 0, 0, 0),
        }, 1, &prim, &.{}, t_int32, &st);
    };
    try expectRejected(&image, "cond read before any in-block definition");

    // A `cmov` reads cond too: no comparison defined it in this block.
    var image2 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: int32
            ir(.const_, 1, 0, 0), // %1: int32
            ir(.cmov, 2, 0, 1), // %2 = cond ? %0 : %1
            ir(.ret, 2, 0, 0),
        }, 3, &prim, &.{intConst(t_int32, 1, 0)}, t_int32, &st);
    };
    try expectRejected(&image2, "cmov reads cond");
}

test "stage-2 structural: conversion matrix" {
    // The explicit `cvt.<src>.<dst>` spellings (Instruction Set §4): the
    // 20 cast pairs among byte/i32/u32/f32/f64. C format: `a` = dst,
    // `b` = src; identity entries have no opcode.
    const image = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: int32
            ir(.cvt_i32_u32, 1, 0, 0), // %1 = u32(%0)
            ir(.cvt_i32_f32, 2, 0, 0), // %2 = f32(%0)
            ir(.cvt_i32_f64, 3, 0, 0), // %3 = f64(%0)
            ir(.ret, 3, 0, 0),
        }, 4, &prim, &.{intConst(t_int32, 1, 0)}, t_f64, &st);
    };
    try expectValid(&image);

    const image2 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: uint32
            ir(.cvt_u32_i32, 1, 0, 0),
            ir(.cvt_u32_b, 2, 0, 0),
            ir(.cvt_u32_f32, 3, 0, 0),
            ir(.cvt_u32_f64, 4, 0, 0),
            ir(.ret, 4, 0, 0),
        }, 5, &prim, &.{intConst(t_uint32, 1, 0)}, t_f64, &st);
    };
    try expectValid(&image2);

    const image3 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: byte
            ir(.cvt_b_i32, 1, 0, 0),
            ir(.cvt_b_u32, 2, 0, 0),
            ir(.cvt_b_f32, 3, 0, 0),
            ir(.cvt_b_f64, 4, 0, 0),
            ir(.ret, 4, 0, 0),
        }, 5, &prim, &.{intConst(t_byte, 1, 0)}, t_f64, &st);
    };
    try expectValid(&image3);

    const image4 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: float32
            ir(.cvt_f32_i32, 1, 0, 0),
            ir(.cvt_f32_u32, 2, 0, 0),
            ir(.cvt_f32_b, 3, 0, 0),
            ir(.cvt_f32_f64, 4, 0, 0),
            ir(.ret, 4, 0, 0),
        }, 5, &prim, &.{floatConst(t_float32, 1)}, t_f64, &st);
    };
    try expectValid(&image4);

    const image5 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: f64
            ir(.cvt_f64_i32, 1, 0, 0),
            ir(.cvt_f64_u32, 2, 0, 0),
            ir(.cvt_f64_f32, 3, 0, 0),
            ir(.cvt_f64_b, 4, 0, 0),
            ir(.ret, 4, 0, 0),
        }, 5, &prim, &.{floatConst(t_f64, 1)}, t_byte, &st);
    };
    try expectValid(&image5);

    // The 64-bit cast matrix (`i64`/`u64` sources and targets): one
    // `cvt` image per new source type, all six destinations.
    const image6 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: i64
            ir(.cvt_i64_b, 1, 0, 0),
            ir(.cvt_i64_i32, 2, 0, 0),
            ir(.cvt_i64_u32, 3, 0, 0),
            ir(.cvt_i64_u64, 4, 0, 0),
            ir(.cvt_i64_f32, 5, 0, 0),
            ir(.cvt_i64_f64, 6, 0, 0),
            ir(.ret, 6, 0, 0),
        }, 7, &prim, &.{intConst(t_i64, 1, 0)}, t_f64, &st);
    };
    try expectValid(&image6);

    const image7 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: u64
            ir(.cvt_u64_b, 1, 0, 0),
            ir(.cvt_u64_i32, 2, 0, 0),
            ir(.cvt_u64_u32, 3, 0, 0),
            ir(.cvt_u64_i64, 4, 0, 0),
            ir(.cvt_u64_f32, 5, 0, 0),
            ir(.cvt_u64_f64, 6, 0, 0),
            ir(.ret, 6, 0, 0),
        }, 7, &prim, &.{intConst(t_u64, 1, 0)}, t_f64, &st);
    };
    try expectValid(&image7);

    const image8 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: float32
            ir(.cvt_f32_i64, 1, 0, 0),
            ir(.cvt_f32_u64, 2, 0, 0),
            ir(.ret, 2, 0, 0),
        }, 3, &prim, &.{floatConst(t_float32, 1)}, t_u64, &st);
    };
    try expectValid(&image8);

    const image9 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: f64
            ir(.cvt_f64_i64, 1, 0, 0),
            ir(.cvt_f64_u64, 2, 0, 0),
            ir(.ret, 2, 0, 0),
        }, 3, &prim, &.{floatConst(t_f64, 1)}, t_u64, &st);
    };
    try expectValid(&image9);

    // The 32→64 and byte→64 widenings.
    const image10 = blk: {
        var st: ImageStorage = .{};
        break :blk buildImage(&.{
            ir(.const_, 0, 0, 0), // %0: byte
            ir(.cvt_b_i64, 1, 0, 0),
            ir(.cvt_b_u64, 2, 0, 0),
            ir(.cvt_i32_i64, 3, 0, 0),
            ir(.cvt_i32_u64, 4, 0, 0),
            ir(.cvt_u32_i64, 5, 0, 0),
            ir(.cvt_u32_u64, 6, 0, 0),
            ir(.ret, 6, 0, 0),
        }, 7, &prim, &.{intConst(t_byte, 1, 0)}, t_u64, &st);
    };
    try expectValid(&image10);
}

// ---------------------------------------------------------------------------
// Stage-2 — the loader trust boundary (LLIR Specification §8.1):
//
// 1. Semantic-inconsistent images are ACCEPTED: `zero`'s Copy/void rules,
//    typed-opcode vs metadata type consistency, T staging across calls,
//    and argument ownership sequences are frontend-guaranteed (§8.1 —
//    semantically trusted, structurally validated). Each fixture below
//    mutates a lowered or hand-built image and asserts `validate`
//    accepts it (the validator is called, never the interpreter).
// 2. Every §8.1 structural invariant class has at least one rejection
//    fixture (function/block/entry ranges, terminator shapes, static
//    call targets, side-table IDs and slices, frame/X/window bounds).
// 3. A valid image of 1 or 10,000 instructions validates with 0
//    allocations (failing allocator — any happy-path allocation attempt
//    surfaces as `error.OutOfMemory` and fails the test).
// 4. A raw-word mutation corpus flips every byte of every instruction
//    word: `validate` must return a message or null, never panic — the
//    same suite runs under Debug and ReleaseSafe.
// ---------------------------------------------------------------------------

/// Hand-built caller + callee image for the call-shape fixtures: the
/// caller's block is `[0, instrs.len)` and ends in its own terminator;
/// the callee is a single `ret` block at `instrs.len`. Both functions
/// are standalone (no declaring module). The caller signature is
/// `() -> int32`; the callee returns `callee_ret` (a primitive TypeId or
/// `no_index` for void). `window` is the caller's window_count.
const CallStorage = struct {
    blocks: [2]llir.BlockDesc = undefined,
    functions: [2]llir.FunctionDesc = undefined,
    signatures: [2]llir.SignatureDesc = undefined,
    /// Caller instructions followed by the callee's `ret` — the callee
    /// lives in the same instruction array (contiguous code ranges).
    instrs: [16]llir.Instr = undefined,
};

fn buildCallImage(instrs: []const llir.Instr, window: u16, callee_ret: u32, st: *CallStorage) llir.LlirProgram {
    const callee_pc: u32 = @intCast(instrs.len);
    @memcpy(st.instrs[0..instrs.len], instrs);
    st.instrs[instrs.len] = llir.instrE(.ret, 0, 0); // callee: ret zero
    const all_instrs = st.instrs[0 .. instrs.len + 1];
    st.blocks[0] = .{ .start_pc = 0, .end_pc = callee_pc };
    st.blocks[1] = .{ .start_pc = callee_pc, .end_pc = callee_pc + 1 };
    st.functions[0] = .{
        .code_start = 0,
        .code_end = callee_pc,
        .entry_pc = 0,
        .signature_id = 0,
        // module 0 (the empty module row)
        .f_count = 2,
        .x_count = 0,
        .window_count = window,
    };
    st.functions[1] = .{
        .code_start = callee_pc,
        .code_end = callee_pc + 1,
        .entry_pc = callee_pc,
        .signature_id = 1,
        .f_count = 1,
        .x_count = 0,
        .window_count = 0,
    };
    st.signatures[0] = .{ .params_start = 0, .params_len = 0, .ret = t_int32 };
    st.signatures[1] = .{ .params_start = 0, .params_len = 0, .ret = callee_ret };
    return .{
        .instructions = all_instrs,
        .functions = st.functions[0..2],
        .blocks = st.blocks[0..2],
        .signatures = st.signatures[0..2],
        .types = &prim,
        .constants = &.{},
        .type_decls = &.{},
        .type_decl_fields = &.{},
        .union_variants = &.{},
        .union_payloads = &.{},
        .host_types = &.{},
        .self_symbol = llir.no_index, // anonymous single-function fixture
        .init = llir.no_index,
        .entry_member = llir.no_index,
        .symbols = &.{},
        .imports = &.{},
        .exports = &.{},
        .module_slots = &.{},
        .params = &.{},
        .destructure_dst_types = &.{},
        .call_args = &.{},
        .syscall_descs = &.{},
        .construct_descs = &.{},
        .destructure_dsts = &.{},
        .destructure_descs = &.{},
        .switch_arms = &.{},
        .switch_descs = &.{},
        .member_descs = &.{},
        .drop_descs = &.{},
        .strings = &.{},
    };
}

test "stage-2 semantic trust: ret zero and take zero accept any result type" {
    // `ret zero` of a `str` return: the Copy-numeric restriction on
    // `zero` is a frontend invariant (§3.1) — the loader accepts the
    // zero source.
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @g() -> str {
        \\    entry:
        \\        %0: str = const "x"
        \\        ret %0
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const ret_pc = firstPcOf(&li.image, .ret).?;
    @constCast(li.image.instructions)[ret_pc] = llir.instrE(.ret, llir.zero_reg, 0);
    try expectValid(&li.image);

    // A non-void `jal ra` whose `take` discards into `zero` (an owned
    // str result): "only void/Copy results may be taken directly to
    // zero" is frontend-guaranteed (§5.2) — the loader checks only the
    // take's source register, which stays the result alias `F(L+3+O-A)`.
    // The `@g` result is consumed by the later `@h` call, so the call
    // keeps its take (Step 8 coalescing is rejected across a call).
    var li2 = try lowerForValidation(
        \\module "app" {
        \\    func @g() -> str {
        \\    entry:
        \\        %0: str = const "x"
        \\        ret %0
        \\    }
        \\    func @h(a: str) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1
        \\        ret %1
        \\    }
        \\    func @main() -> int32 {
        \\    entry:
        \\        %0: str = call @g
        \\        %1: int32 = call @h, %0
        \\        %2: int32 = const 0
        \\        ret %2
        \\    }
        \\}
    );
    defer li2.t_arena.deinit();
    defer li2.arena.deinit();
    const jal_pc = blk: {
        for (li2.image.instructions, 0..) |rec, pc| {
            if (llir.decode(rec)) |d| {
                if (d.op == .jal and d.a == llir.ra_reg) break :blk @as(u32, @intCast(pc));
            }
        }
        unreachable;
    };
    const rt_pc = jal_pc + 1;
    const rt_d = llir.decode(li2.image.instructions[rt_pc]) orelse return error.TestUnexpectedResult;
    try testing.expect(rt_d.op == .take);
    @constCast(li2.image.instructions)[rt_pc] = llir.instrE(.take, llir.zero_reg, rt_d.b);
    try expectValid(&li2.image);
}

test "stage-2 semantic trust: opcode reps are not re-derived from the type table" {
    // `add` over cells whose constants are typed int32: the rep is
    // fixed by the decoded opcode and the descriptor-carried types are
    // never cross-checked (§8.1 — no typed dataflow analysis). A
    // type-inconsistent image like this is a trusted-invalid input the
    // loader accepts and the frontend never produces.
    var st: ImageStorage = .{};
    const image = buildImage(&.{
        ir(.const_, 0, 0, 0), // %0: int32 per the ConstRecord
        ir(.const_, 1, 1, 0), // %1: int32
        ir(.add, 2, 0, 1), // i64 add over the int32-typed cells
        ir(.ret, 2, 0, 0),
    }, 3, &prim, &.{ intConst(t_int32, 1, 0), intConst(t_int32, 2, 0) }, t_i64, &st);
    try expectValid(&image);
}

test "stage-2 semantic trust: a T staging value may be live across a call" {
    // `move T0, F0` stages the value into T, `jal ra` clobbers the whole
    // T bank (spec §3.2), and `ret T0` reads it afterwards: staging
    // liveness across a call is a frontend guarantee — the loader
    // accepts the shape and never tracks T.
    var st: CallStorage = .{};
    const image = buildCallImage(&.{
        llir.instrE(.move, llir.temp_base, llir.frame_base), // move T0, F0 — stage into T
        llir.instrU(.jal, llir.ra_reg, 2), // jal ra at pc 1 → callee entry 3
        llir.instrE(.ret, llir.temp_base, 0), // ret T0 — read after the call
    }, 0, llir.no_index, &st);
    try expectValid(&image);
}

test "stage-2 semantic trust: duplicate slot_move into one window cell validates" {
    // Two `slot_move F0, 0` records target the same window offset: the
    // argument ownership sequence is a frontend guarantee (§8.1) — the
    // loader checks only the offset bound.
    var st: CallStorage = .{};
    const image = buildCallImage(&.{
        llir.instrI(.slot_move, llir.frame_base, 0),
        llir.instrI(.slot_move, llir.frame_base, 0),
        llir.instrU(.jal, llir.ra_reg, 2), // jal ra at pc 2 → callee entry 4
        llir.instrE(.ret, 0, 0),
    }, 1, llir.no_index, &st);
    try expectValid(&image);
}

test "stage-2 semantic trust: jal ra to a signature-incompatible entry validates" {
    // The static target must be a *function entry* (structural, §14);
    // the result-type match at a call site is the frontend's guarantee
    // (§5.2) — the loader never compares signatures. The caller is
    // `() -> int32`, the callee `() -> uint32`; the u32 result lands in
    // the caller's int32 cell via `take` and `ret` — the type
    // inconsistency is invisible to the structural loader. The caller's
    // window is `3 + A = 4` (the value area plus its three-cell header),
    // so the take's source is the result alias `F(L+3+O-A) = F5`:
    // f_count = 2, O = 1, A = max(0, 1) = 1 → 2 + 3 + 1 - 1 = 5.
    var st: CallStorage = .{};
    const image = buildCallImage(&.{
        llir.instrU(.jal, llir.ra_reg, 3), // jal ra at pc 0 → callee entry 3
        llir.instrE(.take, llir.frame_base, @intCast(llir.frameReg(5))), // take F0, F5 (the result alias)
        llir.instrE(.ret, 0, 0),
    }, 4, t_uint32, &st);
    try expectValid(&image);
}

test "3.1 LLIR validation: block start_pc does not tile the code range" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: bool) -> bool {
        \\    entry:
        \\        br %0 ? l1 : l2
        \\    l1:
        \\        ret %0
        \\    l2:
        \\        ret %0
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    try testing.expect(li.image.blocks.len >= 2);
    // A gap between block 0's end and block 1's start breaks the tile.
    @constCast(li.image.blocks)[1].start_pc += 1;
    try expectRejected(&li.image, "does not tile");
}

test "3.1 LLIR validation: entry_pc outside the code range or not a block start" {
    // A two-instruction entry block (`add` + `ret`): pc 1 is mid-block.
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = add %0, %1
        \\        ret %2
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    @constCast(li.image.functions)[0].entry_pc = 1; // inside the entry block
    try expectRejected(&li.image, "is not a block start");
    @constCast(li.image.functions)[0].entry_pc = @intCast(li.image.instructions.len);
    try expectRejected(&li.image, "outside the code range");
}

test "3.1 LLIR validation: mid-block terminator is rejected" {
    // The entry block is `add` + `ret`; rewriting the `add` to a `ret`
    // puts a terminator before the block end (the two legal mid-block
    // forms — a `jal ra` call and the long-branch `j` — are
    // handled by the caller).
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = add %0, %1
        \\        ret %2
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    const add_pc = firstPcOf(&li.image, .add).?;
    @constCast(li.image.instructions)[add_pc] = llir.instrE(.ret, 0, 0);
    try expectRejected(&li.image, "is not at the block end");
}

test "3.1 LLIR validation: jal ra target must be a function entry" {
    // A mid-block pc (1) is not any function's entry: the static call
    // target shape is structural (Instruction Set §14).
    var st: CallStorage = .{};
    const image = buildCallImage(&.{
        llir.instrU(.jal, llir.ra_reg, 1), // jal ra at pc 0 → target 1 (mid-block)
        llir.instrE(.ret, 0, 0),
    }, 0, llir.no_index, &st);
    try expectRejected(&image, "is not a function entry");
}

test "3.1 LLIR validation: j target must stay inside the current function" {
    // `j` is the unconditional intra-function jump: a cross-function
    // target is rejected (the callee entry at pc 2 lies in the callee's
    // range). A `jal`-with-`zero` link is not a legal jump at all
    // (Instruction Set §9.1).
    var st: CallStorage = .{};
    const image = buildCallImage(&.{
        llir.instrJ(2), // j at pc 0 → callee entry 2
        llir.instrE(.ret, 0, 0),
    }, 0, llir.no_index, &st);
    try expectRejected(&image, "lies outside this function's code range");
}

test "3.1 LLIR validation: spill XId and arg window offsets out of range" {
    // One spill cell and one window cell; both records address slot 1.
    var st: ImageStorage = .{};
    var image = buildImage(&.{
        llir.instrI(.spill_take, llir.temp_base, 1), // XId 1
        ir(.slot_move, 0, 1, 0), // window offset 1
        ir(.ret, 0, 0, 0),
    }, 1, &prim, &.{}, t_int32, &st);
    @constCast(image.functions)[0].x_count = 1;
    @constCast(image.functions)[0].window_count = 1;
    try expectRejected(&image, "spill XId 1 out of range");
    @constCast(image.functions)[0].x_count = 2; // spill now in range
    try expectRejected(&image, "arg offset 1 outside the window");
}

test "3.1 LLIR validation: x_count beyond the imm16 addressable bound" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    @constCast(li.image.functions)[0].x_count = 65537;
    try expectRejected(&li.image, "exceeds the imm16 addressable maximum");
}

test "3.1 LLIR validation: const id, forged string range, and unknown ConstKind" {
    // A `const` record naming a ConstId with no constants.
    var st: ImageStorage = .{};
    const empty_consts = buildImage(&.{
        ir(.const_, 0, 0, 0),
        ir(.ret, 0, 0, 0),
    }, 1, &prim, &.{}, t_int32, &st);
    try expectRejected(&empty_consts, "const id 0 out of range");

    // A forged string constant whose range exceeds the (empty) strings
    // blob — the static value becomes a slice index (spec §13).
    const oob_string = [_]llir.ConstRecord{.{ .kind = .string, .type_ = t_int32, .a = 0, .b = 8 }};
    const str_image = buildImage(&.{
        ir(.const_, 0, 0, 0),
        ir(.ret, 0, 0, 0),
    }, 1, &prim, &oob_string, t_int32, &st);
    try expectRejected(&str_image, "string range out of bounds");

    // An unknown enum tag (a forged binary table) cannot be *constructed*
    // from a valid enum in Zig (0.16 rejects out-of-range
    // `@enumFromInt`/`@bitCast` at compile time), so the enum-tag class
    // is covered twice elsewhere: the forged-PrimitiveId fixture above
    // (a u32 field the validator scans with `toEnum`), and the binary
    // reader's checked `readEnum`, which rejects an unassigned raw tag
    // as `InvalidFormat` before validate ever runs
    // (frontend_llir_bin_tests.zig).
}

test "3.1 LLIR validation: per-function signature_id out of range; forged symbol ranges" {
    var li = try lowerForValidation(
        \\module "app" {
        \\    func @f() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\}
    );
    defer li.t_arena.deinit();
    defer li.arena.deinit();
    @constCast(li.image.functions)[0].signature_id = 0xffff_fffe;
    try expectRejected(&li.image, "signature_id");
    @constCast(li.image.functions)[0].signature_id = 0;

    // M1: a forged symbol range outside the strings blob is rejected
    // (symbol bytes become the module identity — spec §13).
    const good_range = li.image.symbols[li.image.self_symbol];
    var mutated = li.image;
    const bad = [_]llir.SymRange{.{ .start = 0, .len = @intCast(li.image.strings.len + 1) }};
    mutated.symbols = &bad;
    mutated.self_symbol = 0; // the forged row is the module identity
    try expectRejected(&mutated, "byte range out of bounds");
    _ = good_range;
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&li.image, testing.allocator));
}

test "stage-2 structural: duplicate switch arm tags are rejected" {
    var st: ImageStorage = .{};
    const image = buildImage(&.{
        ir(.switch_, 0, 0, 0),
    }, 1, &prim, &.{}, t_int32, &st);
    const arms = [_]llir.SwitchArm{ .{ .tag = 5, .target = 0 }, .{ .tag = 5, .target = 0 } };
    const descs = [_]llir.SwitchDesc{.{ .arms_start = 0, .arms_len = 2 }};
    var mutated = image;
    mutated.switch_arms = &arms;
    mutated.switch_descs = &descs;
    try expectRejected(&mutated, "duplicate arm tag");
}

test "stage-2: valid images of 1 and 10,000 instructions validate with 0 allocations" {
    // A valid image never reaches the allocator: the failing allocator
    // (fail on the first allocation) must go untouched — any happy-path
    // allocation surfaces as `error.OutOfMemory` and fails the test
    // (LLIR Specification §8.2: "a valid image of 1 or 10,000
    // instructions validates and runs with 0 allocations"). The
    // 10,000-word image proves the loader is O(1)-workspace: nothing
    // scales with the instruction count.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const failing_alloc = failing.allocator();

    var st1: ImageStorage = .{};
    const one = buildImage(&.{ir(.ret, 0, 0, 0)}, 1, &prim, &.{}, t_int32, &st1);
    try testing.expect((try llir_validate.validate(&one, failing_alloc)) == null);

    var instrs: [10_000]llir.Instr = undefined;
    @memset(instrs[0 .. instrs.len - 1], llir.instrR(.add, llir.frame_base, llir.frame_base, llir.frame_base + 1));
    instrs[instrs.len - 1] = llir.instrE(.ret, 0, 0);
    var st2: ImageStorage = .{};
    const ten_k = buildImage(&instrs, 2, &prim, &.{}, t_int32, &st2);
    try testing.expect((try llir_validate.validate(&ten_k, failing_alloc)) == null);
}

test "stage-2: raw-word mutation corpus never panics (Debug and ReleaseSafe)" {
    // Mutate every byte of every instruction word of a six-format image
    // to every byte value: `validate` must return a message (freed) or
    // null — it must never panic, index out of bounds, or assert. The
    // same suite runs under Debug and ReleaseSafe (`zig build test
    // -Doptimize=ReleaseSafe`), so this is the boundary-safety corpus
    // for both modes. Mutations that still decode to a valid word may
    // leave the image valid — that is expected; the invariant is "no
    // panic", and the counters below prove the corpus actually
    // exercises both outcomes.
    var st: ImageStorage = .{};
    // Six-format valid image; each block ends with a B-type branch
    // except the last (R add, B beq + tbz, C cvt, I const + movwz,
    // U lui, E ret).
    const image = buildImageBlocks(&.{
        ir(.add, 0, 0, 1), // R
        ir(.beq, 0, 1, 1), // B → block 1
        ir(.cvt_i32_u32, 2, 0, 0), // C
        ir(.beq, 0, 1, 1), // B → block 2
        ir(.const_, 2, 0, 0), // I
        ir(.beq, 0, 1, 1), // B → block 3
        ir(.movwz0, 2, 0xff, 0xff), // I
        ir(.beq, 0, 1, 1), // B → block 4
        ir(.tbz, 0, 5, 2), // B bit-test → block 5
        ir(.beq, 0, 1, 1), // B → block 5
        llir.instrU(.lui, llir.temp_base, 1), // U (not a terminator)
        ir(.ret, 2, 0, 0), // E terminator
    }, &.{ 2, 4, 6, 8, 10, 12 }, 3, &prim, &.{intConst(t_int32, 1, 0)}, t_int32, &st);
    // The base image itself validates.
    try expectValid(&image);

    var mutated = image;
    var rejected: usize = 0;
    var still_valid: usize = 0;
    for (image.instructions, 0..) |rec, pc| {
        for (0..4) |byte_i| {
            const shift: u5 = @intCast(byte_i * 8);
            for (0..256) |b| {
                const bval: u32 = @intCast(b);
                const word = (llir.wordOf(rec) & ~(@as(u32, 0xff) << shift)) | (bval << shift);
                @constCast(mutated.instructions)[pc] = llir.bytesOf(word);
                if (try llir_validate.validate(&mutated, testing.allocator)) |m| {
                    testing.allocator.free(m);
                    rejected += 1;
                } else {
                    still_valid += 1;
                }
            }
            @constCast(mutated.instructions)[pc] = rec;
        }
    }
    try testing.expect(rejected > 0);
    try testing.expect(still_valid > 0);
}

// ---------------------------------------------------------------------------
// Stage 3.2 — the structural-validator fixture slate (TODO.md §3.2).
// Each item in the TODO's 3.2 checklist has at least one fixture here: every
// format's reserved code plus the top `10` class, opcode-specific register/
// special schemas and the F/T frame bounds, the opcode-specific unused
// operand-bit rejections, the 109/110 frame budget, the C-Type cast vs
// comparison operand roles, the `cond` lifetime rejections across calls and
// block boundaries (plus the positive same-block carrier), the three B-type
// operand schemas, the tbz/tbnz high-bit bound (and the note that the
// immediate-branch family is integer-only), and the `jalr` base/offs16 schema.
// Everything here maps onto decode + `checkInstr`/`checkFrameSlots`/
// `checkCondLifetime` in llir_validate.zig.
// ---------------------------------------------------------------------------

test "3.2 validation: reserved codes in every format and the top-level 10 class" {
    var st: ImageStorage = .{};
    const image = buildImage(&.{
        ir(.movwz0, 0, 1, 0),
        ir(.ret, 0, 0, 0),
    }, 1, &prim, &.{intConst(t_i64, 1, 0)}, t_u64, &st);
    // Each fixture word must itself be undecodable (otherwise the block
    // falls through to a mid-block terminator check and the word was
    // copied wrong). The reserved codes are one past each format's last
    // assigned code (Instruction Set §2–§6).
    const words = [_]llir.Instr{
        llir.bytesOf(0b10 << 30), // the top-level `10` reserved class
        llir.bytesOf((0b01 << 30) | (60 << 24)), // B-type reserved code 60
        llir.bytesOf((0b111001 << 26) | (60 << 20)), // E-type reserved code 60
        llir.bytesOf((0b110 << 29) | (34 << 23)), // I-type reserved code 34
    };
    for (words) |w| {
        try testing.expectEqual(@as(?llir.Decoded, null), llir.decode(w)); // fixture is genuinely reserved
        @constCast(image.instructions)[1] = w;
        try expectRejected(&image, "reserved or unknown");
    }
    // Restore the terminator so the image stays well-formed for any later use.
    @constCast(image.instructions)[1] = llir.instrE(.ret, 0, 0);
}

test "3.2 validation: opcode-specific register class and F/T frame bounds" {
    // A frame-only source field (`slot_move`'s `a` is `.src_f`) rejects a
    // T register just as it would an out-of-frame slot.
    var st: ImageStorage = .{};
    const image = buildImage(&.{
        llir.instrI(.slot_move, llir.temp_base, 0), // slot_move T0, 0 -- src_f forbids T
        ir(.ret, 0, 0, 0),
    }, 1, &prim, &.{}, t_int32, &st);
    @constCast(image.functions)[0].window_count = 1;
    try expectRejected(&image, "register operand is neither a slot nor a special register");

    // A real-slot destination field rejects `cond` (the single special
    // whose schema positions are `not`/`copy`/`cmov` only).
    var st2: ImageStorage = .{};
    const image2 = buildImage(&.{
        llir.instrR(.add, llir.cond_reg, llir.frame_base, llir.frame_base + 1), // dst = cond
        ir(.ret, 0, 0, 0),
    }, 2, &prim, &.{}, t_int32, &st2);
    try expectRejected(&image2, "register operand is neither a slot nor a special register");
    // And `ra` in a source position of an R instruction is equally forged.
    var st3: ImageStorage = .{};
    const image3 = buildImage(&.{
        llir.instrR(.add, llir.frame_base, llir.ra_reg, llir.frame_base + 1), // src = ra
        ir(.ret, 0, 0, 0),
    }, 2, &prim, &.{}, t_int32, &st3);
    try expectRejected(&image3, "register operand is neither a slot nor a special register");
}

test "3.2 validation: opcode-specific nonzero unused operand bits" {
    // `tail` is `dst, src_real, none`: a nonzero third field is an unused
    // operand bit (an R-format counterpart of trap's reserved reason).
    var st: ImageStorage = .{};
    const image = buildImage(&.{
        ir(.tail, 0, 1, 5), // c (none) = 5
        ir(.ret, 0, 0, 0),
    }, 2, &prim, &.{}, t_int32, &st);
    try expectRejected(&image, "nonzero unused field");
}

test "3.2 validation: frame budget -- 109 succeeds, 110 rejects" {
    var st: ImageStorage = .{};
    // A 109-frame function validates: F0..F108 max out the F bank without
    // colliding with the specials (frame_count_max = 109).
    const image = buildImage(&.{ir(.ret, 0, 0, 0)}, 109, &prim, &.{}, t_int32, &st);
    try expectValid(&image);
    // One more cell collides with the specials (zero at 0x6d).
    @constCast(image.functions)[0].f_count = 110;
    try expectRejected(&image, "frame too big");

    // v10 budget: the window counts against the same 109. A frame of
    // L = 107 with a window W = 2 (O = 0) sits exactly at the boundary
    // (107 + 2 = 109); one more register — here W = 3 — rejects.
    var st2: ImageStorage = .{};
    const boundary = buildImage(&.{ir(.ret, 0, 0, 0)}, 107, &prim, &.{}, t_int32, &st2);
    @constCast(boundary.functions)[0].window_count = 2;
    try expectValid(&boundary);
    @constCast(boundary.functions)[0].window_count = 3;
    try expectRejected(&boundary, "frame too big");
}

test "3.2 validation: C-type cast vs comparison operand roles" {
    var st: ImageStorage = .{};
    // A cast is `a = dst, b = src`; `cond` is not a legal cast destination.
    const image = buildImage(&.{
        ir(.const_, 0, 0, 0), // %0: int32
        ir(.cvt_i32_u32, 1, 0, 0), // %1 = u32(%0)
        ir(.ret, 1, 0, 0),
    }, 2, &prim, &.{intConst(t_int32, 1, 0)}, t_uint32, &st);
    @constCast(image.instructions)[1] = llir.instrC(.cvt_i32_u32, llir.cond_reg, 0);
    try expectRejected(&image, "register operand is neither a slot nor a special register");

    // A comparison has no encoded destination: `a`/`b` are both *sources*,
    // and the destination is the implicit `cond`. A `ra` source is forged.
    var st2: ImageStorage = .{};
    const image2 = buildImage(&.{
        ir(.seq, 0, 1, 0), // cond = (%0 == %1)
        ir(.ret, 0, 0, 0),
    }, 2, &prim, &.{}, t_int32, &st2);
    @constCast(image2.instructions)[0] = llir.instrC(.seq, llir.ra_reg, 1);
    try expectRejected(&image2, "register operand is neither a slot nor a special register");
    // The positive cast+comparison form (before the mutation) validates.
    var st3: ImageStorage = .{};
    const ok = buildImage(&.{
        ir(.seq, 0, 1, 0), // cond
        ir(.ret, 0, 0, 0),
    }, 2, &prim, &.{}, t_int32, &st3);
    try expectValid(&ok);
}

test "3.2 validation: cond read across a call and across a block boundary" {
    // A comparison defines cond, `jal ra` clobbers the whole cond
    // availability, and a `copy` reads it afterwards: the call makes cond
    // unavailable (Instruction Set §3.2). The caller is `() -> int32`, the
    // void callee is appended by `buildCallImage`.
    var st: CallStorage = .{};
    const image = buildCallImage(&.{
        llir.instrC(.seq, llir.frame_base, llir.frame_base + 1), // cond = (%0 == %1)
        llir.instrU(.jal, llir.ra_reg, 3), // jal ra at pc 1 -> callee entry 4
        llir.instrE(.copy, llir.frame_base, llir.cond_reg), // copy F0, cond -- after the call
        llir.instrE(.ret, 0, 0),
    }, 0, llir.no_index, &st);
    try expectRejected(&image, "cond read before any in-block definition");

    // A compare defines cond in block 0; block 1 reads it with no intervening
    // definition -- the block boundary resets cond availability.
    var st2: ImageStorage = .{};
    const image2 = buildImageBlocks(&.{
        ir(.seq, 0, 1, 0), // block 0: cond defined
        ir(.bne, 0, 1, 1), // branch -> block 1
        llir.instrE(.copy, llir.frame_base, llir.cond_reg), // block 1: reads cond (undefined here)
        ir(.ret, 0, 0, 0),
    }, &.{ 2, 4 }, 2, &prim, &.{}, t_int32, &st2);
    try expectRejected(&image2, "cond read before any in-block definition");
}

test "3.2 validation: cond lives across a non-cond instruction within a block" {
    // A comparison defines cond, an unrelated R add does not touch it, and a
    // `cmov` still reads it: the block-local lifetime is requirement-based,
    // not physical-adjoining (Instruction Set §7).
    var st: ImageStorage = .{};
    const image = buildImage(&.{
        ir(.seq, 0, 1, 0), // cond = (%0 == %1)
        ir(.add, 2, 0, 1), // %2 = %0 + %1 -- does not write cond
        ir(.cmov, 3, 0, 1), // %3 = cond ? %0 : %1
        ir(.ret, 3, 0, 0),
    }, 4, &prim, &.{}, t_int32, &st);
    try expectValid(&image);
}

test "3.2 validation: B-type register/immediate/bit-test operand schemas" {
    // The three B-type operand schemas: register branches (beq..bleu and the
    // f32/f64 variants), immediate branches (blti/bltiu/beqi/bnei), and the
    // bit-test branches (tbz/tbnz). Each branch targets the next block.
    // Immediate branches are integer-only; no float immediate branch exists
    // (rep = null in the opcode table), so a float immediate form is not even
    // encodable -- the codec rejects it before the loader runs.
    const cases = [_]llir.Opcode{ .beq, .bne, .blt, .ble, .bltu, .bleu, .bltiu, .beqi, .bnei, .tbnz };
    for (cases) |bop| {
        var st: ImageStorage = .{};
        const mid: u8 = if (bop == .tbnz) 5 else 1; // tbnz: bit index; others: rhs/imm7
        // f_count = 2: the register branches reference register 1 as rhs.
        const image = buildImageBlocks(&.{
            ir(bop, 0, mid, 1), // branch F0 -> next block
            ir(.ret, 0, 0, 0),
        }, &.{ 1, 2 }, 2, &prim, &.{}, t_int32, &st);
        try expectValid(&image);
    }

    // Register schema: an immediate branch's `a` is a source -- a `cond`
    // operand is rejected.
    var st2: ImageStorage = .{};
    const bad = buildImage(&.{
        llir.instrB(.blti, llir.cond_reg, 1, 1), // blti cond, 1, +1
        ir(.ret, 0, 0, 0),
    }, 1, &prim, &.{}, t_int32, &st2);
    try expectRejected(&bad, "register operand is neither a slot nor a special register");
}

test "3.2 validation: tbz/tbnz bit-index highest bit and the 64 bound" {
    // Both bit-test branches schema-bind the bit index to 0..63 (the imm7
    // field's high bit must be zero). bit 64 and bit 127 (high bit set) are
    // both rejected, with a small offset so the block still reads as a
    // single-block image.
    for ([_]llir.Opcode{ .tbz, .tbnz }) |bop| {
        for ([_]u8{ 64, 127 }) |bit| {
            var st: ImageStorage = .{};
            const image = buildImageBlocks(&.{
                ir(bop, 0, bit, 1),
                ir(.ret, 0, 0, 0),
            }, &.{ 1, 2 }, 1, &prim, &.{}, t_int32, &st);
            try expectRejected(&image, "immediate out of range");
        }
    }
    // The bound is inclusive of 63 (the lowest bit of the high nibble).
    var st3: ImageStorage = .{};
    const ok63 = buildImageBlocks(&.{
        ir(.tbnz, 0, 63, 1),
        ir(.ret, 0, 0, 0),
    }, &.{ 1, 2 }, 1, &prim, &.{}, t_int32, &st3);
    try expectValid(&ok63);
}

test "3.2 validation: jalr implicit ra, base schema, and signed offs16" {
    // `jalr base, offs16`: the link destination is the fixed, un-encoded `ra`
    // token; the record's only register operand is the base (`.src`). A real
    // base with a negative offs16 accepts.
    var st: ImageStorage = .{};
    const image = buildImage(&.{
        llir.instrI(.jalr, llir.temp_base, 0xfeff), // jalr T0, offs16 = -257
        ir(.ret, 0, 0, 0),
    }, 1, &prim, &.{}, t_int32, &st);
    try expectValid(&image);
    // The base is a source: `ra` in that position is forged.
    var st2: ImageStorage = .{};
    const bad = buildImage(&.{
        llir.instrI(.jalr, llir.ra_reg, 0),
        ir(.ret, 0, 0, 0),
    }, 1, &prim, &.{}, t_int32, &st2);
    try expectRejected(&bad, "register operand is neither a slot nor a special register");
}
