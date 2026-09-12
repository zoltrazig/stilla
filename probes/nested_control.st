// nested_control — chained and nested conditionals producing values.
// Exercises phi insertion/simplification at nested joins, branch folding,
// and if-conversion candidates across several blocks.

fn classify(n: int32) -> int32 {
    if (n < 0) {
        -1
    } else if (n == 0) {
        0
    } else if (n < 10) {
        1
    } else {
        2
    }
}

fn pick(a: bool, b: bool) -> int32 {
    if (a) {
        if (b) { 1 } else { 2 }
    } else {
        if (b) { 3 } else { 4 }
    }
}

fn choose(flag: bool, x: int32, y: int32) -> int32 {
    let value = if (flag) { x } else { y };
    value + 1
}

fn main() -> void {
    let _ = classify(-5);
    let _ = classify(0);
    let _ = classify(5);
    let _ = classify(50);
    let _ = pick(true, false);
    let _ = pick(false, true);
    let _ = pick(false, false);
    let _ = choose(true, 1, 2);
    let _ = choose(false, 3, 4);
}
