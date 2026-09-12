//! Shared compiler metadata — the self-contained source/value/type layer
//! (Core §2, air.md §4.2, §9.1).
//!
//! `meta` owns the concepts every compiler pass agrees on, so no pass has
//! to reach into the CFG (or the HIR, or another pass) to name a type:
//!
//! - the source primitives (`SourceId`, `Span`, `Ident`, `ParamMode`) and
//!   the `PrimitiveKind` set the resolved `Type` is built from;
//! - `Diagnostic`, the shared `{ span, message }` source error;
//! - the resolved `Type` and the ownership / `TypeId` / `Param` /
//!   `FunctionType` it is built from;
//! - the nominal-declaration environment behind a `TypeId`
//!   (`TypeDecl` / `StructDecl` / `UnionDecl` / `OpaqueDecl` /
//!   `HostTypeId`);
//! - `ConstValue`, a compile-time constant;
//! - `substParams`, the `.param` substitution shared by the checker, the
//!   HIR passes, and the CFG lowering.
//!
//! Scope. The module is self-contained: it imports only `std` — never the
//! AST, the CFG, the HIR, or a pass. `ast.zig` depends on `meta` (it
//! re-exports the source primitives). The CFG-specific structures and
//! queries (`Value`, `Instr`, `Op`, `IrProgram` and its ownership/module
//! resolution) stay in `cfg.zig`; the HIR's own handles stay in `hir.zig`.

const std = @import("std");

// ---------------------------------------------------------------------------
// Source primitives (Core §2)
// ---------------------------------------------------------------------------

/// Identifies one source file in a compilation, e.g. an index into the
/// compilation's source table.
pub const SourceId = u32;

/// A half-open byte range `[start, end)` into the text of the source
/// identified by `source`. Offsets are `u32` so a `Span` stays one word
/// per field; sources larger than 4 GiB are out of scope.
pub const Span = struct {
    source: SourceId,
    start: u32,
    end: u32,

    pub fn init(source: SourceId, start: u32, end: u32) Span {
        std.debug.assert(start <= end);
        return .{ .source = source, .start = start, .end = end };
    }

    /// Length in bytes of the covered text.
    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    /// The smallest span that covers both inputs. The spans must belong to
    /// the same source.
    pub fn merge(a: Span, b: Span) Span {
        std.debug.assert(a.source == b.source);
        return .{ .source = a.source, .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }
};

/// An identifier as written: its name and the span of the spelling.
pub const Ident = struct {
    span: Span,
    text: []const u8,
};

/// Ownership mode of a function or lambda parameter (Grammar `param`,
/// `function-param-type`; Core §6, §10). The explicit `u32` backing and
/// values are the serialized LLIR encoding; `llir.ParamMode` aliases this
/// type so the signature tables carry the shared rep.
pub const ParamMode = enum(u32) {
    plain = 0,
    borrow = 1,
    move = 2,
};

/// One source diagnostic: the offending range and a human-readable
/// message. A producer records the first error it finds and owns the
/// message slice. `ast.Diagnostic`, `moduleinfo.Diag`, and
/// `cfg.FinalizeDiag` are aliases of this type.
pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
};

/// `any` is the top type: every value type coerces to it (Core §11.6);
/// `never` is the bottom type, which has no values and coerces to every
/// type (Core §13.2); `hostdata` is an opaque, host-defined payload
/// (Core §11.7), created only by the host and unique like `any`.
pub const PrimitiveKind = enum {
    any,
    byte,
    hostdata,
    int32,
    uint32,
    int64,
    uint64,
    float32,
    float64,
    bool,
    str,
    void,
    never,
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Ownership classification of a value type (Core §10.1–§10.3).
/// `Copy` values may be implicitly copied; `unique` values may be
/// used at most once and must be destroyed exactly once.
pub const Ownership = enum {
    copy,
    unique,
};

/// An AIR-native resolved type (air.md §4.2, §11). The AIR text carries no
/// type declarations, so `named` types defer ownership to their
/// declaration, mirroring the checker's `null`-means-deferred convention.
pub const TypeId = u32;

pub const Type = union(enum) {
    primitive: PrimitiveKind,
    /// A named struct or union reference: the declaration's `TypeId` plus
    /// the type arguments of this instantiation (empty for non-generic
    /// types). Canonical identity is the declaration `TypeId` together with
    /// the arguments (`Named`); the declaration name strings are for
    /// printing and diagnostics only.
    named: Named,
    /// A generic type parameter of an enclosing declaration, e.g. the
    /// `T` of `fn foo[T](x: T) -> T` (Core §12). `null` ownership
    /// (deferred) until a monomorphic substitution fixes it. Distinct
    /// from `named` so a type parameter is never confused with a
    /// nominal struct/union reference.
    param: []const u8,
    /// The static module type of `module_ref` values (Core §2.3).
    module,
    list: *Type,
    box: *Type,
    tuple: []Type,
    function: FunctionType,
    /// The type of a cleanup token (air.md §6.4): a compiler-only value
    /// that schedules the conditional destruction of a maybe-unique
    /// owner. Not a Core type — no source expression, parameter, or
    /// binding ever has this type; only `cleanup_arm` produces it and
    /// only `cleanup_disarm` / `cleanup_drop` consume it. Classified
    /// Copy so ordinary scope-end machinery never drops it.
    cleanup,

    /// A named struct or union reference with its type arguments: the
    /// declaration `TypeId` and the instantiation's arguments, in the
    /// declaration's parameter order.
    pub const Named = struct {
        id: TypeId,
        args: []Type,
    };

    /// Structural ownership (air.md §6.1): primitives are Copy except
    /// the top type `any` and the opaque payload type `hostdata`, which are
    /// unique (Core §11.6, §11.7); function values and module values are
    /// Copy; containers join their components; cleanup tokens are
    /// scheduler-only values; named types defer (`null`).
    pub fn ownership(self: Type) ?Ownership {
        return switch (self) {
            .primitive => |k| if (k == .any or k == .hostdata) Ownership.unique else Ownership.copy,
            .module, .cleanup => Ownership.copy,
            .named, .param => null,
            .list, .box => |inner| inner.ownership(),
            .tuple => |elems| blk: {
                var acc: ?Ownership = Ownership.copy;
                for (elems) |e| {
                    const ow = e.ownership() orelse break :blk null;
                    if (ow == .unique) acc = Ownership.unique;
                }
                break :blk acc;
            },
            .function => Ownership.copy,
        };
    }

    /// Whether two named references denote the same instantiation: the
    /// same declaration with structurally equal type arguments.
    fn namedEql(a: Named, b: Named) bool {
        if (a.id != b.id) return false;
        if (a.args.len != b.args.len) return false;
        for (a.args, b.args) |x, y| {
            if (!eql(x, y)) return false;
        }
        return true;
    }

    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .primitive => |ka| switch (b) {
                .primitive => |kb| ka == kb,
                else => false,
            },
            .module => b == .module,
            .named => |na| switch (b) {
                .named => |nb| namedEql(na, nb),
                else => false,
            },
            .param => |pa| switch (b) {
                .param => |pb| std.mem.eql(u8, pa, pb),
                else => false,
            },
            .list => |la| switch (b) {
                .list => |lb| eql(la.*, lb.*),
                else => false,
            },
            .box => |la| switch (b) {
                .box => |lb| eql(la.*, lb.*),
                else => false,
            },
            .tuple => |ta| switch (b) {
                .tuple => |tb| tupleEql(ta, tb),
                else => false,
            },
            .function => |fa| switch (b) {
                .function => |fb| funcEql(fa, fb),
                else => false,
            },
            .cleanup => b == .cleanup,
        };
    }

    fn tupleEql(a: []Type, b: []Type) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!eql(x, y)) return false;
        return true;
    }

    fn funcEql(a: FunctionType, b: FunctionType) bool {
        if (a.params.len != b.params.len) return false;
        for (a.params, b.params) |x, y| {
            if (x.mode != y.mode or !eql(x.type_, y.type_)) return false;
        }
        return eql(a.ret.*, b.ret.*);
    }
};

/// One parameter: `[borrow|move] name: type` (air.md §11). In function
/// *types* the name is empty.
pub const Param = struct {
    span: Span,
    name: Ident,
    mode: ParamMode,
    type_: Type,
};

/// A synthetic parameter for a syscall signature the frontend itself
/// constructs (the list `len` in list patterns, `unbox` in drop
/// lowering): no written name.
pub fn syntheticParam(span: Span, mode: ParamMode, type_: Type) Param {
    return .{ .span = span, .name = .{ .span = span, .text = "" }, .mode = mode, .type_ = type_ };
}

pub const FunctionType = struct {
    params: []Param,
    ret: *Type,
};

// ---------------------------------------------------------------------------
// Type environment (air.md §9.1)
// ---------------------------------------------------------------------------

/// One nominal type declaration behind a `TypeId` (air.md §9.1): the
/// concrete layout, declared ownership, and destruction information a
/// backend needs to interpret `construct` / `unpack_*` / `drop` over a
/// named type — without reference to the source module graph. The
/// frontend lowering fills these from the module graph; the AIR text
/// parser interns only `.unknown` names (the text form carries no type
/// declarations, air.md §10), so a text-parsed program's layout queries
/// return null.
pub const TypeDecl = union(enum) {
    struct_: StructDecl,
    union_: UnionDecl,
    opaque_: OpaqueDecl,
    /// A name interned by the AIR text parser (air.md §10): the text form
    /// carries no type declarations, so the layout is unknown. The
    /// frontend never emits this form.
    unknown: []const u8,

    /// The written declaration name (printing and diagnostics only;
    /// canonical identity is the `TypeId`, air.md §9.1).
    pub fn name(self: TypeDecl) []const u8 {
        return switch (self) {
            .struct_ => |d| d.name,
            .union_ => |d| d.name,
            .opaque_ => |d| d.name,
            .unknown => |n| n,
        };
    }
};

/// A struct declaration (air.md §9.1 `StructDecl`): fields in declaration
/// order, the declared ownership, and the hidden drop-hook function.
pub const StructDecl = struct {
    /// Written declaration name (printing/diagnostics only).
    name: []const u8,
    /// The declaring module's resolved specifier.
    module: []const u8,
    /// Declaration type-parameter names, in declaration order (empty for
    /// non-generic structs). Field types reference them as `Type.param`;
    /// an instantiation's concrete layout substitutes the arguments.
    type_params: []const []const u8,
    /// The declared ownership class, concrete for non-generic structs.
    /// Null when the struct is generic: the class of an instantiation
    /// depends on its type arguments (`Option[int32]` is Copy,
    /// `Option[File]` is unique) — resolve via `IrProgram.namedOwnership`.
    ownership: ?Ownership,
    /// The hidden drop-hook function name (`{module}.{Type}.drop`, air.md
    /// §6.4), when the struct declares a hook (Core §9.1); null otherwise.
    /// A struct with a hook is unique by declaration.
    drop: ?[]const u8,
    /// Fields in declaration order.
    fields: []FieldDecl,
};

/// One struct field: the written name and the resolved field type (a
/// generic declaration's field types may reference its type parameters
/// as `Type.param`).
pub const FieldDecl = struct {
    name: []const u8,
    type_: Type,
};

/// A union declaration (air.md §9.1 `UnionDecl`): variants in declaration
/// order, the declared ownership, and the discriminant layout.
pub const UnionDecl = struct {
    name: []const u8,
    /// The declaring module's resolved specifier.
    module: []const u8,
    /// Declaration type-parameter names, in declaration order (see
    /// `StructDecl.type_params`; null ownership when generic).
    type_params: []const []const u8,
    ownership: ?Ownership,
    /// Variants in declaration order; the discriminant of a variant is
    /// its position.
    variants: []VariantDecl,
};

/// One union variant: the written name and its payload types in
/// declaration order (empty for a payload-less variant).
pub const VariantDecl = struct {
    name: []const u8,
    payloads: []Type,
};

/// A host-backed opaque nominal type declaration (air.md §9.1
/// `OpaqueDecl`, Core §11.8): no fields, no variants, unique by
/// declaration; the host type implementation is named by `host_id`.
pub const OpaqueDecl = struct {
    name: []const u8,
    /// The declaring module's resolved specifier.
    module: []const u8,
    /// Unique by declaration (Core §11.8): opaque types never take type
    /// arguments that change their ownership.
    ownership: Ownership,
    /// The host type implementation behind the opaque type (Runtime
    /// §3.1): the declaring module's specifier plus the type's written
    /// name — a stable (host_module, type_name) pair.
    host_id: HostTypeId,
};

/// The host identity of an opaque nominal type (air.md §9.1 `HostTypeId`):
/// names the host type implementation of the declaring module.
pub const HostTypeId = struct {
    host_module: []const u8,
    type_name: []const u8,
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// A compile-time constant (air.md §5.1): the payload of a `const` op and
/// of any inline literal materialized from the AIR text. `int` holds the
/// int32 / uint32 payload (sign per type), `float` the float32 / float64
/// payload (float32 narrows into the low word at interning).
pub const ConstValue = union(enum) {
    int: i64, // int32 / uint32 payload; sign per type
    float: f64, // float32 payloads narrow into the low word at interning
    bool: bool,
    string: []const u8,
    void,
};

// ---------------------------------------------------------------------------
// Type substitution
// ---------------------------------------------------------------------------

/// Substitute a type's `.param` occurrences with the instantiation's
/// type arguments (air.md §9.1): a generic struct/union declaration's
/// fields and payloads reference the declaration's type parameters, and
/// resolving an instantiation replaces each `.param` with its argument
/// (`Option[int32]`'s `Some` payload becomes `int32`). Parameters with
/// no matching argument are left unresolved. Best-effort allocation: on
/// OOM the original type is returned unchanged (the queries run in
/// arena contexts where OOM is not recoverable anyway).
pub fn substParams(allocator: std.mem.Allocator, params: []const []const u8, args: []const Type, t: Type) Type {
    return switch (t) {
        .param => |p| blk: {
            // `args` may be shorter than `params` for a wildcard
            // instantiation; parameters past the provided arguments are
            // left unresolved rather than crashing the zip.
            for (params, 0..) |prm, i| {
                if (i >= args.len) break;
                if (std.mem.eql(u8, p, prm)) break :blk args[i];
            }
            break :blk t;
        },
        .named => |n| blk: {
            if (n.args.len == 0) break :blk t;
            const out = allocator.alloc(Type, n.args.len) catch break :blk t;
            for (n.args, 0..) |a, i| out[i] = substParams(allocator, params, args, a);
            break :blk .{ .named = .{ .id = n.id, .args = out } };
        },
        .list => |inner| blk: {
            const sub = substParams(allocator, params, args, inner.*);
            if (Type.eql(sub, inner.*)) break :blk t;
            const ptr = allocator.create(Type) catch break :blk t;
            ptr.* = sub;
            break :blk .{ .list = ptr };
        },
        .box => |inner| blk: {
            const sub = substParams(allocator, params, args, inner.*);
            if (Type.eql(sub, inner.*)) break :blk t;
            const ptr = allocator.create(Type) catch break :blk t;
            ptr.* = sub;
            break :blk .{ .box = ptr };
        },
        .tuple => |elems| blk: {
            var changed = false;
            const out = allocator.alloc(Type, elems.len) catch break :blk t;
            for (elems, 0..) |e, i| {
                out[i] = substParams(allocator, params, args, e);
                if (!Type.eql(out[i], e)) changed = true;
            }
            break :blk if (changed) .{ .tuple = out } else t;
        },
        .function => |f| blk: {
            var changed = false;
            const params_out = allocator.alloc(Param, f.params.len) catch break :blk t;
            for (f.params, 0..) |*p, i| {
                params_out[i] = .{
                    .span = p.span,
                    .name = p.name,
                    .mode = p.mode,
                    .type_ = substParams(allocator, params, args, p.type_),
                };
                if (!Type.eql(params_out[i].type_, p.type_)) changed = true;
            }
            const ret_ptr = allocator.create(Type) catch break :blk t;
            ret_ptr.* = substParams(allocator, params, args, f.ret.*);
            if (!Type.eql(ret_ptr.*, f.ret.*)) changed = true;
            if (!changed) break :blk t;
            break :blk .{ .function = .{ .params = params_out, .ret = ret_ptr } };
        },
        .primitive, .module, .cleanup => t,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const sp = Span.init(0, 0, 0);

fn prim(tag: PrimitiveKind) Type {
    return .{ .primitive = tag };
}

test "Type.eql: primitives, containers, named arguments, functions" {
    try testing.expect(Type.eql(prim(.int32), prim(.int32)));
    try testing.expect(!Type.eql(prim(.int32), prim(.uint32)));
    try testing.expect(Type.eql(Type{ .module = {} }, Type{ .module = {} }));
    try testing.expect(Type.eql(Type{ .cleanup = {} }, Type{ .cleanup = {} }));
    try testing.expect(!Type.eql(Type{ .module = {} }, Type{ .cleanup = {} }));

    const e = prim(.int32);
    const i32_list = Type{ .list = @constCast(&e) };
    const i32_list2 = Type{ .list = @constCast(&e) };
    const u32_list = Type{ .list = @constCast(&prim(.uint32)) };
    try testing.expect(Type.eql(i32_list, i32_list2));
    try testing.expect(!Type.eql(i32_list, u32_list));

    const args_a = [_]Type{prim(.int32)};
    const args_b = [_]Type{prim(.uint32)};
    const named_i32 = Type{ .named = .{ .id = 7, .args = @constCast(&args_a) } };
    const named_i32b = Type{ .named = .{ .id = 7, .args = @constCast(&args_a) } };
    const named_u32 = Type{ .named = .{ .id = 7, .args = @constCast(&args_b) } };
    const named_other = Type{ .named = .{ .id = 8, .args = @constCast(&args_a) } };
    try testing.expect(Type.eql(named_i32, named_i32b));
    try testing.expect(!Type.eql(named_i32, named_u32));
    try testing.expect(!Type.eql(named_i32, named_other));

    const p = Param{ .span = sp, .name = .{ .span = sp, .text = "" }, .mode = .borrow, .type_ = prim(.int32) };
    const f_ret = prim(.float32);
    const other_ret = prim(.float32);
    const params = [_]Param{p};
    const g = Type{ .function = .{ .params = @constCast(&params), .ret = @constCast(&f_ret) } };
    const g2 = Type{ .function = .{ .params = @constCast(&params), .ret = @constCast(&other_ret) } };
    try testing.expect(Type.eql(g, g2));
}

test "Type.ownership: structural copy/unique, deferred named/param" {
    try testing.expectEqual(Ownership.copy, prim(.int32).ownership().?);
    try testing.expectEqual(Ownership.unique, prim(.any).ownership().?);
    try testing.expectEqual(Ownership.unique, prim(.hostdata).ownership().?);
    try testing.expectEqual(Ownership.copy, (Type{ .module = {} }).ownership().?);
    try testing.expectEqual(Ownership.copy, (Type{ .cleanup = {} }).ownership().?);

    const i32_val = prim(.int32);
    const any_val = prim(.any);
    const copy_list = Type{ .list = @constCast(&i32_val) };
    const unique_list = Type{ .list = @constCast(&any_val) };
    try testing.expectEqual(Ownership.copy, copy_list.ownership().?);
    try testing.expectEqual(Ownership.unique, unique_list.ownership().?);

    // Containers join components; a deferred component defers the whole.
    const copy_tuple = [_]Type{ prim(.int32), prim(.bool) };
    const mixed_tuple = [_]Type{ prim(.int32), prim(.any) };
    const deferred_tuple = [_]Type{ prim(.int32), .{ .param = "T" } };
    try testing.expectEqual(Ownership.copy, (Type{ .tuple = @constCast(&copy_tuple) }).ownership().?);
    try testing.expectEqual(Ownership.unique, (Type{ .tuple = @constCast(&mixed_tuple) }).ownership().?);
    try testing.expect((Type{ .tuple = @constCast(&deferred_tuple) }).ownership() == null);

    // A generic parameter defers; function values are Copy.
    try testing.expect((Type{ .param = "T" }).ownership() == null);
    const ret = prim(.int32);
    const params = [_]Param{syntheticParam(sp, .plain, prim(.int32))};
    try testing.expectEqual(Ownership.copy, (Type{ .function = .{ .params = @constCast(&params), .ret = @constCast(&ret) } }).ownership().?);
}

test "substParams: nested and structural substitution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{"T"};
    const args = [_]Type{prim(.int32)};

    try testing.expectEqual(prim(.int32), substParams(a, &names, &args, .{ .param = "T" }));
    // Unmatched parameter stays unresolved.
    try testing.expectEqualStrings("U", substParams(a, &names, &args, .{ .param = "U" }).param);

    // Nested containers are rebuilt with the substituted leaves.
    const inner = a.create(Type) catch unreachable;
    inner.* = .{ .param = "T" };
    const list = a.create(Type) catch unreachable;
    list.* = .{ .list = inner };
    const got = substParams(a, &names, &args, .{ .box = list });
    try testing.expect(got == .box);
    try testing.expect(got.box.* == .list);
    try testing.expectEqual(prim(.int32), got.box.list.*);

    // Named type arguments are substituted recursively.
    const nargs = [_]Type{.{ .param = "T" }};
    const named = Type{ .named = .{ .id = 3, .args = @constCast(&nargs) } };
    const named_got = substParams(a, &names, &args, named);
    try testing.expect(named_got == .named);
    try testing.expectEqual(prim(.int32), named_got.named.args[0]);

    // A function signature substitutes params and return.
    const fparams = [_]Param{syntheticParam(sp, .plain, .{ .param = "T" })};
    const fret = a.create(Type) catch unreachable;
    fret.* = .{ .param = "T" };
    const fn_ty = Type{ .function = .{ .params = @constCast(&fparams), .ret = fret } };
    const fn_got = substParams(a, &names, &args, fn_ty);
    try testing.expect(fn_got == .function);
    try testing.expectEqual(prim(.int32), fn_got.function.params[0].type_);
    try testing.expectEqual(prim(.int32), fn_got.function.ret.*);
}
