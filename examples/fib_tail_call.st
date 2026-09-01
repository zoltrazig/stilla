// fib_tail_call — fibonacci in accumulator (tail-recursive) form.
//
// The classic `fib` of fibonacci.st is not tail-recursive: `fib(n - 1) +
// fib(n - 2)` must unwind back to the caller before the addition runs, so
// call-stack depth grows linearly with n. The version below moves both
// recursive calls into tail position — the call's result *is* the
// function's result, with no pending work after the call returns — by
// threading the running sum and next term through two accumulators.
//
// Stilla functions are order-independent within a module, so `go` may be
// referenced before it is declared; recursion requires an explicit return
// type (Core §6.4), which both functions carry. The optimizer's tail-call
// pass rewrites the self-recursion into a loop (frontend.md Pass 7).
//
// The accumulators widen past int32 range at fib(47), so the integer type
// is int64 (the language's 64-bit signed type). Literals in int64 operator
// contexts type at that width (Core Types §16.3), so no `as int64`
// coercions are needed.

const builtin = import("builtin");

/// fib(n) = fib_go(n, 0, 1)
fn fib(n: int64) -> int64 {
    go(n, 0, 1)
}

/// fib_go(n, a, b) = a                      when n == 0
///                = fib_go(n - 1, b, a + b) otherwise
fn go(n: int64, a: int64, b: int64) -> int64 {
    if (n == 0) { a } else { go(n - 1, b, a + b) }
}

fn print_terms(i: int64, n: int64) -> void {
    if (i < n) {
        builtin.print(builtin.str(fib(i)));
        print_terms(i + 1, n);
    }
}

fn main() -> void {
    print_terms(0, 50);
}
