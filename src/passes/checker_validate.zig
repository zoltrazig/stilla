//! Pass: phase-2 consumer checks — phase2-checker.md, Checks enabled by annotation (type mismatch, match
//! exhaustiveness, refutable patterns, recursive types, module-const
//! initialization order).
//! In: the per-module annotation from `checker_annotate` (expr_of,
//! type_of, call_sig) and the module's AST.
//! Out: the first semantic diagnostic, or the all-clear.
//!
//! Each check is a consumer of the annotation: the annotate pass fills
//! the side tables, and this pass decides. The recursive-types and
//! module-const initialization-order checks are structural walks over the
//! module's declarations (no annotation needed). The remaining checks
//! (non-capture, borrow lifetimes, drop-hook restrictions) live in
//! `checker_annotate`, where the binding-state machinery they need is;
//! the lowerer reports the structural diagnostics (unknown bindings,
//! missing fields, non-list iterables, unspecialized generics, …).

const std = @import("std");
const ast = @import("stilla").ast;
const cfg = @import("stilla").cfg;
const moduleinfo = @import("stilla").moduleinfo;
const type_resolve = @import("type_resolve.zig");
const checker = @import("checker.zig");

const CheckError = checker.CheckError;
const Frame = checker.Frame;
const Scope = checker.Scope;
const ModuleInfo = moduleinfo.ModuleInfo;
const ModuleAnnotation = checker.ModuleAnnotation;

/// Run the checks over one module.
pub fn validateModule(ck: *checker.Checker, info: *ModuleInfo) CheckError!void {
    const program = info.program orelse return;
    const ma = try ck.moduleAnnotation(info);

    const root = try ck.alloc().create(Scope);
    root.* = .{};
    const frame = try ck.alloc().create(Frame);
    frame.* = .{
        .ck = ck,
        .info = info,
        .ma = ma,
        .resolve = .{ .arena = ck.alloc(), .by_specifier = &ck.graph.?.by_specifier, .type_ids = &ck.graph.?.type_interner },
        .scope = root,
    };

    // Module-level structural checks (Core §11.3, Core §5).
    try checkRecursiveTypes(ck, info);
    try InitOrder.run(frame);

    // A host-backed opaque nominal type is declared only by a
    // standard-library or host-provided module interface (Core §11.8): a
    // Stilla source module may not declare one.
    if (info.kind == .source) {
        for (info.types) |tm| switch (tm.decl) {
            .opaque_ => |o| return ck.fail(o.span, "opaque host types may only be declared by a standard-library or host-provided module interface (Core §11.8)", .{}),
            else => {},
        };
    }

    for (program.items) |*item| {
        validateItem(frame, item) catch |err| switch (err) {
            // Per-item continuation: one broken declaration does not
            // hide its siblings' errors (the diagnostic is recorded).
            error.Diagnostic => {},
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
}

/// Run the checks over one module item (const type check, function
/// body checks). The frame is shared across items.
fn validateItem(frame: *Frame, item: *ast.ModuleItem) CheckError!void {
    switch (item.*) {
        .const_def => |*c| try validateConst(frame, c),
        .func_def => |*f| if (f.body) |body| {
            // Generic templates are never checked unspecialized (Core
            // §12.4); each used specialization is validated under the
            // concrete substitution (phase2-checker.md, Generic expansion).
            if (f.type_params.len == 0) try validateFunc(frame, f, body);
        },
        else => {},
    }
}

/// Run the checks over one monomorphized generic instance body
/// (phase2-checker.md, Generic expansion; Core §12.4). The instance was annotated against its
/// defining module by `checkInstanceBody`; this runs the consumer checks
/// over the same annotation.
pub fn validateMonomorphized(ck: *checker.Checker, info: *ModuleInfo, ma: *ModuleAnnotation, f: *const ast.FuncDef) CheckError!void {
    const root = try ck.alloc().create(Scope);
    root.* = .{};
    const frame = try ck.alloc().create(Frame);
    frame.* = .{
        .ck = ck,
        .info = info,
        .ma = ma,
        .resolve = .{ .arena = ck.alloc(), .by_specifier = &ck.graph.?.by_specifier, .type_ids = &ck.graph.?.type_interner },
        .scope = root,
    };
    try validateFunc(frame, f, f.body.?);
}

fn validateConst(frame: *Frame, c: *const ast.ConstDef) CheckError!void {
    if (c.type_ == null or c.init == null) return;
    const dt = frame.ma.type_of.get(&c.type_.?) orelse return;
    const it = frame.ma.expr_of.get(c.init.?) orelse return;
    if (compatible(dt, it)) return;
    return frame.ck.fail(c.span, "constant type mismatch: expected {s}, found {s}", .{
        try fmtType(frame.ck.alloc(), frame.resolve, dt),
        try fmtType(frame.ck.alloc(), frame.resolve, it),
    });
}

fn validateFunc(frame: *Frame, f: *const ast.FuncDef, body: *const ast.Block) CheckError!void {
    if (body.result) |*r| {
        const actual = frame.ma.expr_of.get(r) orelse return;
        const expected = if (f.ret != null)
            frame.ma.type_of.get(&f.ret.?) orelse return
        else
            cfg.Type{ .primitive = .void };
        if (!compatible(expected, actual)) {
            return frame.ck.fail(f.span, "return type mismatch: expected {s}, found {s}", .{
                try fmtType(frame.ck.alloc(), frame.resolve, expected),
                try fmtType(frame.ck.alloc(), frame.resolve, actual),
            });
        }
    }
    try validateBlock(frame, body);
}

fn validateBlock(frame: *Frame, b: *const ast.Block) CheckError!void {
    for (b.stmts) |*stmt| switch (stmt.*) {
        .let => |*l| try validateLet(frame, l),
        .drop => |*d| {
            _ = d;
        },
        .using => {},
        .expr => |*e| try validateExpr(frame, &e.expr),
        .empty => {},
    };
    if (b.result) |*r| try validateExpr(frame, r);
}

fn validateLet(frame: *Frame, l: *const ast.LetStmt) CheckError!void {
    try checkRefutable(frame, &l.pattern);
    try validateExpr(frame, l.init);
    if (l.type_ != null) {
        const dt = frame.ma.type_of.get(&l.type_.?) orelse return;
        const it = frame.ma.expr_of.get(l.init) orelse return;
        if (compatible(dt, it)) return;
        return frame.ck.fail(l.span, "let type mismatch: expected {s}, found {s}", .{
            try fmtType(frame.ck.alloc(), frame.resolve, dt),
            try fmtType(frame.ck.alloc(), frame.resolve, it),
        });
    }
}

/// `let` and `match` require irrefutable patterns (Core §18 *Patterns*);
/// type-test and literal patterns are refutable and accepted only by
/// `match`. List-with-rest, tuple, struct, path, and wildcard patterns are
/// irrefutable.
fn checkRefutable(frame: *Frame, p: *const ast.Pattern) CheckError!void {
    switch (p.*) {
        .type_test, .literal => return frame.ck.fail(p.span(), "refutable pattern not allowed here", .{}),
        else => {},
    }
}

fn validateExpr(frame: *Frame, e: *const ast.Expr) CheckError!void {
    switch (e.*) {
        .int, .float, .string, .bool, .void, .import => {},
        .path => |*p| switch (p.tail) {
            .construct => |*sc| for (sc.fields) |*f| try validateExpr(frame, f.value),
            .variant => |*v| if (v.args) |args| {
                for (args) |*a| try validateExpr(frame, a);
            },
            .none => {},
        },
        .paren => |*p| try validateExpr(frame, p.inner),
        .tuple => |*t| for (t.elems) |*el| try validateExpr(frame, el),
        .list => |*l| for (l.elems) |*el| try validateExpr(frame, el),
        .lambda => |*lam| {
            // Lambdas are annotated but get no argument checks today.
            _ = lam;
        },
        .if_ => |*i| {
            try validateExpr(frame, i.cond);
            try validateBlock(frame, i.then);
            if (i.else_) |else_e| try validateExpr(frame, else_e);
        },
        .match => |*m| try validateMatch(frame, m),
        .block => |*b| try validateBlock(frame, b.block),
        .unary => |*u| try validateUnary(frame, u),
        .binary => |*b| try validateBinary(frame, b),
        .move => {},
        .cast => |*c| try validateCast(frame, c),
        .member => |*mm| try validateExpr(frame, mm.object),
        .call => |*c| try validateCall(frame, c),
        .specialize => |*s| try validateExpr(frame, s.operand),
    }
}

fn validateUnary(frame: *Frame, u: *const ast.Unary) CheckError!void {
    try validateExpr(frame, u.operand);
    const t = frame.ma.expr_of.get(u.operand) orelse return;
    // `never` coerces to every type (Core §13.2).
    if (isNever(t)) return;
    switch (u.op) {
        .neg => {
            if (!isNumeric(t)) return frame.ck.fail(u.span, "unary '-' accepts int32, uint32, int64, uint64, or float32 (Core §16.3)", .{});
        },
        .not => {
            if (!isBool(t)) return frame.ck.fail(u.span, "unary '!' requires a bool operand (Core §16.3)", .{});
        },
    }
}

fn validateBinary(frame: *Frame, b: *const ast.Binary) CheckError!void {
    try validateExpr(frame, b.lhs);
    try validateExpr(frame, b.rhs);
    const l = frame.ma.expr_of.get(b.lhs) orelse return;
    const r = frame.ma.expr_of.get(b.rhs) orelse return;
    // `never` coerces to every type (Core §13.2): a never operand
    // satisfies the operator's requirement when the other side does.
    // `any` deliberately does NOT: Core §16.3 defines no operator on
    // `any` (only `as` and `match` type-testing).
    const never = isNever(l) or isNever(r);
    switch (b.op) {
        .and_, .or_ => {
            if (!((isBool(l) and isBool(r)) or (never and (isBool(l) or isBool(r))))) {
                return frame.ck.fail(b.span, "logical operator requires bool operands (Core §16.3)", .{});
            }
        },
        // Equality is defined only for byte, int32, uint32, float32,
        // bool, and str — never for `any`, structs, unions, tuples,
        // lists, boxes, functions, or modules (Core §16.3).
        .eq, .ne => {
            if (!(never or (isEqScalar(l) and isEqScalar(r) and cfg.Type.eql(l, r)))) {
                return frame.ck.fail(b.span, "equality is defined for byte, int32, uint32, float32, bool, and str only (Core §16.3)", .{});
            }
        },
        // Ordering accepts operands of the same numeric type (Core §16.3).
        .lt, .le, .gt, .ge => {
            if (!(never or (isOrderNumeric(l) and isOrderNumeric(r) and cfg.Type.eql(l, r)))) {
                return frame.ck.fail(b.span, "ordering comparison requires matching numeric operands (Core §16.3)", .{});
            }
        },
        // Bitwise ops accept operands of the same integer type —
        // `int32 & int32 -> int32`, `uint32 | uint32 -> uint32`.
        // They operate on the raw 32-bit patterns (never trap);
        // `byte` has no arithmetic, `float32`/`bool`/`str` have no
        // bit pattern (Core §16.3).
        .bitand, .bitor, .bitxor => {
            if (!(never or (isInt(l) and isInt(r) and cfg.Type.eql(l, r)))) {
                return frame.ck.fail(b.span, "bitwise operator requires matching int32/uint32 operands (Core §16.3)", .{});
            }
        },
        // Shifts accept operands of the same integer type — `int32 <<
        // int32 -> int32`, `uint32 >> uint32 -> uint32`. `byte` has no
        // arithmetic, `float32`/`bool`/`str` have no bit patterns to
        // shift (Core §16.3).
        .shl, .shr => {
            if (!(never or (isInt(l) and isInt(r) and cfg.Type.eql(l, r)))) {
                return frame.ck.fail(b.span, "shift operator requires matching int32/uint32 operands (Core §16.3)", .{});
            }
        },
        .add, .sub, .mul, .div, .rem => {
            // Core §16.3: `%` is the truncated remainder for `int32`/
            // `uint32`/`float32` alike; `float32 %` follows IEEE binary32
            // (C `fmod`, Rust `%`) and never traps (Runtime §7.2).
            const numeric = never or (isNumeric(l) and isNumeric(r) and cfg.Type.eql(l, r));
            const str_concat = b.op == .add and isStr(l) and isStr(r);
            if (!numeric and !str_concat) {
                return frame.ck.fail(b.span, "type mismatch in operator (Core §16.3)", .{});
            }
        },
    }
}

/// Operator typing per Core §16.3 and §18 *Conversion*: `int32 ↔ float32`
/// casts, and `any as T` (an invalid recovery traps at runtime, Runtime
/// §7.2 — not a compile-time error).
/// True when a match arm pattern is irrefutable: a wildcard or a
/// plain identifier binding the whole scrutinee (Core §13.3).
fn armIsIrrefutable(p: *const ast.Pattern) bool {
    return switch (p.*) {
        .wildcard => true,
        .path => |pp| pp.tail == .none,
        else => false,
    };
}

fn validateCast(frame: *Frame, c: *const ast.Cast) CheckError!void {
    try validateExpr(frame, c.operand);
    const src = frame.ma.expr_of.get(c.operand) orelse return;
    const dst = frame.ma.type_of.get(&c.target) orelse return;
    // `hostdata` is tagless (Core §11.7): no cast is defined from or to
    // it. In particular `any as hostdata` is invalid — a tagless payload
    // cannot be named as a recovery target (Core §11.6, §11.6.1).
    if (dst == .primitive and dst.primitive == .hostdata) {
        return frame.ck.fail(c.span, "invalid cast: 'hostdata' has no cast (Core §11.7)", .{});
    }
    // An `any` source recovers by tag (Core §11.6.1) into a concrete
    // target: `any`, `never`, and `hostdata` are not valid recovery
    // targets (Core §16.3). `never` coerces to every type (Core §13.2).
    if (src == .primitive and src.primitive == .never) return;
    if (src == .primitive and src.primitive == .any) {
        if (dst == .primitive and (dst.primitive == .never or dst.primitive == .any)) {
            return frame.ck.fail(c.span, "invalid cast: an 'any' can only be recovered as a concrete type (Core §16.3)", .{});
        }
        return;
    }
    if (validNumCast(src, dst)) return;
    return frame.ck.fail(c.span, "invalid cast", .{});
}

/// The numeric `as` pairs, exactly as Core §16.3 lists them. No identity
/// casts (`int32 as int32`). This predicate is separate from the
/// arithmetic `isNumeric` set: `byte + byte` and `uint32 + uint32` are
/// not defined by Core §16.3 (that is Phase 5 numeric-semantics work), so
/// enabling a cast must not enable arithmetic.
fn validNumCast(src: cfg.Type, dst: cfg.Type) bool {
    if (src != .primitive or dst != .primitive) return false;
    const s = src.primitive;
    const d = dst.primitive;
    // The uniform conversion family (Core §16.3): every pair of the
    // seven conversion types {byte, int32, uint32, i64, u64, float32,
    // f64} is legal — the self pair (a cast naming the source's own
    // type) is the byte conversion at the LLIR level and is not a
    // language cast.
    return switch (s) {
        .byte => d == .int32 or d == .uint32 or d == .int64 or d == .uint64 or d == .float32 or d == .float64,
        .int32 => d == .byte or d == .uint32 or d == .int64 or d == .uint64 or d == .float32 or d == .float64,
        .uint32 => d == .byte or d == .int32 or d == .int64 or d == .uint64 or d == .float32 or d == .float64,
        .int64 => d == .byte or d == .int32 or d == .uint32 or d == .uint64 or d == .float32 or d == .float64,
        .uint64 => d == .byte or d == .int32 or d == .uint32 or d == .int64 or d == .float32 or d == .float64,
        .float32 => d == .byte or d == .int32 or d == .uint32 or d == .int64 or d == .uint64 or d == .float64,
        .float64 => d == .byte or d == .int32 or d == .uint32 or d == .int64 or d == .uint64 or d == .float32,
        else => false,
    };
}

fn validateCall(frame: *Frame, c: *const ast.Call) CheckError!void {
    try validateExpr(frame, c.callee);
    for (c.args) |*a| try validateExpr(frame, a);
    // Generic calls are checked against their FuncInstance's monomorphic
    // signature; non-generic calls against the recorded call signature.
    const sig_t: ?cfg.Type = if (frame.ma.call_of.get(c)) |inst|
        inst.signature
    else
        frame.ma.call_sig.get(c);
    const resolved = sig_t orelse return;
    if (resolved != .function) return;
    const sig = resolved.function;
    if (c.args.len != sig.params.len) {
        return frame.ck.fail(c.span, "expected {d} arguments, found {d}", .{ sig.params.len, c.args.len });
    }
    for (c.args, 0..) |*a, i| {
        const at = frame.ma.expr_of.get(a) orelse continue;
        if (compatible(sig.params[i].type_, at)) continue;
        return frame.ck.fail(a.span(), "argument type mismatch: expected {s}, found {s}", .{
            try fmtType(frame.ck.alloc(), frame.resolve, sig.params[i].type_),
            try fmtType(frame.ck.alloc(), frame.resolve, at),
        });
    }
}

fn validateMatch(frame: *Frame, m: *const ast.MatchExpr) CheckError!void {
    try validateExpr(frame, m.scrutinee);
    const ma = frame.ma;
    const scrut_t = ma.expr_of.get(m.scrutinee) orelse {
        for (m.arms) |*arm| try validateExpr(frame, arm.body);
        return;
    };

    const is_any = scrut_t == .primitive and scrut_t.primitive == .any;

    // Type-test patterns are refutable and accepted only by `match`, only
    // for an `any` scrutinee (Core §14.7, §18 *Patterns*).
    if (!is_any) {
        for (m.arms) |*arm| {
            if (arm.pattern == .type_test) {
                return frame.ck.fail(arm.pattern.span(), "type-test pattern requires an 'any' scrutinee", .{});
            }
        }
    }

    if (is_any) {
        // The tag space of `any` is open (Core §11.6.2): a wildcard arm is
        // required.
        var has_wildcard = false;
        for (m.arms) |*arm| {
            if (arm.pattern == .wildcard) {
                has_wildcard = true;
                break;
            }
        }
        if (!has_wildcard) return frame.ck.fail(m.span, "match over 'any' must include a wildcard arm", .{});
    } else if (scrut_t == .named) {
        // A match over a union must cover every variant (Core §13.3, §18
        // *Match*) unless a wildcard arm exists.
        const ud = moduleinfo.unionDecl(frame.resolve, frame.info, frame.resolve.typeNameOf(scrut_t.named.id) orelse return) orelse return;
        var has_wildcard = false;
        const covered = try frame.ck.alloc().alloc(bool, ud.variants.len);
        @memset(covered, false);
        for (m.arms) |*arm| {
            // A wildcard or plain-identifier arm is irrefutable (Core
            // §13.3): it covers every not-yet-covered variant.
            if (arm.pattern == .wildcard or armIsIrrefutable(&arm.pattern)) {
                has_wildcard = true;
                break;
            }
            if (arm.pattern == .path) {
                const pp = &arm.pattern.path;
                if (pp.tail == .variant) {
                    const name = type_resolve.joinPath(frame.ck.alloc(), pp.path) orelse continue;
                    // Resolve the arm's leading path to its declaration
                    // and compare with the scrutinee's union declaration —
                    // not the unqualified names, which differ under a
                    // `using ... as` alias (`using builtin.Option as Opt`
                    // matches `Opt::Some(..)` against `Option`; Core §2.8).
                    const tm = type_resolve.resolveTypeName(frame.resolve, frame.info, name) orelse continue;
                    const final = type_resolve.followAlias(frame.resolve, frame.info, tm) orelse continue;
                    if (final.decl != .union_) continue;
                    if (final.decl.union_ != ud) continue;
                    if (moduleinfo.variantIndex(final.decl.union_, pp.tail.variant.name.text)) |idx| {
                        covered[@intCast(idx)] = true;
                    }
                }
            }
        }
        if (!has_wildcard) {
            for (ud.variants, 0..) |_, i| {
                if (!covered[i]) return frame.ck.fail(m.span, "match is not exhaustive: missing variant", .{});
            }
        }
    }

    for (m.arms) |*arm| try validateExpr(frame, arm.body);
}

// ---------------------------------------------------------------------------
// Recursive types without indirection (Core §11.3, §18 *Recursion*)
// ---------------------------------------------------------------------------

/// A local struct or union declaration, a node of the storage graph.
const TypeNode = union(enum) {
    struct_: *const ast.StructDef,
    union_: *const ast.UnionDef,

    fn name(self: TypeNode) []const u8 {
        return switch (self) {
            .struct_ => |s| s.name.text,
            .union_ => |u| u.name.text,
        };
    }
};

const DfsColor = enum { white, gray, black };

/// What a single-segment written type name denotes locally: a struct/union
/// declaration, or a transparent type alias (its own type parameters and
/// target written type). Null when the name is not a local struct/union/
/// alias — a type parameter, a primitive, indirection (box/list/function),
/// or a `using` alias to another module.
const LocalRef = union(enum) {
    node: TypeNode,
    alias: AliasRef,
};

/// A module-level transparent alias (Core §11.2): the alias's own type
/// parameters and its target written type. The target is walked with the
/// parameters bound to the reference's type arguments.
const AliasRef = struct {
    params: []const ast.Ident,
    target: ast.Type,
};

/// Resolve a single-segment written type name to a `LocalRef`, falling
/// back to module-level `using` type aliases to local declarations (Core
/// §2.8). Alias targets are not followed here — the walk expands them —
/// except for `using` aliases, which have no parameters and name real
/// members (phase 1 rejects `using`→`using` chains).
fn localRef(info: *ModuleInfo, name: []const u8) ?LocalRef {
    if (info.typeMember(name)) |tm| switch (tm.decl) {
        .struct_ => |s| return .{ .node = .{ .struct_ = s } },
        .union_ => |u| return .{ .node = .{ .union_ = u } },
        .alias => |ad| return .{ .alias = .{ .params = ad.type_params, .target = ad.target } },
        // An opaque host type has no fields or variants and therefore no
        // storage edges (Core §11.3): it terminates the walk.
        .opaque_ => return null,
    };
    // No local type member: a module-level `using` type alias to a local
    // declaration keeps the direct edge (Core §2.8).
    const a = info.alias(name) orelse return null;
    if (a.target != .type) return null;
    if (!std.mem.eql(u8, a.target.type.module, info.specifier)) return null;
    return localRef(info, a.target.type.name);
}

/// Recursive inline storage is forbidden (Core §11.3): every recursive
/// storage cycle must pass through indirection such as `box[T]`, `list[T]`,
/// or a function type. Named references and tuples keep the direct edge;
/// box/list/function break it.
///
/// The walk is a DFS over the module's declarations. A generic reference
/// (a named type with type arguments) is explored with the arguments
/// substituted for the callee's parameters (see `SubEnv`), so a cycle is a
/// re-entry of the same declaration under the same substitution — the DFS
/// stack carries the (declaration, substitution) pairs currently being
/// expanded. The substitution keeps `box[T]`/`list[T]`/function positions
/// from producing false positives on legal programs such as `struct Node {
/// x: Pair[Node]; }` with `struct Pair[T] { v: box[T]; }`.
///
/// Known limitations (documented, not handled here): a cross-module
/// generic instantiation (`m.B[Node]` storing `Node` inline) is skipped —
/// closing it needs cross-module type resolution; and a substitution depth
/// cap (`max_subst_depth`) rejects pathologically nested instantiations
/// whose substitution contexts grow without repeating (`struct B[T] {
/// v: B[B[T]]; }`), which the fixed point of the contexts would never
/// terminate on.
fn checkRecursiveTypes(ck: *checker.Checker, info: *ModuleInfo) CheckError!void {
    const alloc = ck.alloc();
    const program = info.program orelse return;

    var nodes = std.ArrayList(TypeNode).empty;
    for (program.items) |*item| switch (item.*) {
        .struct_def => |*s| try nodes.append(alloc, .{ .struct_ = s }),
        .union_def => |*u| try nodes.append(alloc, .{ .union_ = u }),
        else => {},
    };
    if (nodes.items.len == 0) return;

    var index = std.StringHashMapUnmanaged(u32).empty;
    for (nodes.items, 0..) |n, i| try index.put(alloc, n.name(), @intCast(i));

    // `colors` memoizes fully explored non-generic (no-substitution) visits
    // only: a declaration explored without an instantiation context is
    // context-free, so skipping it again is sound. Generic visits are
    // tracked on the stack and never memoized — a different instantiation
    // may still form a cycle.
    const colors = try alloc.alloc(DfsColor, nodes.items.len);
    @memset(colors, .white);
    var stack = std.ArrayList(StackEntry).empty;
    for (nodes.items, 0..) |_, i| {
        if (colors[i] != .white) continue;
        try visitTypeNode(ck, info, nodes.items, index, colors, &stack, 0, null, i);
    }
}

/// The maximum nested substitution depth: generic descents, alias-target
/// expansions, and parameter substitutions. Deep enough for any realistic
/// program; it bounds substitution contexts that grow without repeating
/// (`B[B[T]]`-style) and circular alias chains.
const max_subst_depth: u32 = 64;

/// A (declaration, substitution) pair currently being expanded on the DFS
/// stack; re-entering the same pair is the back edge that fails the check.
const StackEntry = struct {
    node: usize,
    env: ?*const SubEnv,
};

/// A substitution frame: a callee's type-parameter names mapped to the
/// written argument types they denote in the current instantiation. Args
/// are substituted under the caller's frame before being stored, so a
/// frame's values are fully resolved with respect to every outer context.
const SubEnv = struct {
    map: std.StringHashMapUnmanaged(*const ast.Type) = .empty,
};

/// Build the substitution frame for a callee from its parameters and the
/// reference's written arguments, each substituted under `env`. An identity
/// binding (a parameter passed itself, `B[T]` inside `B`) is dropped: it
/// adds no information and would let the walk loop on `T` -> `T`.
fn buildEnv(ck: *checker.Checker, env: ?*const SubEnv, params: []const ast.Ident, args: []const ast.Type) CheckError!SubEnv {
    var result = SubEnv{};
    for (params, args) |*p, *a| {
        const sub = try substType(ck, env, a);
        if (sub == .named) {
            if (sub.named.path.len == 1 and std.mem.eql(u8, sub.named.path[0].text, p.text)) continue;
        }
        const ptr = try ck.alloc().create(ast.Type);
        ptr.* = sub;
        try result.map.put(ck.alloc(), p.text, ptr);
    }
    return result;
}

/// Substitute the parameter references of the current frame in a written
/// type: a single-segment name bound in `env` denotes its argument; nested
/// positions (type arguments, tuple elements, list/box inners) are
/// substituted recursively. Function types are returned unchanged — they
/// break storage edges, so nothing inside them is ever walked.
fn substType(ck: *checker.Checker, env: ?*const SubEnv, t: *const ast.Type) CheckError!ast.Type {
    const alloc = ck.alloc();
    switch (t.*) {
        .primitive => return t.*,
        .named => |n| {
            if (n.path.len == 1) {
                if (env) |e| {
                    if (e.map.get(n.path[0].text)) |arg| return arg.*;
                }
            }
            if (n.type_args) |args| {
                const new_args = try alloc.alloc(ast.Type, args.len);
                var changed = false;
                for (args, 0..) |*a, i| {
                    new_args[i] = try substType(ck, env, a);
                    if (!typesEqual(a, &new_args[i])) changed = true;
                }
                if (!changed) return t.*;
                return .{ .named = .{ .span = n.span, .path = n.path, .type_args = new_args } };
            }
            return t.*;
        },
        .list => |l| {
            const el = try substType(ck, env, l.elem);
            if (typesEqual(l.elem, &el)) return t.*;
            const p = try alloc.create(ast.Type);
            p.* = el;
            return .{ .list = .{ .span = l.span, .elem = p } };
        },
        .box => |b| {
            const inner = try substType(ck, env, b.inner);
            if (typesEqual(b.inner, &inner)) return t.*;
            const p = try alloc.create(ast.Type);
            p.* = inner;
            return .{ .box = .{ .span = b.span, .inner = p } };
        },
        .tuple => |tp| {
            const new_elems = try alloc.alloc(ast.Type, tp.elems.len);
            var changed = false;
            for (tp.elems, 0..) |*e, i| {
                new_elems[i] = try substType(ck, env, e);
                if (!typesEqual(e, &new_elems[i])) changed = true;
            }
            if (!changed) return t.*;
            return .{ .tuple = .{ .span = tp.span, .elems = new_elems } };
        },
        .function => return t.*,
    }
}

/// Structural equality of two written types (spans ignored — substituted
/// copies are arena-allocated fresh and must compare equal to the originals
/// they replace).
fn typesEqual(a: *const ast.Type, b: *const ast.Type) bool {
    switch (a.*) {
        .primitive => |p| switch (b.*) {
            .primitive => |q| return q.kind == p.kind,
            else => return false,
        },
        .named => |n| switch (b.*) {
            .named => |m| {
                if (n.path.len != m.path.len) return false;
                for (n.path, m.path) |x, y| {
                    if (!std.mem.eql(u8, x.text, y.text)) return false;
                }
                if ((n.type_args == null) != (m.type_args == null)) return false;
                if (n.type_args) |na| {
                    const mb = m.type_args.?;
                    if (na.len != mb.len) return false;
                    for (na, mb) |*x, *y| {
                        if (!typesEqual(x, y)) return false;
                    }
                }
                return true;
            },
            else => return false,
        },
        .list => |l| switch (b.*) {
            .list => |m| return typesEqual(l.elem, m.elem),
            else => return false,
        },
        .box => |bx| switch (b.*) {
            .box => |m| return typesEqual(bx.inner, m.inner),
            else => return false,
        },
        .tuple => |tp| switch (b.*) {
            .tuple => |m| {
                if (tp.elems.len != m.elems.len) return false;
                for (tp.elems, m.elems) |*x, *y| {
                    if (!typesEqual(x, y)) return false;
                }
                return true;
            },
            else => return false,
        },
        .function => |f| switch (b.*) {
            .function => |g| {
                if (f.params.len != g.params.len) return false;
                for (f.params, g.params) |x, y| {
                    if (x.mode != y.mode) return false;
                    if (!typesEqual(x.type_, y.type_)) return false;
                }
                return typesEqual(f.ret, g.ret);
            },
            else => return false,
        },
    }
}

/// Two substitution frames are equal when they bind the same names to
/// structurally equal types (null and an empty frame are distinct: a
/// parameterless context differs from a bare non-generic reference).
fn envEqual(a: ?*const SubEnv, b: ?*const SubEnv) bool {
    if (a == null or b == null) return a == b;
    if (a.?.map.count() != b.?.map.count()) return false;
    var it = a.?.map.iterator();
    while (it.next()) |e| {
        const bv = b.?.map.get(e.key_ptr.*) orelse return false;
        if (!typesEqual(e.value_ptr.*, bv)) return false;
    }
    return true;
}

/// True when (declaration, substitution) is currently being expanded.
fn onStack(stack: []const StackEntry, j: usize, env: ?*const SubEnv) bool {
    for (stack) |e| {
        if (e.node == j and envEqual(e.env, env)) return true;
    }
    return false;
}

fn visitTypeNode(
    ck: *checker.Checker,
    info: *ModuleInfo,
    nodes: []const TypeNode,
    index: std.StringHashMapUnmanaged(u32),
    colors: []DfsColor,
    stack: *std.ArrayList(StackEntry),
    depth: u32,
    env: ?*const SubEnv,
    i: usize,
) CheckError!void {
    if (env == null) colors[i] = .gray;
    try stack.append(ck.alloc(), .{ .node = i, .env = env });
    switch (nodes[i]) {
        .struct_ => |s| for (s.fields) |*f| try visitTypeEdge(ck, info, nodes, index, colors, stack, depth, env, s.name.text, &f.type_),
        .union_ => |u| for (u.variants) |*v| {
            if (v.types) |types| for (types) |*t| try visitTypeEdge(ck, info, nodes, index, colors, stack, depth, env, u.name.text, t);
        },
    }
    _ = stack.pop();
    if (env == null) colors[i] = .black;
}

/// Walk one written type for direct storage edges out of the current
/// node: a named reference to a local declaration is an edge (checked
/// against the DFS stack), tuples keep the edge direct, and
/// box/list/function types are indirection that ends the walk. A
/// single-segment name bound in the current substitution frame is the
/// argument it denotes and is walked in its place (Core §11.3).
fn visitTypeEdge(
    ck: *checker.Checker,
    info: *ModuleInfo,
    nodes: []const TypeNode,
    index: std.StringHashMapUnmanaged(u32),
    colors: []DfsColor,
    stack: *std.ArrayList(StackEntry),
    depth: u32,
    env: ?*const SubEnv,
    owner: []const u8,
    t: *const ast.Type,
) CheckError!void {
    switch (t.*) {
        .named => |n| {
            // Dotted names denote types of imported modules; imports are
            // acyclic (phase1-module-graph.md, Import-cycle detection), so a non-generic cross-module reference cannot
            // cycle back. A cross-module GENERIC instantiation (`m.B[Node]`
            // storing `Node` inline) is a known limitation of this pass —
            // closing it needs cross-module type resolution.
            if (n.path.len != 1) return;
            // A type-parameter reference in the current substitution frame
            // denotes the argument substituted for it: walk that argument.
            // The depth cap terminates self-referential contexts such as a
            // field `v: T` under `T -> tuple[T]`.
            if (env) |e| {
                if (e.map.get(n.path[0].text)) |arg| {
                    if (depth >= max_subst_depth) return ck.fail(n.span, "recursive type '{s}' without indirection (Core §11.3)", .{owner});
                    return try visitTypeEdge(ck, info, nodes, index, colors, stack, depth + 1, env, owner, arg);
                }
            }
            const lr = localRef(info, n.path[0].text) orelse return;
            switch (lr) {
                .node => |target| {
                    const j = index.get(target.name()) orelse return;
                    if (n.type_args) |args| {
                        const params = switch (nodes[j]) {
                            .struct_ => |s| s.type_params,
                            .union_ => |u| u.type_params,
                        };
                        // Wrong-arity generic references are accepted
                        // pipeline-wide; mirror that silence here.
                        if (args.len != params.len) return;
                        const callee_env = try buildEnv(ck, env, params, args);
                        // An empty frame (identity arguments, `A1[T]` inside
                        // `A0[T]`) adds no substitution context: the descent
                        // is bounded by the declaration count plus the stack,
                        // exactly like a non-generic reference, so it must
                        // not consume the depth cap — a long chain of
                        // distinct generic structs passing their parameter
                        // through unchanged is finite and legal. A non-empty
                        // frame keeps the cap, which terminates contexts
                        // that grow without repeating (`B[B[T]]`-style).
                        if (callee_env.map.count() > 0) {
                            if (depth >= max_subst_depth) return ck.fail(n.span, "recursive type '{s}' without indirection (Core §11.3)", .{target.name()});
                            if (onStack(stack.items, j, &callee_env)) return ck.fail(n.span, "recursive type '{s}' without indirection (Core §11.3)", .{target.name()});
                            try visitTypeNode(ck, info, nodes, index, colors, stack, depth + 1, &callee_env, j);
                        } else {
                            if (onStack(stack.items, j, &callee_env)) return ck.fail(n.span, "recursive type '{s}' without indirection (Core §11.3)", .{target.name()});
                            try visitTypeNode(ck, info, nodes, index, colors, stack, depth, &callee_env, j);
                        }
                    } else {
                        // Non-generic reference: context-free, so a fully
                        // explored (black) declaration can be skipped.
                        if (colors[j] == .black) return;
                        if (onStack(stack.items, j, null)) return ck.fail(n.span, "recursive type '{s}' without indirection (Core §11.3)", .{target.name()});
                        try visitTypeNode(ck, info, nodes, index, colors, stack, depth, null, j);
                    }
                },
                .alias => |ad| {
                    // Walk the alias target with the alias's own parameters
                    // bound to the reference's type arguments (Core §11.2);
                    // a non-generic alias simply exposes its target. The
                    // depth cap makes a circular alias chain (`type A = B;
                    // type B = A;`) terminate without a diagnostic.
                    if (depth >= max_subst_depth) return;
                    if (n.type_args) |args| {
                        if (args.len != ad.params.len) return;
                        const alias_env = try buildEnv(ck, env, ad.params, args);
                        try visitTypeEdge(ck, info, nodes, index, colors, stack, depth + 1, &alias_env, owner, &ad.target);
                    } else {
                        try visitTypeEdge(ck, info, nodes, index, colors, stack, depth + 1, env, owner, &ad.target);
                    }
                },
            }
        },
        .tuple => |tup| for (tup.elems) |*el| try visitTypeEdge(ck, info, nodes, index, colors, stack, depth, env, owner, el),
        .list, .box, .function, .primitive => {},
    }
}

// ---------------------------------------------------------------------------
// Module-constant initialization order (Core §5, §6.5)
// ---------------------------------------------------------------------------

/// A scope in the init-order walk: shadowing local names mapped to the
/// module constant they alias (`using`), or null for an ordinary local.
const IOScope = struct {
    locals: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    parent: ?*IOScope = null,
};

/// The outermost local function called from the initializer being walked.
const IOCall = struct {
    name: []const u8,
    span: ast.Span,
};

/// Module constants are evaluated strictly in declaration order (Core §5),
/// so an initializer — and every function it transitively calls — may
/// read only constants declared before it. Function references alone are
/// order-independent (Core §6.5): a bare reference reads nothing, but a
/// call makes the callee's reads transitive. The walk is scope-aware so
/// locals shadowing a constant name are not misread as reads.
const InitOrder = struct {
    frame: *Frame,
    /// Const name → declaration-order index (constants with initializers).
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// The initializer currently being walked.
    cur: u32 = 0,
    /// The outermost local function called from the initializer, when the
    /// walk is inside a callee body (for transitive diagnostics).
    call: ?IOCall = null,
    /// When non-null, the walk is over a module constant's `drop` hook
    /// (teardown order, Core §5); the value is the constant's name, used
    /// in diagnostics.
    drop_owner: ?[]const u8 = null,
    /// Recursion guard over the local call graph (mutual recursion, §6.5).
    visiting: std.AutoHashMapUnmanaged(*const ast.FuncDef, void) = .empty,

    fn run(frame: *Frame) CheckError!void {
        const alloc = frame.ck.alloc();
        const program = frame.info.program orelse return;
        var self = InitOrder{ .frame = frame };
        var idx: u32 = 0;
        for (program.items) |*item| switch (item.*) {
            .const_def => |*c| if (c.init != null) {
                try self.index.put(alloc, c.name.text, idx);
                idx += 1;
            },
            else => {},
        };
        var root = IOScope{};
        try self.bindModuleAliases(&root);
        for (program.items) |*item| switch (item.*) {
            .const_def => |*c| if (c.init != null) {
                self.cur = self.index.get(c.name.text).?;
                self.call = null;
                try self.walkExpr(&root, c.init.?);
            },
            else => {},
        };
        // Teardown (Core §5, Runtime §2.5): a unique module constant whose
        // type defines a `drop` hook is destroyed during normal teardown in
        // reverse declaration order, so a later constant is already
        // destroyed when the hook runs. The hook — and every function it
        // transitively calls — must therefore not read a module constant
        // declared later than the constant being destroyed. The drop hook's
        // parameter is a destruction view of the constant: it shadows the
        // constant's name so its field reads are not misread as module
        // reads. Containers whose elements carry drop hooks (e.g.
        // `list[File]` constants) are not walked; the same hazard class is
        // deferred to conformance work.
        for (program.items) |*item| switch (item.*) {
            .const_def => |*c| if (c.init != null) {
                const vm = frame.info.valueMember(c.name.text) orelse continue;
                const drop = dropHookOf(frame, vm.type_) orelse continue;
                self.cur = self.index.get(c.name.text).?;
                self.drop_owner = c.name.text;
                self.call = null;
                var s = IOScope{};
                try s.locals.put(alloc, drop.param.text, null);
                try self.bindModuleAliases(&s);
                try self.walkBlock(&s, drop.body);
                self.drop_owner = null;
            },
            else => {},
        };
    }

    /// The `drop` hook of a module constant's type, when the type is a
    /// named struct that defines one. A struct with a drop hook is always
    /// unique (Core §10.2), so no separate uniqueness check is needed.
    fn dropHookOf(frame: *Frame, t: cfg.Type) ?*ast.DropDecl {
        if (t != .named) return null;
        const name = frame.resolve.typeNameOf(t.named.id) orelse return null;
        const sd = moduleinfo.structDecl(frame.resolve, frame.info, name) orelse return null;
        return sd.drop;
    }

    /// Module-level `using` aliases are in scope for every initializer
    /// (Core §2.8); an alias of a local const is a read of that const.
    fn bindModuleAliases(self: *InitOrder, scope: *IOScope) CheckError!void {
        for (self.frame.info.using_aliases) |a| switch (a.target) {
            .value => |mr| {
                if (std.mem.eql(u8, mr.module, self.frame.info.specifier)) {
                    if (self.frame.info.valueMember(mr.name)) |vm| {
                        if (vm.decl == .const_) {
                            try scope.locals.put(self.frame.ck.alloc(), a.name, vm.decl.const_.name.text);
                            continue;
                        }
                    }
                }
                try scope.locals.put(self.frame.ck.alloc(), a.name, null);
            },
            .module, .type => try scope.locals.put(self.frame.ck.alloc(), a.name, null),
        };
    }

    /// True when `name` is bound as a local in scope (Core §4): locals
    /// shadow module constants, so the walk must not treat the name as a
    /// module-constant read.
    fn isShadowed(self: *InitOrder, scope: *IOScope, name: []const u8) bool {
        _ = self;
        var s: ?*IOScope = scope;
        while (s) |sc| {
            if (sc.locals.contains(name)) return true;
            s = sc.parent;
        }
        return false;
    }

    /// The module constant a shadowed `using` alias denotes, or null for
    /// an ordinary local.
    fn constTarget(self: *InitOrder, scope: *IOScope, name: []const u8) ?[]const u8 {
        _ = self;
        var s: ?*IOScope = scope;
        while (s) |sc| {
            if (sc.locals.getPtr(name)) |t| return t.*;
            s = sc.parent;
        }
        return null;
    }

    fn checkConst(self: *InitOrder, name: []const u8, span: ast.Span) CheckError!void {
        const i = self.index.get(name) orelse return;
        if (i >= self.cur) {
            if (self.drop_owner) |owner| {
                if (self.call) |c| {
                    return self.frame.ck.fail(c.span, "drop hook of module constant '{s}' calls '{s}', which reads module constant '{s}' declared later (Core §5)", .{ owner, c.name, name });
                }
                return self.frame.ck.fail(span, "drop hook of module constant '{s}' reads '{s}' declared later (Core §5)", .{ owner, name });
            }
            // `i == self.cur` is a self-read: the initializer reads the
            // constant it is defining, directly or through a called local
            // function — circular under Core §5's strict declaration order.
            if (self.call) |c| {
                return self.frame.ck.fail(c.span, "module constant initializer calls '{s}', which reads module constant '{s}' declared later (Core §5)", .{ c.name, name });
            }
            if (i == self.cur) {
                return self.frame.ck.fail(span, "module constant initializer reads '{s}' before it is initialized (Core §5)", .{name});
            }
            return self.frame.ck.fail(span, "module constant initializer reads '{s}' declared later (Core §5)", .{name});
        }
    }

    /// A single-segment name reference: a local shadows it, otherwise a
    /// module constant is a read and a function is order-independent.
    fn readName(self: *InitOrder, scope: *IOScope, name: ast.Ident, span: ast.Span) CheckError!void {
        if (self.isShadowed(scope, name.text)) {
            // A `using` alias of a local const still reads that const.
            if (self.constTarget(scope, name.text)) |t| try self.checkConst(t, span);
            return;
        }
        if (self.frame.info.valueMember(name.text)) |vm| {
            if (vm.decl == .const_) try self.checkConst(vm.decl.const_.name.text, span);
        }
    }

    fn walkPath(self: *InitOrder, scope: *IOScope, p: *const ast.PathExpr) CheckError!void {
        // Only the head segment can reference a module constant; the rest
        // are member selections on the value it names (`module.value`).
        try self.readName(scope, p.path[0], p.span);
    }

    fn walkExpr(self: *InitOrder, scope: *IOScope, e: *const ast.Expr) CheckError!void {
        const alloc = self.frame.ck.alloc();
        switch (e.*) {
            .int, .float, .string, .bool, .void, .import => {},
            .path => |*p| switch (p.tail) {
                .none => try self.walkPath(scope, p),
                .construct => |*sc| for (sc.fields) |*f| try self.walkExpr(scope, f.value),
                .variant => |*v| if (v.args) |args| for (args) |*a| try self.walkExpr(scope, a),
            },
            .paren => |*p| try self.walkExpr(scope, p.inner),
            .tuple => |*t| for (t.elems) |*el| try self.walkExpr(scope, el),
            .list => |*l| for (l.elems) |*el| try self.walkExpr(scope, el),
            .lambda => |*lam| {
                var s = IOScope{ .parent = scope };
                for (lam.params) |*p| try s.locals.put(alloc, p.name.text, null);
                try self.walkBlock(&s, lam.body);
            },
            .if_ => |*i| {
                try self.walkExpr(scope, i.cond);
                try self.walkBlock(scope, i.then);
                if (i.else_) |else_e| try self.walkExpr(scope, else_e);
            },
            .match => |*m| {
                try self.walkExpr(scope, m.scrutinee);
                for (m.arms) |*arm| {
                    var s = IOScope{ .parent = scope };
                    try self.bindPattern(&s, &arm.pattern);
                    try self.walkExpr(&s, arm.body);
                }
            },
            .block => |*b| try self.walkBlock(scope, b.block),
            .unary => |*u| try self.walkExpr(scope, u.operand),
            .binary => |*b| {
                try self.walkExpr(scope, b.lhs);
                try self.walkExpr(scope, b.rhs);
            },
            .cast => |*c| try self.walkExpr(scope, c.operand),
            .member => |*mm| try self.walkExpr(scope, mm.object),
            .call => |*c| try self.walkCall(scope, c),
            .specialize => |*s| try self.walkExpr(scope, s.operand),
            .move => |m| try self.readName(scope, m.name, m.span),
        }
    }

    fn walkBlock(self: *InitOrder, scope: *IOScope, b: *const ast.Block) CheckError!void {
        var s = IOScope{ .parent = scope };
        for (b.stmts) |*stmt| switch (stmt.*) {
            .let => |*l| {
                try self.walkExpr(&s, l.init);
                try self.bindPattern(&s, &l.pattern);
            },
            .drop => |*d| try self.readName(&s, d.name, d.span),
            .using => |*u| try self.bindUsing(&s, u),
            .expr => |*e| try self.walkExpr(&s, &e.expr),
            .empty => {},
        };
        if (b.result) |*r| try self.walkExpr(&s, r);
    }

    /// Bind the names a pattern introduces into `scope` (shadowing any
    /// module constant of the same name, Core §4).
    fn bindPattern(self: *InitOrder, scope: *IOScope, p: *const ast.Pattern) CheckError!void {
        const alloc = self.frame.ck.alloc();
        switch (p.*) {
            .wildcard, .literal => {},
            .type_test => |*tt| if (tt.binding) |b| try scope.locals.put(alloc, b.text, null),
            .tuple => |*tp| for (tp.elems) |*el| try self.bindPattern(scope, el),
            .path => |*pp| switch (pp.tail) {
                .none => if (pp.path.len == 1) try scope.locals.put(alloc, pp.path[0].text, null),
                .struct_ => |*sp| for (sp.fields) |*f| {
                    if (f.pattern) |*fp| try self.bindPattern(scope, fp) else try scope.locals.put(alloc, f.name.text, null);
                },
                .variant => |*vp| if (vp.args) |args| for (args) |*a| try self.bindPattern(scope, a),
            },
            .list => |*lp| {
                for (lp.items) |*it| try self.bindPattern(scope, it);
                if (lp.rest) |r| try scope.locals.put(alloc, r.text, null);
            },
        }
    }

    /// A block-level `using` alias (Core §13.1); an alias of a local
    /// const keeps the read. Mirrors `checker_annotate.bindUsing`.
    fn bindUsing(self: *InitOrder, scope: *IOScope, u: *const ast.UsingDecl) CheckError!void {
        const alias = u.alias orelse return;
        const alloc = self.frame.ck.alloc();
        const target = type_resolve.resolveAliasTarget(self.frame.resolve, self.frame.info, u) orelse {
            try scope.locals.put(alloc, alias.text, null);
            return;
        };
        switch (target) {
            .module, .type => try scope.locals.put(alloc, alias.text, null),
            .value => |mr| {
                if (std.mem.eql(u8, mr.module, self.frame.info.specifier)) {
                    if (self.frame.info.valueMember(mr.name)) |vm| {
                        if (vm.decl == .const_) {
                            try scope.locals.put(alloc, alias.text, vm.decl.const_.name.text);
                            return;
                        }
                    }
                }
                try scope.locals.put(alloc, alias.text, null);
            },
        }
    }

    /// A call: a direct call to a local function makes the callee's
    /// constant reads transitive (Core §5); any other callee is walked as
    /// a value (module-member callees still read their module-const base).
    fn walkCall(self: *InitOrder, scope: *IOScope, c: *const ast.Call) CheckError!void {
        const alloc = self.frame.ck.alloc();
        var callee = c.callee;
        if (callee.* == .specialize) callee = callee.specialize.operand;

        var local: ?*const ast.FuncDef = null;
        if (callee.* == .path and callee.path.tail == .none and callee.path.path.len == 1) {
            const n = callee.path.path[0].text;
            if (!self.isShadowed(scope, n)) {
                if (self.frame.info.valueMember(n)) |vm| {
                    if (vm.decl == .func) local = vm.decl.func;
                }
            }
        }

        if (local) |f| {
            if (f.body) |body| {
                if (!self.visiting.contains(f)) {
                    const outer = self.call orelse IOCall{ .name = f.name.text, .span = c.span };
                    try self.visiting.put(alloc, f, {});
                    var s = IOScope{};
                    for (f.params) |*p| try s.locals.put(alloc, p.name.text, null);
                    try self.bindModuleAliases(&s);
                    const saved = self.call;
                    self.call = outer;
                    try self.walkBlock(&s, body);
                    self.call = saved;
                    _ = self.visiting.remove(f);
                }
            }
        } else {
            try self.walkExpr(scope, callee);
        }
        for (c.args) |*a| try self.walkExpr(scope, a);
    }
};

// ---------------------------------------------------------------------------
// Type compatibility (Core §18 *Typing*, *Conversion*)
// ---------------------------------------------------------------------------

/// Arguments and return values must match exactly, except that the source
/// type `never` coerces to anything and anything coerces to the top type
/// `any` (the sole implicit widening, Core §11.6).
fn compatible(expected: cfg.Type, actual: cfg.Type) bool {
    // Coercion to the top type `any` is the sole implicit widening
    // (Core §11.6) — except that `hostdata` does not coerce to `any`
    // (Core §11.6, §11.7): a tagless payload cannot be an `any` value.
    if (expected == .primitive and expected.primitive == .any)
        return !(actual == .primitive and actual.primitive == .hostdata);
    if (actual == .primitive and actual.primitive == .never) return true;
    if (cfg.Type.eql(expected, actual)) return true;
    return compatibleRecur(expected, actual);
}

/// Recursive compat for composite types. Named types are resolved to the
/// path as *written* (type_resolve §resolveType), so the same declaration
/// has different names in different modules: `Result` inside its own
/// module vs `iter.Result` at a call site. Compare by last path segment;
/// the structural frontend treats named types as opaque strings, so this
/// is no looser than the exact comparison while it spans module
/// boundaries.
fn compatibleRecur(expected: cfg.Type, actual: cfg.Type) bool {
    if (expected == .named and actual == .named) {
        // The same interned declaration, with compatible type arguments.
        // Empty arguments are a wildcard: an uninstantiated construction
        // (`Option::None`) matches any instantiation of the same
        // declaration; a non-empty argument list must match exactly.
        if (expected.named.id != actual.named.id) return false;
        if (expected.named.args.len == 0 or actual.named.args.len == 0) return true;
        if (expected.named.args.len != actual.named.args.len) return false;
        for (expected.named.args, actual.named.args) |x, y| {
            if (!compatible(x, y)) return false;
        }
        return true;
    }
    switch (expected) {
        .function => |pf| return switch (actual) {
            .function => |af| blk: {
                if (pf.params.len != af.params.len) break :blk false;
                for (pf.params, af.params) |x, y| {
                    if (x.mode != y.mode) break :blk false;
                    if (!compatible(x.type_, y.type_)) break :blk false;
                }
                break :blk compatible(pf.ret.*, af.ret.*);
            },
            else => false,
        },
        .list => |pl| return switch (actual) {
            .list => |al| compatible(pl.*, al.*),
            else => false,
        },
        .box => |pb| return switch (actual) {
            .box => |ab| compatible(pb.*, ab.*),
            else => false,
        },
        .tuple => |pt| return switch (actual) {
            .tuple => |at| blk: {
                if (pt.len != at.len) break :blk false;
                for (pt, at) |x, y| {
                    if (!compatible(x, y)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        else => return false,
    }
}

fn isNever(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .never;
}

/// The equality domain of Core §16.3: byte, int32, uint32, float32,
/// bool, and str. Everything else (any, never, hostdata, structs,
/// unions, tuples, lists, boxes, functions, modules) has no `==`/`!=`.
fn isEqScalar(t: cfg.Type) bool {
    if (t != .primitive) return false;
    return switch (t.primitive) {
        .byte, .int32, .uint32, .int64, .uint64, .float32, .float64, .bool, .str => true,
        else => false,
    };
}

/// The ordering domain of Core §16.3 (`< <= > >=`): the numeric types.
/// `byte` is numeric for ordering but has no arithmetic.
fn isOrderNumeric(t: cfg.Type) bool {
    return t == .primitive and (t.primitive == .byte or t.primitive == .int32 or t.primitive == .uint32 or t.primitive == .int64 or t.primitive == .uint64 or t.primitive == .float32 or t.primitive == .float64);
}

fn isBool(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .bool;
}

fn isStr(t: cfg.Type) bool {
    return t == .primitive and t.primitive == .str;
}

fn isNumeric(t: cfg.Type) bool {
    // Core §16.3: arithmetic is defined for `int32`, `uint32`, `i64`,
    // `u64`, and `float32`; `byte` has no arithmetic. Integer
    // arithmetic wraps modulo 2^width and never traps (Runtime §7.2).
    return t == .primitive and (t.primitive == .int32 or t.primitive == .uint32 or t.primitive == .int64 or t.primitive == .uint64 or t.primitive == .float32 or t.primitive == .float64);
}

/// The shift/bitwise domain of Core §16.3 (`<<`/`>>`/`&`/`|`/`^`):
/// the two integer types. `byte` has no arithmetic (its ordering is
/// defined, but shifting or masking an 8-bit pattern has no bit to
/// move into) and `float32` has no bit pattern.
fn isInt(t: cfg.Type) bool {
    return t == .primitive and (t.primitive == .int32 or t.primitive == .uint32 or t.primitive == .int64 or t.primitive == .uint64);
}

/// A human-readable type name for diagnostics.
fn fmtType(alloc: std.mem.Allocator, resolve: moduleinfo.Resolve, t: cfg.Type) ![]const u8 {
    return switch (t) {
        .primitive => |k| std.fmt.allocPrint(alloc, "{s}", .{@tagName(k)}),
        .named => |n| blk: {
            var buf = std.ArrayList(u8).empty;
            try buf.appendSlice(alloc, resolve.typeNameOf(n.id) orelse "?");
            if (n.args.len > 0) {
                try buf.append(alloc, '[');
                for (n.args, 0..) |a, i| {
                    if (i > 0) try buf.append(alloc, ',');
                    try buf.appendSlice(alloc, try fmtType(alloc, resolve, a));
                }
                try buf.append(alloc, ']');
            }
            break :blk try buf.toOwnedSlice(alloc);
        },
        .param => |p| std.fmt.allocPrint(alloc, "{s}", .{p}),
        .module => std.fmt.allocPrint(alloc, "module", .{}),
        .cleanup => std.fmt.allocPrint(alloc, "cleanup", .{}),
        .list => |inner| std.fmt.allocPrint(alloc, "list[{s}]", .{try fmtType(alloc, resolve, inner.*)}),
        .box => |inner| std.fmt.allocPrint(alloc, "box[{s}]", .{try fmtType(alloc, resolve, inner.*)}),
        .tuple => |elems| blk: {
            var buf = std.ArrayList(u8).empty;
            try buf.appendSlice(alloc, "tuple[");
            for (elems, 0..) |e, i| {
                if (i > 0) try buf.append(alloc, ',');
                try buf.appendSlice(alloc, try fmtType(alloc, resolve, e));
            }
            try buf.appendSlice(alloc, "]");
            break :blk try buf.toOwnedSlice(alloc);
        },
        .function => |f| blk: {
            var buf = std.ArrayList(u8).empty;
            try buf.appendSlice(alloc, "fn(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.append(alloc, ',');
                try buf.appendSlice(alloc, try fmtType(alloc, resolve, p.type_));
            }
            try buf.appendSlice(alloc, ") -> ");
            try buf.appendSlice(alloc, try fmtType(alloc, resolve, f.ret.*));
            break :blk try buf.toOwnedSlice(alloc);
        },
    };
}
