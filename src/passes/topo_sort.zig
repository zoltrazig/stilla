//! Pass: module-graph topological sort — cycle detection + reverse postorder (frontend Phase 1).
//! In: a static node set with sorted edge lists (supplied by `src/moduleinfo.zig`).
//! Out: node indexes in reverse postorder, or the offending cycle edge.
//!
//! The import-ordering algorithm of frontend Phase 1 (phase1-module-graph.md, Import-cycle detection,
//! Runtime §2.1, §2.3): cycle detection and topological sort over a static node set.
//!
//! A classic three-color DFS: **white** nodes are unvisited, **gray**
//! nodes are on the current DFS stack, **black** nodes are fully
//! processed. An edge into a gray node is a cycle and is rejected with
//! the offending edge (so the caller can report it at the import site);
//! nodes are otherwise collected in reverse postorder — every node after
//! all of its dependencies, which is exactly the order the runtime
//! instantiates modules.
//!
//! The algorithm is node-index based and knows nothing about modules: the
//! caller (`src/moduleinfo.zig`) supplies the edge lists (sorted, so the
//! traversal is deterministic) and maps the resulting indexes back to its
//! own nodes.

const std = @import("std");
const ast = @import("stilla").ast;

/// A directed edge from one node to another, carrying the source span
/// that created it (for cycle diagnostics).
pub const Edge = struct {
    /// Target node index.
    dep: usize,
    /// Where the edge was written (the importing module's `import(...)`
    /// expression), for the cycle diagnostic's span.
    span: ast.Span,
};

pub const Result = union(enum) {
    /// Reverse postorder: every node appears after all of its
    /// dependencies. The order is deterministic given a fixed edge order.
    order: []usize,
    /// A back edge to a gray (in-progress) node: the import graph has a
    /// cycle. `span` points at the import that closed it; `path` is the
    /// full cycle in import order, **with the closing node repeated** —
    /// `[a, b, c, a]` reads "a imports b imports c imports a".
    cycle: struct {
        span: ast.Span,
        path: []usize,
    },
};

/// Three-color DFS from `entry` over the static node set `0..node_count`.
/// `children[node]` lists node's outgoing edges; the caller should sort
/// each list by a stable key (the module graph sorts by resolved
/// specifier) so the result is reproducible. Every node is reachable from
/// `entry` in a module graph (the phase-1 worklist loads exactly the
/// reachable closure), so a single root suffices.
pub fn reversePostorder(
    allocator: std.mem.Allocator,
    node_count: usize,
    entry: usize,
    children: []const []const Edge,
) error{OutOfMemory}!Result {
    const color = try allocator.alloc(u8, node_count); // 0 white, 1 gray, 2 black
    defer allocator.free(color);
    @memset(color, 0);

    const Frame = struct { node: usize, child: usize };
    var stack = std.ArrayList(Frame).empty;
    defer stack.deinit(allocator);
    var post = std.ArrayList(usize).empty;
    defer post.deinit(allocator); // no-op on the success path (toOwnedSlice empties it)

    color[entry] = 1;
    try stack.append(allocator, .{ .node = entry, .child = 0 });
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.child < children[top.node].len) {
            const edge = children[top.node][top.child];
            top.child += 1;
            if (color[edge.dep] == 1) {
                // Back edge into a gray node: a cycle. Recover the full
                // path (phase1-module-graph.md, Import-cycle detection) by walking the DFS stack from the
                // target down to the stack top, then closing the loop:
                // the stack holds gray nodes where each is the importer of
                // the node above it, so `[target?..top] ++ [target]` is the
                // cycle in import order with both ends equal.
                var j = stack.items.len - 1;
                while (stack.items[j].node != edge.dep) j -= 1;
                const len = (stack.items.len - j) + 1; // gray tail + closing repeat
                const path = try allocator.alloc(usize, len);
                var k: usize = 0;
                var idx = j;
                while (idx < stack.items.len) : (idx += 1) {
                    path[k] = stack.items[idx].node;
                    k += 1;
                }
                path[k] = edge.dep;
                return Result{ .cycle = .{ .span = edge.span, .path = path } };
            }
            if (color[edge.dep] == 0) {
                color[edge.dep] = 1;
                try stack.append(allocator, .{ .node = edge.dep, .child = 0 });
            }
        } else {
            // Copy the frame before popping: the pop invalidates the
            // `top` pointer into the stack.
            const node = stack.items[stack.items.len - 1].node;
            _ = stack.pop();
            color[node] = 2;
            try post.append(allocator, node);
        }
    }
    // Postorder of a DFS over import edges lists every module after its
    // imports, i.e. dependencies before dependents (phase1-module-graph.md, Import-cycle detection).
    return Result{ .order = try post.toOwnedSlice(allocator) };
}

test "topo_sort orders dependencies before dependents" {
    const testing = std.testing;
    // a imports b and c; b imports c; c imports nothing.
    const children = [_][]const Edge{
        &.{ .{ .dep = 1, .span = ast.Span.init(0, 0, 0) }, .{ .dep = 2, .span = ast.Span.init(0, 0, 0) } },
        &.{.{ .dep = 2, .span = ast.Span.init(0, 0, 0) }},
        &.{},
    };
    const result = try reversePostorder(testing.allocator, 3, 0, &children);
    defer testing.allocator.free(result.order);
    // c (2) before b (1) before a (0).
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, result.order);
}

test "topo_sort rejects a cycle with the full path" {
    const testing = std.testing;
    // a imports b, b imports a.
    const children = [_][]const Edge{
        &.{.{ .dep = 1, .span = ast.Span.init(0, 0, 0) }},
        &.{.{ .dep = 0, .span = ast.Span.init(0, 0, 0) }},
    };
    const result = try reversePostorder(testing.allocator, 2, 0, &children);
    try testing.expect(result == .cycle);
    defer testing.allocator.free(result.cycle.path);
    // "a imports b imports a" — both ends name the same module.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 0 }, result.cycle.path);
}

test "topo_sort reports a longer cycle in import order" {
    const testing = std.testing;
    // a imports b, b imports c, c imports a (and c imports d, d imports
    // nothing).
    const children = [_][]const Edge{
        &.{.{ .dep = 1, .span = ast.Span.init(0, 0, 0) }},
        &.{.{ .dep = 2, .span = ast.Span.init(0, 0, 0) }},
        &.{
            .{ .dep = 3, .span = ast.Span.init(0, 0, 0) },
            .{ .dep = 0, .span = ast.Span.init(0, 0, 0) },
        },
        &.{},
    };
    const result = try reversePostorder(testing.allocator, 4, 0, &children);
    try testing.expect(result == .cycle);
    defer testing.allocator.free(result.cycle.path);
    // a imports b imports c imports a (d is never reached).
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 0 }, result.cycle.path);
}
