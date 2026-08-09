// CLI `--run` panic probe: `builtin.panic` terminates execution with
// exit code 1; the CLI prints the owned message — which records the trap
// site (module#function, panic.zig `Panic`) — to stderr.

const builtin = import("builtin");

fn main() -> void {
    builtin.panic("probe boom");
}
