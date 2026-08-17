// iter — list combinators (StdLib §7).
//
// Ordinary Stilla source: `fold_with` and `consume_fold_with` are the
// recursion kernels; every other combinator is derived from them. Stilla
// has no closures (Core §18), so a derived combinator threads its own
// function value as the borrowed *context* of the primitive and passes a
// non-capturing lambda that calls it; the `*_with` variants cannot be
// composed that way (they already carry a user context) and are written
// directly.
//
// The context value is borrowed and passed to every invocation of the
// operation; context threading is the language's compensation for the
// absence of closures (Core §13.5).

// The result of a short-circuiting fold step: `Complete(s)` continues
// with accumulator `s`; `Break(r)` stops iteration immediately and is
// returned as the fold's result (StdLib §7).
union Result[S, R] {
    Complete(S),
    Break(R)
}

// Visit every element in increasing index order; the list and its
// elements are borrowed, so no ownership transfers (Runtime §5).
fn each[T](
    borrow values: list[T],
    action: fn(borrow T) -> void
) -> void {
    // A fold over a bool accumulator: the action runs per element, the
    // accumulator is returned unchanged and discarded.
    {
        fold_with(
            values,
            false,
            action,
            fn(move s: bool, borrow f: fn(borrow T) -> void, borrow x: T) -> bool { f(x); s }
        );
    }
}

// Visit with a borrowed context passed to every invocation.
fn each_with[T, C](
    borrow values: list[T],
    borrow context: C,
    action: fn(borrow C, borrow T) -> void
) -> void {
    match (values) {
        [] => (),
        [head, ..tail] => {
            action(context, head);
            each_with(tail, context, action);
        }
    }
}

// Deterministic left fold, lowest index to highest (Runtime §5): the
// accumulator is moved into each step call and the returned value
// becomes the next accumulator. The list is borrowed.
fn fold[T, S](
    borrow values: list[T],
    move state: S,
    step: fn(move S, borrow T) -> S
) -> S {
    fold_with(
        values,
        move state,
        step,
        fn(move s: S, borrow f: fn(move S, borrow T) -> S, borrow x: T) -> S { f(move s, x) }
    )
}

// Left fold with a borrowed context passed to every step call.
fn fold_with[T, S, C](
    borrow values: list[T],
    move state: S,
    borrow context: C,
    step: fn(move S, borrow C, borrow T) -> S
) -> S {
    match (values) {
        [] => state,
        [head, ..tail] => fold_with(tail, step(move state, context, head), context, step)
    }
}

// Consuming visit: the list is consumed as a whole and each element is
// moved into the action in increasing index order (Runtime §5).
fn consume_each[T](
    move values: list[T],
    action: fn(move T) -> void
) -> void {
    // A fold over a bool accumulator: the action runs per element, the
    // accumulator is returned unchanged and discarded.
    {
        consume_fold_with(
            move values,
            false,
            action,
            fn(move s: bool, borrow f: fn(move T) -> void, move x: T) -> bool { f(move x); s }
        );
    }
}

// Consuming visit with a borrowed context passed to every invocation.
fn consume_each_with[T, C](
    move values: list[T],
    borrow context: C,
    action: fn(borrow C, move T) -> void
) -> void {
    match (move values) {
        [] => (),
        [head, ..tail] => {
            action(context, move head);
            consume_each_with(move tail, context, action);
        }
    }
}

// Consuming left fold: the list is consumed as a whole and each element
// is moved into the step call (Runtime §5).
fn consume_fold[T, S](
    move values: list[T],
    move state: S,
    step: fn(move S, move T) -> S
) -> S {
    consume_fold_with(
        move values,
        move state,
        step,
        fn(move s: S, borrow f: fn(move S, move T) -> S, move x: T) -> S { f(move s, move x) }
    )
}

// Consuming left fold with a borrowed context passed to every step call.
fn consume_fold_with[T, S, C](
    move values: list[T],
    move state: S,
    borrow context: C,
    step: fn(move S, borrow C, move T) -> S
) -> S {
    match (move values) {
        [] => state,
        [head, ..tail] => consume_fold_with(move tail, step(move state, context, move head), context, step)
    }
}

// Short-circuiting left fold, lowest index to highest (Runtime §5): each
// step returns `Result[S, R]`; `Complete(s)` continues with accumulator
// `s`, and the first `Break(r)` stops iteration immediately — the
// remaining elements are not visited — and is returned as the result.
// Completing every element yields `Complete(final state)`. The list is
// borrowed.
//
// Host binding: the body needs generic union-payload substitution
// (`Result[S, R]`'s payload types are the type parameters), which the
// structural frontend defers; the host implements the short-circuiting
// walk.
fn try_fold[T, S, R](
    borrow values: list[T],
    move state: S,
    step: fn(move S, borrow T) -> Result[S, R]
) -> Result[S, R];

// Short-circuiting left fold with a borrowed context passed to every
// step call. Host binding (see `try_fold`).
fn try_fold_with[T, S, R, C](
    borrow values: list[T],
    move state: S,
    borrow context: C,
    step: fn(move S, borrow C, borrow T) -> Result[S, R]
) -> Result[S, R];
