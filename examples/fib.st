// fibonacci — classic recursive fibonacci with a recursive print.
//
// Stilla has immutable bindings, no `return` statement, and no loop
// construct: a function body is an expression (the last expression's value
// is the result), and repetition is expressed with ordinary recursive
// function calls (Core §13.5). `fib` recurses; `print_terms` prints the
// first N terms by recursing over the index range [0, N).

const builtin = import("builtin");

/// fib(n) = n                              for n < 2
///        = fib(n - 1) + fib(n - 2)        otherwise
fn fib(n: int32) -> int32 {
    if (n < 2) { n } else { fib(n - 1) + fib(n - 2) }
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
