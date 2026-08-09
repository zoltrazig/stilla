//! Pass: program lowering and entry selection — `program` (ir.md §11).
//! In: Lowerer + module graph (every module materialized and checked).
//! Out: the `cfg.IrProgram` with module, function, and constant tables,
//! and the host-selected entry function ({spec}.{fn} qualified name).
const std = @import("std");
const ast = @import("../ast.zig");
const cfg = @import("../cfg.zig");
const moduleinfo = @import("../moduleinfo.zig");
const lower = @import("../lower.zig");
const cfg_lower_module = @import("cfg_lower_module.zig");

const Lowerer = lower.Lowerer;
const LowerError = lower.LowerError;

/// Lower the whole program: every module of the graph (frontend §5.7).
pub fn lowerProgram(self: *Lowerer) LowerError!cfg.IrProgram {
    var ir_modules = std.ArrayListUnmanaged(*cfg.IrModule).empty;
    var ir_funcs = std.ArrayListUnmanaged(*cfg.IrFunc).empty;
    for (self.graph.modules) |info| {
        const m = try cfg_lower_module.lowerModule(self, info);
        try ir_modules.append(self.arena, m);
        for (m.funcs) |f| try ir_funcs.append(self.arena, f);
    }
    var program = cfg.IrProgram{
        .modules = try self.arena.dupe(*cfg.IrModule, ir_modules.items),
        .funcs = try self.arena.dupe(*cfg.IrFunc, ir_funcs.items),
        .entry = null,
    };
    // Host-selected entry: a function of the entry module named by
    // `entry_fn` (the runtime convention is `main`, Runtime §3.3).
    // Function names are module-qualified, so compare against the
    // entry module's qualified spelling.
    //
    // The implicit default (`main`) is selected by convention: a
    // module without `main` is legal (a library module) and simply
    // has no entry — the CLI does not error for the default. Only an
    // explicitly named entry that does not exist is a diagnostic.
    if (self.entry_fn) |want| {
        const qualified = try qualifiedName(self, self.graph.entry.specifier, want);
        for (program.funcs) |f| {
            if (std.mem.eql(u8, f.name.text, qualified)) {
                program.entry = f;
                break;
            }
        }
        if (program.entry == null and self.entry_fn_explicit) {
            const span = if (self.graph.entry.source) |s|
                ast.Span.init(s.id, 0, 0)
            else
                ast.Span.init(0, 0, 0);
            return self.fail(span, "entry function '{s}' not found in module '{s}'", .{ want, self.graph.entry.specifier });
        }
    }
    return program;
}

/// The module-qualified spelling of a function name ({spec}.{fn}).
pub fn qualifiedName(self: *Lowerer, specifier: []const u8, name: []const u8) LowerError![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ specifier, name });
}
