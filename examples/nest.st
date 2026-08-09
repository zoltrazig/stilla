// nest — a chain of tiny wrappers, inlined to depth.
//
// Each wrapper is a single expression, far below the inliner's budget
// (optimizer.md, Pass 8.0). The optimizer rewrites the chain bottom-up:
// `base` is spliced into `layer1`, `layer1` into `layer2`, and so on, so
// the call in `nest` is replaced by a splice of `layer4`, whose own body
// already contains three nested splices — the clone of a clone. The
// `nest` driver keeps the spliced copies alive under non-constant
// arguments, exercising the nested splice, block/value renumbering, and
// print-order normalization paths.

const builtin = import("builtin");

fn base(x: int32) -> int32 {
    x * 2
}

fn layer1(x: int32) -> int32 {
    base(x) + 1
}

fn layer2(x: int32) -> int32 {
    layer1(x) * 3
}

fn layer3(x: int32) -> int32 {
    layer2(x) - 4
}

fn layer4(x: int32) -> int32 {
    layer3(x) + 5
}

/// Sum the chain over [i, n): layer4(i) = 6i + 4, so the closed form is
/// Σ(6i + 4) for i in [i, n).
fn nest(i: int32, n: int32) -> int32 {
    if (i < n) {
        layer4(i) + nest(i + 1, n)
    } else {
        0
    }
}

fn main() -> void {
    builtin.assert(layer4(1) == 10, "chain 1");
    builtin.assert(layer4(10) == 64, "chain 10");
    builtin.assert(layer2(5) == 33, "mid chain");
    builtin.assert(nest(0, 5) == 80, "nest sum");
}
