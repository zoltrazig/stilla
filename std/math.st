// math — common mathematical constants and functions (StdLib §4).
//
// Host binding module: every member is a *declaration without a Stilla
// definition* (frontend §5.6). The functions cannot be written in Stilla
// source alone; the host implements them (normally on top of IEEE 754
// `float32`). Results follow IEEE 754, including NaN and infinity; they are
// deterministic within a single execution context (StdLib §4).
//
// There is no implicit numeric conversion in Stilla; integer arguments must
// be converted explicitly with `as` (Core §16.3).

// Constants (StdLib §4): correctly rounded float32 approximations; `inf` is
// positive infinity, `nan` is a quiet NaN. The host provides the values.
const pi: float32;
const e: float32;
const tau: float32;
const inf: float32;
const nan: float32;

// Functions (StdLib §4). `atan2(y, x)` takes y first, matching IEEE 754;
// `round` rounds ties away from zero; `min`/`max` follow IEEE 754
// `fmin`/`fmax`; `abs` is float32 only (integer negation traps on the
// minimum int32, Runtime §7.2).
fn sqrt(x: float32) -> float32;
fn pow(x: float32, y: float32) -> float32;
fn exp(x: float32) -> float32;
fn ln(x: float32) -> float32;
fn log2(x: float32) -> float32;
fn log10(x: float32) -> float32;
fn sin(x: float32) -> float32;
fn cos(x: float32) -> float32;
fn tan(x: float32) -> float32;
fn asin(x: float32) -> float32;
fn acos(x: float32) -> float32;
fn atan(x: float32) -> float32;
fn atan2(y: float32, x: float32) -> float32;
fn floor(x: float32) -> float32;
fn ceil(x: float32) -> float32;
fn round(x: float32) -> float32;
fn trunc(x: float32) -> float32;
fn abs(x: float32) -> float32;
fn min(a: float32, b: float32) -> float32;
fn max(a: float32, b: float32) -> float32;
