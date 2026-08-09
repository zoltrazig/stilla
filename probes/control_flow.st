const builtin = import("builtin");

fn fail() -> never {
    builtin.panic("unreachable")
}

fn require(flag: bool) -> int32 {
    if (flag) {
        42
    } else {
        builtin.panic("required")
    }
}

fn short_circuit(flag: bool) -> tuple[bool, bool] {
    (flag and fail(), flag or fail())
}

fn conditional(flag: bool) -> void {
    if (flag) {
        let value = require(flag);
    }
}

fn main() -> void {
    let _ = require(true);
    let _ = short_circuit(false);
    conditional(true);
}
