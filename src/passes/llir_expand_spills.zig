//! Pass: X-spill expansion (pre-linearize) — the second half of the
//! 2.3 spill decision made in `llir_alloc.zig`. In: the `Builder` after
//! every emission stage and both fusion passes, with spilled values'
//! records carrying their reserved sentinel byte. Out: every record
//! touching a spilled value expanded into `spill_take`/main/
//! `spill_put` staging (Instruction Set §6). Runs immediately before
//! linearization: block record lists grow freely here — PCs do not
//! exist yet, branch offsets are computed by 2.16 from the final
//! layout, and any distance growth beyond a compare-and-branch's ±512
//! reach is covered by the long-branch expansion safety net.
const std = @import("std");
const llir = @import("stilla").llir;
const lower = @import("cfg_lower_llir.zig");

const Builder = lower.Builder;

/// Expand every record that touches a spilled value into
/// `spill_take`/main/`spill_put` staging (Instruction Set §6). Runs after all
/// emission stages (and fusion compaction), immediately before
/// linearization: block record lists grow freely here — PCs do not exist
/// yet, branch offsets are computed by 2.16 from the final layout, and
/// any distance growth beyond a compare-and-branch's ±512 reach is
/// covered by the long-branch expansion safety net.
///
/// Field identification is exact without value identity: spilled values'
/// records carry their reserved sentinel byte (a free T-range code no
/// emitter produces), and only schema dst/src roles are consulted, so
/// immediates and IDs holding the same byte pattern pass through. The
/// register fields are read per format (R: a/b/c, B/C/E: a/b, I/U: a).
///
/// Restricted positions (the `slot_*` sources and the `release_ret`
/// cleanup source — Instruction Set §6/§8 allows only F there) route
/// through the function's reserved staging F cell: take T0 ← X, move
/// stage ← T0, use stage.
pub fn expandSpills(bld: *Builder) error{OutOfMemory}!void {
    if (bld.spill_bytes.count() == 0) return;
    for (bld.ordered_funcs.items, 0..) |_, fi| {
        const r = bld.block_ranges.items[fi];
        for (r.start..r.start + r.len) |bi| {
            const recs = &bld.block_records.items[bi];
            var out = std.ArrayList(llir.Instr).empty;
            for (recs.items) |rec| {
                const d = llir.decode(rec) orelse {
                    try out.append(bld.arena, rec);
                    continue;
                };
                const info = llir.opInfo(d.op);
                // Skip already-expanded records defensively.
                if (d.op == .spill_take or d.op == .spill_put) {
                    try out.append(bld.arena, rec);
                    continue;
                }
                var src_takes = std.ArrayList(struct { byte: u8, t: u8 }).empty;
                defer src_takes.deinit(bld.arena);
                const max_slot: u8 = switch (info.format) {
                    .r => 2,
                    .b, .c, .e => 1,
                    .i, .u => 0,
                };
                var fields = [3]u8{ d.a, d.b, d.c };
                const roles = [3]llir.Field{ info.a, info.b, info.c };
                var restricted = false;
                var dst_spill: ?struct { byte: u8, x: u32 } = null;
                for (0..max_slot + 1) |fi2| {
                    const role = roles[fi2];
                    if (!isRegField(role)) continue;
                    const byte = fields[fi2];
                    if (!isSpillByte(byte)) continue;
                    const x = bld.spill_x.get(byte) orelse continue;
                    if (restrictedPosition(d.op, @intCast(fi2))) {
                        restricted = true;
                        continue;
                    }
                    if (isDstRole(role)) {
                        dst_spill = .{ .byte = byte, .x = x };
                    } else {
                        const t: u8 = @intCast(src_takes.items.len);
                        try src_takes.append(bld.arena, .{ .byte = byte, .t = t });
                    }
                }
                // Restricted routing: every spilled field goes through the
                // reserved staging cell (a = f_count - 1).
                if (restricted) {
                    const stage: u8 = @intCast(bld.func_descs.items[fi].f_count - 1);
                    for (0..max_slot + 1) |fi2| {
                        if (!isRegField(roles[fi2])) continue;
                        const byte = fields[fi2];
                        if (!isSpillByte(byte)) continue;
                        const x = bld.spill_x.get(byte) orelse continue;
                        try out.append(bld.arena, takeInstr(0, x));
                        try out.append(bld.arena, moveStage(stage, 0));
                        fields[fi2] = stage;
                    }
                    try out.append(bld.arena, reencode(d, fields));
                    continue;
                }
                // Ordinary expansion: takes (T staging), the main
                // record with remapped fields, then the put.
                for (src_takes.items) |st| {
                    const x = bld.spill_x.get(st.byte) orelse continue;
                    try out.append(bld.arena, takeInstr(st.t, x));
                    for (fields, 0..) |fld, fi3| {
                        if (fld == st.byte and isSrcRole(roles[fi3])) fields[fi3] = llir.temp_base + st.t;
                    }
                }
                if (dst_spill) |ds| {
                    // The result computes into a T register, then lands
                    // in X. If a source also staged through that same T
                    // index, use the next one (a record reads its srcs
                    // before writing dst — but spill_take/put share the
                    // T bank, so give dst its own index).
                    const t: u8 = @intCast(src_takes.items.len);
                    fields[0] = llir.temp_base + t;
                    try out.append(bld.arena, reencode(d, fields));
                    try out.append(bld.arena, putInstr(t, ds.x));
                } else {
                    try out.append(bld.arena, reencode(d, fields));
                }
            }
            recs.* = out;
        }
    }
}

/// A register-role field (dst/src — spillable), as opposed to an
/// immediate/ID/none field.
fn isRegField(f: llir.Field) bool {
    return switch (f) {
        .dst, .dst_real, .dst_movw, .dst_u, .src, .src_real, .src_f, .src_t, .link, .cond, .tested => true,
        else => false,
    };
}

fn isDstRole(f: llir.Field) bool {
    return switch (f) {
        .dst, .dst_real, .dst_movw, .dst_u => true,
        else => false,
    };
}

fn isSrcRole(f: llir.Field) bool {
    return switch (f) {
        .src, .src_real, .src_f, .src_t, .link, .cond, .tested => true,
        else => false,
    };
}

/// Re-encode a record whose register fields were remapped (the
/// immediates are preserved from the decode).
fn reencode(d: llir.Decoded, fields: [3]u8) llir.Instr {
    return switch (d.format) {
        .r => llir.instrR(d.op, fields[0], fields[1], fields[2]),
        .b => llir.instrB(d.op, fields[0], fields[1], d.offs10),
        .i => llir.instrI(d.op, fields[0], d.imm16),
        .c => llir.instrC(d.op, fields[0], fields[1]),
        .e => llir.instrE(d.op, fields[0], fields[1]),
        .u => llir.instrU(d.op, fields[0], d.imm20),
    };
}

fn isSpillByte(byte: u8) bool {
    return byte >= llir.temp_base and byte < llir.temp_base + llir.temp_count;
}

fn takeInstr(t: u8, x: u32) llir.Instr {
    return llir.instrI(.spill_take, llir.temp_base + t, @intCast(x));
}

fn putInstr(t: u8, x: u32) llir.Instr {
    return llir.instrI(.spill_put, llir.temp_base + t, @intCast(x));
}

fn moveStage(stage: u8, t: u8) llir.Instr {
    return llir.instrE(.move, stage, llir.temp_base + t);
}

/// Whether field `fi2` of `op` is a restricted position that cannot name
/// a T register (Instruction Set §6/§8): the `slot_*` sources and the
/// `release_ret` cleanup source are F-only. Every other register
/// position — `ret`/`jalr` sources, branch operands, `switch`
/// scrutinees, `drop` sources — accepts a T register.
fn restrictedPosition(op: llir.Opcode, fi2: u8) bool {
    return switch (op) {
        .slot_copy, .slot_move, .slot_borrow, .slot_retain => fi2 == 0,
        .release_ret => fi2 == 1,
        else => false,
    };
}
