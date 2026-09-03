const std = @import("std");
const model = @import("./model.zig");
const rng = @import("./rng.zig");

pub const Options = struct {
    seed: u64 = 1,
    statements: u32 = 60,
    funcs: u32 = 5,
    max_depth: u32 = 6,
};

/// Generate a complete self-checking Stilla program. The returned bytes are
/// owned by `alloc`. Same seed + same options => identical bytes.
pub fn generate(alloc: std.mem.Allocator, opts: Options) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var g = Gen{
        .alloc = a,
        .rng = .{ .state = opts.seed },
        .opts = opts,
        .out = std.array_list.Managed(u8).init(a),
        .locals = std.array_list.Managed(Local).init(a),
        .fns = std.array_list.Managed(FnInfo).init(a),
        .recs = std.array_list.Managed(RecFn).init(a),
        .structs = std.array_list.Managed(StructDecl).init(a),
        .unions = std.array_list.Managed(UnionDecl).init(a),
        .tuple_types = std.array_list.Managed(TupleDecl).init(a),
    };
    try g.run();
    return alloc.dupe(u8, g.out.items);
}

const IntW = model.IntW;
const IntVal = model.IntVal;

// -------- expression AST --------

const BinOp = enum { add, sub, mul, div, rem, band, bor, bxor };

const ShiftOp = enum { shl, shr };

const Expr = union(enum) {
    int_lit: IntVal,
    int_var: []const u8,
    cast: struct { inner: *Expr, to: IntW }, // inner is an int expr of known width
    int_bin: struct { op: BinOp, a: *Expr, b: *Expr },
    int_shift: struct { op: ShiftOp, a: *Expr, b: *Expr },
    int_if: struct { cond: *Expr, a: *Expr, b: *Expr },
    int_call: struct { callee: usize, args: []*Expr },
    bool_lit: bool,
    bool_var: []const u8,
    not: *Expr,
    and_or: struct { is_and: bool, a: *Expr, b: *Expr },
    icmp: struct { op: model.Cmp, a: *Expr, b: *Expr },
    scmp: struct { is_eq: bool, a: []const u8, b: []const u8 }, // str-variable compares
};

// -------- locals & scopes --------

const Local = struct { name: []const u8, value: model.Value };

const Bind = struct { name: []const u8, value: model.Value };

const VarRef = struct { name: []const u8, w: IntW };

// -------- acyclic helpers --------

const Param = struct { name: []const u8, w: IntW };

const FnInfo = struct {
    name: []const u8,
    res_w: IntW,
    params: []Param,
    body: *Expr,
};

// -------- recursion templates --------

const RecFn = struct {
    name: []const u8,
    is_count: bool, // count => if(count<=0){base}else{step + rf(count-1,next)}; else list recursion
    // count template exprs over an int32 param named "x"
    c_base: *Expr,
    c_step: *Expr,
    c_next: *Expr,
    // list template: base int32 literal; map over head int32 "h". When
    // `wild_head` is set the map never references the head and the pattern
    // is emitted as `[_, ..t]`.
    l_base: *Expr,
    l_map: *Expr,
    wild_head: bool = false,
};

const StructDecl = struct { name: []const u8, fields: []Field };
const Field = struct { name: []const u8, w: IntW };
const UnionDecl = struct { name: []const u8, variants: []Variant };
const Variant = struct { name: []const u8, payloads: []IntW };
const TupleDecl = struct { name: []const u8, ws: []IntW };

const WIDTHS = [_]IntW{ .i32, .i64, .u32, .u64 };

/// struct field names, indexed by field position (2..3 fields per struct)
const FIELD_NAMES = [_][]const u8{ "x", "y", "z" };

fn binOpName(op: BinOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem => "%",
        .band => "&",
        .bor => "|",
        .bxor => "^",
    };
}

fn shiftOpName(op: ShiftOp) []const u8 {
    return switch (op) {
        .shl => "<<",
        .shr => ">>",
    };
}

const Flav = enum {
    bind_int,
    check_int,
    bind_bool,
    check_bool,
    call_fn,
    rec_count,
    rec_list,
    float_exact,
    str_stmt,
    list_proj,
    tuple_stmt,
    struct_stmt,
    union_stmt,
    any_stmt,
    print_stmt,
    std_str,
    std_slice,
    std_pair,
    std_list,
    std_search,
    std_fold,
    std_cfold,
    std_tryfold,
    std_foldctx,
};

/// every flavor runs once (in this order), then random draws take over
const PRELUDE = [_]Flav{
    .check_int,  .bind_int,    .check_bool,  .call_fn,  .rec_count,
    .bind_bool,  .rec_list,    .float_exact, .str_stmt, .list_proj,
    .tuple_stmt, .struct_stmt, .union_stmt,  .any_stmt, .print_stmt,
    .std_str,    .std_slice,   .std_pair,    .std_list, .std_search,
    .std_fold,   .std_cfold,   .std_tryfold,
};

const FLAV_WEIGHTS = [_]struct { f: Flav, w: u32 }{
    .{ .f = .bind_int, .w = 6 },
    .{ .f = .check_int, .w = 6 },
    .{ .f = .bind_bool, .w = 2 },
    .{ .f = .check_bool, .w = 3 },
    .{ .f = .call_fn, .w = 3 },
    .{ .f = .rec_count, .w = 3 },
    .{ .f = .rec_list, .w = 1 },
    .{ .f = .float_exact, .w = 2 },
    .{ .f = .str_stmt, .w = 3 },
    .{ .f = .list_proj, .w = 1 },
    .{ .f = .tuple_stmt, .w = 1 },
    .{ .f = .struct_stmt, .w = 2 },
    .{ .f = .union_stmt, .w = 1 },
    .{ .f = .any_stmt, .w = 2 },
    .{ .f = .print_stmt, .w = 1 },
    .{ .f = .std_str, .w = 2 },
    .{ .f = .std_slice, .w = 2 },
    .{ .f = .std_pair, .w = 2 },
    .{ .f = .std_list, .w = 2 },
    .{ .f = .std_search, .w = 2 },
    .{ .f = .std_fold, .w = 1 },
    .{ .f = .std_cfold, .w = 2 },
    .{ .f = .std_tryfold, .w = 2 },
    .{ .f = .std_foldctx, .w = 1 },
};

const Gen = struct {
    alloc: std.mem.Allocator,
    rng: rng.Rng,
    opts: Options,
    out: std.array_list.Managed(u8),

    var_n: usize = 0,
    fn_n: usize = 0,
    rec_n: usize = 0,
    type_n: usize = 0,
    alias_n: usize = 0,
    msg_n: usize = 0,

    locals: std.array_list.Managed(Local),
    fns: std.array_list.Managed(FnInfo),
    recs: std.array_list.Managed(RecFn),
    structs: std.array_list.Managed(StructDecl),
    unions: std.array_list.Managed(UnionDecl),
    tuple_types: std.array_list.Managed(TupleDecl),

    /// While building expressions that live inside a function body, bitwise
    /// `|` / `^` are suppressed: stilla's frontend folds any such op whose
    /// operands include a function parameter into `&` (observed empirically),
    /// so emitting them there would make the runtime disagree with our model.
    fn_body_bits_restricted: bool = false,

    // a single fixed classify(any) helper, generated up front
    classify_name: []const u8 = "classify",
    classify_int_body: *Expr = undefined, // over param n (int32), returns int32
    classify_str_equal: []const u8 = "", // str payloads equal to this return classify_c; else classify_d
    classify_c: IntVal = undefined,
    classify_d: IntVal = undefined,

    // ASCII only (letters, digits, space, punctuation): the stdlib string
    // operations the generator models (case conversion, code-point indexing,
    // whitespace trimming, repeat) are all byte-exact on ASCII, so the model
    // stays honest for every constant emitted here. No `"` or `\` ever, so
    // values print raw inside string literals.
    const FIXED_STRS = [_][]const u8{
        "stilla", "hello",    "world", "abc",   "zz",       "q",       "seed",
        "Hello",  "hi there", "ok!",   "x y z", "  padded", "trail  ", "123",
        "A1b2",
    };
    const MSG_STRS = [_][]const u8{ "ok", "gen", "check", "prog", "step", "run", "calc", "verify", "scan", "dot" };

    const SEED_COUNT: usize = 8;

    // ---------- run & output helpers ----------

    fn run(self: *Gen) !void {
        try self.emitHeader();
        self.buildTypeDecls();
        self.buildHelpers();
        self.buildClassify();
        self.buildRecFns();
        try self.emitDecls();
        try self.emitMain();
    }

    fn emitHeader(self: *Gen) !void {
        const s = std.fmt.allocPrint(
            self.alloc,
            "// stsmith -- randomized Stilla program\n" ++
                "// seed={d} statements={d} funcs={d} max-depth={d}\n" ++
                "// Same seed + same options reproduce this file byte-for-byte.\n\n" ++
                "const builtin = import(\"builtin\");\n" ++
                "const string = import(\"string\");\n" ++
                "const lists = import(\"list\");\n" ++
                "const iter = import(\"iter\");\n" ++
                "using builtin.Option;\n" ++
                "using iter.Result;\n\n",
            .{ self.opts.seed, self.opts.statements, self.opts.funcs, self.opts.max_depth },
        ) catch unreachable;
        try self.out.appendSlice(s);
    }

    fn line(self: *Gen, comptime fmt: []const u8, args: anytype) !void {
        const s = std.fmt.allocPrint(self.alloc, "    " ++ fmt ++ "\n", args) catch unreachable;
        try self.out.appendSlice(s);
    }

    fn top(self: *Gen, comptime fmt: []const u8, args: anytype) !void {
        const s = std.fmt.allocPrint(self.alloc, fmt ++ "\n", args) catch unreachable;
        try self.out.appendSlice(s);
    }

    fn raw(self: *Gen, s: []const u8) !void {
        try self.out.appendSlice(s);
    }

    fn blank(self: *Gen) !void {
        try self.out.appendSlice("\n");
    }

    fn allocName(self: *Gen, comptime prefix: []const u8, counter: *usize) []const u8 {
        const n = counter.*;
        counter.* += 1;
        return std.fmt.allocPrint(self.alloc, "{s}{d}", .{ prefix, n }) catch unreachable;
    }

    fn newVar(self: *Gen) []const u8 {
        return self.allocName("v", &self.var_n);
    }
    fn newFn(self: *Gen) []const u8 {
        return self.allocName("f", &self.fn_n);
    }
    fn newRec(self: *Gen) []const u8 {
        return self.allocName("r", &self.rec_n);
    }
    fn newType(self: *Gen) []const u8 {
        return self.allocName("T", &self.type_n);
    }

    fn msg(self: *Gen) []const u8 {
        const n = self.msg_n;
        self.msg_n += 1;
        const base = MSG_STRS[n % MSG_STRS.len];
        return std.fmt.allocPrint(self.alloc, "{s}{d}", .{ base, n / MSG_STRS.len }) catch unreachable;
    }

    fn allocExpr(self: *Gen, e: Expr) *Expr {
        const p = self.alloc.create(Expr) catch unreachable;
        p.* = e;
        return p;
    }

    fn allocSlice(self: *Gen, comptime T: type, n: usize) []T {
        return self.alloc.alloc(T, n) catch unreachable;
    }

    fn pushLocal(self: *Gen, name: []const u8, value: model.Value) void {
        self.locals.append(.{ .name = name, .value = value }) catch unreachable;
    }

    // ---------- random values ----------

    fn lit(self: *Gen, w: IntW) IntVal {
        return switch (w) {
            .i32 => IntVal.mk(.i32, self.rng.range(-(1 << 18), 1 << 18)),
            .i64 => IntVal.mk(.i64, self.rng.range(-(1 << 38), 1 << 38)),
            .u32 => IntVal.fromBits(.u32, self.rng.next()),
            .u64 => IntVal.mk(.u64, @intCast(self.rng.range(0, 1 << 38))),
        };
    }

    fn pickStr(self: *Gen) []const u8 {
        return FIXED_STRS[self.rng.index(FIXED_STRS.len)];
    }

    fn anyBoolVar(self: *Gen) ?*Local {
        var last: ?*Local = null;
        for (self.locals.items) |*loc| {
            if (loc.value == .boolean) last = loc;
        }
        return last;
    }

    fn litSmall(self: *Gen, w: IntW) IntVal {
        const mag = self.rng.range(1, 13);
        return switch (w) {
            .i32, .i64 => IntVal.mk(w, if (self.rng.chance(50)) mag else -mag),
            .u32, .u64 => IntVal.mk(w, mag),
        };
    }

    fn pickVarOfWidth(self: *Gen, w: IntW, vars: []const VarRef) ?[]const u8 {
        _ = self;
        var last: ?[]const u8 = null;
        for (vars) |vr| {
            if (vr.w == w) last = vr.name;
        }
        return last;
    }

    fn pickVarOtherWidth(self: *Gen, w: IntW, vars: []const VarRef) ?VarRef {
        _ = self;
        var last: ?VarRef = null;
        for (vars) |vr| {
            if (vr.w != w) last = vr;
        }
        return last;
    }

    // ============ text rendering ============

    fn intText(self: *Gen, n: *Expr) []const u8 {
        return switch (n.*) {
            .int_lit => |v| self.litText(v),
            .int_var => |nm| nm,
            .cast => |c| std.fmt.allocPrint(self.alloc, "({s} as {s})", .{ self.intText(c.inner), model.typeName(c.to) }) catch unreachable,
            .int_bin => |b| std.fmt.allocPrint(self.alloc, "({s}) {s} ({s})", .{ self.intText(b.a), binOpName(b.op), self.intText(b.b) }) catch unreachable,
            .int_shift => |s| std.fmt.allocPrint(self.alloc, "({s}) {s} ({s})", .{ self.intText(s.a), shiftOpName(s.op), self.intText(s.b) }) catch unreachable,
            .int_if => |f| std.fmt.allocPrint(self.alloc, "if ({s}) {{ {s} }} else {{ {s} }}", .{ self.boolText(f.cond), self.intText(f.a), self.intText(f.b) }) catch unreachable,
            .int_call => |c| blk: {
                const fi = self.fns.items[c.callee];
                var texts = self.allocSlice([]const u8, c.args.len);
                for (c.args, 0..) |a, i| texts[i] = self.intText(a);
                const args = std.mem.join(self.alloc, ", ", texts) catch unreachable;
                break :blk std.fmt.allocPrint(self.alloc, "{s}({s})", .{ fi.name, args }) catch unreachable;
            },
            else => unreachable,
        };
    }

    fn boolText(self: *Gen, n: *Expr) []const u8 {
        return switch (n.*) {
            .bool_lit => |v| if (v) "true" else "false",
            .bool_var => |nm| nm,
            .not => |inner| std.fmt.allocPrint(self.alloc, "!({s})", .{self.boolText(inner)}) catch unreachable,
            .and_or => |ao| std.fmt.allocPrint(self.alloc, "({s}) {s} ({s})", .{
                self.boolText(ao.a),
                if (ao.is_and) "and" else "or",
                self.boolText(ao.b),
            }) catch unreachable,
            .icmp => |c| std.fmt.allocPrint(self.alloc, "({s}) {s} ({s})", .{ self.intText(c.a), model.cmpName(c.op), self.intText(c.b) }) catch unreachable,
            .scmp => |c| std.fmt.allocPrint(self.alloc, "({s}) {s} ({s})", .{ c.a, if (c.is_eq) "==" else "!=", c.b }) catch unreachable,
            else => unreachable,
        };
    }

    fn litText(self: *Gen, v: IntVal) []const u8 {
        var buf: [48]u8 = undefined;
        const s = model.printInt(&buf, v);
        return self.alloc.dupe(u8, s) catch unreachable;
    }

    // ============ evaluators ============

    fn lookInt(self: *Gen, binds: []const Bind, name: []const u8) ?IntVal {
        for (binds) |b| {
            if (std.mem.eql(u8, b.name, name)) {
                if (b.value == .int) return b.value.int;
                return null;
            }
        }
        for (self.locals.items) |loc| {
            if (std.mem.eql(u8, loc.name, name)) {
                if (loc.value == .int) return loc.value.int;
                return null;
            }
        }
        return null;
    }

    fn lookBool(self: *Gen, binds: []const Bind, name: []const u8) ?bool {
        for (binds) |b| {
            if (std.mem.eql(u8, b.name, name)) {
                if (b.value == .boolean) return b.value.boolean;
                return null;
            }
        }
        for (self.locals.items) |loc| {
            if (std.mem.eql(u8, loc.name, name)) {
                if (loc.value == .boolean) return loc.value.boolean;
                return null;
            }
        }
        return null;
    }

    fn lookStr(self: *Gen, binds: []const Bind, name: []const u8) ?[]const u8 {
        for (binds) |b| {
            if (std.mem.eql(u8, b.name, name)) {
                if (b.value == .str) return b.value.str;
                return null;
            }
        }
        for (self.locals.items) |loc| {
            if (std.mem.eql(u8, loc.name, name)) {
                if (loc.value == .str) return loc.value.str;
                return null;
            }
        }
        return null;
    }

    fn evalInt(self: *Gen, n: *Expr, binds: []const Bind) ?IntVal {
        return switch (n.*) {
            .int_lit => |v| v,
            .int_var => |nm| self.lookInt(binds, nm),
            .cast => |c| blk: {
                const inner = self.evalInt(c.inner, binds) orelse return null;
                break :blk IntVal.castInt(inner, c.to);
            },
            .int_bin => |b| blk: {
                const a = self.evalInt(b.a, binds) orelse return null;
                const bv = self.evalInt(b.b, binds) orelse return null;
                break :blk switch (b.op) {
                    .add => IntVal.add(a, bv),
                    .sub => IntVal.sub(a, bv),
                    .mul => IntVal.mul(a, bv),
                    .div => IntVal.div(a, bv) orelse return null,
                    .rem => IntVal.rem(a, bv) orelse return null,
                    .band => IntVal.bitAnd(a, bv),
                    .bor => IntVal.bitOr(a, bv),
                    .bxor => IntVal.bitXor(a, bv),
                };
            },
            .int_shift => |s| blk: {
                const a = self.evalInt(s.a, binds) orelse return null;
                const bv = self.evalInt(s.b, binds) orelse return null;
                break :blk switch (s.op) {
                    .shl => IntVal.shl(a, bv),
                    .shr => IntVal.shr(a, bv),
                };
            },
            .int_if => |f| blk: {
                const c = self.evalBool(f.cond, binds);
                break :blk if (c) self.evalInt(f.a, binds) else self.evalInt(f.b, binds);
            },
            .int_call => |c| self.evalCall(c.callee, c.args, binds),
            else => unreachable,
        };
    }

    fn evalBool(self: *Gen, n: *Expr, binds: []const Bind) bool {
        return switch (n.*) {
            .bool_lit => |v| v,
            .bool_var => |nm| self.lookBool(binds, nm).?,
            .not => |inner| !self.evalBool(inner, binds),
            .and_or => |ao| if (ao.is_and)
                self.evalBool(ao.a, binds) and self.evalBool(ao.b, binds)
            else
                self.evalBool(ao.a, binds) or self.evalBool(ao.b, binds),
            .icmp => |c| blk: {
                const a = self.evalInt(c.a, binds) orelse return false;
                const bv = self.evalInt(c.b, binds) orelse return false;
                break :blk IntVal.cmp(a, bv, c.op);
            },
            .scmp => |c| blk: {
                const a = self.lookStr(binds, c.a) orelse return false;
                const bv = self.lookStr(binds, c.b) orelse return false;
                break :blk if (c.is_eq) std.mem.eql(u8, a, bv) else !std.mem.eql(u8, a, bv);
            },
            .int_lit, .int_var, .cast, .int_bin, .int_shift, .int_if, .int_call => unreachable,
        };
    }

    fn evalCall(self: *Gen, callee: usize, args: []*Expr, binds: []const Bind) ?IntVal {
        const fi = self.fns.items[callee];
        var vals: []IntVal = self.allocSlice(IntVal, args.len);
        for (args, 0..) |arg, i| {
            vals[i] = self.evalInt(arg, binds) orelse return null;
        }
        var frame: []Bind = self.allocSlice(Bind, fi.params.len);
        for (fi.params, 0..) |p, i| {
            frame[i] = .{ .name = p.name, .value = .{ .int = vals[i] } };
        }
        return self.evalInt(fi.body, frame);
    }

    // ============ AST builders ============

    fn toVarRefs(self: *Gen) []VarRef {
        var n: usize = 0;
        for (self.locals.items) |loc| {
            if (loc.value == .int) n += 1;
        }
        const out = self.allocSlice(VarRef, n);
        var i: usize = 0;
        for (self.locals.items) |loc| {
            if (loc.value == .int) {
                out[i] = .{ .name = loc.name, .w = loc.value.int.w };
                i += 1;
            }
        }
        return out;
    }

    fn hasFnResult(self: *Gen, w: IntW, max_fn: usize) bool {
        var i: usize = 0;
        while (i < max_fn and i < self.fns.items.len) : (i += 1) {
            if (self.fns.items[i].res_w == w) return true;
        }
        return false;
    }

    fn pickFnResult(self: *Gen, w: IntW, max_fn: usize) usize {
        var matches: usize = 0;
        var i: usize = 0;
        while (i < max_fn and i < self.fns.items.len) : (i += 1) {
            if (self.fns.items[i].res_w == w) matches += 1;
        }
        const pick = self.rng.index(matches);
        var seen: usize = 0;
        i = 0;
        while (i < max_fn and i < self.fns.items.len) : (i += 1) {
            if (self.fns.items[i].res_w == w) {
                if (seen == pick) return i;
                seen += 1;
            }
        }
        unreachable;
    }

    fn leafInt(self: *Gen, w: IntW, vars: []const VarRef, max_fn: usize) *Expr {
        const same = self.pickVarOfWidth(w, vars);
        const other = self.pickVarOtherWidth(w, vars);
        const callable = self.hasFnResult(w, max_fn);

        // A bare literal is only unambiguous at int32 (its default type). For
        // other widths a literal must sit in a typed position, so prefer an
        // anchored leaf; a literal is only a fallback when nothing anchors.
        var weight: u64 = if (w == .i32) 3 else 0; // literal
        if (same != null) weight += 3;
        if (other != null) weight += 2;
        if (callable) weight += 2;

        if (weight == 0) return self.allocExpr(.{ .int_lit = self.lit(w) });
        var roll = self.rng.below(weight);
        if (same != null) {
            if (roll < 3) return self.allocExpr(.{ .int_var = same.? });
            roll -= 3;
        }
        if (other != null) {
            if (roll < 2) {
                const inner = self.allocExpr(.{ .int_var = other.?.name });
                return self.allocExpr(.{ .cast = .{ .inner = inner, .to = w } });
            }
            roll -= 2;
        }
        if (callable) {
            if (roll < 2) {
                const fi_i = self.pickFnResult(w, max_fn);
                const fi = self.fns.items[fi_i];
                const args = self.allocSlice(*Expr, fi.params.len);
                for (fi.params, 0..) |p, j| {
                    args[j] = self.bInt(p.w, 1, vars, fi_i, false);
                }
                return self.allocExpr(.{ .int_call = .{ .callee = fi_i, .args = args } });
            }
        }
        return self.allocExpr(.{ .int_lit = self.lit(w) });
    }

    fn randIntOp(self: *Gen, allow_div: bool) BinOp {
        // NB: bitwise `|` and `^` are never generated: stilla's lowering
        // folds them into `&` whenever an operand is not a compile-time
        // constant (function params, cast results, bound locals) — observed
        // empirically. `&` is correct everywhere, so it stays.
        const restrict = self.fn_body_bits_restricted;
        if (!allow_div) {
            return switch (self.rng.below(4)) {
                0 => .add,
                1 => .sub,
                2 => .mul,
                else => .band,
            };
        }
        _ = restrict;
        return switch (self.rng.below(6)) {
            0 => .add,
            1 => .sub,
            2 => .mul,
            3 => .div,
            4 => .rem,
            else => .band,
        };
    }

    fn bInt(self: *Gen, w: IntW, depth: u32, vars: []const VarRef, max_fn: usize, allow_div: bool) *Expr {
        if (depth == 0) return self.leafInt(w, vars, max_fn);
        const r = self.rng.below(100);
        if (r < 50) return self.leafInt(w, vars, max_fn);
        if (r < 88) {
            const op = self.randIntOp(allow_div);
            const a = self.bInt(w, depth - 1, vars, max_fn, allow_div);
            const b = self.bInt(w, depth - 1, vars, max_fn, allow_div);
            return self.allocExpr(.{ .int_bin = .{ .op = op, .a = a, .b = b } });
        }
        const op: ShiftOp = if (self.rng.chance(50)) .shl else .shr;
        const a = self.bInt(w, depth - 1, vars, max_fn, allow_div);
        const b = self.bInt(w, 1, vars, max_fn, allow_div);
        return self.allocExpr(.{ .int_shift = .{ .op = op, .a = a, .b = b } });
    }

    fn bBool(self: *Gen, depth: u32, vars: []const VarRef, max_fn: usize) *Expr {
        const have_bv = self.anyBoolVar() != null;
        const have_str2 = self.countStrVars() >= 2;
        if (depth == 0) return self.leafBool(have_bv, have_str2, vars, max_fn);
        const r = self.rng.below(100);
        // Short-circuit `and`/`or` combine two bool subtrees; the
        // evaluation order matches Stilla's (both short-circuit), so the
        // model stays honest. Earlier builds of stilla miscompiled some
        // if-converted `and`/`or` shapes ("optimizer invariant
        // violation") and generation was withheld; the frontend bug is
        // fixed, so the operands are exercised again.
        if (r < 50) return self.leafBool(have_bv, have_str2, vars, max_fn);
        if (r < 80) return self.allocExpr(.{ .not = self.bBool(depth - 1, vars, max_fn) });
        const is_and = self.rng.chance(50);
        return self.allocExpr(.{ .and_or = .{ .is_and = is_and, .a = self.bBool(depth - 1, vars, max_fn), .b = self.bBool(depth - 1, vars, max_fn) } });
    }

    fn countStrVars(self: *Gen) usize {
        var n: usize = 0;
        for (self.locals.items) |loc| {
            if (loc.value == .str) n += 1;
        }
        return n;
    }

    fn leafBool(self: *Gen, have_bv: bool, have_str2: bool, vars: []const VarRef, max_fn: usize) *Expr {
        var weight: u64 = 2; // literals
        if (have_bv) weight += 3;
        weight += 6; // int compare always available
        if (have_str2) weight += 2;

        var roll = self.rng.below(weight);
        if (have_bv) {
            if (roll < 3) {
                var nm: []const u8 = undefined;
                for (self.locals.items) |*loc| {
                    if (loc.value == .boolean) nm = loc.name;
                }
                return self.allocExpr(.{ .bool_var = nm });
            }
            roll -= 3;
        }
        if (roll < 2) return self.allocExpr(.{ .bool_lit = self.rng.chance(50) });
        roll -= 2;
        if (have_str2) {
            if (roll < 2) {
                var s1: []const u8 = undefined;
                var s2: []const u8 = undefined;
                var got = false;
                for (self.locals.items) |*loc| {
                    if (loc.value == .str) {
                        if (!got) {
                            s1 = loc.name;
                            got = true;
                        } else s2 = loc.name;
                    }
                }
                const is_eq = self.rng.chance(50);
                return self.allocExpr(.{ .scmp = .{ .is_eq = is_eq, .a = s1, .b = s2 } });
            }
            roll -= 2;
        }
        // int comparison (eq/ne exist only for byte/int32/uint32/float32/bool/str;
        // 64-bit widths get the ordering comparisons only)
        const cw = WIDTHS[self.rng.index(WIDTHS.len)];
        const a = self.bInt(cw, 1, vars, max_fn, false);
        const b = self.bInt(cw, 1, vars, max_fn, false);
        const six = cw == .i32 or cw == .u32;
        const op: model.Cmp = if (six)
            switch (self.rng.below(6)) {
                0 => .eq,
                1 => .ne,
                2 => .lt,
                3 => .le,
                4 => .gt,
                else => .ge,
            }
        else switch (self.rng.below(4)) {
            0 => .lt,
            1 => .le,
            2 => .gt,
            else => .ge,
        };
        return self.allocExpr(.{ .icmp = .{ .op = op, .a = a, .b = b } });
    }

    // ============ type-decl and function preparation ============

    fn buildTypeDecls(self: *Gen) void {
        // structs (1..3): fields are resolved per struct type, including
        // across structs that reuse field names (the former one-struct-per-
        // module limitation, fixed in the interpreter — see the removed
        // entry in README's avoided-behaviors list)
        const struct_count: u32 = @intCast(1 + self.rng.index(3));
        var s: usize = 0;
        while (s < struct_count) : (s += 1) {
            const fcount = 2 + self.rng.index(2); // 2..3 fields
            const sname = self.newType();
            const fields = self.allocSlice(Field, fcount);
            for (fields, 0..) |*f, j| {
                f.* = .{
                    // short field names, deliberately reused across structs:
                    // resolution must be per struct type
                    .name = FIELD_NAMES[j],
                    .w = WIDTHS[self.rng.index(WIDTHS.len)],
                };
            }
            self.structs.append(.{ .name = sname, .fields = fields }) catch unreachable;
        }
        // unions
        const union_count = 1 + @as(u32, @min(self.opts.funcs, 2));
        var u: usize = 0;
        while (u < union_count) : (u += 1) {
            const vcount = 2 + self.rng.index(2); // 2..3 variants
            const variants = self.allocSlice(Variant, vcount);
            for (variants, 0..) |*v, j| {
                const pcount = 1 + self.rng.index(2); // 1..2 payloads
                const payloads = self.allocSlice(IntW, pcount);
                for (payloads) |*pw| pw.* = WIDTHS[self.rng.index(WIDTHS.len)];
                v.* = .{
                    .name = std.fmt.allocPrint(self.alloc, "V{d}", .{j}) catch unreachable,
                    .payloads = payloads,
                };
            }
            self.unions.append(.{ .name = self.newType(), .variants = variants }) catch unreachable;
        }
        // tuple aliases
        const alias_count = 2;
        var t: usize = 0;
        while (t < alias_count) : (t += 1) {
            const ws = self.allocSlice(IntW, 2);
            for (ws) |*w| w.* = WIDTHS[self.rng.index(WIDTHS.len)];
            self.tuple_types.append(.{
                .name = self.allocName("t", &self.alias_n),
                .ws = ws,
            }) catch unreachable;
        }
    }

    fn buildHelpers(self: *Gen) void {
        var f: u32 = 0;
        while (f < self.opts.funcs) : (f += 1) {
            const arity = self.rng.index(3); // 0..2 params
            const params = self.allocSlice(Param, arity);
            var vars = self.allocSlice(VarRef, arity);
            for (params, 0..) |*p, i| {
                const w = WIDTHS[self.rng.index(WIDTHS.len)];
                const nm = std.fmt.allocPrint(self.alloc, "a{d}", .{i}) catch unreachable;
                p.* = .{ .name = nm, .w = w };
                vars[i] = .{ .name = nm, .w = w };
            }
            const res_w = WIDTHS[self.rng.index(WIDTHS.len)];
            const max_fn = self.fns.items.len;
            self.fn_body_bits_restricted = true;
            const body = self.bInt(res_w, 2, vars, max_fn, false);
            self.fn_body_bits_restricted = false;
            self.fns.append(.{
                .name = self.newFn(),
                .res_w = res_w,
                .params = params,
                .body = body,
            }) catch unreachable;
        }
    }

    fn buildClassify(self: *Gen) void {
        const vars = self.allocSlice(VarRef, 1);
        vars[0] = .{ .name = "n", .w = .i32 };
        const max_fn = self.fns.items.len;
        self.fn_body_bits_restricted = true;
        self.classify_int_body = self.bInt(.i32, 2, vars, max_fn, false);
        self.fn_body_bits_restricted = false;
        self.classify_str_equal = self.pickStr();
        self.classify_c = IntVal.mk(.i32, self.rng.range(1, 100));
        self.classify_d = IntVal.mk(.i32, self.rng.range(1, 100));
    }

    fn buildRecFns(self: *Gen) void {
        // two count-down recursion templates
        const xv = self.allocSlice(VarRef, 1);
        xv[0] = .{ .name = "x", .w = .i32 };
        var c: usize = 0;
        while (c < 2) : (c += 1) {
            self.fn_body_bits_restricted = true;
            const base = self.bInt(.i32, 2, xv, 0, false);
            const step = self.bInt(.i32, 2, xv, 0, false);
            const next = self.bInt(.i32, 2, xv, 0, false);
            self.fn_body_bits_restricted = false;
            self.recs.append(.{
                .name = self.newRec(),
                .is_count = true,
                .c_base = base,
                .c_step = step,
                .c_next = next,
                .l_base = undefined,
                .l_map = undefined,
            }) catch unreachable;
        }
        // one list recursion template; the head pattern is a wildcard when
        // the sampled map expression never reads it
        const wild_head = self.rng.chance(50);
        const hv = self.allocSlice(VarRef, 1);
        hv[0] = .{ .name = "h", .w = .i32 };
        const empty_vars = self.allocSlice(VarRef, 0);
        self.fn_body_bits_restricted = true;
        const l_base = self.bInt(.i32, 1, empty_vars, 0, false);
        const l_map = self.bInt(.i32, 2, if (wild_head) empty_vars else hv, 0, false);
        self.fn_body_bits_restricted = false;
        self.recs.append(.{
            .name = self.newRec(),
            .is_count = false,
            .c_base = undefined,
            .c_step = undefined,
            .c_next = undefined,
            .l_base = l_base,
            .l_map = l_map,
            .wild_head = wild_head,
        }) catch unreachable;
    }

    // ============ recursion evaluation ============

    fn evalRecC(self: *Gen, r: *RecFn, count: i32, x0: i32) IntVal {
        var binds = [_]Bind{.{ .name = "x", .value = .{ .int = IntVal.mk(.i32, x0) } }};
        if (count <= 0) return self.evalInt(r.c_base, binds[0..]).?;
        var acc = IntVal.mk(.i32, 0);
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            const s = self.evalInt(r.c_step, binds[0..]).?;
            acc = IntVal.add(acc, s);
            const nv = self.evalInt(r.c_next, binds[0..]).?;
            binds[0].value = .{ .int = nv };
        }
        const base_v = self.evalInt(r.c_base, binds[0..]).?;
        return IntVal.add(acc, base_v);
    }

    fn evalRecL(self: *Gen, r: *RecFn, elems: []const IntVal) IntVal {
        const no_binds = self.allocSlice(Bind, 0);
        var acc = self.evalInt(r.l_base, no_binds).?;
        var binds = [_]Bind{.{ .name = "h", .value = .{ .int = IntVal.mk(.i32, 0) } }};
        for (elems) |e| {
            binds[0].value = .{ .int = e };
            const m = self.evalInt(r.l_map, binds[0..]).?;
            acc = IntVal.add(acc, m);
        }
        return acc;
    }

    fn emitDecls(self: *Gen) !void {
        // structs
        for (self.structs.items) |sd| {
            try self.top("struct {s} {{", .{sd.name});
            for (sd.fields) |fl| {
                try self.top("    {s}: {s};", .{ fl.name, model.typeName(fl.w) });
            }
            try self.top("}}", .{});
            try self.blank();
        }
        // unions
        for (self.unions.items) |ud| {
            try self.top("union {s} {{", .{ud.name});
            var parts = self.allocSlice([]const u8, ud.variants.len);
            for (ud.variants, 0..) |v, i| {
                var pl = self.allocSlice([]const u8, v.payloads.len);
                for (v.payloads, 0..) |pw, j| pl[j] = model.typeName(pw);
                const payloads = std.mem.join(self.alloc, ", ", pl) catch unreachable;
                parts[i] = std.fmt.allocPrint(self.alloc, "{s}({s})", .{ v.name, payloads }) catch unreachable;
            }
            const joined = std.mem.join(self.alloc, ", ", parts) catch unreachable;
            try self.top("    {s}", .{joined});
            try self.top("}}", .{});
            try self.blank();
        }
        // tuple aliases
        for (self.tuple_types.items) |td| {
            try self.top("type {s} = tuple[{s}, {s}];", .{
                td.name,
                model.typeName(td.ws[0]),
                model.typeName(td.ws[1]),
            });
        }
        if (self.tuple_types.items.len > 0) try self.blank();

        // helper functions
        for (self.fns.items) |fi| {
            try self.writeFnDecl(&fi);
        }
        try self.writeClassify();
        for (self.recs.items) |*r| {
            try self.writeRecFn(r);
        }
    }

    fn writeFnDecl(self: *Gen, fi: *const FnInfo) !void {
        var pl = self.allocSlice([]const u8, fi.params.len);
        for (fi.params, 0..) |p, i| {
            pl[i] = std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ p.name, model.typeName(p.w) }) catch unreachable;
        }
        const params = std.mem.join(self.alloc, ", ", pl) catch unreachable;
        const head = std.fmt.allocPrint(self.alloc, "fn {s}({s}) -> {s} {{\n    ", .{ fi.name, params, model.typeName(fi.res_w) }) catch unreachable;
        try self.raw(head);
        try self.raw(self.intText(fi.body));
        try self.raw("\n}\n\n");
    }

    fn writeClassify(self: *Gen) !void {
        var cbuf: [24]u8 = undefined;
        var dbuf: [24]u8 = undefined;
        const arm = std.fmt.allocPrint(self.alloc, "        str text => if (text == \"{s}\") {{ {s} }} else {{ {s} }},\n", .{
            self.classify_str_equal,
            model.printInt(&cbuf, self.classify_c),
            model.printInt(&dbuf, self.classify_d),
        }) catch unreachable;
        const body = std.fmt.allocPrint(
            self.alloc,
            "fn {s}(value: any) -> int32 {{\n" ++
                "    match (value) {{\n" ++
                "        int32 n => {s},\n" ++
                "        {s}" ++
                "        _ => 0,\n" ++
                "    }}\n" ++
                "}}\n\n",
            .{ self.classify_name, self.intText(self.classify_int_body), arm },
        ) catch unreachable;
        try self.raw(body);
    }

    fn writeRecFn(self: *Gen, r: *RecFn) !void {
        if (r.is_count) {
            const s = std.fmt.allocPrint(
                self.alloc,
                "fn {s}(count: int32, x: int32) -> int32 {{\n" ++
                    "    if (count <= 0) {{ {s} }} else {{ ({s}) + {s}(count - 1, {s}) }}\n" ++
                    "}}\n\n",
                .{ r.name, self.intText(r.c_base), self.intText(r.c_step), r.name, self.intText(r.c_next) },
            ) catch unreachable;
            try self.raw(s);
        } else {
            const s = std.fmt.allocPrint(
                self.alloc,
                "fn {s}(xs: list[int32]) -> int32 {{\n" ++
                    "    match (xs) {{\n" ++
                    "        [] => {s},\n" ++
                    "        [{s}, ..t] => ({s}) + {s}(t),\n" ++
                    "    }}\n" ++
                    "}}\n\n",
                .{ r.name, self.intText(r.l_base), if (r.wild_head) "_" else "h", self.intText(r.l_map), r.name },
            ) catch unreachable;
            try self.raw(s);
        }
    }

    // ---------- statement dispatch ----------

    fn flavorFor(self: *Gen, i: usize) Flav {
        if (i < PRELUDE.len) return PRELUDE[i];
        var total: u32 = 0;
        for (FLAV_WEIGHTS) |fw| total += fw.w;
        var roll = self.rng.below(total);
        for (FLAV_WEIGHTS) |fw| {
            if (roll < fw.w) return fw.f;
            roll -= fw.w;
        }
        return .check_int;
    }

    fn emitMain(self: *Gen) !void {
        try self.raw("fn main() -> void {\n");

        // seed one scalar local of each kind so later statements always have
        // typed anchors to build on.
        const widths = [_]IntW{ .i32, .u32, .i64, .u64 };
        for (widths) |w| {
            const v = self.litSmall(w);
            const nm = self.newVar();
            try self.line("let {s}: {s} = {s};", .{ nm, model.typeName(w), self.litText(v) });
            self.pushLocal(nm, .{ .int = v });
        }
        const bnm = self.newVar();
        try self.line("let {s}: bool = true;", .{bnm});
        self.pushLocal(bnm, .{ .boolean = true });
        const snm = self.newVar();
        const sv = self.pickStr();
        try self.line("let {s} = \"{s}\";", .{ snm, sv });
        self.pushLocal(snm, .{ .str = sv });

        var i: usize = 0;
        while (i < self.opts.statements) : (i += 1) {
            const f = self.flavorFor(i);
            switch (f) {
                .bind_int => try self.sBindInt(),
                .check_int => try self.sCheckInt(),
                .bind_bool => try self.sBindBool(),
                .check_bool => try self.sCheckBool(),
                .call_fn => try self.sCallFn(),
                .rec_count => try self.sRecCount(),
                .rec_list => try self.sRecList(),
                .float_exact => try self.sFloat(),
                .str_stmt => try self.sStr(),
                .list_proj => try self.sListProj(),
                .tuple_stmt => try self.sTuple(),
                .struct_stmt => try self.sStruct(),
                .union_stmt => try self.sUnion(),
                .any_stmt => try self.sAny(),
                .print_stmt => try self.sPrint(),
                .std_str => try self.sStdStr(),
                .std_slice => try self.sStdSlice(),
                .std_pair => try self.sStdPair(),
                .std_list => try self.sStdList(),
                .std_search => try self.sStdSearch(),
                .std_fold => try self.sStdFold(),
                .std_cfold => try self.sStdCFold(),
                .std_tryfold => try self.sStdTryFold(),
                .std_foldctx => try self.sStdFoldCtx(),
            }
        }
        try self.raw("}\n");
    }

    fn buildChecked(self: *Gen, w: IntW, max_fn: usize, allow_div: bool) struct { e: *Expr, v: IntVal } {
        const vars = self.toVarRefs();
        var attempt: usize = 0;
        while (attempt < 6) : (attempt += 1) {
            const depth: u32 = @intCast(1 + self.rng.index(3));
            const e = self.bInt(w, depth, vars, max_fn, allow_div);
            if (self.evalInt(e, &.{})) |v| return .{ .e = e, .v = v };
        }
        const v = self.lit(w);
        return .{ .e = self.allocExpr(.{ .int_lit = v }), .v = v };
    }

    fn buildCheckedBool(self: *Gen, max_fn: usize) struct { e: *Expr, v: bool } {
        const vars = self.toVarRefs();
        const e = self.bBool(2, vars, max_fn);
        return .{ .e = e, .v = self.evalBool(e, &.{}) };
    }

    /// Assert that an int expression equals an expected value. Equality (==)
    /// exists only for byte/int32/uint32/float32/bool/str (Core §16.3), so
    /// 64-bit widths assert equality via an `and`-joined <= / >= on a bound
    /// local (referencing the value twice would duplicate a possibly-
    /// expensive or conditional expression). The short-circuit `and` also
    /// exercises the if-conversion path the generator used to avoid.
    fn intEqAssert(self: *Gen, e: []const u8, v: IntVal, m: []const u8) !void {
        const lit_s = self.litText(v);
        switch (v.w) {
            .i32, .u32 => try self.line("builtin.assert(({s}) == {s}, \"{s}\");", .{ e, lit_s, m }),
            .i64, .u64 => {
                const nm = self.newVar();
                try self.line("let {s}: {s} = {s};", .{ nm, model.typeName(v.w), e });
                try self.line("builtin.assert((({s}) <= {s}) and (({s}) >= {s}), \"{s}\");", .{ nm, lit_s, nm, lit_s, m });
            },
        }
    }

    fn sBindInt(self: *Gen) !void {
        const w = WIDTHS[self.rng.index(WIDTHS.len)];
        const got = self.buildChecked(w, self.fns.items.len, true);
        const nm = self.newVar();
        try self.line("let {s}: {s} = {s};", .{ nm, model.typeName(w), self.intText(got.e) });
        self.pushLocal(nm, .{ .int = got.v });
    }

    fn sCheckInt(self: *Gen) !void {
        const w = WIDTHS[self.rng.index(WIDTHS.len)];
        const got = self.buildChecked(w, self.fns.items.len, true);
        try self.intEqAssert(self.intText(got.e), got.v, self.msg());
    }

    fn sBindBool(self: *Gen) !void {
        const got = self.buildCheckedBool(self.fns.items.len);
        const nm = self.newVar();
        try self.line("let {s}: bool = {s};", .{ nm, self.boolText(got.e) });
        self.pushLocal(nm, .{ .boolean = got.v });
    }

    fn sCheckBool(self: *Gen) !void {
        const got = self.buildCheckedBool(self.fns.items.len);
        try self.line("builtin.assert(({s}) == {s}, \"{s}\");", .{ self.boolText(got.e), if (got.v) "true" else "false", self.msg() });
    }

    fn sCallFn(self: *Gen) !void {
        if (self.fns.items.len == 0) return;
        const fi_i = self.rng.index(self.fns.items.len);
        const fi = self.fns.items[fi_i];
        var args = self.allocSlice(*Expr, fi.params.len);
        for (fi.params, 0..) |p, i| {
            args[i] = self.buildChecked(p.w, fi_i, true).e;
        }
        const expected = self.evalCall(fi_i, args, &.{}).?;
        const nm = self.newVar();
        var texts = self.allocSlice([]const u8, fi.params.len);
        for (args, 0..) |a, i| texts[i] = self.intText(a);
        const joined = std.mem.join(self.alloc, ", ", texts) catch unreachable;
        try self.line("let {s}: {s} = {s}({s});", .{ nm, model.typeName(fi.res_w), fi.name, joined });
        self.pushLocal(nm, .{ .int = expected });
        try self.intEqAssert(nm, expected, self.msg());
    }

    fn sRecCount(self: *Gen) !void {
        // pick a count template
        var idx: usize = 0;
        var found = false;
        for (self.recs.items, 0..) |*r, i| {
            if (r.is_count) {
                if (!found or self.rng.chance(50)) {
                    idx = i;
                    found = true;
                }
            }
        }
        if (!found) return;
        const r = self.recs.items[idx];
        const hi: i64 = if (self.opts.max_depth < 1) 1 else @as(i64, self.opts.max_depth);
        const c0: i64 = self.rng.range(0, hi);
        const x0: i64 = self.rng.range(-4096, 4096);
        const exp = self.evalRecC(&self.recs.items[idx], @intCast(c0), @intCast(x0));
        try self.line("builtin.assert({s}({d}, {d}) == {s}, \"{s}\");", .{ r.name, c0, x0, self.litText(exp), self.msg() });
    }

    fn sRecList(self: *Gen) !void {
        var idx: usize = 0;
        var found = false;
        for (self.recs.items, 0..) |*r, i| {
            if (!r.is_count) {
                idx = i;
                found = true;
            }
        }
        if (!found) return;
        const r = self.recs.items[idx];
        const n = self.rng.index(5); // 0..4 elements
        const elems = self.allocSlice(IntVal, n);
        for (elems) |*e| e.* = IntVal.mk(.i32, self.rng.range(-2000, 2000));
        const exp = self.evalRecL(&self.recs.items[idx], elems);
        var texts = self.allocSlice([]const u8, n);
        for (elems, 0..) |e, i| texts[i] = self.litText(e);
        if (n == 0) {
            try self.line("builtin.assert({s}([]) == {s}, \"{s}\");", .{ r.name, self.litText(exp), self.msg() });
        } else {
            const joined = std.mem.join(self.alloc, ", ", texts) catch unreachable;
            try self.line("builtin.assert({s}([{s}]) == {s}, \"{s}\");", .{ r.name, joined, self.litText(exp), self.msg() });
        }
    }

    fn sFloat(self: *Gen) !void {
        const use64 = self.rng.chance(40);
        const w: IntW = if (use64) .i64 else .i32;
        // keep operands small enough that + - * are exactly representable
        // in the target float width (|result| <= 2^24 for f32, 2^53 for f64)
        const cap: i128 = if (use64) (1 << 26) else (1 << 12);
        // candidate locals of the right width and magnitude
        var cands = std.array_list.Managed(Local).init(self.alloc);
        for (self.locals.items) |loc| {
            if (loc.value == .int and loc.value.int.w == w) {
                const v = loc.value.int;
                if (@abs(IntVal.toI128(v)) <= cap) cands.append(loc) catch unreachable;
            }
        }
        if (cands.items.len == 0) return;
        const op_roll = self.rng.below(10);
        const is_div = op_roll == 9;

        var attempt: usize = 0;
        while (attempt < 40) : (attempt += 1) {
            const a = cands.items[self.rng.index(cands.items.len)];
            const b = cands.items[self.rng.index(cands.items.len)];
            const av = a.value.int;
            const bv = b.value.int;
            var q: ?IntVal = null;
            if (is_div) {
                if (IntVal.isZero(bv)) continue;
                if (IntVal.rem(av, bv)) |r| {
                    if (!IntVal.isZero(r)) continue;
                    q = IntVal.div(av, bv).?;
                } else continue;
            }
            // compute in the target float width
            const r: f64 = blk: {
                const fa: f64 = if (use64) model.toF64(av) else model.toF32(av);
                const fb: f64 = if (use64) model.toF64(bv) else model.toF32(bv);
                break :blk switch (op_roll) {
                    0, 1, 2 => fa + fb,
                    3, 4, 5 => fa - fb,
                    6, 7, 8 => fa * fb,
                    else => fa / fb,
                };
            };
            if (std.math.isNan(r) or std.math.isInf(r)) continue;
            if (r != @trunc(r)) continue;
            if (@abs(r) > 2.0 * @as(f64, @floatFromInt(if (use64) @as(i128, 1) << 62 else @as(i128, 1) << 30))) continue;
            const expected = model.fromFloat(r, w);
            if (is_div) {
                if (q) |qv| {
                    if (IntVal.toI128(expected) != IntVal.toI128(qv)) continue;
                }
            }
            const opc: []const u8 = switch (op_roll) {
                0, 1, 2 => "+",
                3, 4, 5 => "-",
                6, 7, 8 => "*",
                else => "/",
            };
            const ft = if (use64) "float64" else "float32";
            const back = model.typeName(w);
            const aCast = std.fmt.allocPrint(self.alloc, "({s} as {s})", .{ a.name, ft }) catch unreachable;
            const bCast = std.fmt.allocPrint(self.alloc, "({s} as {s})", .{ b.name, ft }) catch unreachable;
            const sum = std.fmt.allocPrint(self.alloc, "({s} {s} {s})", .{ aCast, opc, bCast }) catch unreachable;
            const whole = std.fmt.allocPrint(self.alloc, "({s} as {s})", .{ sum, back }) catch unreachable;
            try self.intEqAssert(whole, expected, self.msg());
            return;
        }
        // give up quietly if no safe pair found
    }

    fn sStr(self: *Gen) !void {
        const nstr = self.countStrVars();
        if (nstr == 0) return;
        const roll = self.rng.below(10);
        if (roll < 2) {
            // concat into a fresh local and verify it
            const s1 = self.pickStrName();
            const s2 = if (nstr >= 2) self.pickStrNameOther(s1) else s1;
            const v1 = self.lookStr(&.{}, s1).?;
            const v2 = self.lookStr(&.{}, s2).?;
            const cat = std.mem.concat(self.alloc, u8, &.{ v1, v2 }) catch unreachable;
            const nm = self.newVar();
            try self.line("let {s} = ({s} + {s});", .{ nm, s1, s2 });
            self.pushLocal(nm, .{ .str = cat });
            try self.line("builtin.assert({s} == \"{s}\", \"{s}\");", .{ nm, cat, self.msg() });
        } else if (roll < 4) {
            const nm = self.pickStrName();
            const v = self.lookStr(&.{}, nm).?;
            try self.line("builtin.assert(({s}) == \"{s}\", \"{s}\");", .{ nm, v, self.msg() });
        } else if (roll < 5) {
            const v = self.pickStr();
            const nm = self.newVar();
            try self.line("let {s} = \"{s}\";", .{ nm, v });
            self.pushLocal(nm, .{ .str = v });
        } else if (roll < 8) {
            // builtin.str on an int or bool local
            const pick = self.pickNumericLocal();
            if (pick == null) return;
            const loc = pick.?;
            const digits: []const u8 = switch (loc.value) {
                .int => |v| blk: {
                    var buf: [48]u8 = undefined;
                    const s = model.printInt(&buf, v);
                    break :blk self.alloc.dupe(u8, s) catch unreachable;
                },
                .boolean => |b| if (b) "true" else "false",
                .str => unreachable,
            };
            try self.line("builtin.assert(builtin.str({s}) == \"{s}\", \"{s}\");", .{ loc.name, digits, self.msg() });
        } else {
            // builtin.str of a bool constant
            try self.line("builtin.assert(builtin.str(true) == \"true\", \"{s}\");", .{self.msg()});
        }
    }

    fn pickStrName(self: *Gen) []const u8 {
        const n = self.countStrVars();
        const pick = self.rng.index(n);
        var i: usize = 0;
        for (self.locals.items) |loc| {
            if (loc.value == .str) {
                if (i == pick) return loc.name;
                i += 1;
            }
        }
        unreachable;
    }

    fn pickStrNameOther(self: *Gen, avoid: []const u8) []const u8 {
        var others: usize = 0;
        for (self.locals.items) |loc| {
            if (loc.value == .str and !std.mem.eql(u8, loc.name, avoid)) others += 1;
        }
        if (others == 0) return self.pickStrName();
        const pick = self.rng.index(others);
        var i: usize = 0;
        for (self.locals.items) |loc| {
            if (loc.value == .str and !std.mem.eql(u8, loc.name, avoid)) {
                if (i == pick) return loc.name;
                i += 1;
            }
        }
        unreachable;
    }

    fn pickNumericLocal(self: *Gen) ?Local {
        var count: usize = 0;
        for (self.locals.items) |loc| {
            if (loc.value == .int or loc.value == .boolean) count += 1;
        }
        if (count == 0) return null;
        const pick = self.rng.index(count);
        var i: usize = 0;
        for (self.locals.items) |loc| {
            if (loc.value == .int or loc.value == .boolean) {
                if (i == pick) return loc;
                i += 1;
            }
        }
        unreachable;
    }

    fn sListProj(self: *Gen) !void {
        const n = self.rng.index(5); // 0..4 elements
        const vals = self.allocSlice(IntVal, n);
        for (vals) |*v| v.* = IntVal.mk(.i32, self.rng.range(-5000, 5000));
        const ln = self.newVar();
        var texts = self.allocSlice([]const u8, n);
        for (vals, 0..) |v, i| texts[i] = self.litText(v);
        const elems = std.mem.join(self.alloc, ", ", texts) catch unreachable;
        if (n == 0) {
            try self.line("let {s}: list[int32] = [];", .{ln});
        } else {
            try self.line("let {s}: list[int32] = [{s}];", .{ ln, elems });
        }
        const wild = self.rng.chance(50); // [_, ..t]: expr never reads the head
        const hv = self.allocSlice(VarRef, 1);
        hv[0] = .{ .name = "h", .w = .i32 };
        self.fn_body_bits_restricted = true; // h is a pattern binding (behaves like a param)
        const hE = self.bInt(.i32, 2, if (wild) self.allocSlice(VarRef, 0) else hv, 0, false);
        self.fn_body_bits_restricted = false;
        var binds = [_]Bind{.{ .name = "h", .value = .{ .int = IntVal.mk(.i32, 0) } }};
        const expected: IntVal = if (n > 0) blk: {
            binds[0].value = .{ .int = vals[0] };
            break :blk self.evalInt(hE, binds[0..]).?;
        } else IntVal.mk(.i32, 777);
        const dv = IntVal.mk(.i32, 777);
        const htext = self.intText(hE);
        try self.line("builtin.assert(match ({s}) {{ [{s}, ..t] => {s}, [] => {s} }} == {s}, \"{s}\");", .{
            ln, if (wild) "_" else "h", htext, self.litText(dv), self.litText(expected), self.msg(),
        });
    }

    fn sTuple(self: *Gen) !void {
        if (self.tuple_types.items.len == 0) return;
        const td = self.tuple_types.items[self.rng.index(self.tuple_types.items.len)];
        const a = self.buildChecked(td.ws[0], self.fns.items.len, false);
        const b = self.buildChecked(td.ws[1], self.fns.items.len, false);
        const tv = self.newVar();
        const a0 = self.newVar();
        const a1 = self.newVar();
        try self.line("let {s}: {s} = ({s}, {s});", .{ tv, td.name, self.intText(a.e), self.intText(b.e) });
        // half the time one destructure slot is a wildcard; only the bound
        // side becomes a local and gets asserted
        if (self.rng.chance(50)) {
            if (self.rng.chance(50)) {
                try self.line("let ({s}, _) = {s};", .{ a0, tv });
                self.pushLocal(a0, .{ .int = a.v });
                try self.intEqAssert(a0, a.v, self.msg());
            } else {
                try self.line("let (_, {s}) = {s};", .{ a1, tv });
                self.pushLocal(a1, .{ .int = b.v });
                try self.intEqAssert(a1, b.v, self.msg());
            }
            return;
        }
        try self.line("let ({s}, {s}) = {s};", .{ a0, a1, tv });
        self.pushLocal(a0, .{ .int = a.v });
        self.pushLocal(a1, .{ .int = b.v });
        const use_first = self.rng.chance(50);
        if (use_first) {
            try self.intEqAssert(a0, a.v, self.msg());
        } else {
            try self.intEqAssert(a1, b.v, self.msg());
        }
    }

    fn sStruct(self: *Gen) !void {
        if (self.structs.items.len == 0) return;
        const sd = self.structs.items[self.rng.index(self.structs.items.len)];
        var texts = self.allocSlice([]const u8, sd.fields.len);
        var vals = self.allocSlice(IntVal, sd.fields.len);
        var parts = self.allocSlice([]const u8, sd.fields.len);
        for (sd.fields, 0..) |fl, i| {
            const got = self.buildChecked(fl.w, self.fns.items.len, false);
            vals[i] = got.v;
            texts[i] = self.intText(got.e);
            parts[i] = std.fmt.allocPrint(self.alloc, "{s}: ({s})", .{ fl.name, texts[i] }) catch unreachable;
        }
        const joined = std.mem.join(self.alloc, ", ", parts) catch unreachable;
        const sv = self.newVar();
        try self.line("let {s}: {s} = {s} {{ {s} }};", .{ sv, sd.name, sd.name, joined });
        const k = self.rng.index(sd.fields.len);
        const accessor = std.fmt.allocPrint(self.alloc, "({s}.{s})", .{ sv, sd.fields[k].name }) catch unreachable;
        try self.intEqAssert(accessor, vals[k], self.msg());
    }

    fn sUnion(self: *Gen) !void {
        if (self.unions.items.len == 0) return;
        const ud = self.unions.items[self.rng.index(self.unions.items.len)];
        const vi = self.rng.index(ud.variants.len);
        const vd = ud.variants[vi];
        var vals = self.allocSlice(IntVal, vd.payloads.len);
        var texts = self.allocSlice([]const u8, vd.payloads.len);
        for (vd.payloads, 0..) |pw, i| {
            const got = self.buildChecked(pw, self.fns.items.len, false);
            vals[i] = got.v;
            texts[i] = self.intText(got.e);
        }
        const uv = self.newVar();
        const payload_join = std.mem.join(self.alloc, ", ", texts) catch unreachable;
        try self.line("let {s}: {s} = {s}::{s}({s});", .{ uv, ud.name, ud.name, vd.name, payload_join });

        var arm_parts = std.array_list.Managed([]const u8).init(self.alloc);
        // Arm-shape sampling: 40% wildcard `_` in some payload positions of
        // the taken variant, 30% a collapsed `_` catch-all tail (pattern
        // arms only for a prefix of the variants), 30% fully-bound
        // exhaustive arms. A taken variant covered by the tail matches the
        // catch-all, so the expected value is the tail body (0).
        const shape = self.rng.below(10);
        const wild_payloads = shape < 4;
        const wild_tail = shape >= 4 and shape < 7;
        const split: usize = if (wild_tail) 1 + self.rng.index(ud.variants.len - 1) else ud.variants.len;
        var chosen_expected = IntVal.mk(.i32, 0);
        for (ud.variants, 0..) |v, j| {
            if (j >= split) break;
            const is_taken = (j == vi);
            var names = self.allocSlice([]const u8, v.payloads.len);
            var bound = self.allocSlice(VarRef, v.payloads.len);
            var bidx = self.allocSlice(usize, v.payloads.len);
            var nbound: usize = 0;
            for (v.payloads, 0..) |pw, k| {
                if (is_taken and wild_payloads and self.rng.chance(50)) {
                    names[k] = "_";
                } else {
                    names[k] = std.fmt.allocPrint(self.alloc, "q{d}_{d}", .{ j, k }) catch unreachable;
                    bound[nbound] = .{ .name = names[k], .w = pw };
                    bidx[nbound] = k;
                    nbound += 1;
                }
            }
            var body_text: []const u8 = "0";
            if (is_taken) {
                const refs = bound[0..nbound];
                var frame = self.allocSlice(Bind, nbound);
                for (refs, 0..) |r, k| {
                    frame[k] = .{ .name = r.name, .value = .{ .int = vals[bidx[k]] } };
                }
                self.fn_body_bits_restricted = true; // arm bindings behave like params
                const body = self.bInt(.i32, 2, refs, 0, false);
                self.fn_body_bits_restricted = false;
                chosen_expected = self.evalInt(body, frame).?;
                body_text = self.intText(body);
            }
            const pattern = if (v.payloads.len > 0) blk: {
                const args = std.mem.join(self.alloc, ", ", names) catch unreachable;
                break :blk std.fmt.allocPrint(self.alloc, "{s}::{s}({s})", .{ ud.name, v.name, args }) catch unreachable;
            } else std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ ud.name, v.name }) catch unreachable;
            const arm = std.fmt.allocPrint(self.alloc, "        {s} => {s},", .{ pattern, body_text }) catch unreachable;
            arm_parts.append(arm) catch unreachable;
        }
        if (wild_tail) {
            arm_parts.append("        _ => 0,") catch unreachable;
        }
        const arms = std.mem.join(self.alloc, "\n", arm_parts.items) catch unreachable;
        const whole = std.fmt.allocPrint(self.alloc, "    builtin.assert(match ({s}) {{\n{s}\n    }} == {s}, \"{s}\");", .{
            uv, arms, self.litText(chosen_expected), self.msg(),
        }) catch unreachable;
        try self.raw(whole);
        try self.raw("\n");
    }

    fn sAny(self: *Gen) !void {
        const roll = self.rng.below(10);
        const an = self.newVar();
        if (roll < 4) {
            // recover via `as`
            const got = self.buildChecked(.i32, self.fns.items.len, true);
            try self.line("let {s}: any = {s};", .{ an, self.intText(got.e) });
            try self.line("builtin.assert(({s} as int32) == {s}, \"{s}\");", .{ an, self.litText(got.v), self.msg() });
        } else if (roll < 8) {
            // classify an int payload
            const got = self.buildChecked(.i32, self.fns.items.len, true);
            try self.line("let {s}: any = {s};", .{ an, self.intText(got.e) });
            const frame = [_]Bind{.{ .name = "n", .value = .{ .int = got.v } }};
            const expected = self.evalInt(self.classify_int_body, frame[0..]).?;
            try self.line("builtin.assert(classify(move {s}) == {s}, \"{s}\");", .{ an, self.litText(expected), self.msg() });
        } else {
            // classify a str payload
            const v = self.pickStr();
            try self.line("let {s}: any = \"{s}\";", .{ an, v });
            const expected: IntVal = if (std.mem.eql(u8, v, self.classify_str_equal))
                self.classify_c
            else
                self.classify_d;
            try self.line("builtin.assert(classify(move {s}) == {s}, \"{s}\");", .{ an, self.litText(expected), self.msg() });
        }
    }

    fn sPrint(self: *Gen) !void {
        const loc = self.pickNumericLocal();
        if (loc == null) return;
        try self.line("builtin.print(builtin.str({s}));", .{loc.?.name});
    }

    // ============ stdlib string/list/iter statements ============
    //
    // These exercise the derived standard-library modules (string.st,
    // list.st, iter.st) the way the integer statements exercise the core
    // language: only calls whose results the generator can model exactly are
    // emitted, and each result is asserted. The generator only emits ASCII
    // strings, so the stdlib's Unicode operations (code-point indexing, case
    // conversion, whitespace trimming) reduce to byte operations in the
    // model. Lists are built with `lists.range` and fully consumed within
    // one statement, so no list value needs to be carried in the model.

    fn strEqAssert(self: *Gen, nm: []const u8, v: []const u8, m: []const u8) !void {
        try self.line("builtin.assert({s} == \"{s}\", \"{s}\");", .{ nm, v, m });
    }

    /// Assert a found Option[int32]: half the time via the `Some(_)`
    /// wildcard form (presence only), half via a payload equality check.
    fn assertOptionFound(self: *Gen, opt: []const u8, k: i64) !void {
        if (self.rng.chance(50)) {
            try self.line("builtin.assert(match ({s}) {{ Option::Some(_) => true, Option::None => false }}, \"{s}\");", .{ opt, self.msg() });
        } else {
            try self.line("builtin.assert(match ({s}) {{ Option::Some(v) => v == {d}, Option::None => false }}, \"{s}\");", .{ opt, k, self.msg() });
        }
    }

    /// ASCII case conversion; byte-exact for the ASCII strings emitted.
    fn asciiMap(self: *Gen, s: []const u8, to_upper: bool) []const u8 {
        const out = self.alloc.dupe(u8, s) catch unreachable;
        for (out) |*c| {
            if (to_upper) {
                if (c.* >= 'a' and c.* <= 'z') c.* -= 32;
            } else {
                if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
            }
        }
        return out;
    }

    /// Byte index of the first occurrence of `needle`, or null. An empty
    /// needle matches at index 0, mirroring string.st's documented behavior.
    fn strFind(_: *Gen, haystack: []const u8, needle: []const u8) ?usize {
        return std.mem.indexOf(u8, haystack, needle);
    }

    fn asciiTrim(s: []const u8) []const u8 {
        var start: usize = 0;
        while (start < s.len and isAsciiSpace(s[start])) start += 1;
        var end = s.len;
        while (end > start and isAsciiSpace(s[end - 1])) end -= 1;
        return s[start..end];
    }

    fn isAsciiSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn strRepeat(self: *Gen, s: []const u8, n: usize) []const u8 {
        const out = self.alloc.alloc(u8, s.len * n) catch unreachable;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            @memcpy(out[k * s.len ..][0..s.len], s);
        }
        return out;
    }

    /// string.len / upper / lower / is_empty on a str local.
    fn sStdStr(self: *Gen) !void {
        const s = self.pickStrName();
        const sv = self.lookStr(&.{}, s).?;
        const r = self.rng.below(10);
        if (r < 3) {
            const e = std.fmt.allocPrint(self.alloc, "string.len({s})", .{s}) catch unreachable;
            try self.intEqAssert(e, IntVal.mk(.i32, @intCast(sv.len)), self.msg());
        } else if (r < 6) {
            const w = self.newVar();
            const up = self.asciiMap(sv, true);
            try self.line("let {s} = string.upper({s});", .{ w, s });
            self.pushLocal(w, .{ .str = up });
            try self.strEqAssert(w, up, self.msg());
        } else if (r < 9) {
            const w = self.newVar();
            const lo = self.asciiMap(sv, false);
            try self.line("let {s} = string.lower({s});", .{ w, s });
            self.pushLocal(w, .{ .str = lo });
            try self.strEqAssert(w, lo, self.msg());
        } else {
            const e = std.fmt.allocPrint(self.alloc, "string.is_empty({s})", .{s}) catch unreachable;
            try self.line("builtin.assert(({s}) == {s}, \"{s}\");", .{ e, if (sv.len == 0) "true" else "false", self.msg() });
        }
    }

    /// string.substring / repeat / trim, each bound and asserted against the
    /// byte-exact ASCII model.
    fn sStdSlice(self: *Gen) !void {
        const s = self.pickStrName();
        const sv = self.lookStr(&.{}, s).?;
        const r = self.rng.below(10);
        if (r < 4) {
            const n: i64 = @intCast(sv.len);
            const i = self.rng.range(0, n); // inclusive: 0..n
            const j = self.rng.range(i, n);
            const w = self.newVar();
            const sub = sv[@intCast(i)..@intCast(j)];
            try self.line("let {s} = string.substring({s}, {d}, {d});", .{ w, s, i, j });
            self.pushLocal(w, .{ .str = sub });
            try self.strEqAssert(w, sub, self.msg());
        } else if (r < 7) {
            const k = self.rng.range(0, 3); // 0..3 repeats
            const w = self.newVar();
            const rep = self.strRepeat(sv, @intCast(k));
            try self.line("let {s} = string.repeat({s}, {d});", .{ w, s, k });
            self.pushLocal(w, .{ .str = rep });
            try self.strEqAssert(w, rep, self.msg());
        } else {
            const w = self.newVar();
            const tr = asciiTrim(sv);
            try self.line("let {s} = string.trim({s});", .{ w, s });
            self.pushLocal(w, .{ .str = tr });
            try self.strEqAssert(w, tr, self.msg());
        }
    }

    /// Two-string predicates: string.contains / starts_with / ends_with /
    /// index_of over a haystack local and a needle (a second str local, a
    /// literal, or the empty string literal).
    fn sStdPair(self: *Gen) !void {
        const a = self.pickStrName();
        const av = self.lookStr(&.{}, a).?;
        const needle_is_local = self.countStrVars() >= 2 and self.rng.chance(50);
        const b_local: ?[]const u8 = if (needle_is_local) self.pickStrNameOther(a) else null;
        const b_val: []const u8 = if (needle_is_local)
            self.lookStr(&.{}, b_local.?).?
        else if (self.rng.chance(15))
            ""
        else
            self.pickStr();
        const b_arg: []const u8 = if (needle_is_local)
            b_local.?
        else
            std.fmt.allocPrint(self.alloc, "\"{s}\"", .{b_val}) catch unreachable;

        const r = self.rng.below(11);
        if (r < 3) {
            const found = self.strFind(av, b_val) != null;
            try self.line("builtin.assert(string.contains({s}, {s}) == {s}, \"{s}\");", .{ a, b_arg, if (found) "true" else "false", self.msg() });
        } else if (r < 5) {
            const pre = std.mem.startsWith(u8, av, b_val);
            try self.line("builtin.assert(string.starts_with({s}, {s}) == {s}, \"{s}\");", .{ a, b_arg, if (pre) "true" else "false", self.msg() });
        } else if (r < 7) {
            const suf = std.mem.endsWith(u8, av, b_val);
            try self.line("builtin.assert(string.ends_with({s}, {s}) == {s}, \"{s}\");", .{ a, b_arg, if (suf) "true" else "false", self.msg() });
        } else {
            const io = self.newVar();
            try self.line("let {s} = string.index_of({s}, {s});", .{ io, a, b_arg });
            if (self.strFind(av, b_val)) |k| {
                try self.assertOptionFound(io, @intCast(k));
            } else {
                try self.line("builtin.assert(match ({s}) {{ Option::Some(v) => v == 0, Option::None => true }}, \"{s}\");", .{ io, self.msg() });
            }
        }
    }

    /// list.range binding with len and head self-checks. The range is
    /// inclusive [a, b] (len = b - a + 1); empty when a > b.
    fn sStdList(self: *Gen) !void {
        const a = self.rng.range(-8, 8);
        const empty = self.rng.chance(25);
        const b: i64 = if (empty) a - self.rng.range(1, 3) else self.rng.range(a, a + 9);
        const l = self.newVar();
        try self.line("let {s}: list[int32] = lists.range({d}, {d});", .{ l, a, b });
        const len: i64 = if (empty) 0 else b - a + 1;
        const len_e = std.fmt.allocPrint(self.alloc, "lists.len({s})", .{l}) catch unreachable;
        try self.intEqAssert(len_e, IntVal.mk(.i32, @intCast(len)), self.msg());
        // head consumes the list, so this must come after the len assert.
        if (!empty) {
            const h = std.fmt.allocPrint(self.alloc, "lists.head({s})", .{l}) catch unreachable;
            try self.assertOptionFound(h, a);
        } else {
            try self.line("builtin.assert(match (lists.head({s})) {{ Option::Some(v) => v == 0, Option::None => true }}, \"{s}\");", .{ l, self.msg() });
        }
    }

    /// list.contains / count / index_of with an equality lambda over a fresh
    /// list.range list. The needle is drawn from inside the range (70%) or
    /// strictly below it, so found/not-found outcomes are model-exact.
    fn sStdSearch(self: *Gen) !void {
        const a = self.rng.range(-8, 8);
        const empty = self.rng.chance(25);
        const b: i64 = if (empty) a - self.rng.range(1, 3) else self.rng.range(a, a + 9);
        const l = self.newVar();
        try self.line("let {s}: list[int32] = lists.range({d}, {d});", .{ l, a, b });
        const found = !empty and self.rng.chance(70);
        const needle: i64 = if (found) self.rng.range(a, b) else self.rng.range(a - 4, a - 1);
        const eq = "fn(borrow a: int32, borrow b: int32) -> bool { a == b }";
        const op = self.rng.below(10);
        if (op < 4) {
            const res = self.newVar();
            try self.line("let {s} = lists.contains({s}, {d}, {s});", .{ res, l, needle, eq });
            try self.line("builtin.assert({s} == {s}, \"{s}\");", .{ res, if (found) "true" else "false", self.msg() });
        } else if (op < 5) {
            const res = self.newVar();
            try self.line("let {s} = lists.count({s}, {d}, {s});", .{ res, l, needle, eq });
            try self.intEqAssert(res, IntVal.mk(.i32, if (found) 1 else 0), self.msg());
        } else {
            const res = self.newVar();
            try self.line("let {s} = lists.index_of({s}, {d}, {s});", .{ res, l, needle, eq });
            if (found) {
                try self.assertOptionFound(res, needle - a);
            } else {
                try self.line("builtin.assert(match ({s}) {{ Option::Some(v) => v == 0, Option::None => true }}, \"{s}\");", .{ res, self.msg() });
            }
        }
    }

    /// Inclusive [a, b] int32 range draw shared by the stdlib list/iter
    /// statements: empty 25% of the time, otherwise up to 10 elements.
    const Range = struct { a: i64, b: i64, empty: bool };

    fn drawRange(self: *Gen) Range {
        const a = self.rng.range(-8, 8);
        const empty = self.rng.chance(25);
        const b: i64 = if (empty) a - self.rng.range(1, 3) else self.rng.range(a, a + 9);
        return .{ .a = a, .b = b, .empty = empty };
    }

    /// init + wrapping int32 sum of the range elements (the fold model).
    fn foldRange(r: Range, init: IntVal) IntVal {
        var acc = init;
        var i: i64 = r.a;
        while (i <= r.b) : (i += 1) {
            acc = IntVal.add(acc, IntVal.mk(.i32, @intCast(i)));
        }
        return acc;
    }

    /// iter.fold with the addition step over a fresh list.range: the model is
    /// init + the sum of the inclusive range elements, wrapping like the
    /// runtime.
    fn sStdFold(self: *Gen) !void {
        const r = self.drawRange();
        const init = self.rng.range(-2000, 2000);
        const step = "fn(move acc: int32, borrow x: int32) -> int32 { acc + x }";
        const res = self.newVar();
        try self.line("let {s} = iter.fold(lists.range({d}, {d}), {d}, {s});", .{ res, r.a, r.b, init, step });
        try self.intEqAssert(res, foldRange(r, IntVal.mk(.i32, @intCast(init))), self.msg());
    }

    /// iter.consume_fold: the consuming variant of fold over a fresh range,
    /// same spec model. 20% of the time this flavor instead emits
    /// iter.each / iter.consume_each with a builtin.print action — a void
    /// action has no value to assert, so those are output-only statements.
    fn sStdCFold(self: *Gen) !void {
        if (self.rng.below(10) < 8) {
            const r = self.drawRange();
            const init = self.rng.range(-2000, 2000);
            const step = "fn(move acc: int32, move x: int32) -> int32 { acc + x }";
            const res = self.newVar();
            try self.line("let {s} = iter.consume_fold(lists.range({d}, {d}), {d}, {s});", .{ res, r.a, r.b, init, step });
            try self.intEqAssert(res, foldRange(r, IntVal.mk(.i32, @intCast(init))), self.msg());
        } else {
            const consuming = self.rng.chance(50);
            const call: []const u8 = if (consuming) "iter.consume_each" else "iter.each";
            const act: []const u8 = if (consuming)
                "fn(move x: int32) -> void { builtin.print(builtin.str(x)); }"
            else
                "fn(borrow x: int32) -> void { builtin.print(builtin.str(x)); }";
            const r = self.drawRange();
            try self.line("{s}(lists.range({d}, {d}), {s});", .{ call, r.a, r.b, act });
        }
    }

    /// iter.try_fold with a spec-modeled step: an always-`Complete` step
    /// folds the whole range (result `Complete(init + sum)`); an
    /// always-`Break` step stops at the first element (result `Break(a)`,
    /// or `Complete(init)` for an empty range). The result is asserted
    /// through a `match` whose catch-all `_` arm yields false.
    fn sStdTryFold(self: *Gen) !void {
        const r = self.drawRange();
        const init = self.rng.range(-2000, 2000);
        const res = self.newVar();
        if (self.rng.chance(40)) {
            const step = "fn(move acc: int32, borrow x: int32) -> iter.Result[int32, int32] { iter.Result::Break(x) }";
            try self.line("let {s} = iter.try_fold(lists.range({d}, {d}), {d}, {s});", .{ res, r.a, r.b, init, step });
            if (r.empty) {
                try self.line("builtin.assert(match ({s}) {{ Result::Complete(v) => v == {d}, _ => false }}, \"{s}\");", .{ res, init, self.msg() });
            } else {
                try self.line("builtin.assert(match ({s}) {{ Result::Break(v) => v == {d}, _ => false }}, \"{s}\");", .{ res, r.a, self.msg() });
            }
        } else {
            const step = "fn(move acc: int32, borrow x: int32) -> iter.Result[int32, int32] { iter.Result::Complete(acc + x) }";
            try self.line("let {s} = iter.try_fold(lists.range({d}, {d}), {d}, {s});", .{ res, r.a, r.b, init, step });
            const expected = foldRange(r, IntVal.mk(.i32, @intCast(init)));
            try self.line("builtin.assert(match ({s}) {{ Result::Complete(v) => v == {s}, _ => false }}, \"{s}\");", .{ res, self.litText(expected), self.msg() });
        }
    }

    /// iter.fold_with. The spec (StdLib §7) says the borrowed context equals
    /// the argument on every step, so a context-reading step models as
    /// `(acc op ctx) op x` with the fixed ctx constant. Context-reading
    /// steps currently miscompute at runtime (see README "Stilla behaviors
    /// stsmith avoids"), so they are sampled only 15% of the time inside
    /// this already-light flavor; otherwise the context-ignoring step is
    /// emitted, whose model is identical to fold.
    fn sStdFoldCtx(self: *Gen) !void {
        const r = self.drawRange();
        const init = self.rng.range(-2000, 2000);
        const ctx = self.rng.range(-100, 100);
        const read_ctx = self.rng.chance(15);
        const op_roll = self.rng.below(3);
        const opn: []const u8 = switch (op_roll) {
            0 => "+",
            1 => "-",
            else => "*",
        };
        const step = if (read_ctx)
            std.fmt.allocPrint(self.alloc, "fn(move acc: int32, borrow c: int32, borrow x: int32) -> int32 {{ acc {s} c {s} x }}", .{ opn, opn }) catch unreachable
        else
            "fn(move acc: int32, borrow c: int32, borrow x: int32) -> int32 { acc + x }";
        const ctxv = IntVal.mk(.i32, @intCast(ctx));
        var acc = IntVal.mk(.i32, @intCast(init));
        var i: i64 = r.a;
        while (i <= r.b) : (i += 1) {
            const xv = IntVal.mk(.i32, @intCast(i));
            acc = if (!read_ctx) IntVal.add(acc, xv) else blk: {
                const with_ctx = switch (op_roll) {
                    0 => IntVal.add(acc, ctxv),
                    1 => IntVal.sub(acc, ctxv),
                    else => IntVal.mul(acc, ctxv),
                };
                break :blk switch (op_roll) {
                    0 => IntVal.add(with_ctx, xv),
                    1 => IntVal.sub(with_ctx, xv),
                    else => IntVal.mul(with_ctx, xv),
                };
            };
        }
        const res = self.newVar();
        try self.line("let {s} = iter.fold_with(lists.range({d}, {d}), {d}, {d}, {s});", .{ res, r.a, r.b, init, ctx, step });
        try self.intEqAssert(res, acc, self.msg());
    }
};

test "same seed reproduces identical output" {
    const alloc = std.testing.allocator;
    const opts = Options{ .seed = 99, .statements = 40, .funcs = 4, .max_depth = 4 };
    const a = try generate(alloc, opts);
    defer alloc.free(a);
    const b = try generate(alloc, opts);
    defer alloc.free(b);
    try std.testing.expectEqualStrings(a, b);
    const c = try generate(alloc, Options{ .seed = 100, .statements = 40, .funcs = 4, .max_depth = 4 });
    defer alloc.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "generated program parses basic shape" {
    const alloc = std.testing.allocator;
    const src = try generate(alloc, Options{ .statements = 20, .funcs = 2 });
    defer alloc.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "fn main() -> void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const builtin = import(\"builtin\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const lists = import(\"list\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const string = import(\"string\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const iter = import(\"iter\");") != null);
}

test "prelude always emits try_fold match with wildcard arm" {
    const alloc = std.testing.allocator;
    // statements >= PRELUDE.len runs every prelude flavor, so these strings
    // are deterministic; the sampled wildcard forms and fold_with flavor are
    // deliberately not asserted.
    const src = try generate(alloc, Options{ .seed = 7, .statements = 40, .funcs = 3 });
    defer alloc.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "using iter.Result;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "iter.try_fold") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "_ => false") != null);
}
