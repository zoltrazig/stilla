// CLI `--run` probe: prints one deterministic line. `helper` is declared
// before `main`, so `main` is not function 0 — a binary `--run` load must
// honor the header's entry id (D3), not execute the first function.

const builtin = import("builtin");

fn helper() -> int32 { 42 }

fn main() -> void {
    builtin.print(builtin.str(helper()));
}
