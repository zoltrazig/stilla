// mutual_recursion — even/odd over two mutually recursive functions, a
// non-tail self call, and a self tail call. Exercises call lowering, the
// inliner's non-recursive-callee rule, and the tail-call pass' cycle guard
// (a self tail call becomes a loop, the mutual cycle must not).

fn odd(n: int32) -> bool {
    if (n == 0) { false } else { even(n - 1) }
}

fn even(n: int32) -> bool {
    if (n == 0) { true } else { odd(n - 1) }
}

fn sum_squares(n: int32) -> int32 {
    if (n == 0) { 0 } else { n * n + sum_squares(n - 1) }
}

fn count_down(n: int32) -> int32 {
    if (n == 0) { 0 } else { count_down(n - 1) }
}

fn main() -> void {
    let _ = even(10);
    let _ = odd(10);
    let _ = sum_squares(5);
    let _ = count_down(1000);
}
