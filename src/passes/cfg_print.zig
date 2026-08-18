//! Canonical IR text printer — ir.md §9 (the `cfg` text form).
//!
//! Serializes the in-memory CFG structures of `cfg.zig` back to the
//! canonical text form. Print order is the round-trip contract (ir.md
//! §13): phi incoming lists are emitted in printed-block order, so every
//! printed program re-parses exactly through `passes/cfg_parse.zig`.
//!
//! `src/cfg.zig` re-exports `print`, so `cfg.print` keeps working for IR
//! dumps and golden files. The round-trip white-box tests live here too —
//! they exercise the printer's defining property against the parser.

const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const cfg_parse = @import("cfg_parse.zig");

/// The round-trip tests parse and print; the parser itself lives in
/// `cfg_parse.zig`.
const parseText = cfg_parse.parseText;

// IR structures (cfg.zig), brought into scope under the bare names the
// printer uses.
const Type = cfg.Type;
const TypeDecl = cfg.TypeDecl;
const Param = cfg.Param;
const ValueState = cfg.ValueState;
const ConstValue = cfg.ConstValue;
const Value = cfg.Value;
const Instr = cfg.Instr;
const Op = cfg.Op;
const Bin = cfg.Bin;
const Proj = cfg.Proj;
const Index = cfg.Index;
const Construct = cfg.Construct;
const LoadMember = cfg.LoadMember;
const StoreMember = cfg.StoreMember;
const DirectCallee = cfg.DirectCallee;
const Callee = cfg.Callee;
const Call = cfg.Call;
const BuiltinId = cfg.BuiltinId;
const SysCallTarget = cfg.SysCallTarget;
const SysCall = cfg.SysCall;
const Phi = cfg.Phi;
const PhiIn = cfg.PhiIn;
const Terminator = cfg.Terminator;
const Switch = cfg.Switch;
const SwitchArm = cfg.SwitchArm;
const BasicBlock = cfg.BasicBlock;
const IrFunc = cfg.IrFunc;
const SlotMeta = cfg.SlotMeta;
const IrModule = cfg.IrModule;
const IrProgram = cfg.IrProgram;

// ---------------------------------------------------------------------------
// Printer (canonical text form)
// ---------------------------------------------------------------------------

/// Serialize a program back to the canonical IR text form (ir.md §9).
/// Values are printed by id (`%0, %1, …`), types are always explicit, and
/// terminators are always explicit — the output round-trips through the
/// parser.
pub fn print(program: *const IrProgram, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (program.modules) |m| {
        try w(&out, allocator, "module \"{s}\" {{\n", .{m.name});
        for (m.funcs) |f| try printFunc(&out, allocator, program.types, f);
        try w(&out, allocator, "}}\n", .{});
    }
    return out.toOwnedSlice(allocator);
}

fn w(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    try out.print(allocator, fmt, args);
}

fn printFunc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, types: []const TypeDecl, f: *const IrFunc) !void {
    try w(out, allocator, "    func @{s}(", .{f.name.text});
    for (f.params, 0..) |p, i| {
        if (i > 0) try w(out, allocator, ", ", .{});
        if (p.mode != .plain) try w(out, allocator, "{s} ", .{@tagName(p.mode)});
        try w(out, allocator, "{s}: ", .{p.name.text});
        try printType(out, allocator, types, p.type_);
    }
    try w(out, allocator, ") -> ", .{});
    try printType(out, allocator, types, f.ret);
    try w(out, allocator, " {{\n", .{});
    // Blocks print in value-definition order (ascending minimum value id)
    // so the text form's `%N` ids are sequential: the standalone parser
    // requires ids in text order (ir.md §4.1). A match's test chain, for
    // example, defines its `type_is`/`eq` values before the arm bodies,
    // while the arm blocks were created earlier; sorting keeps the text
    // self-consistent. Blocks whose instructions define no values (bare
    // `j` joins) sort after value-bearing blocks, and the entry block is
    // pinned first regardless (see `BlockOrder`).
    var order = try allocator.alloc(*const BasicBlock, f.blocks.len);
    defer allocator.free(order);
    for (f.blocks, 0..) |b, i| order[i] = b;
    std.mem.sort(*const BasicBlock, order, cfg.BlockOrder{ .entry = f.entry }, cfg.BlockOrder.lessThan);
    // Block → print position: phis print their incoming in text order.
    var block_index = std.AutoHashMap(*const BasicBlock, u32).init(allocator);
    defer block_index.deinit();
    for (order, 0..) |b, i| try block_index.put(b, @intCast(i));
    for (order) |b| {
        try w(out, allocator, "    {s}:\n", .{b.name});
        for (b.instrs) |instr| {
            if (instr.synth) continue; // re-inlined at its operand site
            try w(out, allocator, "        ", .{});
            try printInstr(out, allocator, types, instr, &block_index);
            try w(out, allocator, "\n", .{});
        }
        try w(out, allocator, "        ", .{});
        try printTerminator(out, allocator, types, b.terminator);
        try w(out, allocator, "\n", .{});
    }
    try w(out, allocator, "    }}\n", .{});
}

fn printType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, types: []const TypeDecl, t: Type) !void {
    switch (t) {
        .primitive => |k| try w(out, allocator, "{s}", .{@tagName(k)}),
        .named => |n| {
            if (n.id < types.len) {
                try w(out, allocator, "{s}", .{types[n.id].name()});
            } else {
                try w(out, allocator, "#{d}", .{n.id});
            }
            if (n.args.len > 0) {
                try w(out, allocator, "[", .{});
                for (n.args, 0..) |a, i| {
                    if (i > 0) try w(out, allocator, ", ", .{});
                    try printType(out, allocator, types, a);
                }
                try w(out, allocator, "]", .{});
            }
        },
        .param => |s| try w(out, allocator, "{s}", .{s}),
        .module => try w(out, allocator, "module", .{}),
        .cleanup => try w(out, allocator, "cleanup", .{}),
        .list => |inner| {
            try w(out, allocator, "list[", .{});
            try printType(out, allocator, types, inner.*);
            try w(out, allocator, "]", .{});
        },
        .box => |inner| {
            try w(out, allocator, "box[", .{});
            try printType(out, allocator, types, inner.*);
            try w(out, allocator, "]", .{});
        },
        .tuple => |elems| {
            try w(out, allocator, "tuple[", .{});
            for (elems, 0..) |e, i| {
                if (i > 0) try w(out, allocator, ", ", .{});
                try printType(out, allocator, types, e);
            }
            try w(out, allocator, "]", .{});
        },
        .function => |ft| {
            try w(out, allocator, "fn (", .{});
            for (ft.params, 0..) |p, i| {
                if (i > 0) try w(out, allocator, ", ", .{});
                if (p.mode != .plain) try w(out, allocator, "{s} ", .{@tagName(p.mode)});
                try printType(out, allocator, types, p.type_);
            }
            try w(out, allocator, ") -> ", .{});
            try printType(out, allocator, types, ft.ret.*);
        },
    }
}

fn printValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: *const Value) !void {
    try w(out, allocator, "%{d}", .{v.id});
}

/// Print an operand: inline literal constants materialized from the text
/// are printed as literals again (they have no def line), everything else
/// as `%id`.
fn printOperand(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: *const Value) !void {
    if (v.def) |def| {
        if (def.synth) {
            switch (def.op) {
                .const_ => |c| {
                    try printConst(out, allocator, c);
                    return;
                },
                else => {},
            }
        }
    }
    try printValue(out, allocator, v);
}

fn printConst(out: *std.ArrayList(u8), allocator: std.mem.Allocator, c: ConstValue) !void {
    switch (c) {
        .int => |i| try w(out, allocator, "{d}", .{i}),
        .float => |f| {
            // The IR parser distinguishes floats from ints by the '.';
            // `{d}` drops it for integral values (3.0 → "3"), so append
            // an explicit fraction. Non-finite values print as
            // inf/-inf/nan (no '.' either) — the parser accepts those
            // spellings as float literals.
            const start = out.items.len;
            try w(out, allocator, "{d}", .{f});
            const s = out.items[start..];
            if (std.mem.indexOfScalar(u8, s, '.') == null and
                !std.mem.eql(u8, s, "inf") and
                !std.mem.eql(u8, s, "-inf") and
                !std.mem.eql(u8, s, "nan"))
            {
                try out.appendSlice(allocator, ".0");
            }
        },
        .bool => |b| try w(out, allocator, "{s}", .{if (b) "true" else "false"}),
        .string => |s| {
            try w(out, allocator, "\"", .{});
            for (s) |ch| switch (ch) {
                '\n' => try w(out, allocator, "\\n", .{}),
                '\t' => try w(out, allocator, "\\t", .{}),
                '"' => try w(out, allocator, "\\\"", .{}),
                '\\' => try w(out, allocator, "\\\\", .{}),
                else => try out.append(allocator, ch),
            };
            try w(out, allocator, "\"", .{});
        },
        .void => try w(out, allocator, "void", .{}),
    }
}

fn opText(op: Op) []const u8 {
    return cfg.opInfo(std.meta.activeTag(op)).text;
}

fn printInstr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, types: []const TypeDecl, instr: *const Instr, block_index: *const std.AutoHashMap(*const BasicBlock, u32)) !void {
    // The lhs: one `%id: type` per result, comma-separated — a single
    // result for ordinary ops, several for the atomic destructure ops
    // (ir.md §5.3, §9).
    if (instr.results.len > 0) {
        for (instr.results, 0..) |v, i| {
            if (i > 0) try w(out, allocator, ", ", .{});
            try w(out, allocator, "%{d}: ", .{v.id});
            try printType(out, allocator, types, v.type_);
        }
        try w(out, allocator, " = ", .{});
    }
    switch (instr.op) {
        .const_ => |c| {
            try w(out, allocator, "const ", .{});
            try printConst(out, allocator, c);
        },
        .module_ref => |s| try w(out, allocator, "module_ref \"{s}\"", .{s}),
        .fn_ref => |n| try w(out, allocator, "fn_ref @{s}", .{n}),
        .neg, .not_, .num_cast, .any_pack_copy, .any_pack_move, .any_unpack_copy, .any_unpack_move, .cleanup_arm, .copy, .borrow, .move_, .tail, .unpack_struct, .unpack_tuple, .split_list, .read_tag, .read_payload => |v| {
            try w(out, allocator, "{s} ", .{opText(instr.op)});
            try printOperand(out, allocator, v);
        },
        .unpack_variant => |uv| {
            try w(out, allocator, "unpack_variant ", .{});
            try printOperand(out, allocator, uv.base);
            try w(out, allocator, ", #{d}", .{uv.tag});
        },
        .borrow_variant => |bv| {
            try w(out, allocator, "borrow_variant ", .{});
            try printOperand(out, allocator, bv.base);
            try w(out, allocator, ", #{d}", .{bv.tag});
        },
        .type_is => |ti| {
            try w(out, allocator, "type_is ", .{});
            try printOperand(out, allocator, ti.value);
            try w(out, allocator, ", ", .{});
            try printType(out, allocator, types, ti.type_);
        },
        .add, .sub, .mul, .div, .rem, .concat, .eq, .ne, .lt, .le, .gt, .ge => |bin| {
            try w(out, allocator, "{s} ", .{opText(instr.op)});
            try printOperand(out, allocator, bin.a);
            try w(out, allocator, ", ", .{});
            try printOperand(out, allocator, bin.b);
        },
        .load_member => |lm| {
            try w(out, allocator, "load_member ", .{});
            try printOperand(out, allocator, lm.module);
            try w(out, allocator, ", #{d}", .{lm.member});
        },
        .store_member => |sm| {
            try w(out, allocator, "store_member #{d}, ", .{sm.slot});
            try printOperand(out, allocator, sm.value);
        },
        .construct => |c| {
            try w(out, allocator, "construct", .{});
            if (c.tag) |tag| try w(out, allocator, " #{d}", .{tag});
            for (c.args, 0..) |arg, i| {
                const sep: []const u8 = if (i == 0) " " else ", ";
                try w(out, allocator, "{s}", .{sep});
                try printOperand(out, allocator, arg);
            }
        },
        .read_field, .read_tuple => |p| {
            try w(out, allocator, "{s} ", .{opText(instr.op)});
            try printOperand(out, allocator, p.base);
            try w(out, allocator, ", #{d}", .{p.index});
        },
        .read_index => |ix| {
            try w(out, allocator, "{s} ", .{opText(instr.op)});
            try printOperand(out, allocator, ix.base);
            try w(out, allocator, ", ", .{});
            try printOperand(out, allocator, ix.index);
        },
        .call => |c| {
            try w(out, allocator, "call ", .{});
            switch (c.callee) {
                .direct => |d| {
                    if (d.func) |f| {
                        try w(out, allocator, "@{s}", .{f.name.text});
                    } else {
                        try w(out, allocator, "@{s}", .{d.name});
                    }
                },
                .value => |v| try printValue(out, allocator, v),
            }
            for (c.args) |arg| {
                try w(out, allocator, ", ", .{});
                try printOperand(out, allocator, arg);
            }
        },
        .syscall => |sc| {
            try w(out, allocator, "syscall ", .{});
            switch (sc.target) {
                .builtin => |id| try w(out, allocator, "builtin#{s}", .{@tagName(id)}),
                .host_module => |hm| try w(out, allocator, "{s}#{s}", .{ hm.module, hm.member }),
            }
            for (sc.args) |arg| {
                try w(out, allocator, ", ", .{});
                try printOperand(out, allocator, arg);
            }
        },
        .phi => |phi| {
            try w(out, allocator, "phi ", .{});
            // The standalone parser recomputes predecessors in *text*
            // order (ir.md §4.3), so a printed phi must list its inputs in
            // the order its pred blocks appear in the text. In-memory the
            // incoming list is in block-creation order, which can differ
            // from the print order (blocks print by min-value-id, with
            // value-less blocks last — e.g. a nested short-circuit join's
            // outer phi lists the inner join, which prints earlier).
            const incoming = try allocator.alloc(PhiIn, phi.incoming.len);
            defer allocator.free(incoming);
            @memcpy(incoming, phi.incoming);
            std.mem.sort(PhiIn, incoming, block_index, struct {
                fn lt(m: *const std.AutoHashMap(*const BasicBlock, u32), a: PhiIn, b: PhiIn) bool {
                    return m.get(a.pred).? < m.get(b.pred).?;
                }
            }.lt);
            for (incoming, 0..) |inc, i| {
                if (i > 0) try w(out, allocator, ", ", .{});
                try w(out, allocator, "[", .{});
                try printOperand(out, allocator, inc.value);
                try w(out, allocator, ", {s}]", .{inc.pred.name});
            }
        },
        .drop_ => |v| {
            try w(out, allocator, "drop ", .{});
            try printOperand(out, allocator, v);
        },
        .cleanup_disarm => |v| {
            try w(out, allocator, "cleanup_disarm ", .{});
            try printOperand(out, allocator, v);
        },
        .cleanup_drop => |v| {
            try w(out, allocator, "cleanup_drop ", .{});
            try printOperand(out, allocator, v);
        },
    }
}

fn printTerminator(out: *std.ArrayList(u8), allocator: std.mem.Allocator, types: []const TypeDecl, term: Terminator) !void {
    _ = types;
    switch (term) {
        .ret => |v| {
            try w(out, allocator, "ret", .{});
            if (v) |val| {
                try w(out, allocator, " ", .{});
                try printOperand(out, allocator, val);
            }
        },
        .j => |b| try w(out, allocator, "j {s}", .{b.name}),
        .br => |bc| {
            try w(out, allocator, "br ", .{});
            try printOperand(out, allocator, bc.cond);
            try w(out, allocator, " ? {s} : {s}", .{ bc.then_.name, bc.else_.name });
        },
        .@"switch" => |s| {
            try w(out, allocator, "switch ", .{});
            try printOperand(out, allocator, s.disc);
            try w(out, allocator, " {{ ", .{});
            for (s.arms, 0..) |arm, i| {
                if (i > 0) try w(out, allocator, ", ", .{});
                try w(out, allocator, "#{d} -> {s}", .{ arm.tag, arm.block.name });
            }
            try w(out, allocator, " }}", .{});
        },
        .trap => try w(out, allocator, "trap", .{}),
        .tailcall => |tc| {
            try w(out, allocator, "tailcall @{s}", .{tc.name});
            for (tc.args) |a| {
                try w(out, allocator, ", ", .{});
                try printOperand(out, allocator, a);
            }
        },
    }
}
test "cfg round-trips through the printer" {
    const src =
        \\module "app" {
        \\    func @init() -> void {
        \\    entry:
        \\        %g: str = const "hello"
        \\        store_member #0, %g
        \\        ret
        \\    }
        \\    func @add(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %gt: bool = gt %a, %b
        \\        br %gt ? big : small
        \\    big:
        \\        %r1: int32 = add %a, %b
        \\        j join
        \\    small:
        \\        %r2: int32 = sub %b, %a
        \\        j join
        \\    join:
        \\        %r: int32 = phi [%r1, big], [%r2, small]
        \\        ret %r
        \\    }
        \\}
    ;
    var t1 = try parseText(src);
    defer t1.arena.deinit();

    const out1 = try print(&t1.program, std.testing.allocator);
    defer std.testing.allocator.free(out1);

    var t2 = try parseText(out1);
    defer t2.arena.deinit();
    const out2 = try print(&t2.program, std.testing.allocator);
    defer std.testing.allocator.free(out2);

    try std.testing.expectEqualStrings(out1, out2);
    // The reparse preserved the CFG shape.
    try std.testing.expectEqualStrings("join", t2.program.funcs[1].blocks[3].name);
}
test "cfg round-trips type_is and hostdata through the printer" {
    const src =
        \\module "app" {
        \\    func @use(a: any, h: hostdata) -> bool {
        \\    entry:
        \\        %t: bool = type_is %a, fn(int32) -> hostdata
        \\        ret %t
        \\    }
        \\}
    ;
    var t1 = try parseText(src);
    defer t1.arena.deinit();

    const out1 = try print(&t1.program, std.testing.allocator);
    defer std.testing.allocator.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "type_is") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "hostdata") != null);

    var t2 = try parseText(out1);
    defer t2.arena.deinit();
    const out2 = try print(&t2.program, std.testing.allocator);
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings(out1, out2);
}
test "cfg round-trips construct, tail, and read/take projections" {
    const text =
        \\module "m" {
        \\    func @init() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\    func @m.f(p: list[int32]) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1
        \\        %2: list[int32] = construct %1, %1
        \\        %3: int32 = read_index %2, %1
        \\        %4: int32, %5: list[int32] = split_list %2
        \\        %6: list[int32] = tail %2
        \\        ret %3
        \\    }
        \\}
    ;
    var t = try parseText(text);
    defer t.arena.deinit();

    const out = try print(&t.program, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "construct") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "read_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "split_list") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "%4: int32, %5: list[int32] = split_list %2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tail ") != null);
}
test "cfg round-trips call, syscall, and type_is" {
    var t = try parseText(
        \\module "m" {
        \\    func @init() -> void {
        \\    entry:
        \\        ret
        \\    }
        \\    func @m.f(x: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 1
        \\        %2: bool = type_is %0, int32
        \\        %3: int32 = call @m.g, %1, %0
        \\        %4: int32 = syscall builtin#peek, %1
        \\        ret %3
        \\    }
        \\    func @m.g(a: int32, b: int32) -> int32 {
        \\    entry:
        \\        %2: int32 = add %0, %1
        \\        ret %2
        \\    }
        \\}
    );
    defer t.arena.deinit();

    const f = t.program.funcs[1];
    const b = f.blocks[0];
    try std.testing.expectEqual(@as(usize, 4), b.instrs.len);
    try std.testing.expect(b.instrs[2].op == .call);
    const call = switch (b.instrs[2].op) {
        .call => |c| c,
        else => unreachable,
    };
    try std.testing.expect(call.callee == .direct);
    try std.testing.expectEqualStrings("m.g", call.callee.direct.func.?.name.text);
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expect(b.instrs[3].op == .syscall);

    // Direct call targets resolve to the callee's *IrFunc.
    const g = t.program.funcs[2];
    try std.testing.expect(call.callee.direct.func.? == g);
}
test "cfg round-trips a phi join with branching" {
    var t = try parseText(
        \\module "m" {
        \\    func @m.sign(value: int32) -> int32 {
        \\    entry:
        \\        %1: int32 = const 0
        \\        %2: bool = ge %0, %1
        \\        br %2 ? pos : neg
        \\    pos:
        \\        %3: int32 = const 1
        \\        j join
        \\    neg:
        \\        %4: int32 = const -1
        \\        j join
        \\    join:
        \\        %5: int32 = phi [%3, pos], [%4, neg]
        \\        ret %5
        \\    }
        \\}
    );
    defer t.arena.deinit();

    const f = t.program.funcs[0];
    try std.testing.expectEqual(@as(usize, 4), f.blocks.len);
    const join = f.blocks[3];
    const phi = switch (join.instrs[0].op) {
        .phi => |p| p,
        else => unreachable,
    };
    try std.testing.expectEqual(@as(usize, 2), phi.incoming.len);
    try std.testing.expectEqualStrings("pos", phi.incoming[0].pred.name);
    try std.testing.expectEqualStrings("neg", phi.incoming[1].pred.name);

    const out = try print(&t.program, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "phi [%3, pos], [%4, neg]") != null);
}
test "cfg round-trips module_ref with store_member slots" {
    var t = try parseText(
        \\module "m" {
        \\    func @init() -> void {
        \\    entry:
        \\        %0: module = module_ref "m"
        \\        %1: int32 = const 7
        \\        store_member #0, %1
        \\        ret
        \\    }
        \\}
    );
    defer t.arena.deinit();

    const m = t.program.modules[0];
    try std.testing.expectEqual(@as(usize, 1), m.slots.len);
    try std.testing.expect(m.slots[0].type_.primitive == .int32);
}
