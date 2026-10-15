// bool_str_branch — the general bool test on a `bool`/`str` equality
// condition (`cfg_lower_llir_control.zig` `fusedBranchOperands`). A
// `bool`/`str` `==`/`!=` has no numeric ordering branch, so the
// register fused form rejects the non-numeric rep and the branch tests
// the materialized condition against zero (`bne cond, zero` /
// `beq cond, zero`) instead of selecting `bltu`/`bleu` over the
// bool/str slots. `main` prints one token per shape so the
// consumers / SEG on-off differentials compare observable output
// verbatim.

const builtin = import("builtin");

fn bool_eq_branch(a: bool, b: bool) -> void {
    if (a == b) { builtin.print("bool eq"); } else { builtin.print("bool ne"); }
}

fn bool_ne_branch(a: bool, b: bool) -> void {
    if (a != b) { builtin.print("bool ne"); } else { builtin.print("bool eq"); }
}

fn str_eq_branch(a: str, b: str) -> void {
    if (a == b) { builtin.print("str eq"); } else { builtin.print("str ne"); }
}

fn str_ne_branch(a: str, b: str) -> void {
    if (a != b) { builtin.print("str ne"); } else { builtin.print("str eq"); }
}

fn main() -> void {
    bool_eq_branch(true, true);
    bool_eq_branch(true, false);
    bool_ne_branch(true, true);
    bool_ne_branch(true, false);
    str_eq_branch("x", "x");
    str_eq_branch("x", "y");
    str_ne_branch("x", "x");
    str_ne_branch("x", "y");
}
