// string — Unicode text operations and conversions (StdLib §5).
//
// Host binding module: every member is a *declaration without a Stilla
// definition* (frontend §5.6); the host implements the functions (normally
// on top of `builtin` extensions).
//
// Strings are sequences of Unicode code points (scalar values); all text
// processing operates on code points and never exposes byte offsets.
// All functions are deterministic within a single execution context.

// `index_of` returns a code-point index, or `Option::None` (StdLib §5);
// `Option` is the `builtin` type member (Core §2.8); `builtin` is imported
// like any other standard-library module (Core §3).
const builtin = import("builtin");
using builtin.Option;

// §5: lengths are in code points, not bytes.
fn len(s: str) -> int32;
fn is_empty(s: str) -> bool;
fn concat(a: str, b: str) -> str;
fn contains(haystack: str, needle: str) -> bool;
fn starts_with(s: str, prefix: str) -> bool;
fn ends_with(s: str, suffix: str) -> bool;

// Code-point index of the first occurrence of `needle`, or None.
// An empty needle matches at index 0.
fn index_of(haystack: str, needle: str) -> Option[int32];

// Half-open interval [start, end); out-of-range offsets trap (Runtime §7.2).
fn substring(s: str, start: int32, end: int32) -> str;

// Splits at every occurrence of `sep`; an empty `sep` yields
// single-code-point strings; an empty `s` splits to [""].
fn split(s: str, sep: str) -> list[str];
fn join(parts: list[str], sep: str) -> str;

// Removes leading and trailing Unicode whitespace.
fn trim(s: str) -> str;

// Full Unicode default case conversion; may change the string length.
fn lower(s: str) -> str;
fn upper(s: str) -> str;

// Replaces every non-overlapping occurrence of `from` with `to`; an empty
// `from` inserts `to` between every code point and at both ends.
fn replace(s: str, from: str, to: str) -> str;
fn repeat(s: str, count: int32) -> str;

// UTF-8 and code-point conversions. Invalid UTF-8 and non-scalar code
// points (surrogates, values above 0x10FFFF) trap (Runtime §7.2).
fn to_utf8(s: str) -> list[byte];
fn from_utf8(bytes: list[byte]) -> str;
fn to_codepoints(s: str) -> list[uint32];
fn from_codepoints(cps: list[uint32]) -> str;
