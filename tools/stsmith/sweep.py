#!/usr/bin/env python3
"""Sweep stsmith seeds through `stilla --run` and report per-seed results.

Generates one self-checking Stilla program per seed with stsmith, runs it
under `stilla --run`, and reports which seeds pass, which panic (assert
failure => the generator's model disagrees with the runtime), and which
fail to generate. Failing programs are kept under a temp directory so each
regression can be reproduced. Exits nonzero if any seed fails.

Usage:
    zig build                          # build zig-out/bin/stsmith and stilla
    python3 tools/stsmith/sweep.py
    python3 tools/stsmith/sweep.py --seed 0-100 --statements 120
    python3 tools/stsmith/sweep.py --seed 0-100 --drop-hook
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__)) + "/../.."
BIN = ROOT + "/zig-out/bin"


def run(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def main():
    ap = argparse.ArgumentParser(
        description="Sweep stsmith seeds through stilla --run.")
    ap.add_argument("--seed", default="0-99", metavar="START-END",
                    help="seed range as 'START-END' (inclusive)")
    ap.add_argument("--stsmith", default=BIN + "/stsmith")
    ap.add_argument("--stilla", default=BIN + "/stilla")
    ap.add_argument("--statements", type=int)
    ap.add_argument("--funcs", type=int)
    ap.add_argument("--max-depth", type=int)
    ap.add_argument("--drop-hook", action="store_true",
                    help="pass --drop-hook to stsmith (unique drop-hook type "
                         "with borrow/move access patterns)")
    args = ap.parse_args()

    try:
        start_s, end_s = args.seed.split("-")
        start, end = int(start_s), int(end_s)
    except ValueError:
        ap.error(f"invalid --seed {args.seed!r}; expected 'START-END'")
    if start > end:
        ap.error("start seed greater than end seed")

    for tool, path in (("stsmith", args.stsmith), ("stilla", args.stilla)):
        if not os.path.isfile(path):
            sys.exit(f"error: {tool} not found at {path}; run `zig build` first")

    keep = tempfile.mkdtemp(prefix="stsmith-sweep-")
    fails = []
    total = end - start + 1
    for seed in range(start, end + 1):
        prog = f"{keep}/seed{seed}.st"
        gen = [args.stsmith, "--seed", str(seed), "--output", prog]
        if args.statements is not None:
            gen += ["--statements", str(args.statements)]
        if args.funcs is not None:
            gen += ["--funcs", str(args.funcs)]
        if args.max_depth is not None:
            gen += ["--max-depth", str(args.max_depth)]
        if args.drop_hook:
            gen += ["--drop-hook"]
        rc, out, err = run(gen)
        if rc != 0:
            print(f"seed {seed}: GENERATION FAILED")
            fails.append(seed)
            continue
        rc, out, err = run([args.stilla, "--run", prog])
        if rc == 0:
            continue
        tail = (err or out).strip().splitlines()
        print(f"seed {seed}: FAILED (rc={rc})")
        for line in tail[-3:]:
            print(f"    {line}")
        fails.append(seed)

    print(f"=== {total} seeds: {total - len(fails)} passed, "
          f"{len(fails)} failed ===")
    if fails:
        print(f"failing seeds: {fails}")
        print(f"failing programs kept in: {keep}")
        return 1
    try:
        shutil.rmtree(keep)
    except OSError:
        pass  # best-effort cleanup; the sweep result is already reported
    return 0


if __name__ == "__main__":
    sys.exit(main())
