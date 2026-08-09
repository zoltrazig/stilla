// strings — text processing with the `string` standard module (StdLib §5).
//
// All `string` members are host bindings (frontend §5.6): lengths and
// indexes are in code points, never bytes, and every operation is
// deterministic within one execution context. The example also exercises
// `builtin.assert`, whose message argument is evaluated even when the
// condition holds (Runtime §4.8) — so these checks are a compile-time
// exercise of the whole pipeline, not just a runtime gate.

const builtin = import("builtin");
const s = import("string");

fn main() -> void {
    // Basic properties.
    builtin.assert(s.len("hello") == 5, "len is in code points");
    builtin.assert(s.is_empty(""), "is_empty");

    // Composition.
    builtin.assert(s.concat("foo", "bar") == "foobar", "concat");
    builtin.assert(s.repeat("ab", 3) == "ababab", "repeat");

    // Substring predicates.
    builtin.assert(s.contains("needle in haystack", "needle"), "contains");
    builtin.assert(s.starts_with("prefix-suffix", "prefix"), "starts_with");
    builtin.assert(s.ends_with("prefix-suffix", "suffix"), "ends_with");

    // Half-open interval [start, end); out-of-range offsets trap
    // (Runtime §7.2).
    builtin.assert(s.substring("hello", 1, 3) == "el", "substring");

    // Splitting and joining are inverse operations.
    builtin.assert(s.join(s.split("a,b,c", ","), "-") == "a-b-c", "split/join");

    // Case conversion may change the string length (full Unicode default
    // case conversion).
    builtin.assert(s.upper("hello") == "HELLO", "upper");
    builtin.assert(s.lower("HELLO") == "hello", "lower");

    // Trim removes leading and trailing Unicode whitespace.
    builtin.assert(s.trim("  x  ") == "x", "trim");
}
