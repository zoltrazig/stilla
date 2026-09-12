fn is_even(n: int32) -> bool { if (n == 0) { true } else { is_odd(n - 1) } }
fn is_odd(n: int32) -> bool { if (n == 0) { false } else { is_even(n - 1) } }
fn main() -> void { let r = is_even(4); }
