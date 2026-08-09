// basics — primitive values, operators, and expression-oriented control flow.
//
// Bindings are immutable. `if` is an expression, and `and` / `or`
// short-circuit, so their right-hand sides run only when needed.

const builtin = import("builtin");

fn main() -> void {
    let width = 6;
    let height = 7;
    let area = width * height;
    builtin.assert(area == 42, "integer arithmetic");

    let label = if (area >= 40) { "large" } else { "small" };
    builtin.assert(label == "large", "if expression");

    builtin.assert(true or (10 / 0 == 0), "or short-circuits");
    builtin.assert(!(false and (10 / 0 == 0)), "and short-circuits");

    let ratio = area as float32 / 10.0;
    builtin.assert(ratio > 4.0 and ratio < 5.0, "explicit conversion");
}
