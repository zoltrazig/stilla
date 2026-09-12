// Indirect-call target narrowing (docs/effects.md §9.2): a `let`-bound
// fn-ref and a `let`-bound λ are called through their local, an `if`
// selects a finite two-target set, and a function parameter (no binding
// site) stays the conservative `Top`.
fn plus_one(x: int32) -> int32 { x + 1 }
fn plus_two(x: int32) -> int32 { x + 2 }

fn apply_arg(f: fn(int32) -> int32, x: int32) -> int32 { f(x) }

fn main() -> void {
    let direct = plus_one;
    let _ = direct(41);
    let lam = fn(x: int32) -> int32 { x * 3 };
    let _ = lam(2);
    let flag = true;
    let branchy = if (flag) { plus_one } else { plus_two };
    let _ = branchy(10);
    let _ = apply_arg(plus_two, 5);
}
