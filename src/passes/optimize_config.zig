const std = @import("std");

/// Independently configurable on/off toggles for every optimization the
/// compiler can run. The three top-level gates (`hir`, `seg`, `cfg`) must be
/// enabled for their sub-toggles to have any effect; a disabled gate ignores
/// its children. Library defaults: every gate off, every sub-toggle on.
pub const OptimizeConfig = struct {
    // --- M2b effect-driven HIR consumers (hir_simplify.zig) ---
    /// Gate: run the M2b consumers at all.
    hir: bool = false,
    dead_let: bool = true,
    anf: bool = true,
    never_suffix: bool = true,

    // --- M2a SEG (hir_seg.zig + hir_egraph.zig) ---
    /// Gate: run SEG at all.
    seg: bool = false,
    seg_beta: bool = true,
    seg_eta: bool = true,
    seg_let_dead: bool = true,
    seg_let_forward: bool = true,
    seg_let_atom: bool = true,
    seg_match: bool = true,
    seg_reorder: bool = true,
    egraph_fold: bool = true,
    egraph_algebra: bool = true,
    egraph_cond: bool = true,
    egraph_project: bool = true,
    egraph_cse: bool = true,

    // --- CFG mid-level optimizer (cfg_optimize.zig) ---
    /// Gate: run the CFG optimizer + post-optimization drop lowering.
    cfg: bool = false,
    cfg_tail_call: bool = true,
    cfg_inline: bool = true,
    cfg_cse: bool = true,
    cfg_copy_prop: bool = true,
    cfg_pre: bool = true,
    cfg_if_convert: bool = true,
    cfg_dead_block: bool = true,
    cfg_drop_elide: bool = true,
    cfg_dead_instr: bool = true,
    cfg_jump_thread: bool = true,
    cfg_phi_simplify: bool = true,
};

/// Set one toggle by its field name (`name` is matched against the struct
/// field names). Returns `false` for an unknown name, leaving the config
/// unchanged. This is how the CLI's `--opt`/`--no-opt <name>` resolve.
pub fn setByName(config: *OptimizeConfig, name: []const u8, enabled: bool) bool {
    inline for (std.meta.fields(OptimizeConfig)) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            @field(config, f.name) = enabled;
            return true;
        }
    }
    return false;
}

/// Every toggle name, for `--help` and tests. Comptime-generated from the
/// struct fields so it can never drift.
pub const names = blk: {
    const fields = std.meta.fields(OptimizeConfig);
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| out[i] = f.name;
    break :blk out;
};

fn defaultOf(comptime field_name: []const u8) bool {
    const defaults = OptimizeConfig{};
    return @field(defaults, field_name);
}

test "setByName flips every named toggle" {
    inline for (names) |name| {
        var config = OptimizeConfig{};
        const before = @field(config, name);
        try std.testing.expect(setByName(&config, name, !before));
        try std.testing.expectEqual(!before, @field(config, name));
    }
}

test "setByName rejects an unknown name without mutating" {
    var config = OptimizeConfig{};
    const before = config;
    try std.testing.expect(!setByName(&config, "not_a_toggle", false));
    try std.testing.expectEqualDeep(before, config);
}

test "names has one entry per toggle field" {
    // Hard-coded so a table that silently drifts fails here.
    try std.testing.expectEqual(@as(usize, 29), names.len);
    try std.testing.expectEqual(std.meta.fields(OptimizeConfig).len, names.len);
}

test "defaults: gates off, sub-toggles on" {
    inline for (names) |name| {
        const expected = !std.mem.eql(u8, name, "hir") and
            !std.mem.eql(u8, name, "seg") and
            !std.mem.eql(u8, name, "cfg");
        try std.testing.expectEqual(expected, defaultOf(name));
    }
}
