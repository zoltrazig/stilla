#!/usr/bin/env python3
"""Generate src/unicode_case.zig from the Unicode 16.0.0 UCD files.

Usage:
    python3 tools/gen_unicode_case.py > src/unicode_case.zig

The pinned Unicode 16.0.0 UCD inputs are read from `tools/ucd/` (next to
this script):

    tools/ucd/UnicodeData.txt
    tools/ucd/SpecialCasing.txt
    tools/ucd/DerivedCoreProperties.txt

Emitted tables:
  - `simple`          UnicodeData.txt simple (one-to-one) mappings
  - `special_lower` / `special_upper`
                      SpecialCasing.txt unconditional full mappings that
                      differ from the simple mapping (expansions)
  - `cased_ranges`    DerivedCoreProperties.txt `Cased` (Lu + Ll + Lt +
                      Other_Lowercase + Other_Uppercase)
  - `ignorable_ranges`
                      DerivedCoreProperties.txt `Case_Ignorable`
  - `xid_start_ranges` / `xid_continue_ranges`
                      DerivedCoreProperties.txt `XID_Start` / `XID_Continue`
                      (UAX #31 identifier classes for the lexer)

`cased_ranges` and `ignorable_ranges` implement the Final_Sigma context of
the default case algorithm (Unicode Standard §3.13): Σ maps to ς when
preceded by a cased character and not followed by a cased character, with
case-ignorable characters skipped on both sides.
"""
import os
import re
import sys

VERSION = "16.0.0"

UCD_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ucd")


def ucd_path(name):
    """Path of a pinned UCD file under tools/ucd/."""
    return os.path.join(UCD_DIR, name)


def read_lines(path):
    """Read a UCD file, failing with a clean message instead of a traceback."""
    try:
        with open(path, encoding="utf-8") as f:
            return f.readlines()
    except OSError as e:
        sys.exit("gen_unicode_case: cannot read %s: %s" % (path, e))


def parse_unicode_data(path):
    """UnicodeData.txt -> {cp: (upper, lower)} for chars with any mapping."""
    simple = {}  # cp -> (upper, lower)
    for line in read_lines(path):
        parts = line.rstrip("\n").split(";")
        cp = int(parts[0], 16)
        upper = int(parts[12], 16) if parts[12] else cp
        lower = int(parts[13], 16) if parts[13] else cp
        if upper != cp or lower != cp:
            simple[cp] = (upper, lower)
    return simple


def parse_derived_core_properties(path):
    """DerivedCoreProperties.txt -> (cased, ignorable, xid_start, xid_continue),
    each a sorted list of inclusive (lo, hi) code-point ranges."""
    cased, ignorable = [], []
    xid_start, xid_continue = [], []
    for line in read_lines(path):
        line = line.split("#")[0].strip()
        if not line:
            continue
        m = re.match(
            r"^([0-9A-F]{4,6})(?:\.\.([0-9A-F]{4,6}))?\s*;\s*(\w+)", line
        )
        if not m:
            continue
        lo = int(m.group(1), 16)
        hi = int(m.group(2), 16) if m.group(2) else lo
        name = m.group(3)
        if name == "Cased":
            cased.append((lo, hi))
        elif name == "Case_Ignorable":
            ignorable.append((lo, hi))
        elif name == "XID_Start":
            xid_start.append((lo, hi))
        elif name == "XID_Continue":
            xid_continue.append((lo, hi))

    def compress(ranges):
        ranges.sort()
        out = []
        for lo, hi in ranges:
            if out and lo <= out[-1][1] + 1:
                out[-1] = (out[-1][0], max(out[-1][1], hi))
            else:
                out.append((lo, hi))
        return out

    return compress(cased), compress(ignorable), compress(xid_start), compress(xid_continue)


def parse_special_casing(path):
    """SpecialCasing.txt -> unconditional expansion mappings that differ
    from the (self-mapping) default, as {cp: [cps]}."""
    special_lower = {}
    special_upper = {}
    for line in read_lines(path):
        if not line.strip() or line.startswith("#"):
            continue
        data = line.rstrip("\n").split("#", 1)[0]
        parts = data.split(";")
        if len(parts) < 4:
            continue
        cp = int(parts[0].strip(), 16)
        lower = [int(x, 16) for x in parts[1].split()]
        upper = [int(x, 16) for x in parts[3].split()]
        # Keep only unconditional entries (no condition field, or empty).
        cond = parts[4].strip() if len(parts) > 4 else ""
        if cond:
            continue
        if len(lower) == 1 and lower[0] == cp:
            special_lower.pop(cp, None)
        else:
            special_lower[cp] = lower
        if len(upper) == 1 and upper[0] == cp:
            special_upper.pop(cp, None)
        else:
            special_upper[cp] = upper
    return special_lower, special_upper


def esc(cps):
    """Escape a code-point sequence for a Zig string literal: ASCII passes
    through, everything else becomes UTF-8 \\xNN escapes (which Zig decodes
    back to the same bytes)."""
    out = []
    for cp in cps:
        if cp < 0x80:
            out.append(chr(cp))
        elif cp <= 0x7FF:
            out.append("\\x%02X\\x%02X" % (0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)))
        elif cp <= 0xFFFF:
            out.append(
                "\\x%02X\\x%02X\\x%02X"
                % (0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
            )
        else:
            out.append(
                "\\x%02X\\x%02X\\x%02X\\x%02X"
                % (
                    0xF0 | (cp >> 18),
                    0x80 | ((cp >> 12) & 0x3F),
                    0x80 | ((cp >> 6) & 0x3F),
                    0x80 | (cp & 0x3F),
                )
            )
    return "".join(out)


def main():
    simple = parse_unicode_data(ucd_path("UnicodeData.txt"))
    cased, ignorable, xid_start, xid_continue = parse_derived_core_properties(ucd_path("DerivedCoreProperties.txt"))
    sl, su = parse_special_casing(ucd_path("SpecialCasing.txt"))
    # Only emit special entries whose expansion differs from the simple mapping.
    sl = {cp: cps for cp, cps in sl.items() if cps != [simple.get(cp, (cp, cp))[1]] or len(cps) != 1}
    su = {cp: cps for cp, cps in su.items() if cps != [simple.get(cp, (cp, cp))[0]] or len(cps) != 1}

    print("//! Unicode 16.0.0 lexical tables (StdLib §5 full default case")
    print("//! conversion for `string.lower` / `string.upper`; UAX #31 XID")
    print("//! identifier classes for the Core lexer).")
    print("//!")
    print("//! GENERATED FILE — do not edit by hand. Regenerate with:")
    print("//!")
    print("//!     python3 tools/gen_unicode_case.py > src/unicode_case.zig")
    print("//!")
    print("//! from the pinned Unicode %s UCD files in tools/ucd/:" % VERSION)
    print("//! UnicodeData.txt, SpecialCasing.txt, and")
    print("//! DerivedCoreProperties.txt.")
    print("//!")
    print("//! `simple` holds the one-to-one (simple) case mappings of")
    print("//! UnicodeData.txt; `special_lower` / `special_upper` hold the")
    print("//! unconditional full (expansion) mappings of SpecialCasing.txt")
    print("//! that differ from the simple mapping; `cased_ranges` holds the")
    print("//! Cased property and `ignorable_ranges` the Case_Ignorable")
    print("//! property (DerivedCoreProperties.txt), compressed into inclusive")
    print("//! [lo, hi] ranges and used by the Final_Sigma context (Unicode")
    print("//! Standard §3.13 Default Case Algorithms); `xid_start_ranges` /")
    print("//! `xid_continue_ranges` hold the UAX #31 identifier classes.")
    print("//!")
    print("//! © 2024 Unicode®, Inc. — Unicode data files and software")
    print("//! licensed under the Unicode License v3 (https://www.unicode.org/license.txt).")
    print()
    print("pub const version = \"%s\";" % VERSION)
    print()
    print("/// One simple (one-to-one) case mapping.")
    print("pub const Simple = struct {")
    print("    cp: u32,")
    print("    upper: u32,")
    print("    lower: u32,")
    print("};")
    print()
    print("/// Sorted by `cp`; binary-search with `lookupSimple`.")
    print("pub const simple = [_]Simple{")
    for cp in sorted(simple):
        u, l = simple[cp]
        print("    .{ .cp = 0x%X, .upper = 0x%X, .lower = 0x%X }," % (cp, u, l))
    print("};")
    print()
    print("/// One unconditional full (expansion) mapping: cp -> UTF-8 bytes.")
    print("pub const Special = struct {")
    print("    cp: u32,")
    print("    expansion: []const u8,")
    print("};")
    print()
    print("/// Sorted by `cp`; binary-search with `lookupSpecialLower`.")
    print("pub const special_lower = [_]Special{")
    for cp in sorted(sl):
        print('    .{ .cp = 0x%X, .expansion = "%s" },' % (cp, esc(sl[cp])))
    print("};")
    print()
    print("/// Sorted by `cp`; binary-search with `lookupSpecialUpper`.")
    print("pub const special_upper = [_]Special{")
    for cp in sorted(su):
        print('    .{ .cp = 0x%X, .expansion = "%s" },' % (cp, esc(su[cp])))
    print("};")
    print()
    print("/// The Cased property as inclusive [lo, hi] ranges, sorted by")
    print("/// `lo`. Used by the Final_Sigma casing context.")
    print("pub const cased_ranges = [_][2]u32{")
    for lo, hi in cased:
        print("    .{ 0x%X, 0x%X }," % (lo, hi))
    print("};")
    print()
    print("/// The Case_Ignorable property as inclusive [lo, hi] ranges,")
    print("/// sorted by `lo`. Skipped when resolving the Final_Sigma")
    print("/// context (SpecialCasing.txt: a cased character followed by")
    print("/// zero or more case-ignorable characters).")
    print("pub const ignorable_ranges = [_][2]u32{")
    for lo, hi in ignorable:
        print("    .{ 0x%X, 0x%X }," % (lo, hi))
    print("};")
    print()
    print("/// The XID_Start property (UAX #31) as inclusive [lo, hi] ranges,")
    print("/// sorted by `lo`. Identifier start characters.")
    print("pub const xid_start_ranges = [_][2]u32{")
    for lo, hi in xid_start:
        print("    .{ 0x%X, 0x%X }," % (lo, hi))
    print("};")
    print()
    print("/// The XID_Continue property (UAX #31) as inclusive [lo, hi] ranges,")
    print("/// sorted by `lo`. Identifier continuation characters.")
    print("pub const xid_continue_ranges = [_][2]u32{")
    for lo, hi in xid_continue:
        print("    .{ 0x%X, 0x%X }," % (lo, hi))
    print("};")
    print()
    print("/// True when `cp` has the Cased property.")
    print("pub fn isCased(cp: u21) bool {")
    print("    return inRanges(&cased_ranges, cp);")
    print("}")
    print()
    print("/// True when `cp` has the Case_Ignorable property.")
    print("pub fn isCaseIgnorable(cp: u21) bool {")
    print("    return inRanges(&ignorable_ranges, cp);")
    print("}")
    print()
    print("/// True when `cp` may start an identifier (XID_Start, UAX #31).")
    print("/// ASCII `\"_\"` is allowed separately by the lexer.")
    print("pub fn isXidStart(cp: u21) bool {")
    print("    return inRanges(&xid_start_ranges, cp);")
    print("}")
    print()
    print("/// True when `cp` may continue an identifier (XID_Continue, UAX #31).")
    print("/// ASCII `\"_\"` is allowed separately by the lexer.")
    print("pub fn isXidContinue(cp: u21) bool {")
    print("    return inRanges(&xid_continue_ranges, cp);")
    print("}")
    print()
    print("fn inRanges(ranges: []const [2]u32, cp: u21) bool {")
    print("    const c: u32 = cp;")
    print("    for (ranges) |r| {")
    print("        if (c < r[0]) return false;")
    print("        if (c <= r[1]) return true;")
    print("    }")
    print("    return false;")
    print("}")
    print()
    print("fn search(comptime T: type, table: []const T, cp: u32) ?T {")
    print("    var lo: usize = 0;")
    print("    var hi: usize = table.len;")
    print("    while (lo < hi) {")
    print("        const mid = lo + (hi - lo) / 2;")
    print("        if (table[mid].cp < cp) lo = mid + 1 else hi = mid;")
    print("    }")
    print("    if (lo >= table.len or table[lo].cp != cp) return null;")
    print("    return table[lo];")
    print("}")
    print()
    print("/// The simple mapping of `cp`, or null when it maps to itself.")
    print("pub fn lookupSimple(cp: u21) ?Simple {")
    print("    return search(Simple, &simple, cp);")
    print("}")
    print()
    print("/// The unconditional full lowercase expansion of `cp`, or null.")
    print("pub fn lookupSpecialLower(cp: u21) ?Special {")
    print("    return search(Special, &special_lower, cp);")
    print("}")
    print()
    print("/// The unconditional full uppercase expansion of `cp`, or null.")
    print("pub fn lookupSpecialUpper(cp: u21) ?Special {")
    print("    return search(Special, &special_upper, cp);")
    print("}")
    print()
    print("test \"tables are sorted by cp / lo\" {")
    print("    for (simple[1..], 0..) |m, i| try std.testing.expect(simple[i].cp < m.cp);")
    print("    for (special_lower[1..], 0..) |m, i| try std.testing.expect(special_lower[i].cp < m.cp);")
    print("    for (special_upper[1..], 0..) |m, i| try std.testing.expect(special_upper[i].cp < m.cp);")
    print("    for (cased_ranges[1..], 0..) |r, i| try std.testing.expect(cased_ranges[i][1] < r[0]);")
    print("    for (ignorable_ranges[1..], 0..) |r, i| try std.testing.expect(ignorable_ranges[i][1] < r[0]);")
    print("    for (xid_start_ranges[1..], 0..) |r, i| try std.testing.expect(xid_start_ranges[i][1] < r[0]);")
    print("    for (xid_continue_ranges[1..], 0..) |r, i| try std.testing.expect(xid_continue_ranges[i][1] < r[0]);")
    print("}")
    print()
    print("test \"Final_Sigma context spot checks\" {")
    print("    // Combining acute is Case_Ignorable, µ is Other_Lowercase Cased,")
    print("    // apostrophe and middle dot are Case_Ignorable, Σ is Cased.")
    print("    try std.testing.expect(isCaseIgnorable(0x301));")
    print("    try std.testing.expect(!isCased(0x301));")
    print("    try std.testing.expect(isCased(0x3A3));")
    print("    try std.testing.expect(isCased(0xB5));")
    print("    try std.testing.expect(isCaseIgnorable(0x27));")
    print("    try std.testing.expect(isCaseIgnorable(0xB7));")
    print("    // XID spot checks: Greek letters are identifier characters,")
    print("    // combining marks continue but do not start, emoji do neither.")
    print("    try std.testing.expect(isXidStart(0x3BA)); // κ")
    print("    try std.testing.expect(isXidContinue(0x3BA));")
    print("    try std.testing.expect(!isXidStart(0x301)); // combining acute")
    print("    try std.testing.expect(isXidContinue(0x301));")
    print("    try std.testing.expect(!isXidStart(0x1F600)); // emoji")
    print("    try std.testing.expect(!isXidContinue(0x1F600));")
    print("    try std.testing.expect(isXidContinue('0')); // digits continue")
    print("    try std.testing.expect(!isXidStart('0'));")
    print("}")
    print()
    print("const std = @import(\"std\");")

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as e:
        # Missing/mis-downloaded UCD files (OSError) or malformed lines
        # (ValueError from int()) fail with a clean message, not a traceback.
        sys.exit("gen_unicode_case: %s" % e)
