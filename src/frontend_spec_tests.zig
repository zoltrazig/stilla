//! Test file: `frontend spec` — the spec-example conformance programs:
//! the normative examples of the spec documents (Core, Runtime, StdLib),
//! assembled into compilable programs and compiled through the pipeline
//! (`expectCompiles`, local). The region also carries the generic
//! instantiation / monomorphization tests and the further lowering and
//! checker-rejection coverage that followed the conformance examples in
//! the unsplit file. Split out of the former
//! `src/frontend_lowering_tests.zig`.
//!
//! Shared helpers (compilation drivers and string/CFG lookups) are aliased
//! from `src/frontend_test_support.zig` below, so the test bodies are
//! unchanged from the unsplit file.
//!
//! Run via `zig build test` (wired into `src/root.zig`'s test block).

const std = @import("std");
const testing = std.testing;
const helpers = @import("frontend_test_support.zig");
const compileText = helpers.compileText;
const irText = helpers.irText;

fn expectCompiles(entry: []const u8, texts: []const struct { []const u8, []const u8 }) !void {
    var c = try compileText(entry, texts);
    defer c.deinit();
    if (c.program == null) {
        const msg = if (c.diag) |d| d.message else "no diagnostic";
        std.log.err("spec example failed to compile: {s}", .{msg});
        return error.SpecExampleFailed;
    }
}

// ---------------------------------------------------------------------------
// Spec-example conformance: the normative examples of the spec documents
// (Core, Runtime, StdLib), assembled into compilable programs. Each example
// is the exact source from the spec (wrapped in `fn main` where the spec
// shows a fragment), so a regression here means the specs and the frontend
// have drifted.
// ---------------------------------------------------------------------------

test "spec examples compile: Core 2.8 using value alias" {
    // `using string.upper as up; up(text)` resolves to the member.
    const src = try helpers.probeSource("probes/cases", "spec_core_2_8_using_value_alias");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "spec examples compile: Core 6.1 no implicit receiver" {
    const src = try helpers.probeSource("probes/cases", "spec_core_6_1_no_implicit_receiver");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "spec examples compile: Core 10.8 box and unbox" {
    // Runtime §4.5/§4.6; Core §10.8. Boxes are written and read by
    // construction/consumption only: `box` takes ownership, `unbox`
    // returns it. A *Unique* payload is extracted only by consuming the
    // box — `unbox(move b)` — the no-borrowed-returns rule of Core
    // §10.7 applied to boxes.
    const src = try helpers.probeSource("probes/cases", "spec_core_10_8_box_and_unbox");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "spec examples compile: Core 11.6 any" {
    const src = try helpers.probeSource("probes/cases", "spec_core_11_6_any");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "spec examples compile: Core 11.6.1 recovery by as" {
    const src = try helpers.probeSource("probes/cases", "spec_core_11_6_1_recovery_by_as");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "spec examples compile: Core 11.6.2 type-test match" {
    const src = try helpers.probeSource("probes/cases", "spec_core_11_6_2_type_test_match");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "spec examples compile: Core 12 generics" {
    // §12.1 declarations, §12.2 inferred call, §12.3 explicit call,
    // §12.4 an explicit specialization as a first-class monomorphic value.
    const src = try helpers.probeSource("probes/cases", "spec_core_12_generics");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "frontend lowers only monomorphic functions: instances, not templates" {
    // Core §12, checker.md, Generic expansion: the AIR carries one monomorphic function per
    // used specialization (`{module}.{fn}.{id}`) with concrete signatures;
    // the unspecialized template never appears, and no `.param` type
    // survives. Calls target the instances; recursion inside a generic
    // stays a self-loop under tail-call optimization.
    const src = try helpers.probeSource("probes/cases", "spec_monomorphic_instances");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // The specialized functions have concrete signatures; the generic
    // template is absent.
    try testing.expect(std.mem.indexOf(u8, out, "func @iter.fold.0(borrow values: list[int32]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @iter.fold_with.1(borrow values: list[int32]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @iter.fold(") == null);
    // Calls target the instances; no type-parameter survives in the text.
    try testing.expect(std.mem.indexOf(u8, out, "call @iter.fold.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "list[T]") == null);
    try testing.expect(std.mem.indexOf(u8, out, ": T ") == null);
}

test "frontend distinguishes generic instantiations and types payloads" {
    // Core §12.1/§12.3: `Option[int32]` and `Option[str]` are distinct
    // instantiations; a payload read is typed by the instantiation, and a
    // payload-type mismatch is a compile error (not silently accepted).
    const src = try helpers.probeSource("probes/cases", "spec_generic_instantiation_payload_read");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Option[int32]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "= read_payload") != null);

    // The payload-type mismatch is caught: Option::Some(42) is
    // Option[int32], not Option[str].
    const src2 = try helpers.probeSource("probes/cases", "spec_generic_instantiation_payload_mismatch");
    defer testing.allocator.free(src2);
    var c2 = try compileText("app", &.{.{ "app", src2 }});
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "let type mismatch") != null);
}

test "spec examples compile: Core 13.3 match" {
    const src = try helpers.probeSource("probes/cases", "spec_core_13_3_match");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "spec examples compile: Core 17 file module" {
    // The `os` module is a hypothetical host module, supplied here.
    const os_src = try helpers.probeSource("probes/cases", "spec_core_17_file_module_os");
    defer testing.allocator.free(os_src);
    const app_src = try helpers.probeSource("probes/cases", "spec_core_17_file_module_app");
    defer testing.allocator.free(app_src);
    try expectCompiles("app", &.{ .{ "os", os_src }, .{ "app", app_src } });
}

test "spec examples compile: StdLib 4 math and Runtime 4 box" {
    const math_src = try helpers.probeSource("probes/cases", "spec_stdlib_4_math");
    defer testing.allocator.free(math_src);
    try expectCompiles("app", &.{.{ "app", math_src }});
    // Runtime §4.5/§4.6: box and unbox.
    const box_src = try helpers.probeSource("probes/cases", "spec_runtime_4_box");
    defer testing.allocator.free(box_src);
    try expectCompiles("app", &.{.{ "app", box_src }});
}

test "spec examples compile: StdLib 7 iter" {
    const src = try helpers.probeSource("probes/cases", "spec_stdlib_7_iter");
    defer testing.allocator.free(src);
    try expectCompiles("app", &.{.{ "app", src }});
}

test "frontend rejects missing, duplicate, and unknown struct fields" {
    // Core §8.1: all fields must be supplied exactly once; unknown fields
    // and duplicate fields are frontend.compile-time errors.
    const missing_src = try helpers.probeSource("probes/cases", "spec_reject_missing_field");
    defer testing.allocator.free(missing_src);
    var c1 = try compileText("app", &.{.{ "app", missing_src }});
    defer c1.deinit();
    try testing.expect(c1.program == null);
    try testing.expect(std.mem.indexOf(u8, c1.diag.?.message, "missing field") != null);

    const duplicate_src = try helpers.probeSource("probes/cases", "spec_reject_duplicate_field");
    defer testing.allocator.free(duplicate_src);
    var c2 = try compileText("app", &.{.{ "app", duplicate_src }});
    defer c2.deinit();
    try testing.expect(c2.program == null);
    try testing.expect(std.mem.indexOf(u8, c2.diag.?.message, "duplicate field") != null);

    const unknown_src = try helpers.probeSource("probes/cases", "spec_reject_unknown_field");
    defer testing.allocator.free(unknown_src);
    var c3 = try compileText("app", &.{.{ "app", unknown_src }});
    defer c3.deinit();
    try testing.expect(c3.program == null);
    try testing.expect(std.mem.indexOf(u8, c3.diag.?.message, "has no field") != null);
}

test "frontend rejects import outside a module constant initializer" {
    // Core §2.2 / Binding Power Table document, import form: `import(...)` may appear
    // only as the initializer of a module-level `const` binding. Binding the module
    // value is rejected by the checker under Core §2.3 (`let m = import("builtin")` —
    // a module value cannot be bound by a local let); a bare statement position,
    // whose result the checker discards, reaches the phase-3 backstop
    // (cfg_lower_expr.zig) tested here.
    const src = try helpers.probeSource("probes/cases", "spec_reject_import_outside_module_const");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "module constant initializer") != null);
}

test "frontend lowers arithmetic, comparison, and string concat operators" {
    // Core §16.3: int32 arithmetic; str + str concatenation.
    const src = try helpers.probeSource("probes/cases", "spec_lower_arithmetic_comparison_concat");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = add ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = mul ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = sub ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = div ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = rem ") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = concat ") != null);
}

test "frontend lowers as casts" {
    // Core §16.3: `float32 as int32` and `int32 as float32` are core
    // conversions; the AIR emits a `num_cast` op.
    const src = try helpers.probeSource("probes/cases", "spec_lower_as_casts");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = num_cast ") != null);
}

test "frontend lowers shadowing with the previous binding read first" {
    // Core §4: `let x = x + 1;` — the right-hand `x` refers to the
    // previous binding.
    const src = try helpers.probeSource("probes/cases", "spec_lower_shadowing");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    // 10 + 1 folds at construction (optimizer.md, On-the-fly optimizations) to the constant.
    try testing.expect(std.mem.indexOf(u8, out, " = const 11") != null);
}

test "frontend lowers mutual recursion with declared return types" {
    // Core §6.5: functions are order-independent; mutual recursion is
    // permitted when every participant declares its return type.
    const src = try helpers.probeSource("probes/cases", "spec_lower_mutual_recursion");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.is_odd") != null);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.is_even") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.is_odd") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.is_even") != null);
}

test "frontend lowers tuple destructuring to read_tuple projections" {
    // Core §14.2 / §14.6: tuple patterns project elements; the whole
    // tuple is consumed as one value.
    const src = try helpers.probeSource("probes/cases", "spec_lower_tuple_destructuring");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "read_tuple") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#1") != null);
}

test "frontend lowers list pattern reads with read_index" {
    // Core §11.5: there is no indexed element-read function (`list.get`
    // does not exist); element reads happen by list matching. A
    // non-consuming `[h, ..t]` pattern lowers to the bounds-checked
    // `read_index` op (borrowed view of a *Unique* element).
    const src = try helpers.probeSource("probes/cases", "spec_lower_list_pattern_read_index");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "read_index") != null);
}

test "frontend rejects list.get as a removed member" {
    // Core §11.5: `list.get` was removed — a *Unique* element cannot be
    // returned by value without consuming the list (Core §10.7), and no
    // function returns a borrowed value, so element reads happen by
    // matching instead. The binding no longer exists.
    const src = try helpers.probeSource("probes/cases", "spec_reject_list_get");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "no member 'get'") != null);
}

test "frontend lowers consuming list-pattern destructuring with split_list" {
    // Core §18 (whole-owner rule): destructuring an owned list with
    // `let [head, ..rest] = move xs` consumes the collection as a whole;
    // one atomic `split_list` defines the item and the owned rest (air.md
    // §5.3) — each unique element becomes an owner.
    const src = try helpers.probeSource("probes/cases", "spec_lower_split_list");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const program = c.program orelse {
        std.log.err("frontend.compile failed: {any}", .{c.diag});
        return error.TestUnexpectedResult;
    };
    const out = try irText(&program);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, " = split_list %") != null);
    try testing.expect(std.mem.indexOf(u8, out, " = move %") != null);
}

test "frontend lowers box and unbox to syscalls" {
    // Core §10.8 / Runtime §4.5–§4.6: box/unbox are host bindings;
    // box takes ownership, unbox(move b) transfers ownership back.
    const src = try helpers.probeSource("probes/cases", "spec_lower_box_unbox_syscalls");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#box") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#unbox") != null);
    // `unbox(move b)` on a Copy box[int32] lowers `move` to nothing
    // (Core §10.6: a copy of a Copy value is the value itself), so
    // no copy instruction is emitted — the unbox takes the box directly.
    try testing.expect(std.mem.indexOf(u8, out, "copy") == null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#unbox, %1") != null);
}

test "frontend rejects an unspecialized generic used as a value" {
    // Core §12.4: an unspecialized generic function is a compile-time
    // template, not a runtime function value; `let f = identity` references
    // the template itself and is rejected. A specialization (`identity::[int32]`)
    // is a valid monomorphic function value.
    const src = try helpers.probeSource("probes/cases", "spec_reject_unspecialized_generic");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(c.diag != null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "unspecialized generic") != null);
}

test "frontend accepts an explicitly specialized generic as a value" {
    // Core §12.4: `identity::[int32]` is a first-class monomorphic function
    // value of type `fn(move int32) -> int32`; the checker records the
    // specialization and the lowering emits a `fn_ref` to the instance's
    // monomorphic function (`{module}.{fn}.{id}`).
    const src = try helpers.probeSource("probes/cases", "spec_accept_specialized_generic_value");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program != null);
    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "fn_ref @app.identity.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.identity.0(") != null);
}

test "frontend lowers an explicitly specialized generic call" {
    // Core §12.3: `identity::[int32](42)` is frontend.compile-time specialization
    // syntax; the call lowers to the concrete monomorphic function.
    const src = try helpers.probeSource("probes/cases", "spec_lower_specialized_generic_call");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "call @app.identity") != null);
    try testing.expect(std.mem.indexOf(u8, out, "func @app.identity") != null);
}

test "frontend rejects moving an unknown binding" {
    // Core §10.4: `move` names a complete local binding.
    const src = try helpers.probeSource("probes/cases", "spec_reject_move_unknown_binding");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "move of unknown binding") != null);
}

test "frontend rejects dropping an unknown binding" {
    // Core §9.4: explicit drop applies only to an owning unique local.
    const src = try helpers.probeSource("probes/cases", "spec_reject_drop_unknown_binding");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "drop of unknown binding") != null);
}

test "frontend lowers list.range and list.len with generics" {
    // Core §12.2: inferred specialization resolves `len[T]` against the
    // concrete `list[int32]` from `range` (Runtime §4.3–§4.4).
    const src = try helpers.probeSource("probes/cases", "spec_lower_list_range_len");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall list#len") != null);
    try testing.expect(std.mem.indexOf(u8, out, "syscall list#range") != null);
}

test "frontend lowers a never-returning call to a trap path" {
    // Core §13.2 / Runtime §7.1: `never` coerces to any type; a panic
    // call terminates the block (trap), so the if/else join type-checks.
    const src = try helpers.probeSource("probes/cases", "spec_lower_never_trap");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall builtin#panic") != null);
    try testing.expect(std.mem.indexOf(u8, out, "trap") != null);
}

test "frontend rejects calling a non-function value" {
    const src = try helpers.probeSource("probes/cases", "spec_reject_call_non_function");
    defer testing.allocator.free(src);
    var c = try compileText("app", &.{.{ "app", src }});
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "calling a non-function") != null);
}

test "frontend rejects an unknown module member" {
    const calc_src = try helpers.probeSource("probes/cases", "spec_reject_unknown_module_member_calc");
    defer testing.allocator.free(calc_src);
    const app_src = try helpers.probeSource("probes/cases", "spec_reject_unknown_module_member_app");
    defer testing.allocator.free(app_src);
    var c = try compileText("app", &.{ .{ "calc", calc_src }, .{ "app", app_src } });
    defer c.deinit();
    try testing.expect(c.program == null);
    try testing.expect(std.mem.indexOf(u8, c.diag.?.message, "no member") != null);
}

test "frontend resolves chained module-valued member calls" {
    // Core §2.7: `std.math.sqrt` is chained value-member access through
    // nested module-valued consts.
    const std_src = try helpers.probeSource("probes/cases", "spec_chained_module_member_std");
    defer testing.allocator.free(std_src);
    const app_src = try helpers.probeSource("probes/cases", "spec_chained_module_member_app");
    defer testing.allocator.free(app_src);
    var c = try compileText("app", &.{ .{ "std", std_src }, .{ "app", app_src } });
    defer c.deinit();

    const out = try irText(&c.program.?);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "syscall math#sqrt") != null);
}
