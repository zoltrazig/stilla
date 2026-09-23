//! Module-constant init/teardown dependency seam of the HIR effect
//! analysis (docs/effects.md §7). The method bodies here were moved
//! verbatim out of the driver `passes/hir_effects.zig`, which keeps a
//! `pub const` alias per method so `an.<method>(...)` call syntax is
//! unchanged for every consumer; the docs live with each method body.

const std = @import("std");
const meta = @import("stilla").meta;
const hir = @import("stilla").hir;
const effects = @import("stilla").effects;
const hir_effects = @import("hir_effects.zig");

const Analysis = hir_effects.Analysis;
const Error = hir_effects.Error;
const Summary = hir_effects.Summary;

const call_op = hir_effects.call_op;
const fn_ref_op = hir_effects.fn_ref_op;

// -----------------------------------------------------------------
// Module-constant init / teardown dependency check (docs/effects.md §7)
// -----------------------------------------------------------------

/// `Read(ModuleConst)` dependency check, replacing the checker's
/// ad-hoc `InitOrder` walk (docs/effects.md §7, §14 再后 2). Two
/// symmetric rules, both driven by the same function summaries:
///
/// - **init**: an initializer (and every function it transitively
///   calls) may read only constants declared before it;
/// - **teardown**: a Unique constant's destruction —
///   `drop_effect(type)`, the full hook + field/element chain — may
///   not read a constant destroyed earlier (declared later).
///
/// Both rules compare declaration order within the constant's own
/// module. Cross-module reads are always from already-initialized
/// dependencies (the module graph is acyclic and topologically
/// ordered), so checking the local module is complete. Returns null
/// or the first violation message (owned by `allocator`).
pub fn checkModuleDependencies(self: *Analysis, allocator: std.mem.Allocator) Error!?[]const u8 {
    for (0..self.built.modules.items.len) |mi| {
        const range = self.built.modules.items[mi].consts;
        const slice = self.built.consts.items[range.start..][0..range.len];
        for (slice) |c| {
            if (c.init) |root| {
                if (try self.checkInitReads(c, root, allocator)) |msg| return msg;
                if (try self.checkTeardownReads(c, allocator)) |msg| return msg;
            }
        }
    }
    return null;
}

pub fn checkInitReads(self: *Analysis, c: hir.ConstRecord, root: hir.ExprId, allocator: std.mem.Allocator) Error!?[]const u8 {
    const cur = self.initOrderOf(c) orelse return null;
    const s = try self.effectOf(root);
    return self.checkReadSet(c, cur, s, root, false, true, allocator);
}

pub fn checkTeardownReads(self: *Analysis, c: hir.ConstRecord, allocator: std.mem.Allocator) Error!?[]const u8 {
    const cty = self.built.program.typeOf(c.type_);
    const de = try self.dropEffectOf(cty);
    if (self.eng.isPure(de)) return null;
    const cur = self.initOrderOf(c) orelse return null;
    // Attribute direct reads / calls to the type's own hook body when
    // it has one; nested field hooks fall back to the generic form.
    var origin: ?hir.ExprId = null;
    if (cty == .named and cty.named.id < self.built.types.len) {
        switch (self.built.types[cty.named.id]) {
            .struct_ => |d| if (d.drop) |dn| {
                if (self.findFuncByName(dn)) |fid| origin = self.built.funcs.items[fid].root;
            },
            else => {},
        }
    }
    // An unknown read set is rejected for a nominal type (its
    // destruction is structural and a wildcard can only come from an
    // unmodelled indirect call). For `any`/`hostdata`/unresolved
    // named types the wildcard is the §11.1 "contents unknown" gap,
    // which cannot be attributed to a specific constant — the same
    // position the replaced AST walk took.
    const reject_unknown = self.typeIsNominal(cty);
    return self.checkReadSet(c, cur, de, origin orelse 0, true, reject_unknown, allocator);
}

pub fn typeIsNominal(self: *Analysis, ty: meta.Type) bool {
    if (ty != .named) return false;
    const id = ty.named.id;
    if (id >= self.built.types.len) return false;
    return switch (self.built.types[id]) {
        .struct_, .union_ => true,
        .opaque_, .unknown => false,
    };
}

/// Apply the declaration-order rule to every module-const read in
/// `s` (docs/effects.md §7). `c` owns the read; `root` is used only
/// for diagnostic attribution (0 = none).
pub fn checkReadSet(
    self: *Analysis,
    c: hir.ConstRecord,
    cur: u32,
    s: Summary,
    root: hir.ExprId,
    teardown: bool,
    reject_unknown: bool,
    allocator: std.mem.Allocator,
) Error!?[]const u8 {
    if (reject_unknown and s.accesses.wildcard(.read)) {
        // An unknown read set may target any constant, including a
        // later one or this constant itself (docs/effects.md §7.3,
        // §9.4) — reject on the first initialized sibling.
        const range = self.built.modules.items[c.module].consts;
        for (self.built.consts.items[range.start..][0..range.len]) |other| {
            if (other.init == null) continue;
            return self.readDiag(c, other.name, true, root, teardown, allocator);
        }
        return null;
    }
    for (s.accesses.accesses) |a| {
        if (a.mode != .read) continue;
        const d = switch (a.resource) {
            .module_const => |cid| cid,
            else => continue,
        };
        if (d >= self.built.consts.items.len) continue;
        const dc = self.built.consts.items[d];
        if (dc.module != c.module) continue; // cross-module reads are ordered by the graph
        const dord = self.initOrderOf(dc) orelse continue;
        if (dord < cur) continue;
        return self.readDiag(c, dc.name, dord == cur, root, teardown, allocator);
    }
    return null;
}

pub fn readDiag(
    self: *Analysis,
    c: hir.ConstRecord,
    read_name: []const u8,
    self_read: bool,
    root: hir.ExprId,
    teardown: bool,
    allocator: std.mem.Allocator,
) Error!?[]const u8 {
    const callee = if (root != 0) self.attributingCallee(root) else null;
    if (teardown) {
        if (callee) |caller| {
            return try std.fmt.allocPrint(allocator, "drop hook of module constant '{s}' calls '{s}', which reads module constant '{s}' declared later (Core §5)", .{ c.name, caller, read_name });
        }
        return try std.fmt.allocPrint(allocator, "drop hook of module constant '{s}' reads '{s}' declared later (Core §5)", .{ c.name, read_name });
    }
    if (callee) |caller| {
        return try std.fmt.allocPrint(allocator, "module constant initializer calls '{s}', which reads module constant '{s}' declared later (Core §5)", .{ caller, read_name });
    }
    if (self_read) {
        return try std.fmt.allocPrint(allocator, "module constant initializer reads '{s}' before it is initialized (Core §5)", .{read_name});
    }
    return try std.fmt.allocPrint(allocator, "module constant initializer reads '{s}' declared later (Core §5)", .{read_name});
}

/// The name of the first directly-called local function reachable
/// from `root` whose summary is non-pure. The old AST walk reported
/// the outermost call that introduced a transitive read; this
/// preserves that diagnostic shape (attribution only, never the
/// legality decision).
pub fn attributingCallee(self: *Analysis, root: hir.ExprId) ?[]const u8 {
    const pr = self.p();
    var work = std.ArrayList(hir.ExprId).empty;
    defer work.deinit(self.arena);
    work.append(self.arena, root) catch return null;
    while (work.pop()) |id| {
        const n = pr.node(id);
        if (n.op == call_op) {
            const ops = pr.operands(id);
            if (ops.len > 0) {
                const cn = pr.node(ops[0]);
                if (cn.op == fn_ref_op and cn.payload == .func) {
                    switch (cn.payload.func) {
                        .func => |fid| {
                            if (fid < self.built.funcs.items.len and self.known[fid] and !self.eng.isPure(self.summary[fid])) {
                                return self.built.funcs.items[fid].name;
                            }
                        },
                        .host => {},
                    }
                }
            }
        }
        for (pr.operands(id)) |op| work.append(self.arena, op) catch return null;
        for (pr.regionsOf(id)) |r| work.append(self.arena, pr.region(r).root) catch return null;
    }
    return null;
}

/// The declaration-order rank of `c` among the initialized constants
/// of its own module (uninitialized / module-valued consts are not
/// part of the schedule). Null when `c` has no initializer.
pub fn initOrderOf(self: *Analysis, c: hir.ConstRecord) ?u32 {
    const range = self.built.modules.items[c.module].consts;
    var k: u32 = 0;
    for (self.built.consts.items[range.start..][0..range.len]) |other| {
        if (other.init == null) continue;
        if (std.mem.eql(u8, other.key, c.key)) return k;
        k += 1;
    }
    return null;
}

pub fn isCopyType(self: *Analysis, ty: meta.Type) Error!bool {
    const cap = try self.capabilityOf(ty) orelse return false;
    return cap == .copy;
}

pub fn findFuncByName(self: *Analysis, name: []const u8) ?hir.FuncId {
    for (self.built.funcs.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.name, name)) return @intCast(i);
    }
    return null;
}

/// A host-backed opaque handle's destruction is a `Release` of its
/// host domain (docs/effects.md §11.1). The domain id is a stable
/// hash of the host identity; a collision only merges two release
/// domains, which conservatively adds conflicts, never removes them.
pub fn hostRelease(self: *Analysis, h: meta.HostTypeId) Error!Summary {
    var wh = std.hash.Wyhash.init(0);
    wh.update(h.host_module);
    wh.update(h.type_name);
    const domain: effects.HostDomainId = @truncate(wh.final());
    return self.eng.summaryOf(&.{.{
        .resource = .{ .host = domain },
        .mode = .release,
    }});
}
