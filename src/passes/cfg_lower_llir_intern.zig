//! Pass: CFG → LLIR interning — side-table serialization. In: the
//! prepared `Builder` (dense IDs, ordered tables, zeroed `FunctionDesc`
//! rows). Out: the deduplicated side-table rows the emitted records
//! reference by integer id — strings, constants, types, type decls,
//! modules, signatures, host bindings — plus the operation descriptors
//! the emission stages intern on demand (`syscall`, `construct`,
//! `member`, `drop`, `destructure`, `switch`). Every interner is
//! idempotent: dedup makes re-interning return the same ids, so the
//! later stages can intern fresh entities at any time. The recursive
//! interners preserve the range invariant: nested dependencies are
//! interned *before* a flat `{ start, len }` range is recorded, so a
//! nested append can never interleave another entity's rows into a
//! range's owned copies.

const std = @import("std");
const cfg = @import("stilla").cfg;
const ast = @import("stilla").ast;
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

/// One interned `{ start, len }` range into the flat `params` table —
/// the dedup key of a signature's parameter list (shared with the
/// Builder's `param_ranges`/`arg_ranges` tables).
const ParamRange = lower.ParamRange;

/// The `OwnershipId` of a serialized `TypeDeclDesc.a`:
/// the declared ownership class of a struct or union.
const OwnershipId = enum(u32) {
    copy = 0,
    unique = 1,
};

/// Intern everything into the dense side tables and fill the
/// `FunctionDesc` reference fields (`signature_id`, `module_id`).
/// Idempotent over the Builder state — dedup makes re-interning
/// return the same ids, so the later stages can intern fresh
/// entities at any time. The module/function name maps (`module_ids`,
/// `func_name_ids`) come populated from the preparation stage.
pub fn run(bld: *Builder) error{OutOfMemory}!void {
    // Type declarations (indexed by the same TypeId `Type.named`
    // carries), the artifact header (self symbol, init, entry member,
    // export table, slots). Seeded Builders already carry the canonical
    // type environment, so `serializeDecls` is idempotent.
    if (bld.type_decls.items.len != bld.program.types.len) {
        try serializeDecls(bld);
    }
    try serializeArtifact(bld);
    // Per function: the signature (parameter rows + result type).
    for (bld.ordered_funcs.items, 0..) |f, fi| {
        const fd = &bld.func_descs.items[fi];
        fd.signature_id = try internSignature(bld, f.params, f.ret);
    }
}

/// Intern one string into the program-owned blob; equal strings share
/// bytes (string constants and host-type names index the
/// blob with `{ start, len }` records).
pub fn internString(bld: *Builder, s: []const u8) error{OutOfMemory}!u32 {
    if (bld.string_starts.get(s)) |start| return start;
    const start: u32 = @intCast(bld.strings.items.len);
    try bld.strings.appendSlice(bld.arena, s);
    try bld.string_starts.put(bld.arena, s, start);
    return start;
}

/// Intern one constant payload; equal payloads share one row
/// (`int` carries an `i64` in `{a, b}`, `float` its `f32`
/// bits in `a`, `bool` 0/1 in `a`, `string` a `{start, len}` range
/// into `strings`, `void` both zero).
pub fn internConst(bld: *Builder, v: cfg.ConstValue, t: cfg.Type) error{OutOfMemory}!llir.ConstId {
    // v1: every constant row names its TypeId — the
    // validator's source for the destination cell's exact type.
    const type_id = try internType(bld, t);
    var rec: llir.ConstRecord = undefined;
    switch (v) {
        .int => |i| {
            const bits: u64 = @bitCast(i);
            rec = .{ .kind = .int, .type_ = type_id, .a = @truncate(bits), .b = @truncate(bits >> 32) };
        },
        .float => |f| {
            // binary64 pattern in {a,b}; a float32
            // constant keeps b == 0 so no undefined high bits exist.
            const bits: u64 = @bitCast(f);
            const is_f32 = t == .primitive and t.primitive == .float32;
            rec = .{
                .kind = .float,
                .type_ = type_id,
                // A binary32 constant keeps the f32 bit pattern in
                // `a` (b == 0, no undefined high bits); the carrier
                // is f64, and f32→f64 is exact, so the narrow
                // pattern is recovered losslessly. A binary64
                // constant stores the full 64-bit pattern in {a,b}.
                .a = if (is_f32) @as(u32, @bitCast(@as(f32, @floatCast(f)))) else @as(u32, @truncate(bits)),
                .b = if (is_f32) 0 else @truncate(bits >> 32),
            };
        },
        .bool => |b| rec = .{ .kind = .bool, .type_ = type_id, .a = @intFromBool(b), .b = 0 },
        .string => |str| {
            const start = try internString(bld, str);
            rec = .{ .kind = .string, .type_ = type_id, .a = start, .b = @intCast(str.len) };
        },
        .void => rec = .{ .kind = .void, .type_ = type_id, .a = 0, .b = 0 },
    }
    for (bld.constants.items, 0..) |c, i| {
        if (c.kind == rec.kind and c.type_ == rec.type_ and c.a == rec.a and c.b == rec.b) return @intCast(i);
    }
    try bld.constants.append(bld.arena, rec);
    return @intCast(bld.constants.items.len - 1);
}

/// Intern a type-argument sequence to a deduped, contiguous range
/// into `types` (the `{ b, c }` of a `named`/`tuple` row).
/// A range owns its rows: the argument types are appended as
/// contiguous copies even when the type already has a row elsewhere
/// (the range is the canonical reference; identical sequences share
/// one range, so identical `named`/`tuple` types dedup to one row).
fn internArgRange(bld: *Builder, args: []const cfg.Type) error{OutOfMemory}!ParamRange {
    for (bld.arg_ranges.items) |r| {
        if (r.len != args.len) continue;
        var ok = true;
        for (0..r.len) |i| {
            const want = try internType(bld, args[i]);
            if (!std.meta.eql(bld.types.items[r.start + i], bld.types.items[want])) {
                ok = false;
                break;
            }
        }
        if (ok) return r;
    }
    // Intern every type *before* capturing the range start — the
    // same nested-append hazard as `internParams`: an argument whose
    // type is a function type (or a named type with function type
    // arguments) recursively interns a signature, appending to this
    // same table mid-loop. Pre-computing the ids keeps the range's
    // owned copies contiguous.
    const ids = try bld.arena.alloc(llir.TypeId, args.len);
    for (args, 0..) |a, i| ids[i] = try internType(bld, a);
    const start: u32 = @intCast(bld.types.items.len);
    for (ids) |id| try bld.types.append(bld.arena, bld.types.items[id]); // range-owned copy
    const r = ParamRange{ .start = start, .len = @intCast(args.len) };
    try bld.arg_ranges.append(bld.arena, r);
    return r;
}

/// Intern a `cfg.Type` to a `TypeDesc` row. `void`/`never`
/// have no row (no `PrimitiveId`) and return `no_index` — the caller
/// writes the sentinel (signature rets, void module members). A
/// generic type parameter (`Type.param`) is a post-monomorphization
/// invariant violation and never reaches the table. Dedup is by
/// `TypeDesc` row equality; `named`/`tuple` argument ranges are
/// canonical (see `internArgRange`), so identical types always
/// intern to identical rows.
pub fn internType(bld: *Builder, t: cfg.Type) error{OutOfMemory}!llir.TypeId {
    var desc: llir.TypeDesc = undefined;
    switch (t) {
        .primitive => |k| switch (k) {
            .byte => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.byte), .b = 0, .c = 0 },
            .bool => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.bool), .b = 0, .c = 0 },
            .int32 => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.int32), .b = 0, .c = 0 },
            .uint32 => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.uint32), .b = 0, .c = 0 },
            .i64 => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.i64), .b = 0, .c = 0 },
            .u64 => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.u64), .b = 0, .c = 0 },
            .float32 => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.float32), .b = 0, .c = 0 },
            .f64 => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.f64), .b = 0, .c = 0 },
            .str => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.str), .b = 0, .c = 0 },
            .any => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.any), .b = 0, .c = 0 },
            .hostdata => desc = .{ .kind = .primitive, .a = @intFromEnum(llir.PrimitiveId.hostdata), .b = 0, .c = 0 },
            .void, .never => return llir.no_index, // no TypeDesc row
        },
        .named => |n| {
            const r = try internArgRange(bld, n.args);
            desc = .{ .kind = .named, .a = n.id, .b = r.start, .c = r.len };
        },
        .list => |e| desc = .{ .kind = .list, .a = try internType(bld, e.*), .b = 0, .c = 0 },
        .box => |e| desc = .{ .kind = .box, .a = try internType(bld, e.*), .b = 0, .c = 0 },
        .tuple => |elems| {
            const r = try internArgRange(bld, elems);
            desc = .{ .kind = .tuple, .a = r.start, .b = r.len, .c = 0 };
        },
        .function => |ft| desc = .{ .kind = .function, .a = try internSignature(bld, ft.params, ft.ret.*), .b = 0, .c = 0 },
        .module => desc = .{ .kind = .module, .a = 0, .b = 0, .c = 0 },
        .cleanup => desc = .{ .kind = .cleanup, .a = 0, .b = 0, .c = 0 },
        .param => unreachable, // post-monomorphization invariant
    }
    for (bld.types.items, 0..) |row, i| {
        if (std.meta.eql(row, desc)) return @intCast(i);
    }
    try bld.types.append(bld.arena, desc);
    return @intCast(bld.types.items.len - 1);
}

/// The `ParamMode` of a declared parameter mode (1:1 with the
/// LLIR enum).
fn paramMode(m: ast.ParamMode) llir.ParamMode {
    return switch (m) {
        .plain => .plain,
        .borrow => .borrow,
        .move => .move,
    };
}

/// Intern a parameter list to a deduped `{ start, len }` range into
/// the flat `params` table: identical `(mode, type)` sequences share
/// one range, so identical signatures get identical `params_start`.
fn internParams(bld: *Builder, params: []const cfg.Param) error{OutOfMemory}!ParamRange {
    for (bld.param_ranges.items) |r| {
        if (r.len != params.len) continue;
        var ok = true;
        for (0..r.len) |i| {
            const row = bld.params.items[r.start + i];
            const want = llir.ParamDesc{
                .mode = paramMode(params[i].mode),
                .type_ = try internType(bld, params[i].type_),
            };
            if (row.mode != want.mode or row.type_ != want.type_) {
                ok = false;
                break;
            }
        }
        if (ok) return r;
    }
    // Intern every param type *before* capturing the range start:
    // `internType` of a function-typed parameter recursively interns
    // its signature, whose own `internParams` appends to this same
    // table. If the start were captured first (the pre-fix order) a
    // nested append would claim the leading rows of this range,
    // interleaving two signatures' rows and corrupting both (a
    // fn-typed parameter, e.g. `iter.fold`'s step function, used to
    // make the function's `FunctionDesc.signature_id` disagree with
    // the call descriptor's signature).
    const rows = try bld.arena.alloc(llir.ParamDesc, params.len);
    for (params, 0..) |p, i| {
        rows[i] = .{ .mode = paramMode(p.mode), .type_ = try internType(bld, p.type_) };
    }
    const start: u32 = @intCast(bld.params.items.len);
    try bld.params.appendSlice(bld.arena, rows);
    const r = ParamRange{ .start = start, .len = @intCast(params.len) };
    try bld.param_ranges.append(bld.arena, r);
    return r;
}

/// Intern a function signature (parameter rows + result type); equal
/// signatures share one row. `ret` is `no_index` for `void`/`never`
/// (no `TypeDesc` row).
fn internSignature(bld: *Builder, params: []const cfg.Param, ret: cfg.Type) error{OutOfMemory}!llir.SignatureId {
    const ps = try internParams(bld, params);
    const desc = llir.SignatureDesc{
        .params_start = ps.start,
        .params_len = ps.len,
        .ret = try internType(bld, ret),
    };
    for (bld.signatures.items, 0..) |sig, i| {
        if (std.meta.eql(sig, desc)) return @intCast(i);
    }
    try bld.signatures.append(bld.arena, desc);
    return @intCast(bld.signatures.items.len - 1);
}

/// Intern an opaque type's `(host_module, type_name)` identity —
/// both byte ranges into the strings blob, no numeric module id.
/// Equal pairs share one `HostTypeId`.
fn internHostType(bld: *Builder, ht: cfg.HostTypeId) error{OutOfMemory}!llir.HostTypeId {
    const host_start = try internString(bld, ht.host_module);
    for (bld.host_types.items, 0..) |row, i| {
        if (row.host_len != ht.host_module.len or row.name_len != ht.type_name.len) continue;
        if (row.host_start != host_start) continue;
        const nm = bld.strings.items[row.name_start..][0..row.name_len];
        if (std.mem.eql(u8, nm, ht.type_name)) return @intCast(i);
    }
    const name_start = try internString(bld, ht.type_name);
    try bld.host_types.append(bld.arena, .{ .host_start = host_start, .host_len = @intCast(ht.host_module.len), .name_start = name_start, .name_len = @intCast(ht.type_name.len) });
    return @intCast(bld.host_types.items.len - 1);
}

/// Serialize the type environment 1:1 into `type_decls` — the index
/// space of `TypeDesc.named.a`. Generic
/// templates keep a row (index stability) with `no_index` where the
/// layout is deferred: `.param`-typed fields/payloads and null
/// ownership. Text-form `.unknown` decls (no layout)
/// serialize as an opaque placeholder.
fn serializeDecls(bld: *Builder) error{OutOfMemory}!void {
    for (bld.program.types) |decl| {
        const desc: llir.TypeDeclDesc = switch (decl) {
            .struct_ => |s| blk: {
                const fs: u32 = @intCast(bld.type_decl_fields.items.len);
                var flen: u32 = 0;
                for (s.fields) |fd| {
                    const ft: llir.TypeId = switch (fd.type_) {
                        .param => llir.no_index, // template: deferred
                        else => try internType(bld, fd.type_),
                    };
                    try bld.type_decl_fields.append(bld.arena, ft);
                    flen += 1;
                }
                // The drop hook: a scope-local function lowers to its
                // local `FunctionId` (`b`); any other name lowers to a
                // symbolic import (`e`) — the runtime resolves the
                // hook's VM pc through the declaring module's exports.
                var drop_fn: u32 = llir.no_index;
                var drop_imp: u32 = llir.no_index;
                if (s.drop) |name| {
                    if (bld.func_name_ids.get(name)) |fi| {
                        drop_fn = fi;
                    } else if (Builder.splitQualName(name)) |q| {
                        drop_imp = try bld.importIndex(q.module, q.member);
                    }
                }
                break :blk .{
                    .kind = .struct_,
                    .a = try internOwnership(bld, s.ownership),
                    .b = drop_fn,
                    .c = fs,
                    .d = flen,
                    .e = drop_imp,
                };
            },
            .union_ => |u| blk: {
                const vs: u32 = @intCast(bld.union_variants.items.len);
                var vlen: u32 = 0;
                for (u.variants) |v| {
                    const ps: u32 = @intCast(bld.union_payloads.items.len);
                    var plen: u32 = 0;
                    for (v.payloads) |pt| {
                        const pt_id: llir.TypeId = switch (pt) {
                            .param => llir.no_index, // template: deferred
                            else => try internType(bld, pt),
                        };
                        try bld.union_payloads.append(bld.arena, pt_id);
                        plen += 1;
                    }
                    try bld.union_variants.append(bld.arena, .{ .payloads_start = ps, .payloads_len = plen });
                    vlen += 1;
                }
                break :blk .{ .kind = .union_, .a = try internOwnership(bld, u.ownership), .b = vs, .c = vlen, .d = 0, .e = llir.no_index };
            },
            .opaque_ => |o| .{ .kind = .opaque_, .a = try internHostType(bld, o.host_id), .b = 0, .c = 0, .d = 0, .e = llir.no_index },
            .unknown => .{ .kind = .opaque_, .a = llir.no_index, .b = 0, .c = 0, .d = 0, .e = llir.no_index },
        };
        try bld.type_decls.append(bld.arena, desc);
    }
}

/// The `OwnershipId` of a declared ownership; `null` (a generic
/// template, deferred to the instantiation) serializes as
/// `no_index`.
fn internOwnership(bld: *Builder, o: ?cfg.Ownership) error{OutOfMemory}!u32 {
    _ = bld;
    return if (o) |ow| switch (ow) {
        .copy => @intFromEnum(OwnershipId.copy),
        .unique => @intFromEnum(OwnershipId.unique),
    } else llir.no_index; // generic template: deferred to the instantiation
}

/// Whether a type mentions a generic parameter anywhere — the
/// declared type of a generic template member, which the LLIR
/// cannot encode. The member row stays (member index space) with
/// `no_index` type and ref: a template is never a runtime value
/// (the checker rejects using it as one).
fn containsParam(t: cfg.Type) bool {
    switch (t) {
        .param => return true,
        .named => |n| for (n.args) |a| if (containsParam(a)) return true,
        .list => |e| return containsParam(e.*),
        .box => |e| return containsParam(e.*),
        .tuple => |elems| for (elems) |e| if (containsParam(e)) return true,
        .function => |ft| {
            for (ft.params) |p| if (containsParam(p.type_)) return true;
            return containsParam(ft.ret.*);
        },
        else => return false,
    }
    return false;
}

/// Serialize the artifact header (spec §2): the module's own symbol,
/// its init function, the symbolic entry member, the sorted export
/// table, and the constant slots. Export rows are the module's public
/// members plus every function of the artifact, keyed by the function's
/// name within the module (a function member's member row and its
/// function row coincide — the member row wins, marked public).
fn serializeArtifact(bld: *Builder) error{OutOfMemory}!void {
    const m = bld.program.modules[bld.scopeModuleIndex()];
    bld.self_symbol = try bld.internSymbol(m.name);
    bld.artifact_init = if (m.init) |f| bld.func_ids.get(f).? else llir.no_index;
    // The symbolic entry member: the entry function's name within its
    // module (the same symbol its export row carries).
    if (bld.program.entry) |e| {
        if (bld.inScope(e)) {
            if (Builder.splitQualName(e.name.text)) |q| {
                bld.entry_member = try bld.internSymbol(q.member);
            }
        }
    }
    // Export rows: collected with their name bytes, then sorted by
    // symbol bytes (byte-exact comparison order).
    const Row = struct { name: []const u8, desc: llir.ExportDesc };
    var rows = std.ArrayList(Row).empty;
    if (m.members) |members| {
        for (members) |mm| {
            const kind: llir.ExportKind = switch (mm.kind) {
                .const_slot => .const_slot,
                .function => .function,
                .module_ref => .nested_module,
                .host_binding => .host_binding,
            };
            const ref: u32 = switch (mm.kind) {
                // A void constant occupies no storage.
                .const_slot => |slot| slot orelse llir.no_index,
                // A generic template is never lowered and never a
                // runtime member — no export row.
                .function => |f| if (f) |ff| bld.func_ids.get(ff).? else continue,
                .module_ref => |spec| try bld.internSymbol(spec),
                // Host bindings are never first-class values.
                .host_binding => llir.no_index,
            };
            try rows.append(bld.arena, .{ .name = mm.name, .desc = .{ .member_sym = try bld.internSymbol(mm.name), .kind = kind, .ref = ref, .public = 1 } });
        }
    }
    for (bld.ordered_funcs.items) |f| {
        const q = Builder.splitQualName(f.name.text) orelse continue;
        if (!std.mem.eql(u8, q.module, m.name)) continue;
        var covered = false;
        for (rows.items) |r| {
            if (std.mem.eql(u8, r.name, q.member)) covered = true;
        }
        if (covered) continue;
        try rows.append(bld.arena, .{ .name = q.member, .desc = .{ .member_sym = try bld.internSymbol(q.member), .kind = .function, .ref = bld.func_ids.get(f).?, .public = 0 } });
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    for (rows.items, 0..) |r, i| {
        if (i > 0 and std.mem.eql(u8, rows.items[i - 1].name, r.name)) {
            bld.export_duplicate = true;
        }
        try bld.exports.append(bld.arena, r.desc);
    }
    // Constant slots, in slot order (Runtime §2.5).
    for (m.slots) |slot| {
        try bld.module_slots.append(bld.arena, .{ .type_ = try internType(bld, slot.type_), .init_order = slot.init_order });
    }
}

/// Intern a syscall descriptor: the host binding, its specialized
/// signature (types + plain/borrow/move modes + return type), and
/// one register per argument — sharing the `call_args` table the
/// call descs use. Identical `(binding, signature,
/// args)` triples share one row.
pub fn internSyscallDesc(bld: *Builder, binding: u32, sig: cfg.FunctionType, args: []const *cfg.Value) error{OutOfMemory}!llir.SyscallDescId {
    const signature_id = try internSignature(bld, sig.params, sig.ret.*);
    for (bld.syscall_descs.items, 0..) |d, i| {
        if (d.host_binding_id != binding or d.signature_id != signature_id or d.args_len != args.len) continue;
        var same = true;
        for (0..args.len) |k| {
            if (bld.call_args.items[d.args_start + k] != bld.slotOf(args[k])) {
                same = false;
                break;
            }
        }
        if (same) return @intCast(i);
    }
    const start: u32 = @intCast(bld.call_args.items.len);
    for (args) |a| try bld.call_args.append(bld.arena, bld.fit7(bld.slotOf(a)));
    try bld.syscall_descs.append(bld.arena, .{
        .host_binding_id = binding,
        .signature_id = signature_id,
        .args_start = start,
        .args_len = @intCast(args.len),
    });
    return @intCast(bld.syscall_descs.items.len - 1);
}

/// Intern a construct descriptor: the union discriminant (`no_tag`
/// for struct/tuple/list construction — the kind is the
/// destination's type) and one register per component, in
/// declaration order, from the shared `call_args` register table
/// (the same table the call and syscall descs range
/// into; there is no separate construct table in the frozen model).
/// Identical `(tag, args)` pairs share one row.
pub fn internConstructDesc(bld: *Builder, tag: ?u32, args: []const *cfg.Value, result_type: *const cfg.Type) error{OutOfMemory}!llir.ConstructDescId {
    const want_tag = tag orelse llir.no_tag;
    const want_result = try internType(bld, result_type.*);
    for (bld.construct_descs.items, 0..) |d, i| {
        if (d.tag != want_tag or d.args_len != args.len or d.result_type != want_result) continue;
        var same = true;
        for (0..args.len) |k| {
            if (bld.call_args.items[d.args_start + k] != bld.slotOf(args[k])) {
                same = false;
                break;
            }
        }
        if (same) return @intCast(i);
    }
    const start: u32 = @intCast(bld.call_args.items.len);
    for (args) |a| try bld.call_args.append(bld.arena, bld.fit7(bld.slotOf(a)));
    try bld.construct_descs.append(bld.arena, .{
        .tag = want_tag,
        .args_start = start,
        .args_len = @intCast(args.len),
        .result_type = want_result,
    });
    return @intCast(bld.construct_descs.items.len - 1);
}

/// Intern one v1 `MemberDesc`: base/result TypeIds
/// plus the member/slot/index reference. Equal rows share one id.
/// `base_type` may be null only for the write-only `store_member`.
pub fn internMemberDesc(bld: *Builder, base_type: ?cfg.Type, res_type: ?cfg.Type, ref: u32) error{OutOfMemory}!u32 {
    const base_id: llir.TypeId = if (base_type) |bt| try internType(bld, bt) else llir.no_index;
    const res_id: llir.TypeId = if (res_type) |rt| try internType(bld, rt) else llir.no_index;
    for (bld.member_descs.items, 0..) |d, i| {
        if (d.base_type == base_id and d.type_ == res_id and d.ref == ref) return @intCast(i);
    }
    try bld.member_descs.append(bld.arena, .{ .base_type = base_id, .type_ = res_id, .ref = ref });
    return @intCast(bld.member_descs.items.len - 1);
}

/// Intern one v1 `DropDesc`: a typed drop of an `any`
/// / `hostdata` value names its TypeId; a host-backed opaque names
/// its HostTypeId. Exactly one side is set.
pub fn internDropDesc(bld: *Builder, t: cfg.Type) error{OutOfMemory}!u32 {
    switch (t) {
        .named => |n| {
            // A host-backed opaque declaration drops through the host.
            if (n.id < bld.program.types.len) {
                switch (bld.program.types[n.id]) {
                    .opaque_ => |opd| {
                        const host_id = try internHostType(bld, opd.host_id);
                        for (bld.drop_descs.items, 0..) |d, i| {
                            if (d.type_ == llir.no_index and d.host_type_ == host_id) return @intCast(i);
                        }
                        try bld.drop_descs.append(bld.arena, .{ .type_ = llir.no_index, .host_type_ = host_id });
                        return @intCast(bld.drop_descs.items.len - 1);
                    },
                    else => {},
                }
            }
            const tid = try internType(bld, t);
            for (bld.drop_descs.items, 0..) |d, i| {
                if (d.type_ == tid and d.host_type_ == llir.no_index) return @intCast(i);
            }
            try bld.drop_descs.append(bld.arena, .{ .type_ = tid, .host_type_ = llir.no_index });
            return @intCast(bld.drop_descs.items.len - 1);
        },
        else => {
            const tid = try internType(bld, t);
            for (bld.drop_descs.items, 0..) |d, i| {
                if (d.type_ == tid and d.host_type_ == llir.no_index) return @intCast(i);
            }
            try bld.drop_descs.append(bld.arena, .{ .type_ = tid, .host_type_ = llir.no_index });
            return @intCast(bld.drop_descs.items.len - 1);
        },
    }
}

/// Intern a destructure descriptor: the shape kind (the opcode must
/// match — `unpack_struct` requires `.struct_`, `unpack_tuple`
/// `.tuple`, `unpack_variant`/`borrow_variant` `.variant`,
/// `split_list` `.list`) and one result slot per defined value, in
/// result order, from `destructure_dsts`. Identical
/// `(kind, dsts)` rows share one descriptor; a zero-result
/// destructure (a `[]` consuming arm) names an empty range.
pub fn internDestructureDesc(bld: *Builder, kind: llir.DestructureKind, base: *const cfg.Value, results: []const *cfg.Value) error{OutOfMemory}!llir.DestructureDescId {
    // v1: the descriptor carries the consumed base's
    // TypeId and each result's TypeId (parallel `destructure_dst_types`
    // rows), so the validator and VM never consult a slot-type table.
    const base_id = try internType(bld, base.type_);
    var result_ids = try bld.arena.alloc(llir.TypeId, results.len);
    for (results, 0..) |r, k| result_ids[k] = try internType(bld, r.type_);
    for (bld.destructure_descs.items, 0..) |d, i| {
        if (d.kind != kind or d.base_type != base_id or d.dsts_len != results.len) continue;
        var same = true;
        for (0..results.len) |k| {
            if (bld.destructure_dsts.items[d.dsts_start + k] != bld.slotOf(results[k])) same = false;
            if (bld.destructure_dst_types.items[d.dsts_start + k] != result_ids[k]) same = false;
            if (!same) break;
        }
        if (same) return @intCast(i);
    }
    const start: u32 = @intCast(bld.destructure_dsts.items.len);
    for (results) |v| {
        try bld.destructure_dsts.append(bld.arena, bld.fit7(bld.slotOf(v)));
        try bld.destructure_dst_types.append(bld.arena, try internType(bld, v.type_));
    }
    try bld.destructure_descs.append(bld.arena, .{
        .kind = kind,
        .base_type = base_id,
        .dsts_start = start,
        .dsts_len = @intCast(results.len),
    });
    return @intCast(bld.destructure_descs.items.len - 1);
}

/// Intern a switch descriptor: one arm per `cfg.SwitchArm` — tag
/// and the arm's routed target `BlockId` (a symbolic target;
/// linearization resolves it to the arm's signed offset from the
/// `switch` instruction's own pc). Routing (stage 7) sends each arm
/// through its edge block when the edge carries phi copies or lifecycle
/// kills, so the arm's target is the LLIR-only edge block when present,
/// else the successor block itself. From
/// `switch_arms`. The lowering emits one descriptor per
/// `switch`: arm targets are pc-relative, so interning identical
/// `(tag, target)` sequences would encode wrong offsets at every pc
/// but the first. The implicit trap default
/// is never an arm.
pub fn internSwitchDesc(bld: *Builder, pred: *const cfg.BasicBlock, arms: []const cfg.SwitchArm) error{OutOfMemory}!llir.SwitchDescId {
    const start: u32 = @intCast(bld.switch_arms.items.len);
    // Symbolic targets: the arm's target holds the routed target's
    // dense `BlockId` until linearization resolves it to a signed offset
    // from the switch instruction's own pc.
    for (arms) |arm| try bld.switch_arms.append(bld.arena, .{ .tag = arm.tag, .target = @intCast(bld.block_ids.get(bld.targetForEdge(pred, arm.block)).?) });
    try bld.switch_descs.append(bld.arena, .{ .arms_start = start, .arms_len = @intCast(arms.len) });
    return @intCast(bld.switch_descs.items.len - 1);
}
