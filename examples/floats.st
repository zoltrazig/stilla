// math — float32 arithmetic and explicit numeric conversion (StdLib §4,
// Core §16.3).
//
// There is no implicit numeric conversion in Stilla: `float32 as int32`
// and `int32 as float32` are the only core conversions and must be
// written explicitly. `min`/`max`/`abs` are float32-only; integer
// negation traps on the minimum int32 (Runtime §7.2).

const builtin = import("builtin");
const m = import("math");

fn main() -> void {
    // Constants are float32 members of the module.
    builtin.assert(m.pi > 3.14 and m.pi < 3.15, "pi");
    builtin.assert(m.tau == 2.0 * m.pi, "tau");

    // Powers, roots, and logarithms follow IEEE 754. Exact equality is
    // fragile across a round trip, so compare within a tolerance.
    builtin.assert(m.sqrt(16.0) == 4.0, "sqrt");
    builtin.assert(m.pow(2.0, 10.0) == 1024.0, "pow");
    builtin.assert(m.abs(m.exp(m.ln(2.0)) - 2.0) < 0.0001, "exp/ln round-trip");

    // Rounding: floor, ceil, round (ties away from zero), trunc.
    builtin.assert(m.floor(2.7) == 2.0, "floor");
    builtin.assert(m.ceil(2.1) == 3.0, "ceil");
    builtin.assert(m.round(2.5) == 3.0, "round away from zero");
    builtin.assert(m.trunc(-2.7) == -2.0, "trunc");

    // min/max/abs are float32-only (StdLib §4).
    builtin.assert(m.min(1.5, 2.5) == 1.5, "min");
    builtin.assert(m.max(1.5, 2.5) == 2.5, "max");
    builtin.assert(m.abs(-3.0) == 3.0, "abs");

    // Trigonometry.
    builtin.assert(m.sin(0.0) == 0.0, "sin");
    builtin.assert(m.cos(m.pi) < -0.99, "cos");

    // Core §16.3: the explicit conversions.
    let f = 3.75;
    let i = f as int32; // truncates toward zero
    builtin.assert(i == 3, "float32 as int32");
    let back = i as float32;
    builtin.assert(back == 3.0, "int32 as float32");

    // Floats convert to text like the other primitives (Runtime §4.2).
    builtin.print(builtin.str(f));
}
