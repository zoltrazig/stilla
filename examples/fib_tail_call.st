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

const builtin = import("builtin");

/// fib(n) = fib_go(n, 0, 1)
fn fib(n: int32) -> int32 {
    go(n, 0, 1)
}

/// fib_go(n, a, b) = a                      when n == 0
///                = fib_go(n - 1, b, a + b) otherwise
fn go(n: int32, a: int32, b: int32) -> int32 {
    if (n == 0) { a } else { go(n - 1, b, a + b) }
}

fn print_terms(i: int32, n: int32) -> void {
    if (i < n) {
        builtin.print(builtin.str(fib(i)));
        print_terms(i + 1, n);
    }
}

fn main() -> void {
    print_terms(0, 10);
}
