// A `strict_ltr` call with nine non-floatable operands. `combine` takes
// nine `read()` results, and a read declared `Write` is observable, so
// none of them is `canFloatAsTree`. Selective ANF hoists exactly one —
// the *first* non-floatable operand — per round; the synthesized `local`
// left behind is floatable, so the first-non-floatable index strictly
// advances and the parent admits one hoist per argument. Nine operands
// therefore need nine changing rounds plus the quiet round that sets
// `converged`: more rounds than the old `max_iterations = 8` cap could
// ever run, so the cap silently truncated the chain at eight hoists
// (docs/hir.md §5.7, docs/effects.md §12.1). The fixture is host-backed:
// the test supplies `app.read`'s Write summary, which is what makes each
// read an observable effect that cannot float. It lives under
// `probes/cases/` and is read by spec, never enumerated, so its nine
// writes and bodyless `read` never join the runnable corpus.
fn read() -> int32;

fn combine(a0: int32, a1: int32, a2: int32, a3: int32, a4: int32, a5: int32, a6: int32, a7: int32, a8: int32) -> int32 {
    a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
}

fn f() -> int32 {
    combine(read(), read(), read(), read(), read(), read(), read(), read(), read())
}
