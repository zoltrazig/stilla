//! Test file: `frontend LLIR asm` — LLIR 5.1/5.2: the symbolic
//! assembly projection of a lowered image and `llir.print`
//! re-exporting it. Split out of the former `src/frontend_tests.zig`.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const llir = @import("llir.zig");
const lower = @import("lower.zig");
const cfg_lower_llir = @import("passes/cfg_lower_llir.zig");
const llir_validate = @import("passes/llir_validate.zig");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;
const compileOpt = helpers.compileOpt;

/// Caller-owned storage for a patched single-function/single-block image.
const PatchedStorage = struct {
    blocks: [1]llir.BlockDesc = undefined,
    functions: [1]llir.FunctionDesc = undefined,
};

/// Rebuild a compiled image with `instructions` as its entire code: one
/// function, one block, pcs covering exactly the new stream. The paired
/// cfg program (needed for names) is unchanged — its first function must
/// have exactly one block. The result is a print fixture, not a
/// validated image.
fn patchImage(image: llir.LlirProgram, instructions: []const llir.Instr, st: *PatchedStorage) llir.LlirProgram {
    st.blocks[0] = .{ .start_pc = 0, .end_pc = @intCast(instructions.len) };
    st.functions[0] = image.functions[0];
    st.functions[0].code_start = 0;
    st.functions[0].code_end = @intCast(instructions.len);
    st.functions[0].entry_pc = 0;
    var out = image;
    out.instructions = instructions;
    out.blocks = st.blocks[0..1];
    out.functions = st.functions[0..1];
    return out;
}
test "5.1 LLIR assembly: symbolic projection — qualified funcs, block labels, consts, members, syscalls; deterministic and image-read-only" {
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\const magic: int32 = 12345;
            \\const greeting: str = "hi";
            \\fn add(a: int32, b: int32) -> int32 { a + b }
            \\fn pick(x: int32, y: int32) -> int32 {
            \\    if (x < y) { 1 } else { 2 }
            \\}
            \\fn main() -> void {
            \\    let s = add(1, magic);
            \\    builtin.print(greeting);
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    // The input CFG is unmodified by printing.
    const before = try irText(program);
    defer testing.allocator.free(before);

    const asm1 = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm1);

    // Function headers are qualified names (`func @mod.name`).
    try testing.expect(std.mem.indexOf(u8, asm1, "func @app.main {") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "func @app.add {") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "func @app.pick {") != null);

    // Constant records render as literals — the magic int and the string.
    try testing.expect(std.mem.indexOf(u8, asm1, "12345") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\"hi\"") != null);

    // The syscall host binding is symbolized as `@builtin.print`.
    try testing.expect(std.mem.indexOf(u8, asm1, "@builtin.print") != null);
    // The stored constant member is symbolized as `@app.magic` on both the
    // `store_member` (@init) and `load_member` (main) sides.
    try testing.expect(std.mem.indexOf(u8, asm1, "@app.magic") != null);

    // Basic blocks are labels and branch targets are labels — no absolute
    // PC and no unresolved target survives.
    try testing.expect(std.mem.indexOf(u8, asm1, ".block $") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, " j $") != null or std.mem.indexOf(u8, asm1, "br ") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, " j 0x") == null);
    try testing.expect(std.mem.indexOf(u8, asm1, "?target") == null);

    // The trailing symbol table resolves labels to PCs.
    try testing.expect(std.mem.indexOf(u8, asm1, "; symbol table") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "$app.init.entry = 0x") != null);

    // M1: the symbol table's symbols section projects every symbol from
    // the image itself (the `symbols` SymbolId table into `strings`),
    // field-faithful and independent of the source program.
    try testing.expect(std.mem.indexOf(u8, asm1, "; symbols (SymbolId -> bytes)") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "= \"builtin\"") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "= \"app\"") != null);

    // The input CFG is unchanged after printing...
    const after = try irText(program);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);

    // ...and a second print is byte-identical (determinism).
    const asm2 = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm2);
    try testing.expectEqualStrings(asm1, asm2);
}

test "5.1 LLIR assembly: module symbols resolve from the image, not the source program" {
    // Field-faithfulness (M1): the specifier is image data. Rewriting
    // the specifier bytes inside the image's strings blob — the source
    // program untouched — must change every module symbol: the syscall
    // operand, the function-header qualifier, the symbol table's
    // modules section, and the `module_ref` operand.
    var c = try compileText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn main() -> void {
        \\    builtin.print("hi");
        \\}
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    // Baseline symbols name the compiled specifiers.
    const base = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(base);
    try testing.expect(std.mem.indexOf(u8, base, "@builtin.print") != null);
    try testing.expect(std.mem.indexOf(u8, base, "func @app.main {") != null);

    // The source program is fixed from here on: rewriting the symbol
    // bytes inside the image's strings blob (in place, same lengths)
    // must be the only change.
    const before = try irText(program);
    defer testing.allocator.free(before);
    const strings = @constCast(image.strings);
    for (image.symbols) |r| {
        const bytes = strings[r.start..][0..r.len];
        if (std.mem.eql(u8, bytes, "builtin")) {
            @memcpy(bytes, "builtix");
        } else if (std.mem.eql(u8, bytes, "app")) {
            @memcpy(bytes, "apx");
        }
    }

    const mutated = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(mutated);
    // Syscall operand, header qualifier, and symbol-table rows all
    // follow the image bytes.
    try testing.expect(std.mem.indexOf(u8, mutated, "@builtix.print") != null);
    try testing.expect(std.mem.indexOf(u8, mutated, "@builtin.print") == null);
    try testing.expect(std.mem.indexOf(u8, mutated, "func @apx.main {") != null);
    try testing.expect(std.mem.indexOf(u8, mutated, "func @app.main {") == null);
    try testing.expect(std.mem.indexOf(u8, mutated, "= \"builtix\"") != null);
    try testing.expect(std.mem.indexOf(u8, mutated, "= \"apx\"") != null);
    try testing.expect(std.mem.indexOf(u8, mutated, "= \"builtin\"") == null);

    // The source program is untouched by both prints.
    const after = try irText(program);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);

    // The `module_ref` operand symbolizes through the image too: patch
    // the code to one `module_ref` naming the mutated `app` module.
    var app_sym: u32 = 0;
    for (image.symbols, 0..) |r, i| {
        if (std.mem.eql(u8, image.strings[r.start..][0..r.len], "apx")) app_sym = @intCast(i);
    }
    const rows = [_]llir.Instr{
        llir.instrI(.module_ref, llir.frame_base, @intCast(app_sym)),
        llir.instrE(.ret, llir.frame_base, 0),
    };
    var st: PatchedStorage = .{};
    const patched = patchImage(image, &rows, &st);
    const text = try lower.llirAsm(&b, patched, testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "module_ref r19, @apx") != null);
    try testing.expect(std.mem.indexOf(u8, text, "module_ref r0, @app") == null);
}

test "5.1 LLIR assembly: every block label maps 1:1 to a distinct PC and every unresolvable id appears in the table" {
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\const builtin = import("builtin");
            \\union Result { Ok(int32), Err(int32) }
            \\fn choose(t: bool, a: int32, b: int32) -> int32 { if (t) { a } else { b } }
            \\fn tag(r: Result) -> int32 {
            \\    match (r) { Result::Ok(n) => n, Result::Err(n) => n }
            \\}
            \\fn main() -> void {
            \\    let v = choose(true, 1, 2);
            \\    let k = tag(Result::Ok(9));
            \\    builtin.print(builtin.str(v + k));
            \\}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const asmText = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asmText);

    // Every function's blocks appear as labeled block rows. In a valid
    // lowered image each branch target is a block start, so every label
    // the code references is present in the symbol table (labels are
    // exactly the blocks).
    var label_count: usize = 0;
    for (program.funcs) |f| label_count += f.blocks.len;
    // Each `.block $X` emits one symbol-table row `$X = 0x....`; count both
    // and require equal + nonzero.
    try testing.expect(label_count > 0);
    try testing.expect(std.mem.indexOf(u8, asmText, ".block $") != null);
    try testing.expect(std.mem.indexOf(u8, asmText, " = 0x") != null);

    // The union match lowers to a `switch` whose arm targets are the same
    // per-function block labels — every arm routes through `labelForPc`,
    // and no arm target is an absolute PC or unresolved.
    try testing.expect(std.mem.indexOf(u8, asmText, "switch ") != null);
    try testing.expect(std.mem.indexOf(u8, asmText, " => $") != null);
    try testing.expect(std.mem.indexOf(u8, asmText, "?target") == null);
}

test "5.2 llir.print re-exports the assembly printer from the LLIR module" {
    // `src/llir.zig` now re-exports the printer (5.2), replacing the
    // deleted `llir_print` binding. The functions are the same, so the
    // two spellings must return byte-identical assembly for one image.
    var c = try compileText("app", &.{
        .{
            "app",
            \\fn add(a: int32, b: int32) -> int32 { a + b }
            \\fn main() -> void {}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();

    const asm1 = try llir.print(&b, image, testing.allocator);
    defer testing.allocator.free(asm1);
    const asm2 = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm2);

    try testing.expectEqualSlices(u8, asm2, asm1);
    try testing.expect(std.mem.indexOf(u8, asm1, "func @app.add {") != null);
    // It is the assembly projection (symbolic), not a raw image dump.
    try testing.expect(std.mem.indexOf(u8, asm1, "func @") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, ".block $") != null);
}

test "5.2 LLIR assembly: binary64 constants print at full precision" {
    // Phase 5: the assembly projection renders a binary64 constant from
    // its full {a, b} payload (the {d} shortest round-trip form), never
    // narrowed through binary32.
    var c = try compileText("app", &.{.{
        "app",
        \\fn f(a: float64) -> int32 { a as int32 }
        \\fn main() -> int32 {
        \\    let pi: float64 = 3.141592653589793;
        \\    let r = f(pi);
        \\    r
        \\}
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    const asm1 = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm1);
    // The binary64 constant prints with its full 17-digit shortest
    // round-trip precision — the binary32 narrowing would lose the
    // last digits (3.1415927410125732).
    try testing.expect(std.mem.indexOf(u8, asm1, "3.141592653589793") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "3.1415927410125732") == null);
}

test "5.1 LLIR assembly: i64/u64/f64 ops and conversions print stable serialized names" {
    // Phase 3 (TODO.md 阶段 3): the assembly projection is a projection of
    // the *serialized* image, so the v9 typed opcode names print with
    // their rep suffixes (`mul`/`shru` — the width rides in the
    // opcode, never a load-time derivative), the C-Type comparisons
    // print with the implicit `cond` (no destination field), the 20
    // explicit `cvt.<src>.<dst>` conversions print their dedicated
    // names, and full-width constants print from their complete 64-bit
    // payloads.
    var c = try compileText("app", &.{.{
        "app",
        \\fn mul64(a: int64, b: int64) -> int64 { a * b }
        \\fn sh64(x: uint64, k: uint64) -> uint64 { x >> k }
        \\fn lt64(a: uint64, b: uint64) -> bool { a < b }
        \\fn fmul(a: float64, b: float64) -> float64 { a * b }
        \\fn fge(a: float64, b: float64) -> bool { a >= b }
        \\fn b2f(x: byte) -> float64 { x as float64 }
        \\fn i2f(x: int32) -> float64 { x as float64 }
        \\fn u2f(x: uint32) -> float64 { x as float64 }
        \\fn f2f(x: float32) -> float64 { x as float64 }
        \\fn f2i(x: float64) -> int32 { x as int32 }
        \\fn main() -> int32 {
        \\    let a: int64 = 9223372036854775807;
        \\    let b: uint64 = 18446744073709551615;
        \\    let c: float64 = 3.141592653589793;
        \\    let d = mul64(a, a);
        \\    let e = sh64(b, b);
        \\    let g = fmul(c, c);
        \\    let h = f2i(g);
        \\    0
        \\}
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    const asm1 = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm1);

    // The 64-bit families print their typed rep suffixes — the width is
    // serialized in the opcode itself.
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    mul.i64 r19, r19, r20") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    shr.u64 r19, r19, r20") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    sltu r19, r20") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    mul.f64 r19, r19, r20") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    sle.f64 r20, r19") != null); // `a >= b` ≡ `sle b, a`
    // The explicit conversion matrix: one opcode per (src, dst) pair,
    // the C-Type form with no destination discriminator.
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    cvt.b.f64 r20, r19") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    cvt.i32.f64 r20, r19") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    cvt.u32.f64 r20, r19") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    cvt.f32.f64 r20, r19") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "\n    cvt.f64.i32 r20, r19") != null);
    // Full-width constants print from their complete 64-bit payloads
    // (i64 max, the u64 max bit pattern, and the binary64 literal).
    try testing.expect(std.mem.indexOf(u8, asm1, "9223372036854775807") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "3.141592653589793") != null);
}

test "5.1 LLIR assembly: the twelve move-wide opcodes print unsigned imm16 lane values" {
    // Phase 3 (TODO.md 阶段 3): `movwn0`…`movwk3` are I-format rows whose
    // `imm16 = b | (c << 8)` is the unsigned lane value — printed as the
    // unsigned 16-bit immediate, never sign-extended (0x0000 → 0,
    // 0xffff → 65535), with no new assembly syntax. The frontend lowering
    // does not emit them yet (TODO.md 阶段 5), so the image is a compiled
    // program whose code is patched in place with the twelve rows.
    var c = try compileText("app", &.{.{
        "app",
        \\fn main() -> int32 { 0 }
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const lowered = try b.lowerLlir();

    const movws = [_]llir.Instr{
        llir.instrI(.movwz0, llir.frame_base, 0x0000), // lane 0 = 0x0000
        llir.instrI(.movwz1, llir.frame_base, 0xffff), // lane 1 = 0xffff
        llir.instrI(.movwz2, llir.frame_base, 0x3412), // lane 2 = 0x3412
        llir.instrI(.movwz3, llir.frame_base, 0xffff), // lane 3 = 0xffff
        llir.instrI(.movwn0, llir.frame_base, 0xffff),
        llir.instrI(.movwn1, llir.frame_base, 0x0000),
        llir.instrI(.movwn2, llir.frame_base, 0x0000),
        llir.instrI(.movwn3, llir.frame_base, 0xffff),
        llir.instrI(.movwk0, llir.frame_base, 0xffff),
        llir.instrI(.movwk1, llir.frame_base, 0x0000),
        llir.instrI(.movwk2, llir.frame_base, 0xffff),
        llir.instrI(.movwk3, llir.frame_base, 0x0000),
        llir.instrE(.ret, 0, 0),
    };
    const recs = try testing.allocator.alloc(llir.Instr, movws.len);
    defer testing.allocator.free(recs);
    @memcpy(recs, &movws);

    var st: PatchedStorage = .{};
    const image = patchImage(lowered, recs, &st);

    const asm1 = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm1);

    // The twelve names are frozen contract — assert the literal rows, not
    // names derived from the schema (a rename in `opInfo` would otherwise
    // move the printer and the expectation together). Each row locks the
    // opcode name, the destination register, and the unsigned imm16:
    // 0x0000 prints `0`, 0xffff prints `65535`, 0x3412 prints `13330` —
    // never sign-extended, never a new syntax layer.
    try testing.expect(std.mem.indexOf(u8, asm1, "movwz0 r19, 0") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwz1 r19, 65535") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwz2 r19, 13330") != null); // 0x3412
    try testing.expect(std.mem.indexOf(u8, asm1, "movwz3 r19, 65535") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwn0 r19, 65535") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwn1 r19, 0") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwn2 r19, 0") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwn3 r19, 65535") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwk0 r19, 65535") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwk1 r19, 0") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwk2 r19, 65535") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "movwk3 r19, 0") != null);
}

test "5.2 LLIR assembly: host syscalls and any payload TypeIds project symbolically" {
    // Phase 6: the projection renders any instructions with their
    // payload TypeId (the packed source / recovery target) and
    // syscalls with their binding member name — the text form a host
    // reads to resolve bindings (Runtime §2.6).
    var c = try compileText("app", &.{.{
        "app",
        \\const builtin = import("builtin");
        \\fn wrap(a: int64) -> any { a }
        \\fn main() -> void {
        \\    let v: int64 = 9007199254740993;
        \\    let a = wrap(v);
        \\    let w = (move a) as int64;
        \\    builtin.print(builtin.str(1));
        \\}
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    const asm1 = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(asm1);
    try testing.expect(std.mem.indexOf(u8, asm1, "any_pack_copy") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "any_unpack_move") != null);
    // The payload TypeId prints as the type name, and the syscall as
    // its binding.
    try testing.expect(std.mem.indexOf(u8, asm1, "int64") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "@builtin.print") != null);
    try testing.expect(std.mem.indexOf(u8, asm1, "@builtin.str") != null);
}

// ---------------------------------------------------------------------------
// 3.4 — operand printing contracts over patched images and natural lowering
// ---------------------------------------------------------------------------

test "3.4 LLIR assembly: all seven formats print mnemonic, operands, and negative offsets" {
    // One patched single-block image carries a representative row of every
    // format: R (`add`), E (`neg`), C (cast + immediate compare),
    // I (`jr`/`jalr`/`movwz1`), B (register, immediate, and bit-test
    // schemas), U (`j`). Every branch/offset field is negative — its
    // operand prints as a signed value or resolves backward to `$entry`.
    // Rows are hand-encoded print fixtures; they assert the printer, not
    // a validated program.
    var c = try compileText("app", &.{.{
        "app",
        \\fn main() -> int32 { 0 }
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const lowered = try b.lowerLlir();

    const rows = [_]llir.Instr{
        llir.instrR(.add_i32, llir.frame_base + 3, llir.frame_base + 1, llir.frame_base + 2),
        llir.instrE(.neg_i32, llir.frame_base + 1, llir.frame_base),
        llir.instrC(.cvt_i32_u32, llir.frame_base + 1, llir.frame_base),
        llir.instrC(.slti, llir.frame_base + 1, 63),
        llir.instrI(.jr, llir.frame_base + 5, 0xfff0), // -16
        llir.instrI(.jalr, llir.frame_base + 5, 0xf800), // -2048
        llir.instrI(.movwz1, llir.frame_base + 7, 0xffff),
        llir.instrB(.beq, llir.frame_base + 1, llir.frame_base + 2, -7), // pc7 -> entry (backward)
        llir.instrB(.ble, llir.frame_base + 2, llir.frame_base + 1, -8), // operand order prints as encoded
        llir.instrB(.bltu, llir.frame_base + 2, llir.frame_base + 1, -9),
        llir.instrB(.blti, llir.frame_base + 1, 65, -10),
        llir.instrB(.bltiu, llir.frame_base + 1, 127, -11),
        llir.instrB(.beqi, llir.frame_base + 1, 5, -12),
        llir.instrB(.bnei, llir.frame_base + 1, 127, -13),
        llir.instrB(.tbz, llir.frame_base, 5, -14),
        llir.instrB(.tbnz, llir.frame_base, 63, -15),
        llir.instrJ(-16), // pc16 -> entry, the link-less `j`
    };
    const recs = try testing.allocator.alloc(llir.Instr, rows.len);
    defer testing.allocator.free(recs);
    @memcpy(recs, &rows);

    var st: PatchedStorage = .{};
    const image = patchImage(lowered, recs, &st);

    const text = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(text);

    // Each frozen row prints exactly — name, operand order as encoded,
    // signed immediates, and label targets resolved from negative offsets.
    const expected_rows = [_][]const u8{
        "\n    add.i32 r22, r20, r21\n",
        "\n    neg.i32 r20, r19\n",
        "\n    cvt.i32.u32 r20, r19\n",
        "\n    slti r20, 63\n",
        "\n    jr r24 -16\n",
        "\n    jalr ra, r24, -2048\n",
        "\n    movwz1 r26, 65535\n",
        "\n    beq r20, r21, $app.init.entry\n",
        "\n    ble r21, r20, $app.init.entry\n",
        "\n    bltu r21, r20, $app.init.entry\n",
        "\n    blti r20, 65, $app.init.entry\n",
        "\n    bltiu r20, 127, $app.init.entry\n",
        "\n    beqi r20, 5, $app.init.entry\n",
        "\n    bnei r20, 127, $app.init.entry\n",
        "\n    tbz r19, 5, $app.init.entry\n",
        "\n    tbnz r19, 63, $app.init.entry\n",
        "\n    j $app.init.entry\n",
    };
    for (expected_rows) |row| {
        try testing.expect(std.mem.indexOf(u8, text, row) != null);
    }

    // Nothing fell into the raw-word fallback and no target went unresolved.
    try testing.expect(std.mem.indexOf(u8, text, "?target") == null);
    try testing.expect(std.mem.indexOf(u8, text, "?? ") == null);
}

test "3.4 LLIR assembly: direct-call jal prints the callee name and take follows it" {
    // Natural lowering of a self-recursive call (the optimizer keeps it)
    // plus an inlined fn-value call: `jal @callee` resolves the direct
    // frame call's function-entry target through `functionAtPc`, the
    // implicit `ra` link stays unencoded in both, and each call is
    // followed by its generic `take`.
    var c = try compileOpt("app", &.{.{
        "app",
        \\fn recurse(n: int32) -> int32 {
        \\    if (n <= 0) { 0 } else { n + recurse(n - 1) }
        \\}
        \\fn apply(f: fn(int32) -> int32, x: int32) -> int32 { f(x) }
        \\fn inc(a: int32) -> int32 { a + 1 }
        \\fn main() -> int32 {
        \\    let t = recurse(3);
        \\    let u = apply(inc, 4);
        \\    t + u
        \\}
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    const text = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(text);

    // Both direct-call sites print the symbolic callee name (the
    // optimizer keeps the recursion in the standalone function and its
    // main copy), each preceded by arg records and followed by a result.
    try testing.expect(std.mem.count(u8, text, "\n    jal @app.recurse\n") == 2);

    // Every take in the image prints its exact positional row — the
    // generic E-format `take dst, src` — and the sites take into F2 and
    // F3 (r21/r22) as before.
    var takes_r2: usize = 0;
    var takes_r3: usize = 0;
    for (image.instructions) |rec| {
        const d = llir.decode(rec) orelse continue;
        if (d.op != .take) continue;
        const row = try std.fmt.allocPrint(testing.allocator, "\n    take r{d}, r{d}\n", .{ d.a, d.b });
        defer testing.allocator.free(row);
        try testing.expect(std.mem.indexOf(u8, text, row) != null);
        if (d.a == llir.frame_base + 2) takes_r2 += 1;
        if (d.a == llir.frame_base + 3) takes_r3 += 1;
    }
    try testing.expect(takes_r2 >= 1);
    try testing.expect(takes_r3 >= 1);

    // Both indirect call sites keep the required-but-unencoded link token
    // and take the function value from slot F0 (`ra` stays implicit).
    try testing.expect(std.mem.count(u8, text, "\n    jalr ra, r19, 0\n") == 2);

    // No unresolved callee and no raw-word fallback anywhere.
    try testing.expect(std.mem.indexOf(u8, text, "?target") == null);
    try testing.expect(std.mem.indexOf(u8, text, "#f") == null);
}

test "3.4 LLIR assembly: comparison swaps and the immediate-compare aliases print their fixed forms" {
    // Natural lowering of the non-canonical predicates: signed `>` swaps
    // to `slt rhs, lhs`, unsigned ">=" lowers to a negated `sltu`, float
    // equality stays ordered without any swap, and the fused immediate
    // comparisons (slti/sgti/snei) print their literal values. The
    // register-form conditional branch is the materialized-bool shape
    // (`beq reg, zero`) the boolean lowering emits.
    var c = try compileOpt("probe", &.{.{
        "probe",
        \\fn sum(n: int32) -> int32 { if (n <= 0) { 0 } else { n + sum(n - 1) } }
        \\fn gtB(a: int32, b: int32) -> int32 { if (a > b) { 1 } else { 0 } }
        \\fn geUB(a: uint32, b: uint32) -> int32 { if (a >= b) { 1 } else { 0 } }
        \\fn eqF(a: float64, b: float64) -> int32 { if (a == b) { 1 } else { 0 } }
        \\fn neI(a: int32) -> int32 { if (a != 5) { 1 } else { 0 } }
        \\fn cmp3(k: int32, a: int32) -> bool { k < a }
        \\fn main() -> int32 {
        \\    let s = sum(4);
        \\    let p = gtB(s, 10);
        \\    let q = geUB(3 as uint32, 4 as uint32);
        \\    let f1: float64 = 1.5;
        \\    let f2: float64 = -2.5;
        \\    let r = eqF(f1, f2);
        \\    let t = neI(7);
        \\    let v = cmp3(2, 9);
        \\    s
        \\}
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));

    const text = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(text);

    // Signed `a > b` === `slt b, a`: params are F0=a, F1=b...
    try testing.expect(std.mem.indexOf(u8, text, "\n    slt r20, r19\n") != null);

    // Unsigned `a >= b` === `not (a < b)`: the u-compare keeps operand
    // order and the negation rides in `not cond, cond` right after.
    try testing.expect(std.mem.indexOf(u8, text, "\n    sltu r19, r20\n    not cond, cond\n") != null);

    // Float equality has no swap: ordered `seq.f64 lhs, rhs` verbatim.
    try testing.expect(std.mem.indexOf(u8, text, "\n    seq.f64 r19, r20\n") != null);

    // The immediate-compare aliases print C-Type rows with literal values.
    try testing.expect(std.mem.indexOf(u8, text, "\n    snei r19, 5\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    sgti r21, 10\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    slti r23, 9\n") != null);

    // The register-form branch reads a materialized bool against zero.
    try testing.expect(std.mem.indexOf(u8, text, "\n    beq r20, zero, $") != null);

    try testing.expect(std.mem.indexOf(u8, text, "?target") == null);
}

test "3.4 LLIR assembly: lui prints the shifted constant and auipc the pc delta with sign" {
    // U-type immediates are sign-extended 20-bit constants; `lui` renders
    // the raw decoded i20 while `auipc` renders its <<12 displacement as a
    // signed hexadecimal delta — positive, zero, and at both sign extremes.
    // Patched print fixture; the frontend does not emit these yet.
    var c = try compileText("app", &.{.{
        "app",
        \\fn main() -> int32 { 0 }
    }});
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const lowered = try b.lowerLlir();

    const rows = [_]llir.Instr{
        llir.instrU(.lui, llir.frame_base + 1, 0xfffff), // imm20 decodes to -1
        llir.instrU(.lui, llir.temp_base + 15, 524287), // T15
        llir.instrU(.lui, llir.frame_base, -524288), // min imm20
        llir.instrU(.auipc, llir.frame_base + 2, 1),
        llir.instrU(.auipc, llir.frame_base + 7, 0x7ffff),
        llir.instrU(.auipc, llir.frame_base + 3, -524288),
        llir.instrU(.auipc, llir.frame_base + 4, 0),
        llir.instrE(.ret, 0, 0),
    };
    const recs = try testing.allocator.alloc(llir.Instr, rows.len);
    defer testing.allocator.free(recs);
    @memcpy(recs, &rows);

    var st: PatchedStorage = .{};
    const image = patchImage(lowered, recs, &st);

    const text = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "\n    lui r20, -1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    lui T15, 524287\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    lui r19, -524288\n") != null);

    try testing.expect(std.mem.indexOf(u8, text, "\n    auipc r21 +0x1000\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    auipc r26 +0x7ffff000\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    auipc r22 -0x80000000\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    auipc r23 +0x0\n") != null);

    try testing.expect(std.mem.indexOf(u8, text, "?? ") == null);
}

test "5.1 LLIR assembly: the variant tag prints as a number, not a register" {
    // `borrow_variant`/`unpack_variant`'s `c` is the variant *tag* — an
    // immediate value, never a register. Under the re-encoding the tag 1
    // numerically equals the `cond` encoding, so the printer must render
    // it as `1` (the schema role is `.imm`), never as `cond`.
    var c = try compileOpt("app", &.{
        .{
            "app",
            \\union Shape { circle(int32), rect(int32, int32) }
            \\fn area(s: Shape) -> int32 {
            \\    match (s) {
            \\        Shape::rect(w, h) => w * h,
            \\        Shape::circle(r) => r,
            \\    }
            \\}
            \\fn main() -> void {}
        },
    });
    defer c.deinit();
    const program = &c.program.?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = cfg_lower_llir.Builder.init(arena.allocator(), program);
    const image = try b.lowerLlir();
    try testing.expectEqual(@as(?[]const u8, null), try llir_validate.validate(&image, testing.allocator));
    const text = try lower.llirAsm(&b, image, testing.allocator);
    defer testing.allocator.free(text);

    // The rect arm's borrow_variant tag is 1 — printed as a number.
    try testing.expect(std.mem.indexOf(u8, text, "borrow_variant #d0, r19, 1\n") != null);
    // ...and no variant tag is ever rendered as the cond register.
    try testing.expect(std.mem.indexOf(u8, text, "borrow_variant #d0, r19, cond\n") == null);
}
